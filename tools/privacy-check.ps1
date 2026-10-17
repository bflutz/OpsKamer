#Requires -Version 7.0
<#
.SYNOPSIS
    Fails if anything about to be published looks private: secrets, private IPs, personal emails or
    home-folder paths, tracked local files, non-noreply commit identities, or any term in an optional
    local denylist.

.DESCRIPTION
    Scans every file git would publish (tracked + untracked-but-not-ignored), all commit messages
    and all commit author/committer emails.

    Optional local denylist: one literal term per line in .local/denylist.txt (or -Denylist <path>).
    It is meant for names you must never publish (clients, people, machines, private repos), so it
    lives OUTSIDE version control. CI runs without it; run it locally before every push (the
    pre-push hook in tools/hooks does that).

    A line containing the marker  privacy-check: allow  is skipped (use sparingly, e.g. for the
    pattern definitions in this file).

.EXAMPLE
    pwsh -NoProfile -File tools/privacy-check.ps1
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [string]$Denylist = '',
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $Root

if (-not $Denylist) { $Denylist = Join-Path $Root '.local/denylist.txt' }

# --- generic rules: safe to publish, run everywhere ------------------------------------------
$rules = @(  # privacy-check: allow
    @{ id = 'secret.anthropic';  re = 'sk-ant-[A-Za-z0-9_\-]{16,}' }                         # privacy-check: allow
    @{ id = 'secret.openai';     re = '\bsk-(proj-)?[A-Za-z0-9]{32,}' }                        # privacy-check: allow
    @{ id = 'secret.github';     re = '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}' } # privacy-check: allow
    @{ id = 'secret.slack';      re = '\bxox[abprs]-[A-Za-z0-9\-]{10,}' }                      # privacy-check: allow
    @{ id = 'secret.aws';        re = '\bAKIA[0-9A-Z]{16}\b' }                                 # privacy-check: allow
    @{ id = 'secret.privatekey'; re = '-----BEGIN [A-Z ]*PRIVATE KEY-----' }                   # privacy-check: allow
    @{ id = 'secret.jwt';        re = '\beyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.' }       # privacy-check: allow
    @{ id = 'net.private-ip';    re = '\b(10\.\d{1,3}|192\.168|172\.(1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b' } # privacy-check: allow
    @{ id = 'net.tailscale-ip';  re = '\b100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b' } # privacy-check: allow
    @{ id = 'path.windows-home'; re = '(?i)[A-Z]:\\+Users\\+(?!(<|\$|%|\{|USERNAME|you\b|Public\b|Default\b|runneradmin\b))[A-Za-z0-9._\-]+' } # privacy-check: allow
    @{ id = 'path.mac-home';     re = '/Users/(?!(<|\$|\{|you\b|Shared\b|runner\b|USERNAME\b))[A-Za-z0-9._\-]+' } # privacy-check: allow
    @{ id = 'path.linux-home';   re = '/home/(?!(<|\$|\{|you\b|runner\b|USERNAME\b|linuxbrew\b))[A-Za-z0-9._\-]+' } # privacy-check: allow
    @{ id = 'email';             re = '(?i)\b[A-Z0-9._%+\-]+@(?!(users\.noreply\.github\.com\b|github\.com\b|example\.[a-z]+\b|[a-z0-9.\-]+\.(example|invalid|test)\b))[A-Z0-9.\-]+\.[A-Z]{2,}\b' } # privacy-check: allow
)
# Not people: ssh remotes, URL user-info on github.com (test fixtures), reserved example domains.
$emailAllow = '^(git@github\.com|noreply@anthropic\.com)$'

$findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding([string]$Where, [string]$Rule, [string]$Text) {
    $t = $Text.Trim()
    if ($t.Length -gt 140) { $t = $t.Substring(0, 140) + '...' }
    $findings.Add([PSCustomObject]@{ where = $Where; rule = $Rule; text = $t })
}

# --- local denylist: literal terms, word-bounded, case-insensitive -------------------------
$deny = @()
if (Test-Path -LiteralPath $Denylist) {
    $deny = @(Get-Content -LiteralPath $Denylist -Encoding UTF8 | ForEach-Object { $_.Trim() } |
              Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object {
                  @{ term = $_; re = [regex]::new('(?<![A-Za-z0-9])' + [regex]::Escape($_) + '(?![A-Za-z0-9])', 'IgnoreCase') }
              })
}

