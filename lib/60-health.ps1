# 60-health.ps1 - Environment assertions + preflight
# Split from Mission-Centre.ps1. Dot-sourced by the root script; relies on the
# script-scoped config globals ($ScanRoot, $Pi*, etc.) defined there.

function Assert-DirExists {
    param([string]$Path)
    if (-not (Test-Path $Path -PathType Container)) {
        Write-Host "  ERROR: Directory not found: $Path" -ForegroundColor Red
        return $false
    }
    return $true
}

function Assert-CmdExists {
    param([string]$Cmd)
    if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
        Write-Host "  ERROR: '$Cmd' is not in PATH. Is it installed?" -ForegroundColor Red
        return $false
    }
    return $true
}

function Invoke-JigCommandCheck {
    param([string]$ProjectPath, [string]$Label, [scriptblock]$Script)
    # Function-scoped EAP (auto-restored): under the root script's Stop policy, 2>&1 on a native
    # command in PS 5.1 turns ANY stderr line into a terminating RemoteException - even when the
    # command exits 0 - which would misreport a healthy jig profile as a preflight failure.
    # The exit code below is the real gate.
    $ErrorActionPreference = 'Continue'
    $prev = Get-Location
    try {
        Set-Location -LiteralPath $ProjectPath
        $output = & $Script 2>&1
        # $LASTEXITCODE is visible across scopes; treat an unknown code as failure (safer for a gate).
        $code = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 1 }
        return [PSCustomObject]@{
            label  = $Label
            ok     = ($code -eq 0)
            output = ($output | Out-String).Trim()
        }
    } catch {
        return [PSCustomObject]@{
            label  = $Label
            ok     = $false
            output = [string]$_
        }
    } finally {
        Set-Location $prev
    }
}

$script:PreflightCache = @{}

function Invoke-ProfilePreflight {
    param([string]$ProjectPath, [string]$ProfileName, [switch]$Force)
    if ($PreflightMode -eq 'off') { return $true }
    if (-not (Assert-DirExists $ProjectPath)) { return $false }
    if (-not (Get-Command 'jig' -ErrorAction SilentlyContinue)) {
        Write-Host "  WARN: jig is not in PATH; profile preflight skipped." -ForegroundColor Yellow
        return ($PreflightMode -ne 'block')
    }

    # Preflight spawns jig twice; a profile that validated once this session will
    # validate again, so cache passes per profile+path. Only successes are cached
    # (a failed profile can be fixed and retried immediately), and the explicit
    # [P] menu action passes -Force to re-check on demand.
    $cacheKey = "$ProfileName|$ProjectPath"
    if (-not $Force -and $script:PreflightCache.ContainsKey($cacheKey)) {
        Write-Host "  Preflight OK (cached this session)." -ForegroundColor DarkGreen
        return $true
    }

    Write-Host "  Preflight: validating Jig profile '$ProfileName' ..." -ForegroundColor DarkGray
    $checks = @(
        (Invoke-JigCommandCheck $ProjectPath 'jig profiles validate' { & jig profiles validate $ProfileName }),
        (Invoke-JigCommandCheck $ProjectPath 'jig run --dry-run' { & jig run $ProfileName --dry-run })
    )
    $failed = @($checks | Where-Object { -not $_.ok })
    if ($failed.Count -eq 0) {
        Write-Host '  Preflight OK.' -ForegroundColor DarkGreen
        $script:PreflightCache[$cacheKey] = $true
        return $true
    }

    foreach ($f in $failed) {
        Write-Host "  WARN: $($f.label) failed." -ForegroundColor Yellow
        if ($f.output) {
            $snippet = $f.output
            if ($snippet.Length -gt 500) { $snippet = $snippet.Substring(0, 500) + '...' }
            Write-Host "        $snippet" -ForegroundColor DarkYellow
        }
    }
    if ($PreflightMode -eq 'block') {
        Write-Host '  Launch blocked by preflightMode=block.' -ForegroundColor Red
        return $false
    }
    Write-Host '  Continuing because preflightMode=warn.' -ForegroundColor Yellow
    return $true
}

