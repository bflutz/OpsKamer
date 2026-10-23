# 65-updates.ps1 - Tool freshness checks + global npm package updates.
#
# Why this exists: agent CLIs (pi, claude, codex, gemini, amp) ship several
# releases a week, and a stale CLI silently loses access to new models. Most
# visible case: Anthropic version-gates new models server-side, so an old
# Claude Code build gets
#   "Claude Code X does not support this model; version Y or newer is required"
# for models that otherwise work fine. Keeping the toolchain current is
# therefore a correctness concern, not just hygiene.
#
# Design constraints learned the hard way:
#   * One package per `npm i -g` invocation. A single batch install aborts the
#     whole batch when any one package fails (e.g. a rotating dist-tag), so
#     batching silently skips updates the user asked for.
#   * `latest` can point at a version that is not actually fetchable yet
#     (observed with @sourcegraph/amp). Fall back to the newest concretely
#     published version instead of reporting failure.
#   * Never block a launch. Every path here is best-effort and returns control
#     even when the network, npm, or a registry is unavailable.
#   * Throttle by default. Version probes hit the network, so results are
#     cached in .mission-centre/tool-updates.json and only refreshed every
#     `intervalHours`.

function Get-ToolUpdateStatePath {
    return (Join-Path $MissionStateDir 'tool-updates.json')
}

function Get-ToolUpdateState {
    # Shape: @{ packages = @{ '<name>' = @{ lastCheck = <iso8601>; latest = '<ver>' } } }
    $path = Get-ToolUpdateStatePath
    if (-not (Test-Path $path -PathType Leaf)) { return @{} }
    try {
        $raw = Get-Content $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json
    } catch {
        # A corrupt cache must never break startup - just re-probe.
        return @{}
    }
    $map = @{}
    if ($obj -and $obj.PSObject.Properties['packages'] -and $obj.packages) {
        foreach ($prop in $obj.packages.PSObject.Properties) {
            $map[$prop.Name] = @{
                lastCheck = [string](Get-OptionalProperty $prop.Value 'lastCheck' '')
                latest    = [string](Get-OptionalProperty $prop.Value 'latest' '')
                note      = [string](Get-OptionalProperty $prop.Value 'note' '')
            }
        }
    }
    return $map
}

function Save-ToolUpdateState {
    param([hashtable]$State)
    try {
        if (-not (Test-Path $MissionStateDir -PathType Container)) {
            New-Item -ItemType Directory -Path $MissionStateDir -Force | Out-Null
        }
        $packages = [PSCustomObject]@{}
        foreach ($key in $State.Keys) {
            $entry = [PSCustomObject]@{
                lastCheck = [string]$State[$key].lastCheck
                latest    = [string]$State[$key].latest
            }
            # Optional pending-problem note (pi fork): kept only when set.
            if ($State[$key].ContainsKey('note') -and $State[$key].note) {
                $entry | Add-Member -NotePropertyName 'note' -NotePropertyValue ([string]$State[$key].note)
            }
            $packages | Add-Member -NotePropertyName $key -NotePropertyValue $entry
        }
        ([PSCustomObject]@{ packages = $packages } | ConvertTo-Json -Depth 6) |
            Set-Content -Path (Get-ToolUpdateStatePath) -Encoding UTF8
    } catch {
        # Cache write failures are non-fatal: we just re-probe next launch.
    }
}