function Test-Line([string]$Where, [string]$Line) {
    if ($Line -match 'privacy-check: allow') { return }
    foreach ($r in $rules) {
        foreach ($m in [regex]::Matches($Line, $r.re)) {
            if ($r.id -eq 'email' -and $m.Value -match $emailAllow) { continue }
            Add-Finding $Where $r.id $Line
            break
        }
    }
    foreach ($d in $deny) {
        if ($d.re.IsMatch($Line)) { Add-Finding $Where "denylist:$($d.term)" $Line }
    }
}

# --- what would be published --------------------------------------------------------------
$tracked   = @(git ls-files 2>$null)
$untracked = @(git ls-files --others --exclude-standard 2>$null)
$files = @($tracked + $untracked | Where-Object { $_ } | Sort-Object -Unique)

foreach ($f in $files) {
    if ($f -match '(^|/)\.local(/|$)') { Add-Finding $f 'tracked.local' 'a .local file is tracked or would be committed'; continue }
    if ($f -match '(^|/)(\.env(\..+)?|auth\.json|[^/]*\.credentials[^/]*)$' -and $f -notmatch '\.env\.example$') {
        Add-Finding $f 'tracked.secret-file' 'secret-looking file would be committed'; continue
    }
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }   # deleted in the working tree
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $f))
    if ($bytes.Length -gt 0 -and ([Array]::IndexOf($bytes, [byte]0) -ge 0)) { continue }   # binary
    # File names themselves can leak (e.g. a client logo file).
    Test-Line "$f (name)" $f
    $n = 0
    foreach ($line in ([System.Text.Encoding]::UTF8.GetString($bytes) -split "`r?`n")) {
        $n++
        Test-Line "${f}:$n" $line
    }
}

# --- history: identities and messages ---------------------------------------------------------
$hasCommits = $false
git rev-parse --verify --quiet HEAD *> $null
if ($LASTEXITCODE -eq 0) { $hasCommits = $true }
if ($hasCommits) {
    # Allowed: personal GitHub noreply addresses, and GitHub's own identity (noreply@github.com), which
    # GitHub uses for the test merge of every pull request and for merges made on the website. It names
    # no person, so it leaks nothing.
    foreach ($row in @(git log --all --format='%h%x09%ae%x09%ce')) {
        $p = $row -split "`t"
        foreach ($e in $p[1], $p[2]) {
            if ($e -notmatch '@users\.noreply\.github\.com$' -and $e -ne 'noreply@github.com') { Add-Finding "commit $($p[0])" 'identity' "author/committer email is not a GitHub noreply address: $e" }
        }
    }
    foreach ($row in @(git log --all --format='%h%x09%B%x1e')) {
        if (-not $row.Trim()) { continue }
        $h = ($row.Trim() -split "`t", 2)[0]
        foreach ($line in (($row -split "`t", 2)[-1] -split "`r?`n")) { Test-Line "commit $h (message)" $line }
    }
}
# The identity the NEXT commit will use.
$nextEmail = (git config user.email) 2>$null
if ($nextEmail -and $nextEmail -notmatch '@users\.noreply\.github\.com$') {
    Add-Finding 'git config user.email' 'identity' "next commits would use $nextEmail; set a GitHub noreply address in this repo"
}

# --- report -----------------------------------------------------------------------------------
$mode = if ($deny.Count) { "generic rules + $($deny.Count) local denylist terms" } else { 'generic rules only (no local denylist found)' }
if ($findings.Count -eq 0) {
    if (-not $Quiet) { Write-Host "privacy-check: PASS - $($files.Count) files, $mode" -ForegroundColor Green }
    exit 0
}
Write-Host "privacy-check: FAIL - $($findings.Count) finding(s) in $($files.Count) files ($mode)" -ForegroundColor Red
$findings | Sort-Object where | Format-Table -AutoSize -Wrap where, rule, text | Out-String -Width 260 | Write-Host
exit 1