function Get-PluginCacheDrift {
    # Pure-ish: for every installed Claude Code plugin whose marketplace source is a
    # local directory, compare the source's skills/ against the installed cache copy.
    # Returns one object per drifted plugin: @{ plugin; missingInCache[]; sourceNewer }.
    # A cache that was installed once and never refreshed silently drops every skill
    # added to the source afterwards (this happened: forge frozen for 3 months).
    param([string]$ClaudeDir = (Join-Path $HOME '.claude'))
    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $settingsPath  = Join-Path $ClaudeDir 'settings.json'
        $installedPath = Join-Path $ClaudeDir (Join-Path 'plugins' 'installed_plugins.json')
        if (-not (Test-Path $settingsPath) -or -not (Test-Path $installedPath)) { return @() }
        $settings  = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $installed = Get-Content $installedPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $markets   = Get-OptionalProperty $settings 'extraKnownMarketplaces' $null
        if ($null -eq $markets) { return @() }

        foreach ($entry in $installed.plugins.PSObject.Properties) {
            # key is "name@marketplace"; only directory-sourced marketplaces can be diffed locally
            $marketName = ($entry.Name -split '@')[-1]
            $market = Get-OptionalProperty $markets $marketName $null
            if ($null -eq $market) { continue }
            $source = Get-OptionalProperty $market 'source' $null
            if ($null -eq $source -or (Get-OptionalProperty $source 'source' '') -ne 'directory') { continue }
            $srcDir = Get-OptionalProperty $source 'path' ''
            $records = @($entry.Value)
            foreach ($rec in $records) {
                $cacheDir = Get-OptionalProperty $rec 'installPath' ''
                if (-not $srcDir -or -not $cacheDir) { continue }
                $srcSkills   = Join-Path $srcDir 'skills'
                $cacheSkills = Join-Path $cacheDir 'skills'
                if (-not (Test-Path $srcSkills -PathType Container)) { continue }
                $srcNames   = @(Get-ChildItem $srcSkills -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
                $cacheNames = @(Get-ChildItem $cacheSkills -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
                $missing = @($srcNames | Where-Object { $cacheNames -notcontains $_ })
                # Newest content mtime catches in-place skill edits that keep the same names.
                $srcNewest   = (Get-ChildItem $srcSkills -Recurse -File -ErrorAction SilentlyContinue | Measure-Object LastWriteTimeUtc -Maximum).Maximum
                $cacheNewest = (Get-ChildItem $cacheSkills -Recurse -File -ErrorAction SilentlyContinue | Measure-Object LastWriteTimeUtc -Maximum).Maximum
                $sourceNewer = ($null -ne $srcNewest -and $null -ne $cacheNewest -and $srcNewest -gt $cacheNewest.AddDays(1))
                if ($missing.Count -gt 0 -or $sourceNewer) {
                    $results.Add([PSCustomObject]@{
                        plugin         = $entry.Name
                        missingInCache = $missing
                        sourceNewer    = $sourceNewer
                    })
                }
            }
        }
    } catch { return @() }
    return $results.ToArray()
}

function Test-ForgeInstalled {
    # Is the Forge plugin (jdforsythe/forge) installed in Claude Code? Kickoffs name its mission-planner
    # skill only when it is. $McClaudeDir overrides ~/.claude (the test suite points it at a fixture).
    param([string]$ClaudeDir = '')
    if (-not $ClaudeDir) {
        $ClaudeDir = Get-Variable -Name McClaudeDir -ValueOnly -ErrorAction SilentlyContinue
        if (-not $ClaudeDir) { $ClaudeDir = Join-Path $(if ($HOME) { $HOME } else { $env:USERPROFILE }) '.claude' }
    }
    $f = Join-Path (Join-Path $ClaudeDir 'plugins') 'installed_plugins.json'
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $false }
    try {
        $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
        $plugins = Get-OptionalProperty $j 'plugins' $null
        if ($null -eq $plugins) { return $false }
        foreach ($p in $plugins.PSObject.Properties) { if ((($p.Name -split '@')[0]) -eq 'forge') { return $true } }
    } catch { }
    return $false
}