function Test-ToolCheckDue {
    param([hashtable]$State, [string]$Package, [int]$IntervalHours)
    if ($IntervalHours -le 0) { return $true }
    if (-not $State.ContainsKey($Package)) { return $true }
    $stamp = [string]$State[$Package].lastCheck
    if ([string]::IsNullOrWhiteSpace($stamp)) { return $true }
    try { $last = [datetime]::Parse($stamp, [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { return $true }
    return ((Get-Date) - $last).TotalHours -ge $IntervalHours
}

function Compare-SemverLike {
    # Returns -1/0/1 comparing dotted numeric segments, ignoring any pre-release
    # suffix. Used only to decide "is installed behind latest"; npm itself owns
    # the real resolution.
    param([string]$A, [string]$B)
    if ($A -eq $B) { return 0 }
    $clean = {
        param($v)
        $v = ([string]$v).Trim()
        if ($v -match '^[^0-9]*([0-9]+(\.[0-9]+)*)') { return $Matches[1] }
        return ''
    }
    $ca = & $clean $A; $cb = & $clean $B
    if (-not $ca -or -not $cb) { if ($A -eq $B) { return 0 } else { return -1 } }
    $pa = @($ca -split '\.'); $pb = @($cb -split '\.')
    $len = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $na = if ($i -lt $pa.Count) { [int64]$pa[$i] } else { 0 }
        $nb = if ($i -lt $pb.Count) { [int64]$pb[$i] } else { 0 }
        if ($na -lt $nb) { return -1 }
        if ($na -gt $nb) { return 1 }
    }
    # Equal numerically but textually different (build/pre-release suffix):
    # treat as behind so rotating-build packages like amp still update.
    if ($A -ne $B) { return -1 }
    return 0
}

function Get-NpmExecutable {
    # On Windows `Get-Command npm` resolves to npm.ps1 (an ExternalScript), which
    # Start-Process cannot execute - it would fail with "not a valid application".
    # Prefer a real executable (npm.cmd / npm.exe), falling back to a sibling .cmd
    # next to the script when only the .ps1 shim is on PATH.
    $all = @(Get-Command 'npm' -All -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return '' }
    $app = @($all | Where-Object { $_.CommandType -eq 'Application' }) | Select-Object -First 1
    if ($app) { return [string]$app.Source }
    foreach ($candidate in $all) {
        $dir = Split-Path ([string]$candidate.Source) -Parent
        foreach ($leaf in @('npm.cmd', 'npm.exe')) {
            $probe = Join-Path $dir $leaf
            if (Test-Path $probe -PathType Leaf) { return $probe }
        }
    }
    return ''
}

function ConvertTo-ProcessArgumentString {
    # Start-Process joins an -ArgumentList array with bare spaces and does NOT quote, so
    # `git commit -m 'fork edit'` arrives as `-m fork edit` (message "fork", pathspec
    # "edit") and silently fails. Build one command line with the standard Windows
    # (CommandLineToArgvW) quoting rules, which .NET also applies on macOS/Linux.
    param([string[]]$ArgumentList = @())
    $parts = foreach ($a in $ArgumentList) {
        $s = [string]$a
        if ($s.Length -gt 0 -and $s -notmatch '[\s"]') { $s; continue }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $slashes = 0
        foreach ($ch in $s.ToCharArray()) {
            if ($ch -eq '\') { $slashes++; continue }
            if ($ch -eq '"') {
                # backslashes before a quote are doubled, and the quote is escaped
                [void]$sb.Append('\' * ($slashes * 2 + 1)); [void]$sb.Append('"')
            } else {
                [void]$sb.Append('\' * $slashes); [void]$sb.Append($ch)
            }
            $slashes = 0
        }
        # trailing backslashes are doubled so they don't escape the closing quote
        [void]$sb.Append('\' * ($slashes * 2)); [void]$sb.Append('"')
        $sb.ToString()
    }
    return (@($parts) -join ' ')
}

function Invoke-ProcessCapture {
    # Run an external program and return @{ ok; exit; out }. Shared by npm and git.
    # Defensive by design:
    #  * Start-Process + file redirection keeps native stderr (npm/git write progress
    #    and warnings there constantly) out of PowerShell's error stream, where
    #    $ErrorActionPreference='Stop' on Windows PowerShell 5.1 could make it fatal.
    #  * Arguments are quoted by ConvertTo-ProcessArgumentString (Start-Process itself
    #    does not quote), so values with spaces - paths, commit messages - stay whole.
    #  * -Stream skips redirection so long builds show live progress in the console.
    param(
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = '',
        [int]$TimeoutSeconds = 90,
        [switch]$Stream
    )
    $result = [PSCustomObject]@{ ok = $false; exit = $null; out = ''; err = '' }
    if ([string]::IsNullOrWhiteSpace($FilePath)) { return $result }
    $outFile = $null; $errFile = $null
    try {
        $spArgs = @{ FilePath = $FilePath; NoNewWindow = $true; PassThru = $true }
        if ($ArgumentList.Count -gt 0) { $spArgs.ArgumentList = (ConvertTo-ProcessArgumentString $ArgumentList) }
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $spArgs.WorkingDirectory = $WorkingDirectory }
        if (-not $Stream) {
            $outFile = [System.IO.Path]::GetTempFileName()
            $errFile = [System.IO.Path]::GetTempFileName()
            $spArgs.RedirectStandardOutput = $outFile
            $spArgs.RedirectStandardError  = $errFile
        }
        $proc = Start-Process @spArgs
        # Touch .Handle immediately: without an open handle, .NET can lose the exit code
        # of a process that exits quickly, leaving ExitCode $null (known Start-Process issue).
        try { [void]$proc.Handle } catch { }
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            return $result
        }
        # WaitForExit(ms) can return before the object's exit state is populated,
        # leaving ExitCode $null - which would make a plain `-ne 0` test treat
        # every successful run as a failure. The no-arg overload flushes it.
        try { $proc.WaitForExit() } catch { }
        try { $result.exit = $proc.ExitCode } catch { $result.exit = $null }
        if ($outFile -and (Test-Path $outFile)) {
            $raw = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
            if ($raw) { $result.out = $raw.Trim() }
        }
        if ($errFile -and (Test-Path $errFile)) {
            $rawErr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
            if ($rawErr) { $result.err = $rawErr.Trim() }
        }
        # Unknown exit code = failure. Treating $null as success made a CONFLICTING
        # `git merge` look successful: no abort ran and the half-merged tree was built.
        $result.ok = ($null -ne $result.exit -and $result.exit -eq 0)
        return $result
    } catch {
        return $result
    } finally {
        foreach ($f in @($outFile, $errFile)) {
            if ($f -and (Test-Path $f)) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Invoke-NpmCapture {
    # npm stdout on success, $null on failure/timeout/missing npm.
    param([string[]]$NpmArgs, [int]$TimeoutSeconds = 90, [string]$WorkingDirectory = '')
    $npmExe = Get-NpmExecutable
    if (-not $npmExe) { return $null }
    $r = Invoke-ProcessCapture -FilePath $npmExe -ArgumentList $NpmArgs -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
    if (-not $r.ok) { return $null }
    return $r.out
}

function Get-NpmLatestVersion {
    param([string]$Package)
    $v = Invoke-NpmCapture @('view', $Package, 'version')
    if ([string]::IsNullOrWhiteSpace($v)) { return '' }
    return (@($v -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()
}

function Get-NpmNewestPublishedVersion {
    # `latest` sometimes resolves to a version npm cannot actually install
    # (registry/tag propagation lag). The versions array is the ground truth.
    param([string]$Package)
    $json = Invoke-NpmCapture @('view', $Package, 'versions', '--json')
    if ([string]::IsNullOrWhiteSpace($json)) { return '' }
    try {
        $arr = $json | ConvertFrom-Json
        if ($arr -is [string]) { return $arr }
        $list = @($arr)
        if ($list.Count -eq 0) { return '' }
        return [string]$list[$list.Count - 1]
    } catch { return '' }
}

function Get-NpmGlobalInstalledVersions {
    # One `npm ls -g` call for every package, instead of one per package.
    $json = Invoke-NpmCapture @('ls', '-g', '--depth=0', '--json')
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($json)) { return $map }
    try { $obj = $json | ConvertFrom-Json } catch { return $map }
    if ($obj -and $obj.PSObject.Properties['dependencies'] -and $obj.dependencies) {
        foreach ($prop in $obj.dependencies.PSObject.Properties) {
            $map[$prop.Name] = [string](Get-OptionalProperty $prop.Value 'version' '')
        }
    }
    return $map
}

function Update-NpmGlobalPackage {
    # Isolated install for a single package. Returns a result object rather than
    # writing output, so callers control presentation.
    param([string]$Package)
    $result = [PSCustomObject]@{ package = $Package; ok = $false; version = ''; detail = '' }
    $out = Invoke-NpmCapture @('i', '-g', "$Package@latest") 600
    if ($null -ne $out) {
        $result.ok = $true
        $result.detail = 'installed @latest'
    } else {
        # `latest` unusable (missing/rotated tag). Retry against the newest
        # version actually present in the registry before giving up.
        $fallback = Get-NpmNewestPublishedVersion $Package
        if ($fallback) {
            $out2 = Invoke-NpmCapture @('i', '-g', "$Package@$fallback") 600
            if ($null -ne $out2) {
                $result.ok = $true
                $result.detail = "installed pinned $fallback (latest tag unusable)"
            } else {
                $result.detail = 'npm install failed'
            }
        } else {
            $result.detail = 'npm install failed'
        }
    }
    if ($result.ok) {
        $installed = Get-NpmGlobalInstalledVersions
        if ($installed.ContainsKey($Package)) { $result.version = $installed[$Package] }
    }
    return $result
}

function Get-NpmPackageCommandName {
    # The CLI command a known npm package installs (for 'which one is on PATH' hints); '' when unknown.
    param([string]$Package)
    $known = @{ '@earendil-works/pi-coding-agent' = 'pi' }
    if ($known.ContainsKey($Package)) { return $known[$Package] }
    return ''
}

function Get-ToolUpdateReportLines {
    # Pure: the [U] report when nothing is behind. Says "up to date" only about packages that are
    # actually installed with npm. A package that is not installed but whose command is on PATH (pi from
    # another package, a fork, a source build) is called out: npm updates cannot reach that copy.
    # -FindCommand: { param($Name) -> path or '' }. Returns @{ text; color } rows. Unit tested.
    param([object[]]$Rows, [string]$Label, [scriptblock]$FindCommand)
    $out = [System.Collections.Generic.List[object]]::new()
    $rowsArr = @($Rows)
    $installed = @($rowsArr | Where-Object { $_.installed })
    $header = if ($installed.Count -eq $rowsArr.Count) { "  $Label up to date" }
              elseif ($installed.Count -gt 0) { "  ${Label}: the npm packages that are installed are up to date" }
              else { "  ${Label}: nothing here is installed with npm, so there is nothing to update" }
    $out.Add(@{ text = $header; color = $(if ($installed.Count -eq $rowsArr.Count) { 'DarkGreen' } else { 'DarkGray' }) })
    foreach ($r in $rowsArr) {
        if ($r.installed) {
            $out.Add(@{ text = ("   {0}: {1}" -f $r.package, $r.installed); color = 'DarkGray' })
            continue
        }
        $cmd = Get-NpmPackageCommandName $r.package
        $src = if ($cmd -and $FindCommand) { [string](& $FindCommand $cmd) } else { '' }
        if ($src) {
            $out.Add(@{ text = ("   {0}: not installed with npm. The '{1}' on PATH ({2}) comes from elsewhere;" -f $r.package, $cmd, $src); color = 'Yellow' })
            $out.Add(@{ text = "      update it the way you installed it, or set toolUpdates.packages/piPackages to match it."; color = 'Yellow' })
        } else {
            $out.Add(@{ text = ("   {0}: not installed (npm i -g {0})" -f $r.package); color = 'Yellow' })
        }
    }
    return $out.ToArray()
}

function Get-ToolUpdateStatus {
    # Probe configured packages and report which are behind. Honors the throttle
    # cache unless -Force. Returns one row per package.
    param(
        [string[]]$Packages,
        [int]$IntervalHours = 24,
        [switch]$Force
    )
    $rows = New-Object System.Collections.ArrayList
    $pkgs = @($Packages | Where-Object { $_ -and $_.Trim() })
    if ($pkgs.Count -eq 0) { return $rows.ToArray() }
    if (-not (Get-NpmExecutable)) { return $rows.ToArray() }

    $state = Get-ToolUpdateState
    $installed = Get-NpmGlobalInstalledVersions
    $dirty = $false
    foreach ($pkg in $pkgs) {
        $name = $pkg.Trim()
        $have = if ($installed.ContainsKey($name)) { $installed[$name] } else { '' }
        $latest = ''
        $checked = $false
        if ($Force -or (Test-ToolCheckDue $state $name $IntervalHours)) {
            $latest = Get-NpmLatestVersion $name
            $checked = $true
            if ($latest) {
                $state[$name] = @{ lastCheck = (Get-Date).ToString('o'); latest = $latest }
                $dirty = $true
            }
        } elseif ($state.ContainsKey($name)) {
            $latest = [string]$state[$name].latest
        }
        $behind = $false
        if ($have -and $latest) { $behind = ((Compare-SemverLike $have $latest) -lt 0) }
        [void]$rows.Add([PSCustomObject]@{
            package   = $name
            installed = $have
            latest    = $latest
            behind    = $behind
            checked   = $checked
        })
    }
    if ($dirty) { Save-ToolUpdateState $state }
    return $rows.ToArray()
}

function Get-ClaudeCodeUpdateInfo {
    # Claude Code self-updates via `claude update`; it is not an npm global here.
    # Anthropic version-gates new models on the CLI version, so this is the most
    # important one to keep fresh.
    $cmd = Get-Command 'claude' -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    return [PSCustomObject]@{ command = $cmd.Source }
}

function Invoke-WingetClaudeUpgrade {
    # Separate so tests can stub it. Returns @{ ok; exit; out }.
    $w = Get-Command 'winget' -ErrorAction SilentlyContinue
    if (-not $w) { return [PSCustomObject]@{ ok = $false; exit = $null; out = 'winget not found' } }
    return (Invoke-ProcessCapture -FilePath $w.Source -ArgumentList @(
        'upgrade', '--id', 'Anthropic.ClaudeCode', '--exact', '--silent',
        '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity') -TimeoutSeconds 600)
}

function Update-ClaudeCode {
    # -Quiet (startup/launch checks): say nothing when nothing changed; failures still show.
    param([switch]$Quiet)
    $info = Get-ClaudeCodeUpdateInfo
    if (-not $info) { return $false }
    try {
        $out = & claude update 2>&1 | Out-String
        $lines = @($out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $updated = $lines | Where-Object { $_ -match 'Successfully updated' } | Select-Object -First 1
        $current = $lines | Where-Object { $_ -match 'up to date' } | Select-Object -First 1
        if ($updated) {
            Write-Host "   claude: $updated" -ForegroundColor Green
            return $true
        }
        if ($current) {
            if (-not $Quiet) { Write-Host "   claude: $current" -ForegroundColor DarkGreen }
            return $true
        }
        # Installed via winget: `claude update` only prints "run winget upgrade". Do that.
        if ($out -match 'managed by winget') {
            $avail = if ($out -match 'Update available:\s*(\S+)\s*\S+\s*(\d+\.\d+\.\d+)') { $Matches[2] } else { '' }
            $w = Invoke-WingetClaudeUpgrade
            $wout = [string]$w.out
            if ($wout -match 'Successfully installed') {
                Write-Host "   claude: updated via winget$(if ($avail) { " to $avail" })" -ForegroundColor Green
                return $true
            }
            if ($wout -match 'No available upgrade|No newer package versions|No applicable upgrade') {
                # winget's catalogue trails Anthropic's releases by a day or two. Nothing to do yet.
                if (-not $Quiet) {
                    $note = if ($avail) { " (Anthropic lists $avail; winget has not published it yet)" } else { '' }
                    Write-Host "   claude: newest build on winget$note" -ForegroundColor DarkGray
                }
                return $true
            }
            $wlast = @($wout -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | Select-Object -Last 1
            if (-not $wlast) { $wlast = 'no output' }
            Write-Host "   claude: winget upgrade did not confirm - $wlast" -ForegroundColor Yellow
            return $false
        }
        # Anything else (offline, auth, installer error) must not read as "current":
        # a stale Claude Code silently loses access to new models.
        $last = if ($lines.Count -gt 0) { $lines[-1] } else { 'no output' }
        Write-Host "   claude: update check did not confirm - $last" -ForegroundColor Yellow
        return $false
    } catch {
        Write-Host '   claude: update check failed' -ForegroundColor Yellow
        return $false
    }
}

function Invoke-ClaudeCodeUpdateIfDue {
    # Claude Code gates model access server-side, so it gets its own schedule instead of
    # only riding along when an npm package happens to be behind. Quiet unless something
    # changed or failed.
    param([int]$IntervalHours = 24, [string]$Mode = 'check')
    if (([string]$Mode).ToLowerInvariant() -eq 'off') { return }
    if (-not (Get-ClaudeCodeUpdateInfo)) { return }
    $state = Get-ToolUpdateState
    if (-not (Test-ToolCheckDue $state 'claude-code' $IntervalHours)) { return }
    $ok = Update-ClaudeCode -Quiet
    if ($ok) {
        # Failures are not stamped, so they are retried (and shown) next launch.
        $state = Get-ToolUpdateState
        $state['claude-code'] = @{ lastCheck = (Get-Date).ToString('o'); latest = '' }
        Save-ToolUpdateState $state
    }
}

# ---------------------------------------------------------------------------
# leo-labs-ai pi-mono fork (`pii`), run from a local source build.
#
# The fork is not on npmjs (it publishes to GitHub Packages), so it updates
# from git: fetch -> merge -> npm install -> model data -> build:offline. That
# mirrors the fork's own scripts/bootstrap-worktree.sh. `npm run build` is NOT
# used because it ends in test:build-gate, whose e2e suite has Windows-only
# test failures (POSIX path assumptions) that would block every update.
# ---------------------------------------------------------------------------

function Get-GitExecutable {
    $g = @(Get-Command 'git' -All -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' }) |
         Select-Object -First 1
    if ($g) { return [string]$g.Source }
    return ''
}

function Test-PiForkBuild {
    param([string]$RepoPath = $PiForkRepoPath)
    if ([string]::IsNullOrWhiteSpace($RepoPath)) { return $false }
    $cli = Join-Path (Join-Path (Join-Path (Join-Path $RepoPath 'packages') 'coding-agent') 'dist') 'cli.js'
    return (Test-Path $cli -PathType Leaf)
}

function Test-PiForkBuildStale {
    # True when the fork build predates the checked-out commit (e.g. after a manual
    # merge or pull): dist/ exists, so Test-PiForkBuild passes, but pii runs old code.
    param([string]$RepoPath = $PiForkRepoPath)
    if (-not (Test-PiForkBuild $RepoPath)) { return $false }
    $git = Get-GitExecutable
    if (-not $git) { return $false }
    $ct = Invoke-ProcessCapture -FilePath $git -ArgumentList @('log', '-1', '--format=%ct', 'HEAD') -WorkingDirectory $RepoPath
    if (-not $ct.ok -or $ct.out -notmatch '^\s*(\d+)\s*$') { return $false }
    $headTime = [DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1]).UtcDateTime
    $cli = Join-Path (Join-Path (Join-Path (Join-Path $RepoPath 'packages') 'coding-agent') 'dist') 'cli.js'
    return ((Get-Item -LiteralPath $cli).LastWriteTimeUtc -lt $headTime)
}

function Get-PiForkStatus {
    # Returns the fork checkout's position relative to <remote>/<branch>.
    # -Fetch hits the network; without it, compares against the last fetch.
    param(
        [string]$RepoPath = $PiForkRepoPath,
        [string]$Remote = $PiForkRemote,
        [string]$Branch = $PiForkBranch,
        [switch]$Fetch
    )
    $st = [PSCustomObject]@{
        ok = $false; behind = 0; ahead = 0; dirty = $false; oursDriver = $false
        remoteHead = ''; detail = ''
    }
    $git = Get-GitExecutable
    if (-not $git) { $st.detail = 'git not found'; return $st }
    if ([string]::IsNullOrWhiteSpace($RepoPath) -or -not (Test-Path (Join-Path $RepoPath '.git'))) {
        $st.detail = "not a git checkout: $RepoPath"; return $st
    }
    if ($Fetch) {
        $f = Invoke-ProcessCapture -FilePath $git -ArgumentList @('fetch', '--quiet', $Remote) -WorkingDirectory $RepoPath -TimeoutSeconds 180
        if (-not $f.ok) { $st.detail = "git fetch $Remote failed"; return $st }
    }
    $ref = "$Remote/$Branch"
    $counts = Invoke-ProcessCapture -FilePath $git -ArgumentList @('rev-list', '--left-right', '--count', "HEAD...$ref") -WorkingDirectory $RepoPath
    if (-not $counts.ok -or $counts.out -notmatch '^\s*(\d+)\s+(\d+)\s*$') { $st.detail = "cannot compare with $ref"; return $st }
    $st.ahead = [int]$Matches[1]; $st.behind = [int]$Matches[2]
    $rh = Invoke-ProcessCapture -FilePath $git -ArgumentList @('rev-parse', '--short', $ref) -WorkingDirectory $RepoPath
    if ($rh.ok) { $st.remoteHead = $rh.out }
    # Untracked files are ignored on purpose: local, uncommitted tooling in the
    # checkout must not block or be touched.
    $dirty = Invoke-ProcessCapture -FilePath $git -ArgumentList @('status', '--porcelain', '--untracked-files=no') -WorkingDirectory $RepoPath
    $st.dirty = ($dirty.ok -and -not [string]::IsNullOrWhiteSpace($dirty.out))
    # the fork's .gitattributes marks generated model tables + package-lock.json as
    # merge=ours. That is right for THEM (merging from upstream) but inverted for a
    # downstream clone: once scripts/setup-merge-drivers.sh registers the driver,
    # every sync silently keeps OUR stale generated models. Refuse to auto-merge then.
    $drv = Invoke-ProcessCapture -FilePath $git -ArgumentList @('config', '--get', 'merge.ours.driver') -WorkingDirectory $RepoPath
    $st.oursDriver = ($drv.ok -and -not [string]::IsNullOrWhiteSpace($drv.out))
    $st.ok = $true
    return $st
}

function Update-PiFork {
    # Merge <remote>/<branch> and rebuild. Non-destructive: aborts a conflicting
    # merge, never resets, never cleans (untracked local files are safe).
    param(
        [string]$RepoPath = $PiForkRepoPath,
        [string]$Remote = $PiForkRemote,
        [string]$Branch = $PiForkBranch
    )
    # $script:PiForkLastFailure carries the reason for a $false return so the caller can
    # persist it and keep warning on later launches (see Invoke-PiForkUpdateCheck).
    $script:PiForkLastFailure = ''
    $git = Get-GitExecutable
    $npm = Get-NpmExecutable
    if (-not $git -or -not $npm) {
        $script:PiForkLastFailure = 'git and npm are both required'
        Write-Host '   pii: git and npm are both required.' -ForegroundColor Yellow; return $false
    }

    $st = Get-PiForkStatus -RepoPath $RepoPath -Remote $Remote -Branch $Branch
    if (-not $st.ok) { $script:PiForkLastFailure = $st.detail; Write-Host "   pii: $($st.detail)" -ForegroundColor Yellow; return $false }
    if ($st.dirty) {
        $script:PiForkLastFailure = "uncommitted tracked changes in $RepoPath"
        Write-Host "   pii: $RepoPath has uncommitted tracked changes - commit or stash, then retry." -ForegroundColor Yellow
        return $false
    }
    if ($st.oursDriver) {
        $script:PiForkLastFailure = 'merge.ours.driver is registered (run git config --unset merge.ours.driver)'
        Write-Host '   pii: merge.ours.driver is registered in this clone; a sync would keep stale generated' -ForegroundColor Yellow
        Write-Host '        model tables. Run `git config --unset merge.ours.driver` in the fork, then retry.' -ForegroundColor Yellow
        return $false
    }

    if ($st.behind -gt 0) {
        Write-Host "   pii: merging $($st.behind) commit(s) from $Remote/$Branch ..." -ForegroundColor DarkGray
        $m = Invoke-ProcessCapture -FilePath $git -ArgumentList @('merge', '--no-edit', "$Remote/$Branch") -WorkingDirectory $RepoPath -TimeoutSeconds 600
        if (-not $m.ok) {
            # Name the conflicting files before aborting: "resolve manually" alone is not actionable.
            # Which files conflicted. Three sources, most portable first: the merge's own output
            # ("CONFLICT (content): Merge conflict in a.txt", printed by every git), then
            # `git status --porcelain` (UU/AA/...), then `git diff --diff-filter=U`. On git 2.55
            # (CI) the last two came back empty after a conflicting merge.
            $files = @(($m.out -split '\r?\n') | ForEach-Object { if ($_ -match 'CONFLICT \([^)]*\):.*?(?:conflict in|: )\s*(.+?)\s*$') { $Matches[1] } } | Where-Object { $_ } | Select-Object -Unique)
            if ($files.Count -eq 0) {
                $u = Invoke-ProcessCapture -FilePath $git -ArgumentList @('status', '--porcelain', '--untracked-files=no') -WorkingDirectory $RepoPath
                $files = @(if ($u.ok) { ($u.out -split '\r?\n') | Where-Object { $_ -match '^(UU|AA|DU|UD|AU|UA|DD) ' } | ForEach-Object { $_.Substring(3).Trim() } })
            }
            if ($files.Count -eq 0) {
                $u2 = Invoke-ProcessCapture -FilePath $git -ArgumentList @('diff', '--name-only', '--diff-filter=U') -WorkingDirectory $RepoPath
                $files = @(if ($u2.ok) { ($u2.out -split '\r?\n') | Where-Object { $_ } })
            }
            [void](Invoke-ProcessCapture -FilePath $git -ArgumentList @('merge', '--abort') -WorkingDirectory $RepoPath)
            if ($files.Count -eq 0 -and $m.out -notmatch 'CONFLICT') {
                # Not a conflict: git refused before merging (exit 128: no identity, bad ref, locked index).
                $why = (($m.err -split '\r?\n') | Where-Object { $_ -match '^(fatal|error):' } | Select-Object -First 1)
                if (-not $why) { $why = "git merge exited $($m.exit)" }
                $script:PiForkLastFailure = "merge failed: $why"
                Write-Host "   pii: merge failed ($why) - nothing changed in $RepoPath." -ForegroundColor Yellow
                return $false
            }
            $where = if ($files.Count -gt 0) { " in $($files -join ', ')" } else { '' }
            $script:PiForkLastFailure = "merge conflict$where - resolve manually in $RepoPath"
            Write-Host "   pii: merge conflicted$where and was aborted - resolve manually in $RepoPath." -ForegroundColor Yellow
            return $false
        }
    }

    Write-Host '   pii: npm install --ignore-scripts ...' -ForegroundColor DarkGray
    $i = Invoke-ProcessCapture -FilePath $npm -ArgumentList @('install', '--ignore-scripts', '--no-audit', '--no-fund') -WorkingDirectory $RepoPath -TimeoutSeconds 1800
    if (-not $i.ok) {
        $script:PiForkLastFailure = 'npm install failed'
        Write-Host '   pii: npm install failed - previous build left in place.' -ForegroundColor Yellow; return $false
    }

    # Same order as bootstrap-worktree.sh: hydrate model data when stale. After a merge,
    # always: the data is gitignored and check:model-data validates its shape, not that it
    # matches the merged code (old data can pass the check and then fail the ai build).
    $md = if ($st.behind -gt 0) { [PSCustomObject]@{ ok = $false } }
          else { Invoke-ProcessCapture -FilePath $npm -ArgumentList @('run', '--silent', 'check:model-data') -WorkingDirectory $RepoPath -TimeoutSeconds 300 }
    if (-not $md.ok) {
        Write-Host '   pii: refreshing model data ...' -ForegroundColor DarkGray
        [void](Invoke-ProcessCapture -FilePath $npm -ArgumentList @('run', 'hydrate:model-data') -WorkingDirectory $RepoPath -TimeoutSeconds 900)
    }

    Write-Host "   pii: building ($PiForkBuildScript, several minutes) ..." -ForegroundColor DarkGray
    $b = Invoke-ProcessCapture -FilePath $npm -ArgumentList @('run', $PiForkBuildScript) -WorkingDirectory $RepoPath -TimeoutSeconds 2400 -Stream
    if (-not $b.ok -or -not (Test-PiForkBuild $RepoPath)) {
        $script:PiForkLastFailure = "build ($PiForkBuildScript) failed"
        Write-Host '   pii: build failed. Vanilla `pi` still works; Mission Centre falls back to it if pii cannot start.' -ForegroundColor Yellow
        return $false
    }
    Write-Host "   pii: up to date with $Remote/$Branch ($($st.remoteHead))" -ForegroundColor Green
    return $true
}

function Write-UpdateLog {
    # Write-MissionLog lives in 20-ui.ps1, which the test harness does not load.
    param([string]$Level, [string]$Message)
    if (Get-Command 'Write-MissionLog' -ErrorAction SilentlyContinue) { Write-MissionLog $Level $Message }
}

function Set-PiForkCheckState {
    # Record a fork check. Note is the pending problem ('' when healthy); it keeps
    # warning on every launch until a later check or update clears it.
    param([hashtable]$State, [string]$RemoteHead, [string]$Note)
    $State['git:pi-fork'] = @{ lastCheck = (Get-Date).ToString('o'); latest = [string]$RemoteHead; note = [string]$Note }
    Save-ToolUpdateState $State
}

function Invoke-PiForkUpdateCheck {
    param(
        [string]$Mode = $ToolUpdatesMode,
        [int]$IntervalHours = $ToolUpdateIntervalHours,
        [switch]$Force
    )
    if (-not $PiForkEnabled) { return }
    $Mode = ([string]$Mode).ToLowerInvariant()
    if ($Mode -eq 'off') { return }

    $key = 'git:pi-fork'
    $state = Get-ToolUpdateState
    if (-not $Force -and -not (Test-ToolCheckDue $state $key $IntervalHours)) {
        # Throttled, so no network. A failed or skipped update must still be visible on
        # every launch: staying silent for intervalHours once hid a merge conflict while
        # pii fell 100+ commits behind.
        $note = if ($state.ContainsKey($key)) { [string]$state[$key].note } else { '' }
        if ($note) {
            Write-Host ''
            Write-Host "  pii (leo-labs-ai fork) is NOT up to date: $note" -ForegroundColor Yellow
            Write-Host '  [U] retries the update now.' -ForegroundColor DarkGray
        }
        return
    }

    $st = Get-PiForkStatus -Fetch
    if (-not $st.ok) {
        # Still stamp lastCheck (an offline fetch must not stall every launch), but keep the note.
        Set-PiForkCheckState $state $st.remoteHead "update check failed: $($st.detail)"
        Write-UpdateLog 'WARN' "pii fork check failed: $($st.detail)"
        Write-Host "   pii: update check failed: $($st.detail)" -ForegroundColor Yellow
        return
    }
    $missingBuild = -not (Test-PiForkBuild)
    $staleBuild = (-not $missingBuild) -and (Test-PiForkBuildStale)
    $needsBuild = $missingBuild -or $staleBuild
    if ($st.behind -eq 0 -and -not $needsBuild) {
        Set-PiForkCheckState $state $st.remoteHead ''
        if ($Force) { Write-Host "   pii (leo-labs-ai fork): up to date with $PiForkRemote/$PiForkBranch" -ForegroundColor DarkGreen }
        return
    }

    Write-Host ''
    if ($st.behind -gt 0) {
        Write-Host "  pii (leo-labs-ai fork): $($st.behind) new upstream commit(s) on $PiForkRemote/$PiForkBranch" -ForegroundColor Yellow
    } elseif ($staleBuild) {
        Write-Host '  pii (leo-labs-ai fork): build is older than the checked-out source' -ForegroundColor Yellow
    } else {
        Write-Host '  pii (leo-labs-ai fork): build output missing' -ForegroundColor Yellow
    }
    $pending = if ($st.behind -gt 0) { "$($st.behind) commit(s) behind $PiForkRemote/$PiForkBranch" }
               elseif ($staleBuild) { 'build older than checked-out source' }
               else { 'build output missing' }
    $go = if ($Mode -eq 'auto') { $true } else { Read-YesNo '  Pull and rebuild the fork now? (takes a few minutes)' 'Y' }
    if (-not $go) {
        Set-PiForkCheckState $state $st.remoteHead "$pending (update skipped)"
        Write-Host '  Skipped. [U] updates it later.' -ForegroundColor DarkGray
        return
    }
    if (Update-PiFork) {
        Set-PiForkCheckState $state $st.remoteHead ''
        Write-UpdateLog 'INFO' "pii fork updated to $PiForkRemote/$PiForkBranch ($($st.remoteHead))"
    } else {
        $why = if ($script:PiForkLastFailure) { $script:PiForkLastFailure } else { 'update failed' }
        Set-PiForkCheckState $state $st.remoteHead "$pending; last update failed: $why"
        Write-UpdateLog 'WARN' "pii fork update failed: $why"
    }
}

function Get-EffectivePiCommand {
    # Prefer the configured launcher (normally `pii`, the fork). If that is the
    # fork but its build output is missing or older than the checked-out source,
    # fall back to vanilla `pi` rather than launching a terminal that dies
    # immediately. Stale matters: a build that fails partway leaves cli.js in place
    # while the packages it imports were already rebuilt from newer source.
    $cmd = $PiCommand
    if (-not ($PiForkEnabled -and $cmd -eq 'pii')) { return $cmd }
    $why = if (-not (Test-PiForkBuild)) { 'build missing' }
           elseif (Test-PiForkBuildStale) { 'build older than the checked-out source' }
           else { '' }
    if ($why -and (Get-Command $PiForkFallbackCommand -ErrorAction SilentlyContinue)) {
        Write-Host "  WARN: pii fork $why at $PiForkRepoPath - using '$PiForkFallbackCommand' for this launch ([U] rebuilds)." -ForegroundColor Yellow
        return $PiForkFallbackCommand
    }
    return $cmd
}

function Invoke-ToolUpdateCheck {
    <#
    .SYNOPSIS
        Startup/launch-time toolchain freshness gate.
    .DESCRIPTION
        mode 'off'   - no-op.
        mode 'check' - report packages that are behind, offer to update.
        mode 'auto'  - update silently-ish, no prompt.
        Always best-effort: never throws, never blocks a launch.
    #>
    param(
        [string[]]$Packages = @(),
        [string]$Mode = 'check',
        [int]$IntervalHours = 24,
        [switch]$IncludeClaudeCode,
        [switch]$Force,
        [string]$Label = 'Toolchain'
    )
    $Mode = ([string]$Mode).ToLowerInvariant()
    if ($Mode -eq 'off') { return }
    if ($IncludeClaudeCode -and -not $Force) { Invoke-ClaudeCodeUpdateIfDue -IntervalHours $IntervalHours -Mode $Mode }
    if (-not (Get-NpmExecutable)) { return }

    $rows = @(Get-ToolUpdateStatus -Packages $Packages -IntervalHours $IntervalHours -Force:$Force)
    $behind = @($rows | Where-Object { $_.behind })

    # Nothing to do and nothing to say - stay silent so startup is not noisy.
    if ($behind.Count -eq 0) {
        if ($Force) {
            Write-Host ''
            $finder = { param($Name) $c = Get-Command $Name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { [string]$c.Source } else { '' } }
            foreach ($line in (Get-ToolUpdateReportLines -Rows $rows -Label $Label -FindCommand $finder)) {
                Write-Host $line.text -ForegroundColor $line.color
            }
            if ($IncludeClaudeCode) { [void](Update-ClaudeCode) }
        }
        return
    }

    Write-Host ''
    Write-Host "  $Label updates available:" -ForegroundColor Yellow
    foreach ($r in $behind) {
        Write-Host ("   {0}: {1} -> {2}" -f $r.package, $r.installed, $r.latest) -ForegroundColor Yellow
    }

    $doUpdate = $false
    if ($Mode -eq 'auto') {
        $doUpdate = $true
    } else {
        $doUpdate = Read-YesNo '  Update now?' 'Y'
    }
    if (-not $doUpdate) {
        Write-Host '  Skipped. [U] updates tools later.' -ForegroundColor DarkGray
        return
    }

    foreach ($r in $behind) {
        Write-Host ("   updating {0} ..." -f $r.package) -ForegroundColor DarkGray
        $res = Update-NpmGlobalPackage $r.package
        if ($res.ok) {
            $shown = if ($res.version) { $res.version } else { 'ok' }
            Write-Host ("   {0}: {1} ({2})" -f $res.package, $shown, $res.detail) -ForegroundColor Green
        } else {
            Write-Host ("   {0}: {1}" -f $res.package, $res.detail) -ForegroundColor Yellow
        }
    }
    if ($IncludeClaudeCode -and $Force) { [void](Update-ClaudeCode) }

    # Force a re-probe next time so the cache reflects post-update versions
    # (Claude Code keeps its own schedule).
    $keep = @{}
    $prev = Get-ToolUpdateState
    if ($prev.ContainsKey('claude-code')) { $keep['claude-code'] = $prev['claude-code'] }
    Save-ToolUpdateState $keep
}

function Invoke-PiLaunchUpdateGate {
    # Runs before a pi launch. Keeps pi itself (and Claude Code, which
    # gates model access server-side) current. Throttled like the startup check
    # so back-to-back launches do not re-probe the registry.
    if (-not $ToolUpdatesEnabled) { return }
    if ($ToolUpdatesMode -eq 'off') { return }
    if (-not $ToolUpdatePiOnLaunch) { return }
    $pkgs = @($ToolUpdatePiPackages | Where-Object { $_ -and $_.Trim() })
    if ($pkgs.Count -gt 0) {
        Invoke-ToolUpdateCheck -Packages $pkgs `
                               -Mode $ToolUpdatesMode `
                               -IntervalHours $ToolUpdateIntervalHours `
                               -IncludeClaudeCode:$ToolUpdateIncludeClaudeCode `
                               -Label 'pi toolchain'
    }
    # The leo-labs-ai fork (pii) updates from git, not npm.
    Invoke-PiForkUpdateCheck -Mode $ToolUpdatesMode -IntervalHours $ToolUpdateIntervalHours
    # pi's own packages and tokenjuice, from their sources (66-sources.ps1).
    Invoke-PiSourceUpdates -Mode $ToolUpdatesMode -IntervalHours $ToolUpdateIntervalHours
}

function Invoke-StartupToolUpdateCheck {
    if (-not $ToolUpdatesEnabled) { return }
    Invoke-ToolUpdateCheck -Packages $ToolUpdatePackages `
                           -Mode $ToolUpdatesMode `
                           -IntervalHours $ToolUpdateIntervalHours `
                           -IncludeClaudeCode:$ToolUpdateIncludeClaudeCode `
                           -Label 'Toolchain'
    # Vendored skills, from their upstream repos (66-sources.ps1).
    Invoke-SkillSourceUpdateCheck -Mode $ToolUpdatesMode -IntervalHours $ToolUpdateIntervalHours
}

function Invoke-ToolUpdateMenu {
    # [U] action - always forces a fresh probe and reports everything.
    Write-Host ''
    Write-Host '  Tool updates' -ForegroundColor Cyan
    if (-not (Get-NpmExecutable)) {
        Write-Host '   npm not found - cannot check global CLI packages.' -ForegroundColor Yellow
        return
    }
    Invoke-ToolUpdateCheck -Packages $ToolUpdatePackages `
                           -Mode 'check' `
                           -IntervalHours $ToolUpdateIntervalHours `
                           -IncludeClaudeCode:$ToolUpdateIncludeClaudeCode `
                           -Force `
                           -Label 'Toolchain'
    Invoke-PiForkUpdateCheck -Mode 'check' -Force
    Invoke-PiSourceUpdates -Mode 'check' -Force
    Invoke-SkillSourceUpdateCheck -Mode 'check' -Force
    Write-Host ''
    Write-Host '  Where updates come from' -ForegroundColor Cyan
    foreach ($r in @(Get-UpdateSourceRows)) { Write-Host ("   {0,-38} {1}" -f $r.part, $r.source) -ForegroundColor DarkGray }
}
