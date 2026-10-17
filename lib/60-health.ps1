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

function Get-SkillDescriptionLength {
    # Length of a SKILL.md frontmatter description (folded/quoted forms included), whitespace collapsed.
    param([string]$Path)
    $lines = @(Get-Content -Path $Path -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') { return 0 }
    $parts = [System.Collections.Generic.List[string]]::new()
    $inDesc = $false
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l.Trim() -eq '---') { break }
        if ($l -match '^description:\s*(.*)$') { $inDesc = $true; $parts.Add($Matches[1]); continue }
        if ($inDesc) {
            if ($l -match '^[A-Za-z][\w-]*:') { break }
            $parts.Add($l)
        }
    }
    $text = (($parts -join ' ') -replace '\s+', ' ').Trim()
    $text = ($text -replace '^[>|][-+]?\s*', '').Trim('"', "'", ' ')
    return $text.Length
}

function Get-EnabledPluginSkillDirs {
    # skills/ folders of the Claude Code plugins that are enabled in settings.json (old cache
    # versions on disk are not loaded, so they are not counted).
    param([string]$ClaudeDir = (Join-Path $HOME '.claude'))
    $dirs = [System.Collections.Generic.List[string]]::new()
    try {
        $settingsPath  = Join-Path $ClaudeDir 'settings.json'
        $installedPath = Join-Path $ClaudeDir (Join-Path 'plugins' 'installed_plugins.json')
        if (-not (Test-Path $settingsPath) -or -not (Test-Path $installedPath)) { return @() }
        $settings  = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $installed = Get-Content $installedPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $enabled = Get-RawProperty $settings 'enabledPlugins' $null
        if ($null -eq $enabled) { return @() }
        foreach ($p in $enabled.PSObject.Properties) {
            if ($p.Value -ne $true) { continue }
            $records = Get-RawProperty $installed.plugins $p.Name $null
            if ($null -eq $records) { continue }
            foreach ($rec in @($records)) {
                $path = Get-OptionalProperty $rec 'installPath' ''
                if ($path) { $dirs.Add((Join-Path $path 'skills')) }
            }
        }
    } catch { return @() }
    return $dirs.ToArray()
}

function Get-SkillLibraryStats {
    # Every installed skill puts its description into every session. Past a budget the harness drops
    # some without warning (harness-engineering: "Auditing a skill library"), so [H] shows the cost.
    # Pure: give it the skill roots one harness loads. Never deletes anything.
    param([string]$Harness, [string[]]$Dirs, [int]$LongDescChars = 250)
    $skills = [System.Collections.Generic.List[object]]::new()
    foreach ($d in @($Dirs)) {
        if (-not $d -or -not (Test-Path $d -PathType Container)) { continue }
        foreach ($sd in @(Get-ChildItem -Path $d -Directory -ErrorAction SilentlyContinue)) {
            $file = Join-Path $sd.FullName 'SKILL.md'
            if (-not (Test-Path $file -PathType Leaf)) { continue }
            $skills.Add([pscustomobject]@{ name = $sd.Name; chars = (Get-SkillDescriptionLength $file); root = $d })
        }
    }
    $chars = [int](($skills | Measure-Object chars -Sum).Sum)
    $dups = @($skills | Group-Object name | Where-Object { $_.Count -gt 1 } | ForEach-Object Name)
    $long = @($skills | Where-Object { $_.chars -gt $LongDescChars } | Sort-Object chars -Descending)
    return [pscustomobject]@{
        harness    = $Harness
        count      = $skills.Count
        descChars  = $chars
        tokens     = [int][math]::Ceiling($chars / 4)   # rough: ~4 characters per token
        duplicates = $dups
        long       = $long
    }
}

function Write-SkillLibraryHealth {
    # Warn well below the ~5.4k-token listing budget the guide observed (about 2% of the window).
    param([int]$WarnTokens = 4000)
    $piDirs = @((Get-GlobalAgentsSkillsDir), (Join-Path (Join-Path (Join-Path $HOME '.pi') 'agent') 'skills'))
    $rows = @(
        (Get-SkillLibraryStats -Harness 'Claude Code' -Dirs (@(Get-GlobalClaudeSkillsDir) + @(Get-EnabledPluginSkillDirs))),
        (Get-SkillLibraryStats -Harness 'pi/Codex' -Dirs $piDirs)
    )
    Write-Host ''
    Write-Host '  Skill library (each description loads into every session)' -ForegroundColor Cyan
    foreach ($r in $rows) {
        $color = if ($r.tokens -gt $WarnTokens) { 'Yellow' } else { 'DarkGreen' }
        $warn = if ($r.tokens -gt $WarnTokens) { ' - over budget: the harness may drop some silently; prune or shorten' } else { '' }
        Write-Host ("   {0,-11} : {1} skills, ~{2} tokens of descriptions{3}" -f $r.harness, $r.count, $r.tokens, $warn) -ForegroundColor $color
        if ($r.duplicates.Count -gt 0) {
            Write-Host "     installed twice: $($r.duplicates -join ', ')" -ForegroundColor Yellow
        }
        if ($r.long.Count -gt 0) {
            $top = @($r.long | Select-Object -First 5 | ForEach-Object { "$($_.name) $($_.chars)" })
            Write-Host "     descriptions over 250 chars: $($top -join ', ')$(if ($r.long.Count -gt 5) { " (+$($r.long.Count - 5) more)" })" -ForegroundColor DarkYellow
        }
    }
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
    Write-SkillLibraryHealth

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