function Get-JigProfileKeyWarnings {
    # Installed profiles that set 'permission-mode:' (hyphen). Jig reads only 'permission_mode' from YAML
    # (the hyphen form is its command-line flag), so that setting is silently ignored. Returns file names.
    param([string]$InstalledDir)
    if (-not (Test-Path -LiteralPath $InstalledDir -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $InstalledDir -Filter '*.yaml' -File -ErrorAction SilentlyContinue |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match '(?m)^\s*permission-mode\s*:' } |
        ForEach-Object { $_.Name })
}

function Get-ProfileDriftKey {
    # Pure: identifies one particular drift (which profiles, which status, what the installed copies hold),
    # so a declined update is not asked again until something changes.
    param([object[]]$Stale, [string]$InstalledDir)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $parts = foreach ($d in @($Stale | Sort-Object name)) {
            $f = Join-Path $InstalledDir "$($d.name).yaml"
            $h = if (Test-Path -LiteralPath $f -PathType Leaf) { [System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($f))) } else { '-' }
            "$($d.name)=$($d.status)=$h"
        }
        return (@($parts) -join ';')
    } finally { $sha.Dispose() }
}

function Invoke-StartupDriftCheck {
    # Ambient drift detection, run once per launch before the menu. Cheap checks
    # only (file compares + dir listings - no doctors, no subprocess spawns).
    # Profile drift immediately offers the [G] update flow; plugin cache drift
    # warns with the fix (a stale cache can only be refreshed from a Claude
    # session via /plugin update). Silent when everything is clean.
    # Profiles only matter when Jig is installed; without it, say nothing about them.
    $stale = @()
    $keyWarnings = @()
    if (Get-Command 'jig' -ErrorAction SilentlyContinue) {
        $installedDir = Get-GlobalJigProfilesDir
        $stale = @(Get-JigProfileDrift $BundledJigProfilesDir $installedDir | Where-Object { $_.status -ne 'identical' })
        $keyWarnings = @(Get-JigProfileKeyWarnings $installedDir)
    }
    foreach ($k in $keyWarnings) {
        Write-Host ''
        Write-Host "  Jig profile $k sets 'permission-mode:', which Jig ignores (it reads 'permission_mode:')." -ForegroundColor Yellow
        Write-Host "  Rename the key in $(Join-Path (Get-GlobalJigProfilesDir) $k) to apply that setting." -ForegroundColor DarkGray
    }
    if ($stale.Count -gt 0) {
        # Ask once per drift: a declined update is remembered until the drift changes, so the prompt does
        # not come back on every start. Default No; updates back up the installed copy first.
        $driftKey = Get-ProfileDriftKey $stale (Get-GlobalJigProfilesDir)
        $declinedFile = Join-Path $MissionStateDir 'profile-drift-declined.txt'
        $declined = if (Test-Path -LiteralPath $declinedFile) { (Get-Content -LiteralPath $declinedFile -Raw).Trim() } else { '' }
        if ($declined -ne $driftKey) {
            Write-Host ''
            Write-Host '  Starter profiles differ from the bundled versions:' -ForegroundColor Yellow
            foreach ($d in $stale) { Write-Host "   $($d.name): $($d.status)" -ForegroundColor Yellow }
            if (Read-YesNo '  Review and update them now? (your copies are backed up first)' 'N') {
                Install-StarterJigProfiles
            } else {
                if (-not (Test-Path -LiteralPath $MissionStateDir)) { New-Item -ItemType Directory -Path $MissionStateDir -Force | Out-Null }
                Set-Content -LiteralPath $declinedFile -Value $driftKey -Encoding UTF8
                Write-Host '  Kept yours. Not asked again until they change; [H] shows the drift, [G] updates.' -ForegroundColor DarkGray
            }
        } else {
            $stale = @()   # already declined: no pause below
        }
    }

    $pluginDrift = @(Get-PluginCacheDrift)
    foreach ($p in $pluginDrift) {
        $bits = @()
        if (@($p.missingInCache).Count -gt 0) { $bits += "cache missing: $($p.missingInCache -join ', ')" }
        if ($p.sourceNewer) { $bits += 'source newer than cache' }
        Write-Host ''
        Write-Host "  Plugin cache stale for $($p.plugin) ($($bits -join '; '))." -ForegroundColor Yellow
        Write-Host "  Run /plugin update $((($p.plugin) -split '@')[0]) in a Claude session to refresh." -ForegroundColor DarkGray
    }

    if ($stale.Count -gt 0 -or $pluginDrift.Count -gt 0 -or $keyWarnings.Count -gt 0) {
        Read-Host '  Press Enter to continue'
    }
}

# Lowest patched Node.js release per supported line. pi, pii and the Claude Bridge all
# run on the system node and fetch() remote responses, which decode Brotli on their own.
# Raise these when Node ships a security release; a line not listed here is end of life.
$NodeSecurityFloor = [ordered]@{
    '22' = '22.23.4'   # CVE-2026-111497 Brotli decoder RCE, 2026-10-21 release
    '24' = '24.22.1'
    '26' = '26.12.1'
}
$NodeSecurityAdvisory = 'CVE-2026-111497, Brotli decoder RCE'

function Get-NodeSecurityStatus {
    # Pure: classify a `node --version` string against $NodeSecurityFloor.
    # status: ok | vulnerable | eol | unknown. A major newer than every listed line is
    # treated as ok (released after the advisory), so the table only needs raising.
    param([string]$Version, $Floor = $NodeSecurityFloor)
    $st = [PSCustomObject]@{ version = [string]$Version; status = 'unknown'; minimum = ''; detail = '' }
    if ($Version -notmatch '^\s*v?(\d+)\.(\d+)\.(\d+)') { $st.detail = 'cannot read the version'; return $st }
    $v = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
    $major = [string]$Matches[1]
    $majors = @($Floor.Keys | ForEach-Object { [int]$_ })
    if ($Floor.Contains($major)) {
        $st.minimum = [string]$Floor[$major]
        if ($v -ge [version]$st.minimum) { $st.status = 'ok' }
        else { $st.status = 'vulnerable'; $st.detail = "below $($st.minimum) ($NodeSecurityAdvisory)" }
    } elseif ([int]$major -gt ($majors | Measure-Object -Maximum).Maximum) {
        $st.status = 'ok'
    } else {
        $st.status = 'eol'
        $st.detail = "Node $major is out of support and gets no security fixes"
    }
    return $st
}

function Get-NodeUpdateHint {
    # No fixed winget id: installs show up as OpenJS.NodeJS, .LTS or .22 depending on how they came in.
    if ($MissionIsWindows) { return 'the installer from nodejs.org, or winget upgrade on the id `winget list node` shows' }
    if ($MissionIsMacOS)   { return 'brew upgrade node (or the installer from nodejs.org)' }
    return 'your package manager or nodejs.org'
}

function Get-InstalledNodeSecurityStatus {
    # $null when node is not on PATH: nothing to warn about.
    $node = Get-Command 'node' -ErrorAction SilentlyContinue
    if (-not $node) { return $null }
    $out = try { [string](& $node.Source --version 2>$null | Select-Object -First 1) } catch { '' }
    return (Get-NodeSecurityStatus $out)
}

function Invoke-StartupNodeCheck {
    # One subprocess (node --version); silent unless node needs a security update.
    $st = Get-InstalledNodeSecurityStatus
    if (-not $st -or $st.status -notin @('vulnerable', 'eol')) { return }
    Write-Host ''
    Write-Host "  Node.js $($st.version) needs a security update: $($st.detail)." -ForegroundColor Yellow
    Write-Host '  pi, pii and the Claude Bridge run on it and decode responses from remote servers.' -ForegroundColor Yellow
    Write-Host "  Update: $(Get-NodeUpdateHint); then restart the Claude Bridge." -ForegroundColor DarkGray
    Read-Host '  Press Enter to continue'
}

function Get-JqInstallHint {
    if ($MissionIsWindows) { return 'winget install jqlang.jq' }
    if ($MissionIsMacOS)   { return 'brew install jq' }
    return 'sudo apt install jq (or your distro package manager)'
}

function Invoke-EnvironmentHealth {
    Write-Host ''
    Write-Host '  Environment health' -ForegroundColor Cyan
    foreach ($cmd in @('pwsh', 'claude', 'jig', 'codex', 'git', 'npm')) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) { Write-Host "   $cmd : $($found.Source)" -ForegroundColor DarkGreen }
        else        { Write-Host "   $cmd : missing" -ForegroundColor Yellow }
    }
    # jq is optional for Mission Centre itself, but the bundled jq skill steers agents to it.
    $jq = Get-Command 'jq' -ErrorAction SilentlyContinue
    if ($jq) { Write-Host "   jq : $($jq.Source)" -ForegroundColor DarkGreen }
    else     { Write-Host "   jq : missing (optional; the jq skill expects it) - install: $(Get-JqInstallHint)" -ForegroundColor Yellow }
    $nodeSt = Get-InstalledNodeSecurityStatus
    if (-not $nodeSt) {
        Write-Host '   node : missing' -ForegroundColor Yellow
    } elseif ($nodeSt.status -in @('vulnerable', 'eol')) {
        Write-Host "   node : $($nodeSt.version) - SECURITY UPDATE NEEDED: $($nodeSt.detail) - $(Get-NodeUpdateHint)" -ForegroundColor Red
    } elseif ($nodeSt.status -eq 'unknown') {
        Write-Host "   node : $($nodeSt.detail)" -ForegroundColor Yellow
    } else {
        Write-Host "   node : $($nodeSt.version)" -ForegroundColor DarkGreen
    }

    Write-Host ''
    Write-Host '  Bundled skills (Claude Code: ~/.claude/skills, pi/Codex: ~/.agents/skills)' -ForegroundColor Cyan
    $skillRows = @(Get-BundledSkillStatus)
    if ($skillRows.Count -eq 0) {
        Write-Host '   no bundled skills found' -ForegroundColor DarkGray
    }
    foreach ($r in $skillRows) {
        $color = if ($r.status -eq 'identical') { 'DarkGreen' } else { 'Yellow' }
        $hint = switch ($r.status) { 'missing' { ' - installs on next launch, or run [G]' } 'differs' { ' - run [G] to review/update' } default { '' } }
        Write-Host "   $($r.skill) ($($r.harness)): $($r.status)$hint" -ForegroundColor $color
    }

    if ($PiEnabled) {
        # Local checks only (no registry/git fetch) so [H] stays fast; [U] does the network probe.
        Write-Host ''
        Write-Host '  pi' -ForegroundColor Cyan
        $piCmd = Get-EffectivePiCommand
        $piFound = Get-Command $piCmd -ErrorAction SilentlyContinue
        if ($piFound) { Write-Host "   launcher : $piCmd ($($piFound.Source))" -ForegroundColor DarkGreen }
        else          { Write-Host "   launcher : $piCmd - not found on PATH" -ForegroundColor Yellow }
        if ($piCmd -ne $PiCommand) {
            Write-Host "   (configured '$PiCommand' unavailable - falling back)" -ForegroundColor Yellow
        }
        Write-Host "   model    : $(Get-PiModelLabel)" -ForegroundColor DarkGray
        if ([string]::IsNullOrWhiteSpace($PiServerHealthUrl)) { Write-Host '   server   : none configured (pi.healthUrl)' -ForegroundColor DarkGray }
        elseif (Test-PiServerHealth) { Write-Host "   server   : healthy at $PiServerHealthUrl" -ForegroundColor DarkGreen }
        else                         { Write-Host "   server   : NOT answering at $PiServerHealthUrl (launch will try to start it)" -ForegroundColor Yellow }
        if ($PiForkEnabled) {
            $fs = Get-PiForkStatus
            if (-not $fs.ok) {
                Write-Host "   fork     : $($fs.detail)" -ForegroundColor Yellow
            } else {
                $build = if (Test-PiForkBuild) { 'built' } else { 'NOT BUILT' }
                $color = if ($fs.dirty -or $fs.oursDriver -or $build -ne 'built') { 'Yellow' } else { 'DarkGreen' }
                $bits = @("$build", "$($fs.behind) behind / $($fs.ahead) ahead of last fetch")
                if ($fs.dirty) { $bits += 'uncommitted tracked changes (updates blocked)' }
                if ($fs.oursDriver) { $bits += 'merge.ours.driver set (updates blocked)' }
                Write-Host "   fork     : $($bits -join ', ')" -ForegroundColor $color
            }
            $forkState = Get-ToolUpdateState
            if ($forkState.ContainsKey('git:pi-fork') -and $forkState['git:pi-fork'].note) {
                Write-Host "   pending  : $($forkState['git:pi-fork'].note) ([U] retries)" -ForegroundColor Yellow
            }
        }
        $mode = if ($ToolUpdatesEnabled) { $ToolUpdatesMode } else { 'disabled' }
        Write-Host "   updates  : $mode, every $ToolUpdateIntervalHours h ([U] checks now)" -ForegroundColor DarkGray
    }

    # Drift checks: stale installed profiles / plugin caches rot silently otherwise.
    Write-Host ''
    Write-Host '  Starter profile drift (bundled vs ~/.jig/profiles)' -ForegroundColor Cyan
    $drift = @(Get-JigProfileDrift $BundledJigProfilesDir (Get-GlobalJigProfilesDir))
    $stale = @($drift | Where-Object { $_.status -ne 'identical' })
    if ($drift.Count -eq 0) {
        Write-Host '   no bundled profiles found' -ForegroundColor DarkGray
    } elseif ($stale.Count -eq 0) {
        Write-Host "   all $($drift.Count) starter profiles up to date" -ForegroundColor DarkGreen
    } else {
        foreach ($d in $stale) {
            Write-Host "   $($d.name): $($d.status) - run [G] to review/update" -ForegroundColor Yellow
        }
    }
    foreach ($k in @(Get-JigProfileKeyWarnings (Get-GlobalJigProfilesDir))) {
        Write-Host "   ${k}: sets 'permission-mode:', which Jig ignores - rename it to 'permission_mode:'" -ForegroundColor Yellow
    }
    Write-Host "   Forge plugin (kickoff planning): $(if (Test-ForgeInstalled) { 'installed' } else { 'not installed - kickoffs plan in plain Claude Code' })" -ForegroundColor DarkGray

    $pluginDrift = @(Get-PluginCacheDrift)
    if ($pluginDrift.Count -gt 0) {
        Write-Host ''
        Write-Host '  Plugin cache drift (marketplace source vs installed cache)' -ForegroundColor Cyan
        foreach ($p in $pluginDrift) {
            if ($p.missingInCache.Count -gt 0) {
                Write-Host "   $($p.plugin): cache is missing skills: $($p.missingInCache -join ', ')" -ForegroundColor Yellow
            }
            if ($p.sourceNewer) {
                Write-Host "   $($p.plugin): source has newer content than the cache" -ForegroundColor Yellow
            }
            Write-Host "   -> run /plugin update $((($p.plugin) -split '@')[0]) in a Claude session to refresh" -ForegroundColor DarkGray
        }
    }
    if (Get-Command 'claude' -ErrorAction SilentlyContinue) {
        Write-Host ''
        Write-Host '  Running claude doctor ...' -ForegroundColor DarkGray
        try { & claude doctor } catch { Write-Host "  WARN: claude doctor failed: $_" -ForegroundColor Yellow }
    }
    if (Get-Command 'jig' -ErrorAction SilentlyContinue) {
        Write-Host ''
        Write-Host '  Running jig doctor ...' -ForegroundColor DarkGray
        try { & jig doctor } catch { Write-Host "  WARN: jig doctor failed: $_" -ForegroundColor Yellow }
    }
}
