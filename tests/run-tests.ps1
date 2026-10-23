#Requires -Version 5.1
<#
.SYNOPSIS
    Mission Centre test suite - no dependencies, plain PASS/FAIL, exit 1 on any failure.
.DESCRIPTION
    Dot-sources the real lib/*.ps1 under the same StrictMode + Stop policy the app runs with,
    stubbing the root-script config globals. Hermetic: every file fixture (registry, session
    history, wiki config, scan tree) lives under a per-run temp folder that is removed at the
    end - nothing reads or writes the real ~/.claude, ~/.jig, ~/.obsidian-wiki, or repo config.

    Runs on Windows PowerShell 5.1 (primary target - StrictMode scalar-.Count and native-stderr
    promotion behave differently there) and PowerShell 7+. Version- or OS-specific checks guard
    themselves and report SKIP.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$IsWinHost = ($env:OS -eq 'Windows_NT')
$IsPs5 = ($PSVersionTable.PSVersion.Major -le 5)
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mc-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
# Mission Centre writes a managed block into the agents' global instructions on launch: never the real ones here.
$AgentInstructionHome = Join-Path $TestRoot 'agent-home'

$script:Pass = 0; $script:Fail = 0; $script:Skipped = 0
function Check {
    param([string]$Name, [bool]$Cond)
    if ($Cond) { $script:Pass++; Write-Host "PASS  $Name" }
    else       { $script:Fail++; Write-Host "FAIL  $Name" -ForegroundColor Red }
}
function Skip {
    param([string]$Name, [string]$Why)
    $script:Skipped++; Write-Host "SKIP  $Name ($Why)" -ForegroundColor DarkYellow
}

try {
    # =======================================================================
    # 0. Every product script must parse
    # =======================================================================
    $productFiles = @(Get-Item (Join-Path $RepoRoot 'Mission-Centre.ps1')) + @(Get-Item (Join-Path $RepoRoot 'setup.ps1')) +
                    @(Get-ChildItem (Join-Path $RepoRoot 'lib') -Filter '*.ps1' -File)
    foreach ($f in $productFiles) {
        $tokens = $null; $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$parseErrors)
        Check "parse: $($f.Name)" ($parseErrors.Count -eq 0)
        foreach ($e in @($parseErrors)) { Write-Host "      L$($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red }
    }

    # =======================================================================
    # Stub the root-script globals the lib functions read at call time,
    # then dot-source the libs under test.
    # =======================================================================
    $MissionPlatform = ''; $MissionOS = ''
    $MissionIsMacOS = $false; $MissionIsLinux = -not $IsWinHost; $MissionIsWindows = $IsWinHost
    $MissionRootDir  = $RepoRoot
    $MissionLibDir   = Join-Path $RepoRoot 'lib'
    $MissionStateDir = Join-Path $TestRoot 'state'
    $MissionLogPath  = Join-Path $MissionStateDir 'mission-centre.log'
    $MaxDepth = 4
    $SkipDirNames = @('node_modules', '.git', 'dist', 'build', 'bin', 'obj', 'out',
                      '.next', '.nuxt', 'venv', '.venv', '__pycache__', '.cache')
    $DefinitiveMarkers = @('.git', 'package.json', 'requirements.txt', 'Cargo.toml', 'go.mod', 'pom.xml', 'pyproject.toml')
    $SuggestiveMarkers = @('CLAUDE.md', '*.jig', 'README.md', 'README', 'app.js', 'main.py', 'index.js', 'main.ts', 'index.ts')
    $ProjectMarkers = $DefinitiveMarkers + $SuggestiveMarkers
    $ClaudeProjectsDir = Join-Path $TestRoot 'claude-projects'
    $PiSessionsDir = ''
    $ConfigPath     = Join-Path $TestRoot 'projects.json'
    $AppConfigPath  = Join-Path $TestRoot 'config.json'
    $BundledJigProfilesDir = Join-Path $TestRoot 'bundled-profiles'
    $BundledSkillsDir = Join-Path $TestRoot 'bundled-skills'
    $StarterProfiles = @('standard', 'build', 'maintain', 'review', 'research', 'forge', 'vibe', 'craft')
    $DefaultProfile = 'standard'
    $MetaProfile = 'forge'
    $PreflightMode = 'warn'
    $ScanRoot = $TestRoot
    $ContextIndexEnabled = $false; $ContextIndexCommand = ''; $ContextIndexMaxAgeDays = 3
    $WikiConfigDir  = Join-Path $TestRoot 'obsidian-wiki'
    $WikiConfigPath = Join-Path $WikiConfigDir 'config'
    $WikiProfileVaults = @{}
    $WikiProfilePage = 'profile'; $WikiMapPage = 'system-map'
    # Claude Code home for plugin checks (Test-ForgeInstalled): a fixture with Forge installed.
    $McClaudeDir = Join-Path $TestRoot 'claude-home'
    New-Item -ItemType Directory -Path (Join-Path $McClaudeDir 'plugins') -Force | Out-Null
    '{"version":2,"plugins":{"forge@forge":[{"scope":"user"}]}}' | Set-Content (Join-Path (Join-Path $McClaudeDir 'plugins') 'installed_plugins.json') -Encoding UTF8
    $PiEnabled = $true; $PiCommand = 'pi'; $PiProvider = 'my-proxy'
    $PiModel = 'claude-opus-4-8'; $PiModelCycle = ''; $PiServerHealthUrl = ''
    $PiServerAutoStart = $false; $PiServerTaskName = ''; $PiServerStartCommand = ''; $PiServerWorkingDir = ''
    $PiServerStartWaitSeconds = 1
    # Tool-update globals (lib/65-updates.ps1). Default to disabled so no test
    # path can reach npm or mutate the real toolchain.
    $ToolUpdatesEnabled = $false; $ToolUpdatesMode = 'off'; $ToolUpdateIntervalHours = 24
    $ToolUpdateIncludeClaudeCode = $false; $ToolUpdatePiOnLaunch = $false
    $ToolUpdatePackages = @(); $ToolUpdatePiPackages = @()
    $PiForkEnabled = $false; $PiForkRepoPath = ''; $PiForkRemote = 'origin'; $PiForkBranch = 'main'
    $PiForkMode = 'check'
    $PiForkBuildScript = 'build:offline'; $PiForkFallbackCommand = 'pi'
    # Shared registry + self-update (lib/35-sharedstate.ps1): off unless a test turns it on.
    $SelfUpdateEnabled = $false; $DeviceName = 'TESTDEV'
    $DefaultEngine = 'claude'
    $SharedStateEnabled = $false; $SharedStateRemote = ''; $SharedStateSshKey = ''
    $SharedStateDir = Join-Path $TestRoot 'shared-state'

    . (Join-Path $MissionLibDir '00-config.ps1')
    . (Join-Path $MissionLibDir '05-vibe.ps1')
    . (Join-Path $MissionLibDir '10-util.ps1')
    . (Join-Path $MissionLibDir '20-ui.ps1')
    . (Join-Path $MissionLibDir '30-discovery.ps1')
    . (Join-Path $MissionLibDir '35-sharedstate.ps1')
    . (Join-Path $MissionLibDir '40-sessions.ps1')
    . (Join-Path $MissionLibDir '50-context.ps1')
    . (Join-Path $MissionLibDir '60-health.ps1')
    . (Join-Path $MissionLibDir '65-updates.ps1')
    . (Join-Path $MissionLibDir '66-sources.ps1')
    . (Join-Path $MissionLibDir '80-launch.ps1')

    # =======================================================================
    # 1. Registry handling (PS 5.1 StrictMode scalar-.Count regression)
    # =======================================================================
    '[{"path":"F:\\AI\\solo","name":"Solo","description":"x","added":"2026-01-01","profile":"standard"}]' |
        Set-Content $ConfigPath -Encoding UTF8
    $config = @(Import-ProjectConfig)
    Check 'registry: 1-entry registry is an array of 1 when @()-wrapped' (($config -is [System.Array]) -and $config.Count -eq 1)
    $ok = $true; try { $null = (0 -ge @($config).Count) } catch { $ok = $false }
    Check 'registry: dispatcher count expression safe' $ok
    if ($IsPs5) {
        $bare = Import-ProjectConfig   # un-wrapped, as consumed before the fix
        $crashed = $false; try { $null = $bare.Count } catch { $crashed = $true }
        Check 'registry: un-wrapped 1-entry registry still reproduces the 5.1 crash (sanity)' $crashed
    } else {
        Skip 'registry: un-wrapped crash repro' 'PS6.1+ exempts intrinsic members from StrictMode'
    }
    '[]' | Set-Content $ConfigPath -Encoding UTF8
    $config0 = @(Import-ProjectConfig)
    $ok0 = $true; try { $null = (4 -ge @($config0).Count) } catch { $ok0 = $false }
    Check 'registry: empty registry count safe' ($ok0 -and $config0.Count -eq 0)

    # Save-Config roundtrip: a single project must stay a JSON array on disk
    Save-Config @([PSCustomObject]@{ path = 'F:\AI\one'; name = 'One'; description = 'd'; added = '2026-01-01'; profile = 'standard' })
    $rawSaved = (Get-Content $ConfigPath -Raw -Encoding UTF8).TrimStart()
    Check 'registry: Save-Config emits a JSON array for one project' ($rawSaved.StartsWith('['))
    Check 'registry: roundtrip count is 1' (@(Import-ProjectConfig).Count -eq 1)
    Check 'registry: Test-ConfigHasPath matches case-insensitively' (Test-ConfigHasPath @(Import-ProjectConfig) 'f:\ai\ONE')

    # Resolve-ImportablePath: validates an existing folder (any path) for import.
    $importDir = Join-Path $TestRoot 'an-existing-project'
    New-Item -ItemType Directory -Path $importDir -Force | Out-Null
    $rOk = Resolve-ImportablePath $importDir @()
    Check 'import: real existing dir is importable' ($rOk.ok -eq $true)
    Check 'import: returns a normalized full path' ($rOk.path -eq ([System.IO.Path]::GetFullPath($importDir)))
    $rMissing = Resolve-ImportablePath (Join-Path $TestRoot 'nope-not-here') @()
    Check 'import: non-existent path is rejected' (($rMissing.ok -eq $false) -and ($rMissing.reason -match 'exist'))
    $dupCfg = @([PSCustomObject]@{ path = $rOk.path; name = 'Dup'; description = 'd'; added = '2026-01-01'; profile = 'standard' })
    $rDup = Resolve-ImportablePath ($rOk.path.ToUpper()) $dupCfg
    Check 'import: already-registered path is rejected (case-insensitive)' ($rDup.ok -eq $false)
    $rBlank = Resolve-ImportablePath '   ' @()
    Check 'import: blank input is rejected' ($rBlank.ok -eq $false)

    # =======================================================================
    # 2. Preflight command check (native stderr under the Stop policy)
    # =======================================================================
    if ($IsWinHost) {
        $res = Invoke-JigCommandCheck $RepoRoot 'stderr-exit0' { & cmd.exe /c "echo warn 1>&2 & exit 0" }
        Check 'preflight: stderr + exit 0 reports ok' ($res.ok -eq $true)
        $res2 = Invoke-JigCommandCheck $RepoRoot 'stderr-exit3' { & cmd.exe /c "echo boom 1>&2 & exit 3" }
        Check 'preflight: exit 3 reports failure' ($res2.ok -eq $false)
    } else {
        $res = Invoke-JigCommandCheck $RepoRoot 'stderr-exit0' { & sh -c 'echo warn 1>&2; exit 0' }
        Check 'preflight: stderr + exit 0 reports ok' ($res.ok -eq $true)
        $res2 = Invoke-JigCommandCheck $RepoRoot 'stderr-exit3' { & sh -c 'echo boom 1>&2; exit 3' }
        Check 'preflight: exit 3 reports failure' ($res2.ok -eq $false)
    }

    # =======================================================================
    # 3. Project discovery
    # =======================================================================
    $scanFix = Join-Path $TestRoot 'scanroot'
    New-Item -ItemType Directory -Path (Join-Path $scanFix 'alpha\.git') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $scanFix 'container\beta') -Force | Out-Null
    Set-Content (Join-Path $scanFix 'container\README.md') -Value '# container' -Encoding UTF8
    Set-Content (Join-Path $scanFix 'container\beta\package.json') -Value '{}' -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $scanFix 'loose') -Force | Out-Null
    Set-Content (Join-Path $scanFix 'loose\README.md') -Value '# loose' -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $scanFix 'node_modules') -Force | Out-Null
    Set-Content (Join-Path $scanFix 'node_modules\package.json') -Value '{}' -Encoding UTF8

    $found = @(Find-ProjectDirs $scanFix 0) | Sort-Object
    $expected = @((Join-Path $scanFix 'alpha'), (Join-Path $scanFix 'container\beta'), (Join-Path $scanFix 'loose')) | Sort-Object
    Check 'discovery: definitive, container-child, and suggestive-leaf all found' (($found -join '|') -eq ($expected -join '|'))
    Check 'discovery: skip dirs are skipped' (-not (($found -join '|').Contains('node_modules')))

    $selfScan = @(Find-ProjectDirs $RepoRoot 0)
    Check 'discovery: Mission Centre repo excluded via $MissionRootDir' ($selfScan.Count -eq 0)
    $MissionRootDir = Join-Path $TestRoot 'not-the-repo'
    $selfScan2 = @(Find-ProjectDirs $RepoRoot 0)
    Check 'discovery: guard is what excludes it (sanity)' ($selfScan2.Count -eq 1 -and $selfScan2[0] -ieq $RepoRoot)
    $MissionRootDir = $RepoRoot

    # =======================================================================
    # 4. Selection parsing
    # =======================================================================
    $projects5 = @(1..5 | ForEach-Object { [PSCustomObject]@{ path = "F:\p$_"; name = "p$_" } })
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $selAll = @(ConvertTo-ProjectSelection '1-9999999' $projects5)
    $sw.Stop()
    Check 'selection: oversize range clamps to all 5' ($selAll.Count -eq 5)
    Check "selection: clamp keeps it fast ($($sw.ElapsedMilliseconds)ms < 500ms)" ($sw.ElapsedMilliseconds -lt 500)
    Check 'selection: list + range' ((@(ConvertTo-ProjectSelection '2,4-5' $projects5) | ForEach-Object { $_.name }) -join ',' -eq 'p2,p4,p5')
    Check 'selection: reversed range normalized' ((@(ConvertTo-ProjectSelection '4-2' $projects5) | ForEach-Object { $_.name }) -join ',' -eq 'p2,p3,p4')
    Check 'selection: duplicates collapse' (@(ConvertTo-ProjectSelection '1,1,1-2' $projects5).Count -eq 2)
    Check 'selection: garbage yields empty' (@(ConvertTo-ProjectSelection 'x,;9-1000000000' $projects5).Count -eq 0)
    Check 'selection: index form is 0-based, input order' ((@(ConvertTo-ProjectIndexSelection '5,1-2' 5) -join ',') -eq '4,0,1')

    # =======================================================================
    # 4b. Dormant projects (flag on the registry entry; numbers stay stable)
    # =======================================================================
    $old = (Get-Date).AddDays(-200).ToString('yyyy-MM-dd')
    $new = (Get-Date).ToString('yyyy-MM-dd')
    $dCfg = @(
        [PSCustomObject]@{ path = (Join-Path $TestRoot 'd-old1'); name = 'old1'; added = $old },
        [PSCustomObject]@{ path = (Join-Path $TestRoot 'd-new');  name = 'new';  added = $new },
        [PSCustomObject]@{ path = (Join-Path $TestRoot 'd-old2'); name = 'old2'; added = $old },
        [PSCustomObject]@{ path = (Join-Path $TestRoot 'd-nodate'); name = 'nodate' }
    )
    Check 'dormant: unflagged entry is active' (-not (Test-ProjectDormant $dCfg[0]))
    $idle = @(Get-IdleProjectCandidates $dCfg 60)
    Check 'dormant: idle = old + never launched; new and undated excluded' ((($idle | ForEach-Object { $_.Project.name }) -join ',') -eq 'old1,old2')
    Check 'dormant: idle candidates carry stable 1-based numbers' ((($idle | ForEach-Object { $_.Num }) -join ',') -eq '1,3')

    $n = Set-ProjectDormant ([ref]$dCfg) @(0, 2) $true
    Check 'dormant: two entries marked' ($n -eq 2 -and (Test-ProjectDormant $dCfg[0]) -and (Test-ProjectDormant $dCfg[2]))
    Check 'dormant: dormantSince stamped' ($dCfg[0].dormantSince -eq $new)
    Check 'dormant: re-marking is a no-op' ((Set-ProjectDormant ([ref]$dCfg) @(0) $true) -eq 0)
    $reload = @(Import-ProjectConfig)
    Check 'dormant: flag persisted, order/numbers unchanged' ($reload.Count -eq 4 -and (Test-ProjectDormant $reload[2]) -and $reload[2].name -eq 'old2')
    Check 'dormant: dormant projects are not idle candidates' (@(Get-IdleProjectCandidates $dCfg 60).Count -eq 0)
    Check 'dormant: out-of-range index ignored' ((Set-ProjectDormant ([ref]$dCfg) @(-1, 99) $true) -eq 0)

    $n = Set-ProjectDormant ([ref]$dCfg) @(2) $false
    Check 'dormant: reactivated' ($n -eq 1 -and -not (Test-ProjectDormant $dCfg[2]))
    Check 'dormant: reactivation removes the flags' (-not $dCfg[2].PSObject.Properties['dormant'] -and -not $dCfg[2].PSObject.Properties['dormantSince'])
    Check 'dormant: reactivation stamps reactivatedOn' ($dCfg[2].reactivatedOn -eq $new)
    Check 'dormant: reactivated project gets a fresh idle clock' (@(Get-IdleProjectCandidates $dCfg 60).Count -eq 0)
    Check 'dormant: auto-dormant sweep leaves the reactivated one alone' ((Invoke-AutoDormant ([ref]$dCfg) 60 6>$null) -eq 0)
    $n = Set-ProjectDormant ([ref]$dCfg) @(2) $true
    Check 'dormant: re-parking clears reactivatedOn' ($n -eq 1 -and -not $dCfg[2].PSObject.Properties['reactivatedOn'])

    # auto-dormant: a long-idle active project is swept; a fresh one is not
    [void](Set-ProjectDormant ([ref]$dCfg) @(0, 2) $false)
    $dCfg[0].reactivatedOn = $old; $dCfg[2].reactivatedOn = $old   # pretend they were woken long ago
    $n = Invoke-AutoDormant ([ref]$dCfg) 60 6>$null
    Check 'auto-dormant: idle projects swept' ($n -eq 2 -and (Test-ProjectDormant $dCfg[0]) -and (Test-ProjectDormant $dCfg[2]))
    Check 'auto-dormant: fresh + undated projects untouched' (-not (Test-ProjectDormant $dCfg[1]) -and -not (Test-ProjectDormant $dCfg[3]))
    Check 'auto-dormant: sweep persisted' (Test-ProjectDormant @(Import-ProjectConfig)[0])
    Resume-DormantProject ([ref]$dCfg) 0 6>$null
    Check 'auto-dormant: launching a dormant project wakes it' (-not (Test-ProjectDormant $dCfg[0]))
    Resume-DormantProject ([ref]$dCfg) 1 6>$null
    Check 'auto-dormant: waking an active project is a no-op' (-not $dCfg[1].PSObject.Properties['reactivatedOn'])
    Check 'dormant: string "true" from hand-edited JSON counts' (Test-ProjectDormant ([PSCustomObject]@{ path = 'x'; dormant = 'true' }))

    # =======================================================================
    # 5. Config helpers
    # =======================================================================
    $obj = ConvertFrom-Json '{"a":[],"b":["x","y"],"c":null,"s":"text","empty":"","zero":0,"flag":false}'
    Check 'optarr: explicit [] stays empty'        (@(Get-OptionalArrayProperty $obj 'a' @('d1')).Count -eq 0)
    Check 'optarr: present array returned'         ((@(Get-OptionalArrayProperty $obj 'b' @('d1')) -join ',') -eq 'x,y')
    Check 'optarr: json null falls to default'     ((@(Get-OptionalArrayProperty $obj 'c' @('d1')) -join ',') -eq 'd1')
    Check 'optarr: absent falls to default'        ((@(Get-OptionalArrayProperty $obj 'z' @('d1','d2')) -join ',') -eq 'd1,d2')
    Check 'optarr: scalar value wraps to array'    (@(Get-OptionalArrayProperty $obj 's' @()).Count -eq 1)
    Check 'optprop: present value returned'        ((Get-OptionalProperty $obj 's' 'dft') -eq 'text')
    Check 'optprop: absent returns default'        ((Get-OptionalProperty $obj 'z' 'dft') -eq 'dft')
    Check 'optprop: empty string returns default (documented semantics)' ((Get-OptionalProperty $obj 'empty' 'dft') -eq 'dft')
    Check 'optprop: zero survives'                 ((Get-OptionalProperty $obj 'zero' 9) -eq 0)
    Check 'optprop: false survives'                ((Get-OptionalProperty $obj 'flag' $true) -eq $false)
    $objArr = ConvertFrom-Json '{"blocks":[{"type":"text","text":"t1"},{"type":"text","text":"t2"}]}'
    Check 'rawprop: object array survives (stringifies empty on 5.1)' (@(Get-RawProperty $objArr 'blocks' @()).Count -eq 2)
    Check 'rawprop: absent returns default' ($null -eq (Get-RawProperty $objArr 'nope'))
    Check 'rawprop: null object returns default' ('d' -eq (Get-RawProperty $null 'x' 'd'))
    Check 'bool: yes -> true'   ((ConvertTo-MissionBool 'yes' $false) -eq $true)
    Check 'bool: off -> false'  ((ConvertTo-MissionBool 'off' $true) -eq $false)
    Check 'bool: junk -> default' ((ConvertTo-MissionBool 'maybe' $true) -eq $true)
    Check 'int: junk -> default'  ((ConvertTo-MissionInt 'abc' 7) -eq 7)
    Check 'slug: punctuation collapses' ((ConvertTo-MissionSlug 'Hello, World!') -eq 'hello-world')
    Check 'slug: blank -> mission'      ((ConvertTo-MissionSlug '!!!') -eq 'mission')
    Check 'resolve: ~ expands to HOME'  ((Resolve-UserPath '~/x') -eq (Join-Path $HOME 'x'))

    # Sound volume: Initialize-McVibe clamps the level; Build-McFanfareBytes scales amplitude by it.
    Initialize-McVibe $false $false 5.0
    Check 'sound: volume above 1 clamps to 1' ($script:McSoundVolume -eq 1)
    Initialize-McVibe $false $false -1.0
    Check 'sound: volume below 0 clamps to 0' ($script:McSoundVolume -eq 0)
    # Peak deviation from the 8-bit centre (128) must scale with the volume.
    function Get-McWavPeak { param([byte[]]$Wav) # PCM starts after the 44-byte RIFF/WAVE header
        $peak = 0; for ($k = 44; $k -lt $Wav.Length; $k++) { $d = [math]::Abs([int]$Wav[$k] - 128); if ($d -gt $peak) { $peak = $d } }; return $peak }
    $script:McSoundVolume = 1.0;  $peakFull = Get-McWavPeak (Build-McFanfareBytes)
    $script:McSoundVolume = 0.35; $peakQuiet = Get-McWavPeak (Build-McFanfareBytes)
    Check 'sound: full-volume peak near 8-bit max' ($peakFull -ge 100 -and $peakFull -le 120)
    Check 'sound: quieter volume lowers the peak (~1/3)' ($peakQuiet -lt ($peakFull / 2) -and $peakQuiet -gt 0)

    # Get-WikiProfileVaults (config-driven vault routing)
    $wikiCfg = ConvertFrom-Json '{"wikiVaults":{"corporate":{"vault":"X:/wiki","sources":"X:/raw"},"broken":{"sources":"X:/r"}}}'
    $map = Get-WikiProfileVaults $wikiCfg
    Check 'wikimap: routed profile present'   ($map.ContainsKey('corporate') -and $map['corporate'].vault -eq 'X:/wiki')
    Check 'wikimap: vault-less entry ignored' (-not $map.ContainsKey('broken'))
    Check 'wikimap: absent key -> empty map'  ((Get-WikiProfileVaults (ConvertFrom-Json '{}')).Count -eq 0)
    Check 'wikimap: null config -> empty map' ((Get-WikiProfileVaults $null).Count -eq 0)

    # =======================================================================
    # 6. Quoting and command builders
    # =======================================================================
    Check 'psquote: embedded single quote doubled' ((ConvertTo-PowerShellQuotedString "it's") -eq "'it''s'")
    Check 'posix: embedded single quote spliced' ((ConvertTo-PosixQuotedString "don't") -eq ("'don'" + '"' + "'" + '"' + "'t'"))
    Check 'argv: plain arg unquoted'        ((Format-ProcessArgument 'plain') -eq 'plain')
    Check 'argv: spaces quoted'             ((Format-ProcessArgument 'has space') -eq '"has space"')
    Check 'argv: trailing backslash doubled' ((Format-ProcessArgument 'a b\') -eq '"a b\\"')
    Check 'argv: embedded quote escaped'    ((Format-ProcessArgument 'say "hi"') -eq '"say \"hi\""')
    Check 'argv: backslash before quote'    ((Format-ProcessArgument 'a\"b') -eq '"a\\\"b"')
    Check 'split: simple command line'      ((@(Split-CommandLine 'npx ai-codex') -join '|') -eq 'npx|ai-codex')
    Check 'split: quoted token kept whole'  ((@(Split-CommandLine 'a "b c" d') -join '|') -eq 'a|b c|d')
    Check 'jigcmd: no claude args'   ((New-JigRunCommand 'standard') -eq "& jig 'run' 'standard'")
    Check 'jigcmd: args after --'    ((New-JigRunCommand 'standard' @('--name','x')) -eq "& jig 'run' 'standard' '--' '--name' 'x'")
    Check 'picmd: provider+model'    ((New-PiCommand) -eq "& pi '--provider' 'my-proxy' '--model' 'claude-opus-4-8'")
    Check 'picmd: extra args appended' ((New-PiCommand @('--continue')) -eq "& pi '--provider' 'my-proxy' '--model' 'claude-opus-4-8' '--continue'")
    $PiModelCycle = 'claude-opus-4-8,claude-sonnet-5'
    Check 'picmd: model cycle passed, provider-qualified' ((New-PiCommand @('--name','m')) -eq "& pi '--provider' 'my-proxy' '--model' 'claude-opus-4-8' '--models' 'my-proxy/claude-opus-4-8,my-proxy/claude-sonnet-5' '--name' 'm'")
    # bare ids resolved against every provider in pi (Sonnet/Haiku landed on anthropic/,
    # bypassing the configured provider; opus-5-5 became opus-5-5-200k) - so they get qualified
    Check 'picycle: bare ids qualified'          ((ConvertTo-PiModelCycle 'claude-opus-5-5, claude-haiku-4-5' 'my-proxy') -eq 'my-proxy/claude-opus-5-5,my-proxy/claude-haiku-4-5')
    Check 'picycle: thinking suffix kept'        ((ConvertTo-PiModelCycle 'claude-opus-5-5:high' 'my-proxy') -eq 'my-proxy/claude-opus-5-5:high')
    Check 'picycle: explicit provider untouched' ((ConvertTo-PiModelCycle 'anthropic/claude-sonnet-5,koboldcpp/qwen3-coder-30b' 'my-proxy') -eq 'anthropic/claude-sonnet-5,koboldcpp/qwen3-coder-30b')
    Check 'picycle: globs untouched'             ((ConvertTo-PiModelCycle '*sonnet*,claude-opus-5-?' 'my-proxy') -eq '*sonnet*,claude-opus-5-?')
    Check 'picycle: empty entries dropped'       ((ConvertTo-PiModelCycle 'a,, ,b' 'p') -eq 'p/a,p/b')
    Check 'picycle: empty cycle -> no --models'  ((ConvertTo-PiModelCycle '' 'my-proxy') -eq '')
    $PiModelCycle = ''
    # Empty provider/model: plain `pi`, so pi's own ~/.pi/agent/settings.json decides (existing setups work as is).
    $savedProv = $PiProvider; $savedModel = $PiModel
    $PiProvider = ''; $PiModel = ''
    Check 'picmd: no provider/model -> pi uses its own settings' ((New-PiCommand) -eq '& pi')
    Check 'picmd: no provider/model, args still passed' ((New-PiCommand @('--continue')) -eq "& pi '--continue'")
    Check 'pilabel: nothing set -> pi default' ((Get-PiModelLabel) -eq "pi's own default model")
    $PiProvider = 'my-proxy'
    Check 'picmd: provider only -> no --model' ((New-PiCommand) -eq "& pi '--provider' 'my-proxy'")
    Check 'pilabel: provider only' ((Get-PiModelLabel) -eq "my-proxy (pi's default model)")
    $PiProvider = ''; $PiModelCycle = 'claude-opus-4-8,claude-sonnet-5'
    Check 'picycle: no provider -> ids passed unqualified' ((New-PiCommand) -eq "& pi '--models' 'claude-opus-4-8,claude-sonnet-5'")
    $PiProvider = $savedProv; $PiModel = $savedModel; $PiModelCycle = ''
    Check 'pilabel: provider + model' ((Get-PiModelLabel) -eq 'my-proxy/claude-opus-4-8')

    # =======================================================================
    # 7. Session history (hermetic fixtures under $ClaudeProjectsDir)
    # =======================================================================
    Check 'enc: separators dashed'   ((Get-SessionFolderName 'F:\AI\mission-centre') -eq 'F--AI-mission-centre')
    Check 'enc: dots dashed'         ((Get-SessionFolderName 'F:\AI\my.app') -eq 'F--AI-my-app')
    Check 'enc: underscores dashed'  ((Get-SessionFolderName '/home/you/my_proj') -eq '-home-you-my-proj')
    Check 'enc: spaces dashed'       ((Get-SessionFolderName 'G:\Shared drives\X Y') -eq 'G--Shared-drives-X-Y')

    # labels: the three observed line formats
    $labDir = Join-Path $TestRoot 'labels'
    New-Item -ItemType Directory -Path $labDir -Force | Out-Null
    $f1 = Join-Path $labDir 'f1.jsonl'
    @(
        '{"type":"permission-mode","mode":"default"}',
        '{"type":"file-history-snapshot","files":[]}',
        '{"type":"user","message":{"role":"user","content":"Fix the login bug please"}}',
        '{"type":"custom-title","customTitle":"fix-login-flow"}'
    ) | Set-Content $f1 -Encoding UTF8
    Check 'label: custom-title preferred, hyphens to spaces' ((Get-SessionLabel $f1) -eq 'fix login flow')
    $f2 = Join-Path $labDir 'f2.jsonl'
    '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello from blocks"}]}}' |
        Set-Content $f2 -Encoding UTF8
    Check 'label: array-of-blocks content' ((Get-SessionLabel $f2) -eq 'hello from blocks')
    $f2b = Join-Path $labDir 'f2b.jsonl'
    '{"type":"user","message":{"role":"user","content":[{"type":"image","source":"x"},{"type":"text","text":"after image"}]}}' |
        Set-Content $f2b -Encoding UTF8
    Check 'label: first text block wins past non-text blocks' ((Get-SessionLabel $f2b) -eq 'after image')
    $f3 = Join-Path $labDir 'f3.jsonl'
    @('this line is not json', '{"role":"user","content":"format C prompt"}') | Set-Content $f3 -Encoding UTF8
    Check 'label: role/content format, garbage tolerated' ((Get-SessionLabel $f3) -eq 'format C prompt')
    Check 'label: missing file -> null' ($null -eq (Get-SessionLabel (Join-Path $labDir 'nope.jsonl')))

    # indexed project: recency probe + cache + invalidation + enrichment
    $projIndexed = Join-Path $TestRoot 'work\proj-indexed'
    $idxFolder = Join-Path $ClaudeProjectsDir (Get-SessionFolderName $projIndexed)
    New-Item -ItemType Directory -Path $idxFolder -Force | Out-Null
    $idxPath = Join-Path $idxFolder 'sessions-index.json'
    @'
{ "entries": [
  { "sessionId": "s1", "summary": "compact summary s1", "messageCount": 12, "fileMtime": 1000000, "modified": "2026-01-01T00:00:00Z" },
  { "sessionId": "s2", "messageCount": 3, "fileMtime": 2000000, "modified": "2026-01-02T00:00:00Z" }
] }
'@ | Set-Content $idxPath -Encoding UTF8
    '{"type":"user","message":{"role":"user","content":"opener for s2"}}' |
        Set-Content (Join-Path $idxFolder 's2.jsonl') -Encoding UTF8

    Check 'recency: newest index mtime wins' ((Get-ProjectLastActivityMs $projIndexed) -eq 2000000)
    Check 'recency: cache populated'         ($script:McActivityMsCache.ContainsKey($idxPath))
    Check 'recency: cached call stable'      ((Get-ProjectLastActivityMs $projIndexed) -eq 2000000)
    (Get-Content $idxPath -Raw -Encoding UTF8).Replace('2000000', '3000000') | Set-Content $idxPath -Encoding UTF8
    Check 'recency: cache invalidates when the index is rewritten' ((Get-ProjectLastActivityMs $projIndexed) -eq 3000000)

    $recent = @(Get-RecentSessions $projIndexed)
    Check 'sessions: sorted newest first'            ($recent.Count -eq 2 -and $recent[0].sessionId -eq 's2')
    Check 'sessions: summary-less entry enriched from jsonl' ($recent[0].firstPrompt -eq 'opener for s2')
    Check 'sessions: indexed summary preserved'      ($recent[1].summary -eq 'compact summary s1')

    # index-less project: jsonl fallback
    $projPlain = Join-Path $TestRoot 'work\proj-plain'
    $plainFolder = Join-Path $ClaudeProjectsDir (Get-SessionFolderName $projPlain)
    New-Item -ItemType Directory -Path $plainFolder -Force | Out-Null
    $old = Join-Path $plainFolder 'old.jsonl'; $new = Join-Path $plainFolder 'new.jsonl'
    '{"type":"user","message":{"role":"user","content":"old session"}}' | Set-Content $old -Encoding UTF8
    '{"type":"user","message":{"role":"user","content":"new session"}}' | Set-Content $new -Encoding UTF8
    (Get-Item $old).LastWriteTime = [datetime]'2026-01-05 10:00:00'
    (Get-Item $new).LastWriteTime = [datetime]'2026-01-06 10:00:00'
    $fallback = @(Get-RecentSessions $projPlain)
    Check 'sessions: fallback sorted newest first' ($fallback.Count -eq 2 -and $fallback[0].sessionId -eq 'new')
    Check 'sessions: fallback labels from jsonl'   ($fallback[0].firstPrompt -eq 'new session')
    $expectedMs = [long](((Get-Item $new).LastWriteTime.ToUniversalTime() - [datetime]'1970-01-01').TotalMilliseconds)
    Check 'recency: fallback uses newest jsonl mtime' ((Get-ProjectLastActivityMs $projPlain) -eq $expectedMs)
    Check 'recency: unknown project -> 0' ((Get-ProjectLastActivityMs (Join-Path $TestRoot 'work\never-opened')) -eq 0)

    # pi sessions count as activity too ([PI]/[PC] launches never used to reach the list)
    Check 'pi-dir: Windows path'     ((Get-PiSessionFolderName 'F:\AI\Pi Mono') -eq '--F--AI-Pi Mono--')
    Check 'pi-dir: dots/spaces kept' ((Get-PiSessionFolderName 'D:\Work\My App\Demo.Web.App') -eq '--D--Work-My App-Demo.Web.App--')
    Check 'pi-dir: POSIX path'       ((Get-PiSessionFolderName '/home/you/proj') -eq '--home-you-proj--')
    Check 'pi-dir: trailing sep'     ((Get-PiSessionFolderName 'F:\AI\proj\') -eq '--F--AI-proj--')
    $PiSessionsDir = Join-Path $TestRoot 'pi-sessions'
    $toMs = { param($t) [long](($t.ToUniversalTime() - [datetime]'1970-01-01').TotalMilliseconds) }
    # pi-only project (no Claude history at all) must appear
    $projPiOnly = Join-Path $TestRoot 'work\pi-only'
    $piOnlyDir = Join-Path $PiSessionsDir (Get-PiSessionFolderName $projPiOnly)
    New-Item -ItemType Directory -Path $piOnlyDir -Force | Out-Null
    $piFile = Join-Path $piOnlyDir '2026-01-07T10-00-00-000Z_abc.jsonl'
    '{"type":"session"}' | Set-Content $piFile -Encoding UTF8
    (Get-Item $piFile).LastWriteTime = [datetime]'2026-01-07 10:00:00'
    Check 'recency: pi-only project counted' ((Get-ProjectLastActivityMs $projPiOnly) -eq (& $toMs ([datetime]'2026-01-07 10:00:00')))
    # [PC] continue appends to the SAME file: its mtime must move the project up
    (Get-Item $piFile).LastWriteTime = [datetime]'2026-01-08 09:00:00'
    Check 'recency: pi continue (same file) moves it up' ((Get-ProjectLastActivityMs $projPiOnly) -eq (& $toMs ([datetime]'2026-01-08 09:00:00')))
    # both engines: the newer one wins, either way round ($projPlain's Claude history is 2026-01-06)
    $plainPiDir = Join-Path $PiSessionsDir (Get-PiSessionFolderName $projPlain)
    New-Item -ItemType Directory -Path $plainPiDir -Force | Out-Null
    $plainPi = Join-Path $plainPiDir 'p.jsonl'; '{}' | Set-Content $plainPi -Encoding UTF8
    (Get-Item $plainPi).LastWriteTime = [datetime]'2026-01-09 10:00:00'
    Check 'recency: newer pi beats older Claude'  ((Get-ProjectLastActivityMs $projPlain) -eq (& $toMs ([datetime]'2026-01-09 10:00:00')))
    (Get-Item $plainPi).LastWriteTime = [datetime]'2026-01-01 10:00:00'
    Check 'recency: newer Claude beats older pi'  ((Get-ProjectLastActivityMs $projPlain) -eq $expectedMs)
    # non-session files are ignored; no pi dir configured -> Claude-only behaviour
    Set-Content (Join-Path $plainPiDir 'notes.txt') 'x'
    (Get-Item (Join-Path $plainPiDir 'notes.txt')).LastWriteTime = [datetime]'2026-02-01'
    Check 'recency: non-jsonl files ignored'      ((Get-ProjectLastActivityMs $projPlain) -eq $expectedMs)
    $PiSessionsDir = ''
    Check 'recency: no pi dir -> Claude only'     ((Get-ProjectLastActivityMs $projPiOnly) -eq 0)
    $PiSessionsDir = Join-Path $TestRoot 'pi-sessions'

    # display helpers
    Check 'trunc: whitespace collapsed' ((Get-TruncatedSummary "a`r`nb`tc" 55) -eq 'a b c')
    Check 'trunc: long text ellipsised' ((Get-TruncatedSummary ('x' * 80) 10) -eq ('x' * 7 + '...'))
    Check 'trunc: empty passthrough'    ((Get-TruncatedSummary '' 10) -eq '')

    # =======================================================================
    # 9. Wiki config writer (redirected to the fixture dir)
    # =======================================================================
    $WikiProfileVaults = @{ corporate = @{ vault = 'X:/w'; sources = 'X:/r' } }
    Set-WikiConfig 'corporate'
    Check 'wikicfg: vaulted profile writes config' (Test-Path $WikiConfigPath)
    $cfgText = Get-Content $WikiConfigPath -Raw
    Check 'wikicfg: vault path written' ($cfgText.Contains('OBSIDIAN_VAULT_PATH=X:/w'))
    $bytes = [System.IO.File]::ReadAllBytes($WikiConfigPath)
    Check 'wikicfg: BOM-free for bash consumers' (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF))
    Set-WikiConfig 'standard'
    Check 'wikicfg: unrouted profile clears config' (-not (Test-Path $WikiConfigPath))
    if ($IsWinHost) {
        Set-WikiConfig 'corporate'
        $fs = [System.IO.File]::Open($WikiConfigPath, 'Open', 'Read', 'None')   # exclusive lock
        $threw = $false
        try { Set-WikiConfig 'corporate' } catch { $threw = $true }
        $fs.Close()
        Check 'wikicfg: locked file warns instead of killing the app' (-not $threw)
    } else {
        Skip 'wikicfg: locked file behavior' 'exclusive file locks are Windows semantics'
    }

    # =======================================================================
    # 10. Profile descriptions (bundled fallback, hermetic)
    # =======================================================================
    New-Item -ItemType Directory -Path $BundledJigProfilesDir -Force | Out-Null
    @('name: mc-test-profile-zzz', 'description: "Test profile description"', 'skills: []') |
        Set-Content (Join-Path $BundledJigProfilesDir 'mc-test-profile-zzz.yaml') -Encoding UTF8
    Check 'profile: description parsed from bundled yaml' ((Get-ProfileDescription 'mc-test-profile-zzz') -eq 'Test profile description')
    Check 'profile: unknown profile -> empty' ((Get-ProfileDescription 'mc-no-such-profile-zzz') -eq '')

    # Get-ProfilePermissionMode: direct key, extends chain, unknown/absent
    @('name: mc-test-permmode-zzz', 'permission_mode: plan') |
        Set-Content (Join-Path $BundledJigProfilesDir 'mc-test-permmode-zzz.yaml') -Encoding UTF8
    @('name: mc-test-permchild-zzz', 'extends: mc-test-permmode-zzz') |
        Set-Content (Join-Path $BundledJigProfilesDir 'mc-test-permchild-zzz.yaml') -Encoding UTF8
    Check 'permmode: direct key resolved' ((Get-ProfilePermissionMode 'mc-test-permmode-zzz') -eq 'plan')
    Check 'permmode: extends chain followed' ((Get-ProfilePermissionMode 'mc-test-permchild-zzz') -eq 'plan')
    Check 'permmode: unknown profile -> empty' ((Get-ProfilePermissionMode 'mc-no-such-profile-zzz') -eq '')
    Check 'permmode: no key and no extends -> empty' ((Get-ProfilePermissionMode 'mc-test-profile-zzz') -eq '')

    # Get-JigProfileDrift: line-ending-only difference is identical; real change differs
    $driftBundled = Join-Path $TestRoot 'drift-bundled'; $driftInstalled = Join-Path $TestRoot 'drift-installed'
    New-Item -ItemType Directory -Path $driftBundled, $driftInstalled -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $driftBundled 'same.yaml'), "name: same`nmodel: opus`n")
    [IO.File]::WriteAllText((Join-Path $driftInstalled 'same.yaml'), "name: same`r`nmodel: opus`r`n")
    [IO.File]::WriteAllText((Join-Path $driftBundled 'changed.yaml'), "name: changed`npermission_mode: plan`n")
    [IO.File]::WriteAllText((Join-Path $driftInstalled 'changed.yaml'), "name: changed`npermission_mode: bypassPermissions`n")
    [IO.File]::WriteAllText((Join-Path $driftBundled 'newone.yaml'), "name: newone`n")
    $driftMap = @{}
    foreach ($d in @(Get-JigProfileDrift $driftBundled $driftInstalled)) { $driftMap[$d.name] = $d.status }
    Check 'drift: CRLF/LF-only difference reads identical' ($driftMap['same'] -eq 'identical')
    Check 'drift: content change detected' ($driftMap['changed'] -eq 'differs')
    Check 'drift: missing installed copy detected' ($driftMap['newone'] -eq 'missing')
    Check 'drift: absent bundled dir -> empty' (@(Get-JigProfileDrift (Join-Path $TestRoot 'no-such-bundled') $driftInstalled).Count -eq 0)

    # Get-PluginCacheDrift: hermetic fake ~/.claude with a directory marketplace
    $fakeClaude = Join-Path $TestRoot 'fake-claude'
    $pcSrc = Join-Path $TestRoot 'plugin-src'; $pcCache = Join-Path $TestRoot 'plugin-cache'
    New-Item -ItemType Directory -Path (Join-Path $fakeClaude 'plugins'), (Join-Path $pcSrc 'skills\alpha'), (Join-Path $pcSrc 'skills\beta'), (Join-Path $pcCache 'skills\alpha') -Force | Out-Null
    'x' | Set-Content (Join-Path $pcSrc 'skills\alpha\SKILL.md')
    'x' | Set-Content (Join-Path $pcSrc 'skills\beta\SKILL.md')
    'x' | Set-Content (Join-Path $pcCache 'skills\alpha\SKILL.md')
    (@{ extraKnownMarketplaces = @{ testmkt = @{ source = @{ source = 'directory'; path = $pcSrc } } } } | ConvertTo-Json -Depth 6) |
        Set-Content (Join-Path $fakeClaude 'settings.json') -Encoding UTF8
    (@{ version = 1; plugins = @{ 'testplug@testmkt' = @(@{ scope = 'user'; installPath = $pcCache; version = '1.0.0' }) } } | ConvertTo-Json -Depth 6) |
        Set-Content (Join-Path $fakeClaude 'plugins\installed_plugins.json') -Encoding UTF8
    $pd = @(Get-PluginCacheDrift -ClaudeDir $fakeClaude)
    Check 'plugindrift: skill missing from cache detected' ($pd.Count -eq 1 -and @($pd[0].missingInCache) -contains 'beta')
    Check 'plugindrift: absent claude dir -> empty' (@(Get-PluginCacheDrift -ClaudeDir (Join-Path $TestRoot 'no-such-claude')).Count -eq 0)

    # =======================================================================
    # 11. Bundled skill install (hermetic; redirect both harness skills roots)
    #     Claude Code reads ~/.claude/skills; pi + Codex read ~/.agents/skills.
    # =======================================================================
    $vibeSrc = Join-Path $BundledSkillsDir 'vibe-check'
    $skillSrc = Join-Path $vibeSrc 'references'
    New-Item -ItemType Directory -Path $skillSrc -Force | Out-Null
    'frontmatter' | Set-Content (Join-Path $vibeSrc 'SKILL.md') -Encoding UTF8
    'ref' | Set-Content (Join-Path $skillSrc 'GROWTH-LOOPS.md') -Encoding UTF8
    $jqSrc = Join-Path $BundledSkillsDir 'jq'
    New-Item -ItemType Directory -Path $jqSrc -Force | Out-Null
    'jq frontmatter' | Set-Content (Join-Path $jqSrc 'SKILL.md') -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $BundledSkillsDir 'not-a-skill') -Force | Out-Null

    $fakeSkillsDir = Join-Path $TestRoot 'claude-skills'
    $fakeAgentsSkillsDir = Join-Path $TestRoot 'agents-skills'
    function Get-GlobalClaudeSkillsDir { $fakeSkillsDir }        # hermetic overrides (never
    function Get-GlobalAgentsSkillsDir { $fakeAgentsSkillsDir }  # touch real ~/.claude or ~/.agents)

    $names = @(Get-BundledSkillNames)
    Check 'skill: bundled names = folders with SKILL.md' (($names -join ',') -eq 'jq,vibe-check')
    Check 'skill: fresh status is missing everywhere' (@(Get-BundledSkillStatus | Where-Object { $_.status -ne 'missing' }).Count -eq 0)

    $installed = Install-BundledSkill -Name 'vibe-check' -Quiet
    Check 'skill: Install-BundledSkill returns true' ($installed -eq $true)
    foreach ($root in @($fakeSkillsDir, $fakeAgentsSkillsDir)) {
        $leaf = Split-Path $root -Leaf
        Check "skill: SKILL.md copied to $leaf" (Test-Path (Join-Path (Join-Path $root 'vibe-check') 'SKILL.md') -PathType Leaf)
        Check "skill: references/ copied recursively to $leaf" (Test-Path (Join-Path (Join-Path (Join-Path $root 'vibe-check') 'references') 'GROWTH-LOOPS.md') -PathType Leaf)
    }
    Check 'skill: Test-BundledSkillInstalled sees the install' (Test-BundledSkillInstalled 'vibe-check')
    Check 'skill: quiet re-run is idempotent no-op' ((Install-BundledSkill -Name 'vibe-check' -Quiet) -eq $true)

    # pi-only gap (e.g. vibe-check previously installed for Claude Code only) gets filled
    Remove-Item (Join-Path $fakeAgentsSkillsDir 'vibe-check') -Recurse -Force
    Check 'skill: pi-side gap reported as not installed' (-not (Test-BundledSkillInstalled 'vibe-check'))
    Check 'skill: Install-BundledSkills -Quiet installs all' ((Install-BundledSkills -Quiet) -eq $true)
    Check 'skill: pi-side gap filled' (Test-BundledSkillInstalled 'vibe-check')
    Check 'skill: jq installed for both harnesses' (Test-BundledSkillInstalled 'jq')
    Check 'skill: status identical after install' (@(Get-BundledSkillStatus | Where-Object { $_.status -ne 'identical' }).Count -eq 0)

    # a locally edited install is reported as drift but -Quiet never overwrites it
    $editedSkill = Join-Path (Join-Path $fakeAgentsSkillsDir 'jq') 'SKILL.md'
    'local edit' | Set-Content $editedSkill -Encoding UTF8
    $jqRows = @(Get-BundledSkillStatus -Names @('jq'))
    Check 'skill: edited install reported as differs' (@($jqRows | Where-Object { $_.harness -eq 'pi/Codex' -and $_.status -eq 'differs' }).Count -eq 1)
    [void](Install-BundledSkills -Quiet)
    Check 'skill: quiet install leaves edited copy alone' ((Get-Content $editedSkill -Raw).Trim() -eq 'local edit')

    # missing source bundle reports failure rather than throwing
    $BundledSkillsDir = Join-Path $TestRoot 'no-such-bundle'
    Check 'skill: missing bundle returns false' ((Install-BundledSkill -Name 'vibe-check' -Quiet) -eq $false)
    Check 'skill: no bundle -> no names' (@(Get-BundledSkillNames).Count -eq 0)

    # the real repo bundle: every skill carries frontmatter name + description (pi skips skills without a description)
    foreach ($sd in @(Get-ChildItem (Join-Path $RepoRoot 'skills') -Directory)) {
        $head = (Get-Content (Join-Path $sd.FullName 'SKILL.md') -TotalCount 6) -join "`n"
        Check "skill: repo $($sd.Name) has name + description frontmatter" ($head -match '(?m)^---' -and $head -match "(?m)^name:\s*$([regex]::Escape($sd.Name))\s*$" -and $head -match '(?m)^description:\s*\S')
    }

    # =======================================================================
    # Starter profiles: backups, the permission_mode key, and asking once per drift
    # =======================================================================
    $profBundle = Join-Path $TestRoot 'prof-bundle'; $profHome = Join-Path $TestRoot 'prof-home'
    New-Item -ItemType Directory -Path $profBundle, $profHome -Force | Out-Null
    "name: standard`npermission_mode: default`n" | Set-Content (Join-Path $profBundle 'standard.yaml') -Encoding UTF8
    "name: standard`npermission-mode: plan`n# my own tweak`n" | Set-Content (Join-Path $profHome 'standard.yaml') -Encoding UTF8
    Check 'profiles: hyphen permission-mode is flagged (Jig ignores it)' ((@(Get-JigProfileKeyWarnings $profHome) -join ',') -eq 'standard.yaml')
    Check 'profiles: underscore permission_mode is fine' (@(Get-JigProfileKeyWarnings $profBundle).Count -eq 0)
    $savedBundledProf = $BundledJigProfilesDir; $BundledJigProfilesDir = $profBundle
    $origGjp = ${function:Get-GlobalJigProfilesDir}; $origPcd = ${function:Get-PluginCacheDrift}; $origRyn = ${function:Read-YesNo}
    function Get-GlobalJigProfilesDir { $profHome }
    function jig { $global:LASTEXITCODE = 0 }            # stub: never the real jig
    function Get-PluginCacheDrift { @() }
    $script:yesNoAsked = 0; $script:yesNoAnswer = $false
    function Read-YesNo { param($Prompt, $Default) $script:yesNoAsked++; $script:yesNoLastDefault = $Default; return $script:yesNoAnswer }
    function Read-Host { param($Prompt) '' }
    Invoke-StartupDriftCheck 6>$null
    Check 'profiles: startup asks once, default No' ($script:yesNoAsked -eq 1 -and $script:yesNoLastDefault -eq 'N')
    Invoke-StartupDriftCheck 6>$null
    Check 'profiles: a declined drift is not asked again' ($script:yesNoAsked -eq 1)
    "name: standard`npermission_mode: plan`n# changed again`n" | Set-Content (Join-Path $profHome 'standard.yaml') -Encoding UTF8
    Invoke-StartupDriftCheck 6>$null
    Check 'profiles: a changed drift is asked again' ($script:yesNoAsked -eq 2)
    $script:yesNoAnswer = $true
    Install-StarterJigProfiles 6>$null
    $baks = @(Get-ChildItem $profHome -Filter 'standard.yaml.bak-*')
    Check 'profiles: update backs up your copy first' ($baks.Count -eq 1 -and (Get-Content $baks[0].FullName -Raw) -match 'changed again')
    Check 'profiles: bundled version installed' ((Get-Content (Join-Path $profHome 'standard.yaml') -Raw) -match 'permission_mode: default')
    Set-Item Function:\Get-GlobalJigProfilesDir $origGjp; Set-Item Function:\Get-PluginCacheDrift $origPcd; Set-Item Function:\Read-YesNo $origRyn
    Remove-Item Function:\jig, Function:\Read-Host
    $BundledJigProfilesDir = $savedBundledProf

    # =======================================================================
    # Skills updated from their own upstream (lib/66-sources.ps1) - local bare repo as upstream
    # =======================================================================
    Check 'src: MIT text matches MIT'          (Test-SkillLicenceMatches "MIT License`n`nCopyright (c) 2026 X" 'MIT')
    Check 'src: MIT permission text matches'  (Test-SkillLicenceMatches 'Permission is hereby granted, free of charge, to any person' 'MIT')
    Check 'src: changed licence refused'      (-not (Test-SkillLicenceMatches 'Copyright X. All rights reserved.' 'MIT'))
    Check 'src: missing licence refused'      (-not (Test-SkillLicenceMatches '' 'MIT'))
    Check 'src: Apache 2.0 matches'           (Test-SkillLicenceMatches "Apache License`nVersion 2.0, January 2004" 'Apache-2.0')
    $gitExeS = (Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($gitExeS) {
        $gs = $gitExeS.Source
        $eapSrc = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # git writes progress to stderr (5.1 + Stop = fatal)
        $gid = @('-c', 'user.email=t@example.invalid', '-c', 'user.name=t', '-c', 'commit.gpgsign=false')
        $upBare = Join-Path $TestRoot 'skill-upstream.git'
        $upWork = Join-Path $TestRoot 'skill-upstream-work'
        [void](& $gs init --quiet --bare -b main $upBare 2>&1)
        [void](& $gs init --quiet -b main $upWork 2>&1)
        $commitUp = { param($skillText, $licText, $msg)
            Set-Content (Join-Path $upWork 'SKILL.md') $skillText -Encoding UTF8
            Set-Content (Join-Path $upWork 'LICENSE') $licText -Encoding UTF8
            Set-Content (Join-Path $upWork 'README.md') 'not vendored' -Encoding UTF8
            [void](& $gs -C $upWork add -A 2>&1); [void](& $gs -C $upWork @gid commit --quiet -m $msg 2>&1)
            [void](& $gs -C $upWork push --quiet $upBare HEAD:main 2>&1)
            return ([string](& $gs -C $upWork rev-parse HEAD)).Trim() }
        # file:// URL built by hand: works for git on Windows (file:///C:/...) and macOS (file:///var/...).
        $upUrl = $upBare.Replace('\', '/')
        if ($upUrl -notmatch '^/') { $upUrl = '/' + $upUrl }
        $upUrl = 'file://' + $upUrl
        $c1 = & $commitUp "---`nname: upskill`ndescription: d`n---`nv1" 'MIT License' 'v1'

        $savedBundle = $BundledSkillsDir; $savedState = $MissionStateDir
        $BundledSkillsDir = Join-Path $TestRoot 'bundle-src'; $MissionStateDir = Join-Path $TestRoot 'state-src'
        $bsk = Join-Path $BundledSkillsDir 'upskill'
        New-Item -ItemType Directory -Path $bsk -Force | Out-Null
        Copy-Item (Join-Path $upWork 'SKILL.md'), (Join-Path $upWork 'LICENSE') $bsk
        'provenance' | Set-Content (Join-Path $bsk 'VENDORED.md') -Encoding UTF8
        ([ordered]@{ repo = $upUrl; ref = 'main'; commit = $c1; include = @('SKILL.md', 'LICENSE'); licence = 'MIT' } | ConvertTo-Json) |
            Set-Content (Join-Path $bsk 'source.json') -Encoding UTF8
        $claudeCopy = Join-Path (Join-Path $fakeSkillsDir 'upskill') 'SKILL.md'
        $agentsCopy = Join-Path (Join-Path $fakeAgentsSkillsDir 'upskill') 'SKILL.md'
        [void](Install-BundledSkill -Name 'upskill' -Quiet 6>$null)
        Check 'src: no source.json -> not an upstream skill' ($null -eq (Get-SkillSourceConfig 'jq'))
        Check 'src: source copy starts as the bundled one' ((Get-SkillSourceDir 'upskill') -eq $bsk)
        $r1 = Update-SkillFromSource 'upskill'
        if ($r1.status -ne 'current') { Write-Host "      upstream $upUrl -> $($r1.status): $($r1.detail)" -ForegroundColor Red }
        Check 'src: upstream unchanged -> current' ($r1.status -eq 'current')

        $c2 = & $commitUp "---`nname: upskill`ndescription: d`n---`nv2" 'MIT License' 'v2'
        $r2 = Update-SkillFromSource 'upskill'
        if ($r2.status -ne 'updated') { Write-Host "      $($r2.status): $($r2.detail)" -ForegroundColor Red }
        Check 'src: new upstream commit -> updated' ($r2.status -eq 'updated')
        Check 'src: both harnesses get the upstream version' ((Get-Content $claudeCopy -Raw) -match 'v2' -and (Get-Content $agentsCopy -Raw) -match 'v2')
        Check 'src: provenance files kept, unlisted upstream files not copied' ((Test-Path (Join-Path (Split-Path $agentsCopy) 'VENDORED.md')) -and -not (Test-Path (Join-Path (Split-Path $agentsCopy) 'README.md')))
        Check 'src: installs now come from the staged copy' ((Get-SkillSourceDir 'upskill') -eq (Get-SkillStagingDir 'upskill'))
        Check 'src: staged source.json records the new commit' ((Get-SkillSourceCommit 'upskill') -eq $c2)
        Check 'src: status sees the update as identical (no false drift)' (@(Get-BundledSkillStatus -Names @('upskill') | Where-Object { $_.status -ne 'identical' }).Count -eq 0)
        Check 'src: repo bundle untouched' ((Get-Content (Join-Path $bsk 'SKILL.md') -Raw) -match 'v1')

        'my own edit' | Set-Content $claudeCopy -Encoding UTF8
        $c3 = & $commitUp "---`nname: upskill`ndescription: d`n---`nv3" 'MIT License' 'v3'
        $r3 = Update-SkillFromSource 'upskill'
        Check 'src: an edited install is never overwritten' ($r3.status -eq 'updated' -and (Get-Content $claudeCopy -Raw).Trim() -eq 'my own edit' -and $r3.detail -match 'kept your changed copy for Claude Code')
        Check 'src: the unedited install still updates' ((Get-Content $agentsCopy -Raw) -match 'v3')

        [void](& $commitUp "---`nname: upskill`ndescription: d`n---`nv4" 'Copyright X. All rights reserved.' 'relicensed')
        $r4 = Update-SkillFromSource 'upskill'
        Check 'src: upstream licence change -> refused, nothing installed' ($r4.status -eq 'refused' -and (Get-Content $agentsCopy -Raw) -match 'v3' -and (Get-SkillSourceCommit 'upskill') -eq $c3)

        $BundledSkillsDir = $savedBundle; $MissionStateDir = $savedState; $ErrorActionPreference = $eapSrc
        Remove-Item (Join-Path $fakeSkillsDir 'upskill'), (Join-Path $fakeAgentsSkillsDir 'upskill') -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Skip 'src: skill update from upstream' 'git not found'
    }
    # The real repo: a vendored skill (VENDORED.md) always ships its licence file.
    foreach ($vd in @(Get-ChildItem (Join-Path $RepoRoot 'skills') -Recurse -Filter 'VENDORED.md' -File)) {
        Check "licence: vendored $(Split-Path $vd.DirectoryName -Leaf) ships a LICENSE file" (@(Get-ChildItem $vd.DirectoryName -Filter 'LICENSE*' -File).Count -gt 0)
    }
    # The real repo: every source.json is complete, and its files exist in the bundled copy.
    foreach ($sj in @(Get-ChildItem (Join-Path $RepoRoot 'skills') -Recurse -Filter 'source.json' -File)) {
        $s = Get-Content $sj.FullName -Raw | ConvertFrom-Json
        $okFields = $s.repo -and $s.ref -and ($s.commit -match '^[0-9a-f]{40}$') -and @($s.include).Count -gt 0 -and $s.licence
        $missing = @(@($s.include) | Where-Object { -not (Test-Path (Join-Path $sj.DirectoryName $_)) })
        Check "src: repo $(Split-Path $sj.DirectoryName -Leaf) source.json complete, files present" ($okFields -and $missing.Count -eq 0)
    }

    # =======================================================================
    # Tool update checks (lib/65-updates.ps1) - all hermetic, no npm calls
    # =======================================================================
    # version comparison drives "is this behind?" - the whole feature hinges on it
    Check 'upd: older patch is behind'      ((Compare-SemverLike '0.85.1' '0.87.1') -lt 0)
    Check 'upd: equal versions are equal'   ((Compare-SemverLike '0.87.1' '0.87.1') -eq 0)
    Check 'upd: newer is ahead'             ((Compare-SemverLike '1.2.0' '1.1.9') -gt 0)
    Check 'upd: segment count differs'      ((Compare-SemverLike '1.2' '1.2.1') -lt 0)
    Check 'upd: numeric not lexical (10>9)' ((Compare-SemverLike '0.10.0' '0.9.0') -gt 0)
    # amp-style rotating build tags compare equal numerically but differ textually
    Check 'upd: rotating build tag counts as behind' `
        ((Compare-SemverLike '0.0.1779083535-g196e66' '0.0.1790316087-g0445e9') -lt 0)

    # throttle logic
    $now = (Get-Date).ToString('o')
    $old = (Get-Date).AddHours(-48).ToString('o')
    $stateFresh = @{ 'pkg' = @{ lastCheck = $now; latest = '1.0.0' } }
    $stateOld   = @{ 'pkg' = @{ lastCheck = $old; latest = '1.0.0' } }
    Check 'upd: unknown package is due'        (Test-ToolCheckDue @{} 'pkg' 24)
    Check 'upd: recent check is not due'       (-not (Test-ToolCheckDue $stateFresh 'pkg' 24))
    Check 'upd: stale check is due'            (Test-ToolCheckDue $stateOld 'pkg' 24)
    Check 'upd: interval 0 always due'         (Test-ToolCheckDue $stateFresh 'pkg' 0)
    Check 'upd: unparseable timestamp is due'  (Test-ToolCheckDue @{ 'pkg' = @{ lastCheck = 'garbage'; latest = '' } } 'pkg' 24)

    # state round-trip through the real file path (MissionStateDir is temp here)
    Save-ToolUpdateState @{ 'a-pkg' = @{ lastCheck = $now; latest = '2.3.4' } }
    $roundTrip = Get-ToolUpdateState
    Check 'upd: state round-trips'          ($roundTrip.ContainsKey('a-pkg') -and $roundTrip['a-pkg'].latest -eq '2.3.4')
    Check 'upd: state file written'         (Test-Path (Get-ToolUpdateStatePath) -PathType Leaf)
    # a corrupt cache must degrade to "re-probe", never throw at startup
    Set-Content -Path (Get-ToolUpdateStatePath) -Value '{ not json' -Encoding UTF8
    Check 'upd: corrupt state returns empty' ((Get-ToolUpdateState).Count -eq 0)
    Remove-Item (Get-ToolUpdateStatePath) -Force -ErrorAction SilentlyContinue

    # mode gating: 'off' and empty package lists must do nothing (and not hit npm)
    $ToolUpdatesEnabled = $true; $ToolUpdatesMode = 'off'; $ToolUpdateIntervalHours = 24
    $ToolUpdateIncludeClaudeCode = $false; $ToolUpdatePiOnLaunch = $true
    $ToolUpdatePackages = @('@earendil-works/pi-coding-agent')
    $ToolUpdatePiPackages = @('@earendil-works/pi-coding-agent')
    $offOut = (Invoke-ToolUpdateCheck -Packages $ToolUpdatePackages -Mode 'off' -IntervalHours 24 | Out-String)
    Check 'upd: mode=off is silent no-op' ([string]::IsNullOrWhiteSpace($offOut))
    Check 'upd: empty package list yields no rows' (@(Get-ToolUpdateStatus -Packages @() -IntervalHours 24).Count -eq 0)

    # launch gate respects both the master switch and the per-path switch
    $piGateOut = ''
    $ToolUpdatesEnabled = $false
    $piGateOut += (Invoke-PiLaunchUpdateGate | Out-String)
    $ToolUpdatesEnabled = $true; $ToolUpdatePiOnLaunch = $false
    $piGateOut += (Invoke-PiLaunchUpdateGate | Out-String)
    $ToolUpdatesMode = 'off'; $ToolUpdatePiOnLaunch = $true
    $piGateOut += (Invoke-PiLaunchUpdateGate | Out-String)
    Check 'upd: pi launch gate honours all three off-switches' ([string]::IsNullOrWhiteSpace($piGateOut))

    # startup hook must be inert when disabled
    $ToolUpdatesEnabled = $false
    $startupOut = (Invoke-StartupToolUpdateCheck | Out-String)
    Check 'upd: startup check inert when disabled' ([string]::IsNullOrWhiteSpace($startupOut))

    # Regression: on Windows `Get-Command npm` resolves to npm.ps1, which
    # Start-Process cannot launch. Get-NpmExecutable must hand back a real
    # executable (npm.cmd/npm.exe), never the PowerShell shim.
    if (Get-Command 'npm' -ErrorAction SilentlyContinue) {
        $npmExe = Get-NpmExecutable
        Check 'upd: npm executable resolved'        (-not [string]::IsNullOrWhiteSpace($npmExe))
        Check 'upd: npm executable is not the .ps1 shim' ($npmExe -notmatch '\.ps1$')
        # Regression: Start-Process -PassThru + WaitForExit(ms) can leave ExitCode
        # $null; a naive `-ne 0` check then discards every successful result.
        $npmVer = Invoke-NpmCapture @('--version') 60
        Check 'upd: npm capture returns stdout (null ExitCode handled)' `
            ($null -ne $npmVer -and $npmVer -match '^\d+\.')
    } else {
        Skip 'upd: npm executable resolution' 'npm not on PATH'
    }

    # [U] report with nothing behind: "up to date" only for what npm actually installed. A pi from
    # another package (or a source build) on PATH must not read as current.
    $pkgPi = '@earendil-works/pi-coding-agent'
    $noCmd = { param($n) '' }
    $hasPi = { param($n) if ($n -eq 'pi') { '/opt/homebrew/bin/pi' } else { '' } }
    $rep = @(Get-ToolUpdateReportLines -Rows @([PSCustomObject]@{ package = $pkgPi; installed = '1.3.0' }) -Label 'Toolchain' -FindCommand $noCmd)
    Check 'upd report: all installed -> up to date' ($rep[0].text -eq '  Toolchain up to date' -and $rep[1].text -match '1\.3\.0')
    $rep = @(Get-ToolUpdateReportLines -Rows @([PSCustomObject]@{ package = $pkgPi; installed = '' }) -Label 'Toolchain' -FindCommand $hasPi)
    Check 'upd report: nothing installed -> never says up to date' ($rep[0].text -notmatch 'up to date' -and $rep[0].text -match 'nothing here is installed')
    Check 'upd report: pi from elsewhere on PATH is called out' (@($rep | Where-Object { $_.text -match "The 'pi' on PATH \(/opt/homebrew/bin/pi\) comes from elsewhere" }).Count -eq 1)
    $rep = @(Get-ToolUpdateReportLines -Rows @([PSCustomObject]@{ package = $pkgPi; installed = '' }) -Label 'Toolchain' -FindCommand $noCmd)
    Check 'upd report: missing and not on PATH -> install hint' ($rep[1].text -match 'not installed \(npm i -g @earendil-works/pi-coding-agent\)')
    $rep = @(Get-ToolUpdateReportLines -Rows @([PSCustomObject]@{ package = $pkgPi; installed = '1.3.0' }, [PSCustomObject]@{ package = 'other-cli'; installed = '' }) -Label 'Toolchain' -FindCommand $noCmd)
    Check 'upd report: partly installed -> qualified header' ($rep[0].text -match 'the npm packages that are installed are up to date')

    # Update-ClaudeCode must not report "current" unless Claude says so. A stale Claude
    # Code silently loses access to new models, so failures must be visible.
    # A function named `claude` shadows the real CLI - nothing is updated.
    function claude { $script:FakeClaudeOut }
    $script:FakeClaudeOut = @('Current version: 2.1.282', 'Claude Code is up to date (2.1.282)')
    Check 'claude: up to date -> true'  ((Update-ClaudeCode 6>$null) -eq $true)
    $script:FakeClaudeOut = @('Updating to 2.1.290...', 'Successfully updated from 2.1.282 to version 2.1.290')
    Check 'claude: updated -> true'     ((Update-ClaudeCode 6>$null) -eq $true)
    $script:FakeClaudeOut = @('Checking for updates to latest version...', 'Error: getaddrinfo ENOTFOUND storage.googleapis.com')
    Check 'claude: offline/error -> false (not "current")' ((Update-ClaudeCode 6>$null) -eq $false)
    $script:FakeClaudeOut = @()
    Check 'claude: no output -> false'  ((Update-ClaudeCode 6>$null) -eq $false)

    # winget-managed installs: `claude update` only says "run winget upgrade", so we run it.
    $wingetMsg = @('Current version: 2.1.292', 'Claude is managed by winget.', 'Update available: 2.1.292 -> 2.1.299', 'To update, run:', 'winget upgrade Anthropic.ClaudeCode')
    function Invoke-WingetClaudeUpgrade { $script:WingetCalls++; [PSCustomObject]@{ ok = $true; exit = 0; out = $script:FakeWingetOut } }
    $script:FakeClaudeOut = $wingetMsg; $script:WingetCalls = 0
    $script:FakeWingetOut = "No available upgrade found.`nNo newer package versions are available from the configured sources."
    $quietOut = Update-ClaudeCode -Quiet 6>&1
    Check 'claude/winget: catalogue lag -> true, winget was run' ($script:WingetCalls -eq 1 -and @($quietOut | Where-Object { $_ -is [bool] }) -contains $true)
    Check 'claude/winget: catalogue lag is silent with -Quiet' (@($quietOut | Where-Object { $_ -isnot [bool] }).Count -eq 0)
    $script:FakeWingetOut = 'Successfully installed'
    Check 'claude/winget: upgraded -> true' ((Update-ClaudeCode -Quiet 6>$null) -eq $true)
    $script:FakeWingetOut = 'An unexpected error occurred while executing the command'
    Check 'claude/winget: winget error -> false' ((Update-ClaudeCode -Quiet 6>$null) -eq $false)

    # Claude Code has its own schedule: checked when due even if no npm package is behind.
    $script:FakeWingetOut = 'No available upgrade found.'; $script:WingetCalls = 0
    Save-ToolUpdateState @{}
    Invoke-ClaudeCodeUpdateIfDue -IntervalHours 24 -Mode 'auto' 6>$null
    Check 'claude schedule: due -> checked and stamped' ($script:WingetCalls -eq 1 -and (Get-ToolUpdateState).ContainsKey('claude-code'))
    Invoke-ClaudeCodeUpdateIfDue -IntervalHours 24 -Mode 'auto' 6>$null
    Check 'claude schedule: not due -> skipped' ($script:WingetCalls -eq 1)
    Save-ToolUpdateState @{}; $script:FakeWingetOut = 'boom'
    Invoke-ClaudeCodeUpdateIfDue -IntervalHours 24 -Mode 'auto' 6>$null
    Check 'claude schedule: failure not stamped (retried next launch)' (-not (Get-ToolUpdateState).ContainsKey('claude-code'))
    Invoke-ClaudeCodeUpdateIfDue -IntervalHours 24 -Mode 'off' 6>$null
    Check 'claude schedule: mode off -> nothing' ($script:WingetCalls -eq 2)
    Save-ToolUpdateState @{}
    Remove-Item function:Invoke-WingetClaudeUpgrade
    Remove-Item function:claude

    # Start-Process does not quote -ArgumentList, so args with spaces used to split.
    # Round-trip tricky arguments through a real process and compare what arrives.
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $nodeExe = (Get-Command node).Source
        $tricky = @('fork edit', 'a"b', 'C:\path with space\', '', 'plain', 'x\\"y', 'trail\')
        $echo = Invoke-ProcessCapture -FilePath $nodeExe -ArgumentList (@('-e', 'process.stdout.write(JSON.stringify(process.argv.slice(1)))') + $tricky)
        # PS 5.1 ConvertFrom-Json emits a JSON array as ONE object; foreach unrolls it.
        $got = @()
        if ($echo.ok) { foreach ($x in ($echo.out | ConvertFrom-Json)) { $got += , [string]$x } }
        $same = ($got.Count -eq $tricky.Count)
        if ($same) { for ($i = 0; $i -lt $tricky.Count; $i++) { if ([string]$got[$i] -cne $tricky[$i]) { $same = $false } } }
        Check 'proc: args with spaces/quotes/backslashes/empty arrive intact' $same
        # exit codes must be real numbers: an unknown ($null) code once read as success and
        # let a conflicting git merge go un-aborted
        $ok0 = Invoke-ProcessCapture -FilePath $nodeExe -ArgumentList @('-e', 'process.exit(0)')
        $bad3 = Invoke-ProcessCapture -FilePath $nodeExe -ArgumentList @('-e', 'process.exit(3)')
        Check 'proc: exit 0 -> ok with real code'  ($ok0.ok -and $ok0.exit -eq 0 -and $null -ne $ok0.exit)
        Check 'proc: exit 3 -> not ok, code 3'     ((-not $bad3.ok) -and $bad3.exit -eq 3)
        if (-not $same) { Write-Host ('      sent: ' + ($tricky | ConvertTo-Json -Compress) + '  got: ' + $echo.out) -ForegroundColor Red }
    } else {
        Skip 'proc: argument round-trip' 'node not on PATH'
    }

    # =======================================================================
    # pi fork (pii) updater - hermetic git fixture, never the real checkout
    # =======================================================================
    $fakeFork = Join-Path $TestRoot 'fakefork'
    Check 'fork: no build output detected' (-not (Test-PiForkBuild $fakeFork))
    $distDir = Join-Path $fakeFork 'packages\coding-agent\dist'
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
    Set-Content -Path (Join-Path $distDir 'cli.js') -Value '// stub' -Encoding UTF8
    Check 'fork: build output detected' (Test-PiForkBuild $fakeFork)

    # launcher fallback: pii -> fallback command only when the fork build is missing
    $PiCommand = 'pii'; $PiForkEnabled = $true; $PiForkFallbackCommand = 'git'
    $PiForkRepoPath = $fakeFork
    Check 'fork: build present -> pii used' ((Get-EffectivePiCommand 6>$null) -eq 'pii')
    $PiForkRepoPath = Join-Path $TestRoot 'no-such-fork'
    Check 'fork: build missing -> falls back' ((Get-EffectivePiCommand 6>$null) -eq 'git')
    $PiForkEnabled = $false
    Check 'fork: disabled -> command untouched' ((Get-EffectivePiCommand 6>$null) -eq 'pii')
    $PiCommand = 'pi'; $PiForkFallbackCommand = 'pi'

    # disabled / off gating never touches git
    $PiForkEnabled = $false
    Check 'fork: update check inert when disabled' ([string]::IsNullOrWhiteSpace((Invoke-PiForkUpdateCheck -Mode 'check' -Force | Out-String)))

    $gitExe = Get-GitExecutable
    if ($gitExe) {
        $gx = Join-Path $TestRoot 'gitfx'
        New-Item -ItemType Directory -Path $gx -Force | Out-Null
        $g = { param([string]$wd, [string[]]$a) Invoke-ProcessCapture -FilePath $gitExe -ArgumentList $a -WorkingDirectory $wd -TimeoutSeconds 60 }
        $id = @('-c', 'user.email=t@example.invalid', '-c', 'user.name=t', '-c', 'commit.gpgsign=false')
        [void](& $g $gx @('init', '--bare', '--initial-branch=main', 'remote.git'))
        [void](& $g $gx @('clone', 'remote.git', 'seed'))
        $seed = Join-Path $gx 'seed'
        Set-Content -Path (Join-Path $seed 'a.txt') -Value 'one' -Encoding UTF8
        [void](& $g $seed @('add', 'a.txt'))
        [void](& $g $seed ($id + @('commit', '-m', 'one')))
        [void](& $g $seed @('push', 'origin', 'HEAD:main'))
        [void](& $g $gx @('clone', 'remote.git', 'fork'))
        # Update-PiFork runs plain `git merge`; a merge commit needs an identity. Real clones
        # have one (global git config); CI runners don't, so set it on the fixture like a user would.
        [void](& $g (Join-Path $gx 'fork') @('config', 'user.email', 't@example.invalid'))
        [void](& $g (Join-Path $gx 'fork') @('config', 'user.name', 't'))
        $fork = Join-Path $gx 'fork'

        $st0 = Get-PiForkStatus -RepoPath $fork -Remote 'origin' -Branch 'main' -Fetch
        Check 'fork: fresh clone is level with remote' ($st0.ok -and $st0.behind -eq 0 -and $st0.ahead -eq 0)

        Set-Content -Path (Join-Path $seed 'a.txt') -Value 'two' -Encoding UTF8
        [void](& $g $seed ($id + @('commit', '-am', 'two')))
        [void](& $g $seed @('push', 'origin', 'HEAD:main'))
        $st1 = Get-PiForkStatus -RepoPath $fork -Remote 'origin' -Branch 'main' -Fetch
        Check 'fork: upstream commit counted as behind' ($st1.ok -and $st1.behind -eq 1)
        Check 'fork: remote head reported' (-not [string]::IsNullOrWhiteSpace($st1.remoteHead))

        # untracked local tooling inside the checkout must not count as dirty
        New-Item -ItemType Directory -Path (Join-Path $fork 'local-tool') -Force | Out-Null
        Set-Content -Path (Join-Path $fork 'local-tool\index.js') -Value '//' -Encoding UTF8
        Check 'fork: untracked files are not dirty' (-not (Get-PiForkStatus -RepoPath $fork).dirty)

        # tracked edits block the update, and nothing gets merged
        Set-Content -Path (Join-Path $fork 'a.txt') -Value 'local edit' -Encoding UTF8
        $stD = Get-PiForkStatus -RepoPath $fork
        Check 'fork: tracked edit is dirty' ($stD.dirty)
        Check 'fork: update refuses dirty tree' (-not (Update-PiFork -RepoPath $fork -Remote 'origin' -Branch 'main' 6>$null))
        Check 'fork: refused update merged nothing' ((Get-PiForkStatus -RepoPath $fork).behind -eq 1)
        [void](& $g $fork @('checkout', '--', 'a.txt'))

        # inverted merge=ours driver (a fork maintainer's setting) blocks auto-merge
        [void](& $g $fork @('config', 'merge.ours.driver', 'true'))
        Check 'fork: merge.ours driver detected' ((Get-PiForkStatus -RepoPath $fork).oursDriver)
        Check 'fork: update refuses with merge.ours driver' (-not (Update-PiFork -RepoPath $fork -Remote 'origin' -Branch 'main' 6>$null))
        [void](& $g $fork @('config', '--unset', 'merge.ours.driver'))
        Check 'fork: untracked local tool survived refusals' (Test-Path (Join-Path $fork 'local-tool\index.js'))

        Check 'fork: non-repo path reported, not thrown' (-not (Get-PiForkStatus -RepoPath (Join-Path $TestRoot 'nope')).ok)

        # --- full update path with REAL npm: merge -> install -> model data -> build ---
        if (Get-NpmExecutable) {
            # Fixture scripts stand in for pi-mono's: check:model-data passes, build:offline
            # writes packages/coding-agent/dist/cli.js (what Test-PiForkBuild looks for).
            $pkg = @'
{ "name": "fork-fixture", "version": "0.0.0", "private": true,
  "scripts": {
    "check:model-data": "node -e \"\"",
    "build:offline": "node -e \"const f=require('fs');f.mkdirSync('packages/coding-agent/dist',{recursive:true});f.writeFileSync('packages/coding-agent/dist/cli.js','//built')\"",
    "build:broken": "node -e \"process.exit(3)\""
  } }
'@
            Set-Content -Path (Join-Path $seed 'package.json') -Value $pkg -Encoding ASCII
            [void](& $g $seed @('add', 'package.json'))
            [void](& $g $seed ($id + @('commit', '-m', 'add package.json')))
            [void](& $g $seed @('push', 'origin', 'HEAD:main'))
            $pre = Get-PiForkStatus -RepoPath $fork -Remote 'origin' -Branch 'main' -Fetch
            Check 'fork e2e: two upstream commits pending' ($pre.behind -eq 2)
            # before asking, the incoming commits and install/build-time files are listed
            $inc = (Show-PiForkIncoming -RepoPath $fork -Remote 'origin' -Branch 'main' -Max 1 6>&1 | Out-String)
            Check 'fork e2e: incoming lists the newest commit' ($inc -match 'add package\.json' -and $inc -match 'and 1 more')
            Check 'fork e2e: incoming flags package.json' ($inc -match 'install/build time' -and $inc -match '(?m)^\s+package\.json\s*$')

            $PiForkBuildScript = 'build:offline'
            $okRun = Update-PiFork -RepoPath $fork -Remote 'origin' -Branch 'main' 6>$null
            $post = Get-PiForkStatus -RepoPath $fork -Remote 'origin' -Branch 'main'
            Check 'fork e2e: update reported success' ($okRun -eq $true)
            Check 'fork e2e: update merged everything'  ($post.behind -eq 0)
            Check 'fork e2e: build output produced'     (Test-PiForkBuild $fork)
            Check 'fork e2e: untracked local tool still there' (Test-Path (Join-Path $fork 'local-tool\index.js'))

            # failed build must be reported (Mission Centre then falls back to vanilla pi)
            Remove-Item (Join-Path $fork 'packages') -Recurse -Force
            $PiForkBuildScript = 'build:broken'
            $failRun = Update-PiFork -RepoPath $fork -Remote 'origin' -Branch 'main' 6>$null
            Check 'fork e2e: failed build detected (no false success)' ($failRun -eq $false -and -not (Test-PiForkBuild $fork))
            $PiForkBuildScript = 'build:offline'

            # conflicting upstream change: merge aborted, nothing half-merged, HEAD unchanged
            Set-Content -Path (Join-Path $fork 'a.txt') -Value 'fork side' -Encoding UTF8
            [void](& $g $fork ($id + @('commit', '-am', 'fork edit')))
            Set-Content -Path (Join-Path $seed 'a.txt') -Value 'upstream side' -Encoding UTF8
            [void](& $g $seed ($id + @('commit', '-am', 'upstream edit')))
            [void](& $g $seed @('push', 'origin', 'HEAD:main'))
            $div = Get-PiForkStatus -RepoPath $fork -Remote 'origin' -Branch 'main' -Fetch
            # guard: the conflict case must really be a diverged, CLEAN tree, or the checks
            # below pass for the wrong reason (dirty-tree refusal instead of merge abort)
            Check 'fork e2e: conflict setup really diverged and clean' ($div.ahead -ge 1 -and $div.behind -ge 1 -and -not $div.dirty)
            $headBefore = (& $g $fork @('rev-parse', 'HEAD')).out
            [void](Update-PiFork -RepoPath $fork -Remote 'origin' -Branch 'main' 6>$null)
            Check 'fork e2e: conflicting merge aborted, HEAD unchanged' ((& $g $fork @('rev-parse', 'HEAD')).out -eq $headBefore)
            Check 'fork e2e: no half-finished merge left' (-not (Test-Path (Join-Path $fork '.git\MERGE_HEAD')))
            Check 'fork e2e: tree clean after abort' (-not (Get-PiForkStatus -RepoPath $fork).dirty)
            Check 'fork e2e: conflict reason names the file' ($script:PiForkLastFailure -match 'merge conflict in a\.txt')

            # launch gate: a failed/skipped update is persisted and keeps warning while throttled
            # (silence for intervalHours once hid a conflict while pii fell 100+ commits behind)
            $PiForkEnabled = $true; $PiForkRepoPath = $fork; $PiForkRemote = 'origin'; $PiForkBranch = 'main'
            Remove-Item (Get-ToolUpdateStatePath) -Force -ErrorAction SilentlyContinue
            [void](Invoke-PiForkUpdateCheck -Mode 'auto' -IntervalHours 24 6>$null)
            $fs = Get-ToolUpdateState
            Check 'fork gate: failed update persisted as note' ($fs.ContainsKey('git:pi-fork') -and $fs['git:pi-fork'].note -match 'last update failed: merge conflict in a\.txt')
            $throttled = (Invoke-PiForkUpdateCheck -Mode 'check' -IntervalHours 24 6>&1 | Out-String)
            Check 'fork gate: throttled launch still warns' ($throttled -match 'NOT up to date' -and $throttled -match 'a\.txt')

            $origReadYesNo = ${function:Read-YesNo}
            function Read-YesNo { $false }
            [void](Invoke-PiForkUpdateCheck -Mode 'check' -Force 6>$null)
            Check 'fork gate: declined update persisted' ((Get-ToolUpdateState)['git:pi-fork'].note -match 'update skipped')
            Set-Item -Path function:Read-YesNo -Value $origReadYesNo

            # level with upstream + build present: the next check clears the note
            [void](& $g $fork @('reset', '--hard', 'origin/main'))
            $distDir = Join-Path $fork 'packages\coding-agent\dist'
            New-Item -ItemType Directory -Path $distDir -Force | Out-Null
            Set-Content -Path (Join-Path $distDir 'cli.js') -Value '//built' -Encoding ASCII
            [void](Invoke-PiForkUpdateCheck -Mode 'check' -Force 6>$null)
            Check 'fork gate: healthy check clears the note' ([string]::IsNullOrEmpty((Get-ToolUpdateState)['git:pi-fork'].note))
            $quietNow = (Invoke-PiForkUpdateCheck -Mode 'check' -IntervalHours 24 6>&1 | Out-String)
            Check 'fork gate: throttled + healthy is silent' ([string]::IsNullOrWhiteSpace($quietNow))
            # a build older than HEAD (manual merge/pull) is stale; a fresh one is not
            Check 'fork gate: fresh build is not stale' (-not (Test-PiForkBuildStale $fork))
            $PiCommand = 'pii'; $PiForkFallbackCommand = 'git'
            Check 'fork gate: fresh build -> pii used' ((Get-EffectivePiCommand 6>$null) -eq 'pii')
            (Get-Item (Join-Path $distDir 'cli.js')).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-30)
            Check 'fork gate: build older than HEAD is stale' (Test-PiForkBuildStale $fork)
            # a build that failed partway leaves an old cli.js over newer packages: never launch it
            Check 'fork gate: stale build -> falls back' ((Get-EffectivePiCommand 6>$null) -eq 'git')
            $PiCommand = 'pi'; $PiForkFallbackCommand = 'pi'
            function Read-YesNo { $false }
            [void](Invoke-PiForkUpdateCheck -Mode 'check' -Force 6>$null)
            Check 'fork gate: stale build flagged as pending' ((Get-ToolUpdateState)['git:pi-fork'].note -match 'build older')
            Set-Item -Path function:Read-YesNo -Value $origReadYesNo
            $PiForkEnabled = $false; $PiForkRepoPath = ''
        } else {
            Skip 'fork e2e: real npm update path' 'npm not on PATH'
        }
    } else {
        Skip 'fork: git fixture' 'git not on PATH'
    }

    # =======================================================================
    # Shared registry (lib/35-sharedstate.ps1): pure merge rules
    # =======================================================================
    Check 'shared id: https'          ((ConvertTo-RemoteId 'https://github.com/SomeOwner/Mission-Centre.git') -eq 'github.com/someowner/mission-centre')
    Check 'shared id: https + user'   ((ConvertTo-RemoteId 'https://someone@github.com/someone/notes-repo.git') -eq 'github.com/someone/notes-repo')
    Check 'shared id: scp-like'       ((ConvertTo-RemoteId 'git@github.com:SomeOwner/mission-centre.git') -eq 'github.com/someowner/mission-centre')
    Check 'shared id: ssh with port'  ((ConvertTo-RemoteId 'ssh://git@host.example:2222/team/repo') -eq 'host.example/team/repo')
    Check 'shared id: ssh host alias' ((ConvertTo-RemoteId 'myserver:registry') -eq 'myserver/registry')
    Check 'shared id: same repo, two URL forms, one id' ((ConvertTo-RemoteId 'https://github.com/a/b') -eq (ConvertTo-RemoteId 'git@github.com:A/B.git'))
    Check 'shared id: windows path is not a remote'  ((ConvertTo-RemoteId 'F:\AI\x') -eq '')
    Check 'shared id: C:/ path is not a remote'      ((ConvertTo-RemoteId 'C:/x/y') -eq '')
    Check 'shared id: unix path is not a remote'     ((ConvertTo-RemoteId '/srv/git/x.git') -eq '')
    Check 'shared id: file url is not a remote'      ((ConvertTo-RemoteId 'file:///srv/x.git') -eq '')
    Check 'shared: credentials stripped from remote' ((Remove-UrlCredential 'https://user:ghp_secret@github.com/a/b.git') -eq 'https://github.com/a/b.git')
    $freeDrive = @('Q','R','S','T','U','V','W','X','Y','Z') | Where-Object { -not (Test-Path ($_ + ':')) } | Select-Object -First 1
    if ($IsWinHost -and $freeDrive) {
        $ok = $true; $r = 'x'
        try { $r = Get-ProjectGitRemote ($freeDrive + ':\offline\project') } catch { $ok = $false }
        Check 'shared: a project on an unmounted drive does not throw' ($ok -and $r -eq '')
    } else { Skip 'shared: unmounted drive' 'not Windows, or no free drive letter' }
    Check 'shared: state file name'   ((ConvertTo-StateFileName 'github.com/SomeOwner/x') -eq 'github.com_someowner_x.json')

    $recs = [ordered]@{}
    $pa = [PSCustomObject]@{ path = 'F:\AI\a'; name = 'A local'; description = 'd'; added = '2026-01-01'; profile = 'build'; id = 'github.com/x/a' }
    $pb = [PSCustomObject]@{ path = 'F:\AI\b'; name = 'B'; description = 'd'; added = '2026-01-01'; profile = 'build'; id = 'github.com/x/b'; dormant = $true; dormantSince = '2026-02-01' }
    $m = Merge-SharedProjects @($pa, $pb) $recs 'DEV1'
    Check 'merge: new projects create records' ($recs.Count -eq 2 -and @($m.changed).Count -eq 2)
    Check 'merge: record has the device path'  ($recs['github.com/x/a']['paths']['DEV1'] -eq 'F:\AI\a')
    Check 'merge: dormancy goes into the record' ($recs['github.com/x/b']['dormant'] -eq $true)
    $recs['github.com/x/a']['name'] = 'A shared'
    $recs['github.com/x/b'].Remove('dormant'); $recs['github.com/x/b'].Remove('dormantSince')
    $pa2 = [PSCustomObject]@{ path = 'C:\work\a'; name = 'A laptop'; id = 'github.com/x/a' }
    $pb2 = [PSCustomObject]@{ path = 'C:\work\b'; name = 'B'; id = 'github.com/x/b'; dormant = $true; dormantSince = '2026-02-01' }
    $m2 = Merge-SharedProjects @($pa2, $pb2) $recs 'DEV2'
    Check 'merge: the record wins shared fields' ($pa2.name -eq 'A shared' -and $pa2.profile -eq 'build')
    Check 'merge: dormancy cleared by the record' (-not (Test-ProjectDormant $pb2))
    Check 'merge: second device path added, first kept' ($recs['github.com/x/a']['paths']['DEV2'] -eq 'C:\work\a' -and $recs['github.com/x/a']['paths']['DEV1'] -eq 'F:\AI\a')
    $m3 = Merge-SharedProjects @() $recs 'DEV1'
    Check 'merge: records restore a lost cache (path not checked)' (@($m3.projects).Count -eq 2 -and $m3.projects[0].path -like 'F:\AI\*')
    Check 'merge: other-device list' (@(Get-OtherDeviceRecords $recs 'DEV3').Count -eq 2 -and @(Get-OtherDeviceRecords $recs 'DEV1').Count -eq 0)
    $u = Update-SharedRecordsFromProjects @($pa) $recs 'DEV1'
    Check 'update: removing on one device keeps the record for the other' ($recs.Contains('github.com/x/b') -and -not $recs['github.com/x/b']['paths'].Contains('DEV1') -and @($u.deleted).Count -eq 0)
    $u = Update-SharedRecordsFromProjects @($pa2) $recs 'DEV2'
    Check 'update: the last device removing it deletes the record' (-not $recs.Contains('github.com/x/b') -and (@($u.deleted) -contains 'github.com/x/b'))
    $u = Update-SharedRecordsFromProjects @($pa2) $recs 'DEV2'
    Check 'update: unchanged project is not re-stamped' (@($u.changed).Count -eq 0)
    # remote-less projects: same name on a second device -> same record, not a duplicate
    $nr = [ordered]@{}
    $j1 = [PSCustomObject]@{ path = (Join-Path $TestRoot 'nogit-1\Beach Trip'); name = 'Beach Trip'; profile = 'vibe' }
    [void](Merge-SharedProjects @($j1) $nr 'DEV1')
    $j2 = [PSCustomObject]@{ path = (Join-Path $TestRoot 'nogit-2\beach trip'); name = 'beach trip' }
    [void](Merge-SharedProjects @($j2) $nr 'DEV2')
    Check 'merge: remote-less project gets a local id' ([string]$j1.id -like 'local/beach-trip-*')
    Check 'merge: same name on another device joins that record' ($nr.Count -eq 1 -and $j2.id -eq $j1.id -and @($nr[$j1.id]['paths'].Keys).Count -eq 2)
    $j3 = [PSCustomObject]@{ path = (Join-Path $TestRoot 'nogit-3\Beach Trip'); name = 'Beach Trip' }
    [void](Merge-SharedProjects @($j3) $nr 'DEV1')
    Check 'merge: same name on the SAME device stays a separate project' ($nr.Count -eq 2 -and $j3.id -ne $j1.id)

    # =======================================================================
    # Shared registry end-to-end: two devices through a real (local, bare) git repo
    # =======================================================================
    $gitExe = Get-GitExecutable
    if ($gitExe) {
        $saved = @{ cp = $ConfigPath; dev = $DeviceName; dir = $SharedStateDir }
        $bareRepo = Join-Path $TestRoot 'registry.git'
        [void](Invoke-ProcessCapture -FilePath $gitExe -ArgumentList @('init', '--quiet', '--bare', $bareRepo))
        $SharedStateEnabled = $true; $SharedStateRemote = $bareRepo
        # device 1: existing registry with two projects
        $DeviceName = 'DEV1'; $SharedStateDir = Join-Path $TestRoot 'state-dev1'; $ConfigPath = Join-Path $TestRoot 'dev1.json'
        '[{"path":"F:\\AI\\alpha","name":"Alpha","description":"a","added":"2026-01-01","profile":"build","id":"github.com/t/alpha"},{"path":"F:\\AI\\beta","name":"Beta","description":"b","added":"2026-01-01","profile":"vibe","id":"github.com/t/beta","remote":"https://github.com/t/beta"}]' |
            Set-Content $ConfigPath -Encoding UTF8
        $c1 = @(Import-ProjectConfig)
        Check 'e2e: device 1 keeps its projects' ($c1.Count -eq 2 -and $script:SharedStateStatus -eq 'synced')
        $head = Invoke-ProcessCapture -FilePath $gitExe -ArgumentList @('--git-dir', $bareRepo, 'rev-parse', '--verify', 'main')
        Check 'e2e: device 1 pushed the registry' ($head.ok)
        # device 2: empty, sees both under [O]; adopts Beta and parks it
        $DeviceName = 'DEV2'; $SharedStateDir = Join-Path $TestRoot 'state-dev2'; $ConfigPath = Join-Path $TestRoot 'dev2.json'
        $c2 = @(Import-ProjectConfig)
        Check 'e2e: device 2 starts with no local projects' ($c2.Count -eq 0)
        Check 'e2e: device 2 sees both under other devices' (@(Get-OtherDeviceRecords $script:SharedRecords 'DEV2').Count -eq 2)
        $adopt = New-ProjectFromRecord $script:SharedRecords['github.com/t/beta'] 'C:\dev2\beta'
        Save-Config @($adopt)
        $c2 = @(Import-ProjectConfig)
        [void](Set-ProjectDormant ([ref]$c2) @(0) $true)
        # device 1 again: sees device 2's path and the dormancy
        $DeviceName = 'DEV1'; $SharedStateDir = Join-Path $TestRoot 'state-dev1'; $ConfigPath = Join-Path $TestRoot 'dev1.json'
        $c1 = @(Import-ProjectConfig)
        $beta = @($c1 | Where-Object { $_.id -eq 'github.com/t/beta' })[0]
        Check 'e2e: dormancy set on device 2 reaches device 1' (Test-ProjectDormant $beta)
        Check 'e2e: device 1 keeps its own path' ($beta.path -eq 'F:\AI\beta')
        Check 'e2e: record holds both devices' (@($script:SharedRecords['github.com/t/beta']['paths'].Keys).Count -eq 2)
        Check 'e2e: cache file stores ids' ((Get-Content $ConfigPath -Raw) -match 'github.com/t/alpha')
        # a real git folder with an origin: id AND remote must reach the record (so [O] can clone)
        $gammaDir = Join-Path $TestRoot 'gamma'
        New-Item -ItemType Directory -Path $gammaDir -Force | Out-Null
        [void](Invoke-ProcessCapture -FilePath $gitExe -ArgumentList @('init', '--quiet', $gammaDir))
        [void](Invoke-ProcessCapture -FilePath $gitExe -ArgumentList @('-C', $gammaDir, 'remote', 'add', 'origin', 'https://tok:secret@github.com/T/Gamma.git'))
        Save-Config (@($c1) + @([PSCustomObject]@{ path = $gammaDir; name = 'Gamma'; description = 'g'; added = '2026-01-01'; profile = 'build' }))
        $g = $script:SharedRecords['github.com/t/gamma']
        Check 'e2e: remote-derived id for a new git project' ($null -ne $g)
        Check 'e2e: record stores the remote, credentials stripped' ($null -ne $g -and $g['remote'] -eq 'https://github.com/T/Gamma.git')
        # a project cached with an id but no remote gets the remote backfilled at the next sync
        # assign first, then @(): in PS 5.1, @(... | ConvertFrom-Json) nests a JSON array
        $cached = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $cached = @($cached)
        foreach ($e in $cached) { if ($e.PSObject.Properties['remote'] -and $e.id -eq 'github.com/t/gamma') { $e.PSObject.Properties.Remove('remote') } }
        ConvertTo-Json -InputObject @($cached) -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
        $script:SharedRecords['github.com/t/gamma'].Remove('remote')
        Write-SharedRecords $script:SharedRecords @('github.com/t/gamma') @() $SharedStateDir
        Save-SharedStateCommit 'drop remote (test)'
        $c1 = @(Import-ProjectConfig)
        Check 'e2e: missing remote is backfilled into the record' ($script:SharedRecords['github.com/t/gamma']['remote'] -eq 'https://github.com/T/Gamma.git')
        # remote moved (home server -> GitHub): the existing copy is repointed and its
        # unpushed commits land on the new remote
        $newRemote = Join-Path $TestRoot 'registry-moved.git'
        [void](Invoke-ProcessCapture -FilePath $gitExe -ArgumentList @('clone', '--quiet', '--bare', $bareRepo, $newRemote))
        $SharedStateRemote = $newRemote
        Save-Config (@($c1) + @([PSCustomObject]@{ path = 'F:\AI\delta'; name = 'Delta'; description = 'd'; added = '2026-01-01'; profile = 'build'; id = 'local/delta-111111' }))
        $c1 = @(Import-ProjectConfig)   # a launch loads (pull + repoint + push) before anything else
        $url = Invoke-ProcessCapture -FilePath $gitExe -ArgumentList @('-C', $SharedStateDir, 'remote', 'get-url', 'origin')
        Check 'e2e: changed sharedState.remote repoints the existing copy' ($url.ok -and ($url.out.Trim() -replace '[\\/]+', '/') -eq ($newRemote -replace '[\\/]+', '/'))
        $onNew = Invoke-ProcessCapture -FilePath $gitExe -ArgumentList @('--git-dir', $newRemote, 'ls-tree', '--name-only', 'main', 'projects/')
        Check 'e2e: changes after the move reach the new remote' ($onNew.ok -and $onNew.out -match 'delta')
        $SharedStateRemote = $bareRepo
        # offline: an unreachable remote must not break loading
        $DeviceName = 'DEV3'; $SharedStateDir = Join-Path $TestRoot 'state-dev3'; $ConfigPath = Join-Path $TestRoot 'dev3.json'
        $SharedStateRemote = Join-Path $TestRoot 'does-not-exist.git'
        '[{"path":"F:\\AI\\solo","name":"Solo","description":"x","added":"2026-01-01","profile":"standard","id":"local/solo-abc123"}]' | Set-Content $ConfigPath -Encoding UTF8
        $c3 = @(Import-ProjectConfig)
        Check 'e2e: offline still loads the local registry' ($c3.Count -eq 1 -and $script:SharedStateStatus -eq 'offline')
        $SharedStateEnabled = $false; $SharedStateRemote = ''; $script:SharedRecords = $null
        $ConfigPath = $saved.cp; $DeviceName = $saved.dev; $SharedStateDir = $saved.dir
    } else {
        Skip 'shared registry e2e' 'git not on PATH'
    }

    # =======================================================================
    # Context pack (lib/50-context.ps1): the reading contract for Claude Code / pi
    # =======================================================================
    $vaultDir = Join-Path $TestRoot 'vault'
    foreach ($d in 'entities', 'projects', 'synthesis', 'references', '_meta') { New-Item -ItemType Directory -Path (Join-Path $vaultDir $d) -Force | Out-Null }
    $mk = { param($rel, $title, $summary, $tier, $body)
        "---`ntitle: $title`nsummary: `"$summary`"`ntier: $tier`n---`n# $title`n`n$body`n" | Set-Content (Join-Path $vaultDir $rel) -Encoding UTF8 }
    & $mk 'entities/profile.md' 'Profile' 'Who the user is.' 'core' "He is not a coder.`n`n## Superseded`n- old stuff`n`n## Related`n[[x]]"
    & $mk 'projects/knife-making.md' 'Knife making' 'Projects, steels, heat treatment.' 'supporting' "## Now`n- Order N690 steel"
    & $mk 'projects/gaming.md' 'Gaming' 'PC gaming library and backlog.' 'supporting' 'Steam.'
    & $mk 'synthesis/shared-notes.md' 'The shared notes' 'How knowledge flows.' 'core' 'One vault.'
    & $mk 'references/system-map.md' 'System map: start here' 'Start here: what runs where.' 'core' "## In one screen`n- The to-do app holds the to-do list"
    & $mk '_meta/taxonomy.md' 'Taxonomy' 'tags' '' 'never included'
    'index' | Set-Content (Join-Path $vaultDir 'index.md')
    $pages = @(Read-VaultPages $vaultDir)
    Check 'ctx: reads pages, skips _meta and index' ($pages.Count -eq 5 -and -not ($pages.slug -contains 'taxonomy') -and -not ($pages.slug -contains 'index'))
    $c = @(Get-ContextPackCandidates $pages 'knife-steel-notes' 'knife-steel-notes' 3)
    Check 'ctx: project words rank the matching page first' ($c.Count -ge 1 -and $c[0] -eq 'knife-making')
    Check 'ctx: the profile is never a candidate' (-not ($c -contains 'profile'))
    $c2 = @(Get-ContextPackCandidates $pages 'system map start' 'system-map' 5)
    Check 'ctx: the system map is never a candidate (it is always in the pack)' (-not ($c2 -contains 'system-map'))
    New-Item -ItemType Directory -Path (Join-Path $AgentInstructionHome '.claude') -Force | Out-Null
    $savedWikiDir = $WikiConfigDir; $WikiConfigDir = Join-Path $TestRoot 'obsidian-wiki-ctx'; $WikiConfigPath = Join-Path $WikiConfigDir 'config'
    $WikiProfileVaults = @{ build = @{ vault = $vaultDir; sources = '' } }
    Set-WikiConfig 'build' (Join-Path $TestRoot 'knife-steel-notes') 6>$null
    $packPath = Join-Path $WikiConfigDir 'context-pack.md'
    Check 'ctx: launch writes the pack next to the wiki config' (Test-Path $packPath)
    $pack = Get-Content $packPath -Raw
    Check 'ctx: pack has the profile without Superseded/Related' ($pack -match 'He is not a coder' -and $pack -notmatch 'old stuff')
    Check 'ctx: pack has the related project page' ($pack -match 'Related page: Knife making' -and $pack -match 'Order N690')
    Check 'ctx: pack lists every page' ($pack -match 'synthesis/shared-notes:' -and $pack -match 'projects/gaming:')
    Check 'ctx: pack always carries the system map, after the profile' ($pack -match 'The to-do app holds the to-do list' -and $pack.IndexOf('He is not a coder') -lt $pack.IndexOf('The to-do app holds'))
    Check 'ctx: pack points at wiki-query and the system map' ($pack -match 'wiki-query skill' -and $pack -match 'check the system map')
    $cm = Join-Path (Join-Path $AgentInstructionHome '.claude') 'CLAUDE.md'
    Check 'ctx: launch put the managed block into an installed agent (Claude Code)' ((Test-Path $cm) -and ((Get-Content $cm -Raw) -match 'mission-centre:brain BEGIN'))
    Check 'ctx: agents that are not installed are left alone (no ~/.codex created)' (-not (Test-Path (Join-Path $AgentInstructionHome '.codex')))
    Set-WikiConfig 'corporate' (Join-Path $TestRoot 'x') 6>$null
    Check 'ctx: no vault for the profile clears the pack' (-not (Test-Path $packPath))
    $WikiConfigDir = $savedWikiDir; $WikiConfigPath = Join-Path $WikiConfigDir 'config'; $WikiProfileVaults = @{}

    # =======================================================================
    # Optional local model server (pi.healthUrl): health probe + auto-start gate
    # =======================================================================
    # Invoke-WebRequest is shadowed by a function, so nothing touches the network.
    $script:FakeStatus = 200
    function Invoke-WebRequest { param($Uri, $TimeoutSec, [switch]$UseBasicParsing, $ErrorAction)
        if ($script:FakeStatus -eq 0) { throw 'connection refused' }
        if ($script:FakeStatus -ge 400) { throw "HTTP $($script:FakeStatus)" }
        return [PSCustomObject]@{ StatusCode = $script:FakeStatus } }
    $PiServerHealthUrl = ''
    Check 'server: no healthUrl -> treated as healthy (feature off)' (Test-PiServerHealth)
    $PiServerHealthUrl = 'http://127.0.0.1:11434/'
    Check 'server: 200 -> healthy' (Test-PiServerHealth)
    $script:FakeStatus = 204
    Check 'server: any 2xx -> healthy' (Test-PiServerHealth)
    $script:FakeStatus = 0
    Check 'server: refused -> not healthy' (-not (Test-PiServerHealth))
    $script:FakeStatus = 503
    Check 'server: 5xx -> not healthy' (-not (Test-PiServerHealth))
    $PiServerAutoStart = $false
    Check 'server: autoStart=false never starts anything' (-not (Start-PiServer))
    $PiServerAutoStart = $true; $PiServerTaskName = ''; $PiServerStartCommand = ''
    Check 'server: nothing configured to start -> false, no wait' (-not (Start-PiServer))
    $script:FakeStatus = 200
    Check 'server: already healthy -> immediate success' (Start-PiServer)
    Remove-Item Function:\Invoke-WebRequest
    $PiServerHealthUrl = ''; $PiServerAutoStart = $false

    # =======================================================================
    # Default engine: which engine the single-letter launch keys run
    # =======================================================================
    Check 'engine: claude default, L is Claude'        ((Resolve-LaunchAction 'L' 'claude') -eq 'claude-new')
    Check 'engine: claude default, PI is pi'           ((Resolve-LaunchAction 'pi' 'claude') -eq 'pi-new')
    Check 'engine: claude default, CL is nothing'      ((Resolve-LaunchAction 'CL' 'claude') -eq '')
    Check 'engine: pi default, L is pi'                ((Resolve-LaunchAction 'L' 'pi') -eq 'pi-new')
    Check 'engine: pi default, C/R are pi'             ((Resolve-LaunchAction 'c' 'pi') -eq 'pi-continue' -and (Resolve-LaunchAction 'R' 'pi') -eq 'pi-resume')
    Check 'engine: pi default, CL/CC/CR are Claude'    ((Resolve-LaunchAction 'CL' 'pi') -eq 'claude-new' -and (Resolve-LaunchAction 'CC' 'pi') -eq 'claude-continue' -and (Resolve-LaunchAction 'CR' 'pi') -eq 'claude-resume')
    Check 'engine: pi default, PI still works'         ((Resolve-LaunchAction 'PI' 'pi') -eq 'pi-new')
    Check 'engine: unknown key is nothing'             ((Resolve-LaunchAction 'Q' 'pi') -eq '' -and (Resolve-LaunchAction 'R3' 'pi') -eq '')

    # =======================================================================
    # Default engine pi: new-project / import / New App launch pi, Claude on CL/CK
    # =======================================================================
    $script:launched = @()
    function Start-PiNew { param($p, $prof, $n, $prompt = '') $script:launched += "pi-new|$prompt" }
    function Start-PiContinue { param($p, $prof) $script:launched += 'pi-continue' }
    function Start-PiCommand { param($p, $prof, $a, $d) $script:launched += "pi-cmd|$($a -join ' ')" }
    function Start-WithProfile { param($p, $prof, $n) $script:launched += 'claude-profile' }
    function Start-ContinueMission { param($p, $prof) $script:launched += 'claude-continue' }
    function Start-ClaudeKickoff { param($p, $n) $script:launched += 'claude-kickoff' }
    function Start-TerminalCommand { param($p, $c) $script:launched += "terminal|$c" }

    $PiEnabled = $true; $DefaultEngine = 'pi'
    Check 'engine: pi default when pi enabled' (Test-PiDefaultEngine)
    $PiEnabled = $false
    Check 'engine: not pi when pi disabled' (-not (Test-PiDefaultEngine))
    $PiEnabled = $true; $DefaultEngine = 'claude'
    Check 'engine: claude default stays claude' (-not (Test-PiDefaultEngine))

    Check 'engine: pi kickoff prompt names the project' ((Get-KickoffPrompt 'Zed') -match "'Zed'")

    # =======================================================================
    # Kickoff: plan in Claude Code (Forge / vibe-check), then build in pi
    # =======================================================================
    $kickDir = Join-Path $TestRoot 'kickoff'
    # Forge detection: the kickoff names mission-planner only when the plugin is installed.
    $noForgeDir = Join-Path $TestRoot 'claude-home-noforge'
    New-Item -ItemType Directory -Path (Join-Path $noForgeDir 'plugins') -Force | Out-Null
    '{"version":2,"plugins":{"other@market":[{}]}}' | Set-Content (Join-Path (Join-Path $noForgeDir 'plugins') 'installed_plugins.json') -Encoding UTF8
    Check 'forge: detected in installed_plugins.json' (Test-ForgeInstalled)
    Check 'forge: other plugins only -> not installed' (-not (Test-ForgeInstalled -ClaudeDir $noForgeDir))
    Check 'forge: no plugins file -> not installed' (-not (Test-ForgeInstalled -ClaudeDir (Join-Path $TestRoot 'nowhere')))
    Check 'forge: kickoff names mission-planner with Forge' ((Get-ForgeKickoffPrompt 'Z' $true) -match 'mission-planner')
    $pNo = Get-ForgeKickoffPrompt 'Z' $false
    Check 'forge: kickoff without Forge does not name a missing skill' ($pNo -notmatch 'mission-planner' -and $pNo -match 'Plan it with me: goal' -and $pNo -match 'PLAN\.md')
    $savedClaudeDir = $McClaudeDir; $McClaudeDir = $noForgeDir
    Check 'forge: menu label says when Forge is missing' ((Get-KickoffPlannerLabel) -match 'Forge plugin not installed')
    $McClaudeDir = $savedClaudeDir
    Check 'forge: menu label with Forge' ((Get-KickoffPlannerLabel) -eq 'plan with Forge in Claude Code')

    # macOS: Terminal types the launch line into a tty limited to 1024 bytes, so only a short line is typed.
    $longCmd = "Set-Location -LiteralPath '/tmp/x'; Write-Output '" + ('k' * 1700) + "'; Write-Output 'end'"
    $macLine = Get-MacTerminalShellCommand $longCmd
    $launchFile = if ($macLine -match "-File '([^']+)'") { $Matches[1] } else { '' }
    Check 'mac launch: typed line stays far below 1024 bytes' ($macLine.Length -lt 300 -and $macLine.StartsWith('pwsh -NoExit -File '))
    Check 'mac launch: script holds the full command' ($launchFile -and (Test-Path -LiteralPath $launchFile) -and ((Get-Content -LiteralPath $launchFile -Raw).Trim() -eq $longCmd))
    Check 'mac launch: script lives under .mission-centre/launch' ($launchFile -like "$(Join-Path $MissionStateDir 'launch')*")
    $oldLaunch = Join-Path (Split-Path $launchFile) 'launch-oldoldoldold.ps1'
    'old' | Set-Content $oldLaunch; (Get-Item $oldLaunch).LastWriteTime = (Get-Date).AddDays(-3)
    [void](New-LaunchScriptFile 'Write-Output 1')
    Check 'mac launch: launch scripts older than a day are cleaned up' (-not (Test-Path $oldLaunch))
    New-Item -ItemType Directory -Path $kickDir -Force | Out-Null
    $promptsNoDq = -not ((Get-ForgeKickoffPrompt "O'Brien") + (Get-PiBuildPrompt) + (Get-VibeOpening 'x') + (Get-PlanHandoffInstructions)).Contains('"')
    Check 'kickoff: prompts contain no double quotes (Start-Process would strip them)' $promptsNoDq
    Check 'kickoff: Forge prompt asks for PLAN.md and warns pi cannot run agent teams' ((Get-ForgeKickoffPrompt 'Z') -match 'PLAN\.md' -and (Get-ForgeKickoffPrompt 'Z') -match 'agent teams')

    # The generated line, evaluated in the project folder with Claude and pi faked.
    $runKick = {
        param([bool]$WritePlan, [string]$Answer)
        Remove-Item (Join-Path $kickDir '*') -Force -ErrorAction SilentlyContinue
        $claudeFake = if ($WritePlan) { "Set-Content -LiteralPath 'PLAN.md' -Value 'plan'" } else { "Write-Output 'no plan'" }
        $line = New-KickoffThenPiCommand $claudeFake "Set-Content -LiteralPath 'pi-ran.txt' -Value 'pi'"
        Push-Location $kickDir
        try {
            $script:KickAnswer = $Answer
            function Read-Host { param($Prompt) return $script:KickAnswer }
            [void](Invoke-Expression $line 6>&1)
        } finally { Remove-Item function:Read-Host -ErrorAction SilentlyContinue; Pop-Location }
        return (Test-Path (Join-Path $kickDir 'pi-ran.txt'))
    }
    Check 'kickoff: plan written + Enter -> pi starts'       (& $runKick $true '')
    Check 'kickoff: plan written + y -> pi starts'           (& $runKick $true 'y')
    Check 'kickoff: plan written + n -> pi does not start'   (-not (& $runKick $true 'n'))
    Check 'kickoff: no plan written -> pi does not start'    (-not (& $runKick $false 'y'))

    # Same line through the real terminal path: Start-Process -Command, as Start-TerminalCommand
    # does it. Proves quoting survives (apostrophes in names, spaces in paths).
    if ($IsWinHost) {
        $spaced = Join-Path $TestRoot "kick off dir"
        New-Item -ItemType Directory -Path $spaced -Force | Out-Null
        $planText = "plan for O'Brien"
        $line = New-KickoffThenPiCommand (Format-CommandForPowerShell 'Set-Content' @('PLAN.md', $planText)) (Format-CommandForPowerShell 'Set-Content' @('pi-ran.txt', (Get-PiBuildPrompt)))
        $psCommand = "Set-Location -LiteralPath $(ConvertTo-PowerShellQuotedString $spaced); function Read-Host { 'y' }; $line"
        $shellExe = (Get-Command 'powershell' -ErrorAction SilentlyContinue).Source
        $p = Start-Process -FilePath $shellExe -ArgumentList @('-NoProfile', '-Command', $psCommand) -WindowStyle Hidden -Wait -PassThru
        $piRan = Join-Path $spaced 'pi-ran.txt'
        Check 'kickoff: real Start-Process round trip runs Claude then pi' ($p.ExitCode -eq 0 -and (Test-Path $piRan))
        Check 'kickoff: prompt and apostrophes arrive intact' ((Test-Path $piRan) -and ((Get-Content $piRan -Raw).Trim() -eq (Get-PiBuildPrompt)) -and ((Get-Content (Join-Path $spaced 'PLAN.md') -Raw).Trim() -eq $planText))
    } else {
        $script:Skipped++; Write-Host 'SKIP  kickoff: Start-Process round trip (Windows only)'
    }

    # Start-KickoffThenPi wiring, with pi's launch checks and the terminal stubbed.
    $script:piInit = 'pii'
    function Initialize-PiLaunch { param($p, $prof) return $script:piInit }
    function Install-BundledSkill { param($Name, [switch]$Quiet) return $true }
    function Confirm-ProfileLaunchIntent { param($a, $b) return $true }
    # CI runners have neither jig nor claude, and Start-KickoffThenPi refuses to start without one.
    # A stand-in function satisfies its Get-Command check; it is never called (the terminal is stubbed).
    $claudeStub = -not (Get-Command 'claude' -ErrorAction SilentlyContinue)
    if ($claudeStub) { function claude { } }
    $script:launched = @()
    Start-KickoffThenPi $kickDir 'Zed' 'build' 'forge' 6>$null
    $t = if ($script:launched.Count -eq 1) { [string]$script:launched[0] } else { '' }
    $planner = if (Get-Command 'jig' -ErrorAction SilentlyContinue) { "'run' '$MetaProfile'" } else { '& claude ' }
    Check 'kickoff: Forge kickoff plans in Claude, then runs pii on the plan' ($t -like "terminal|*$planner*" -and $t -like '*mission-planner*' -and $t -like '*& pii *' -and $t -like '*Read PLAN.md*')
    $script:launched = @()
    Start-KickoffThenPi $kickDir 'Zed' 'vibe' 'vibe' 6>$null
    $t = if ($script:launched.Count -eq 1) { [string]$script:launched[0] } else { '' }
    Check 'kickoff: vibe kickoff uses vibe-check, then pii' ($t -like '*vibe-check*' -and $t -like '*& pii *')
    $script:launched = @(); $script:piInit = $null
    Start-KickoffThenPi $kickDir 'Zed' 'build' 'forge' 6>$null
    Check 'kickoff: pi launch checks fail -> nothing opens' ($script:launched.Count -eq 0)
    $script:piInit = 'pii'

    $DefaultEngine = 'pi'; $script:launched = @()
    Start-VibeKickoff $kickDir 'Vibe App' 6>$null
    Check 'engine: New App runs vibe-check in Claude, then pi' ($script:launched.Count -eq 1 -and $script:launched[0] -like '*vibe-check*' -and $script:launched[0] -like '*& pii *')
    if ($claudeStub) { Remove-Item function:claude }

    # [L] on a project: kickoff offered once when there is no plan; the answer is remembered.
    function Start-KickoffThenPi { param($p, $n, $prof, $planner) $script:launched += "kickoff|$planner" }
    function Save-Config { param($c) $script:saved++ }
    $script:asked = 0; $script:answer = ''
    function Read-Host { param($Prompt) $script:asked++; return $script:answer }
    $noPlanDir = Join-Path $TestRoot 'noplan'; New-Item -ItemType Directory -Path $noPlanDir -Force | Out-Null
    $mkProj = { param($path) [PSCustomObject]@{ path = $path; name = 'P'; profile = 'build' } }

    $cfg = @(& $mkProj $noPlanDir); $script:launched = @(); $script:saved = 0; $script:answer = 'k'
    Start-PiNewMission ([ref]$cfg) 0 6>$null
    Check 'kickoff: no plan + K -> kickoff, nothing remembered' ($script:launched -contains 'kickoff|forge' -and $script:saved -eq 0 -and -not $cfg[0].PSObject.Properties['kickoff'])
    $script:launched = @(); $script:answer = ''
    Start-PiNewMission ([ref]$cfg) 0 6>$null
    Check 'kickoff: no plan + Enter -> pi now, skip remembered and saved' ($script:launched -contains 'pi-new|' -and $cfg[0].kickoff -eq 'skipped' -and $script:saved -eq 1)
    $script:launched = @(); $script:asked = 0
    Start-PiNewMission ([ref]$cfg) 0 6>$null
    Check 'kickoff: remembered skip -> straight to pi, not asked' ($script:asked -eq 0 -and $script:launched -contains 'pi-new|')
    Check 'kickoff: skip is a shared field (travels to other devices)' ($SharedFields -contains 'kickoff')
    Set-Content (Join-Path $kickDir 'PLAN.md') 'plan'
    $cfg = @(& $mkProj $kickDir); $script:launched = @(); $script:asked = 0
    Start-PiNewMission ([ref]$cfg) 0 6>$null
    Check 'kickoff: project with PLAN.md -> straight to pi, not asked' ($script:asked -eq 0 -and $script:launched -contains 'pi-new|')
    Remove-Item function:Read-Host
    $DefaultEngine = 'claude'

    # [N] New Project: git init's stdout leaked into New-ScaffoldedProject's return value, so
    # Add-NewProject's $project.path threw under strict mode (seen 2026-10-15).
    if (Get-Command 'git' -ErrorAction SilentlyContinue) {
        $script:answers = [System.Collections.Generic.Queue[string]]::new()
        foreach ($a in @('Scaffold Me', '', '', '', 'y', 'y')) { $script:answers.Enqueue($a) }
        function Read-Host { param($Prompt) return $script:answers.Dequeue() }
        function Show-ProfileMenu { }
        $cfg = @()
        $made = @(New-ScaffoldedProject -ConfigRef ([ref]$cfg) 6>$null)
        Remove-Item function:Read-Host, function:Show-ProfileMenu
        $madePath = Join-Path $ScanRoot 'Scaffold Me'
        Check 'scaffold: git init + CLAUDE.md -> returns exactly the project object' ($made.Count -eq 1 -and $made[0].path -eq $madePath)
        Check 'scaffold: git repo and CLAUDE.md created' ((Test-Path (Join-Path $madePath '.git')) -and (Test-Path (Join-Path $madePath 'CLAUDE.md')))
    }

    # =======================================================================
    # Banner shimmer: repaint only where the panel still is (no second banner over the list)
    # =======================================================================
    # Args: panel buffer top, cursor top, window top, window height, buffer height.
    Check 'shimmer: panel at the top, menu fits -> row 0' ((Get-McPanelWindowRow 0 25 0 31 31) -eq 0)
    # The 2026-10-14 screenshot: ConPTY (buffer = window), menu 2 lines taller than the window, so
    # the prompt sits on the last line and every row moved up 2 while CursorTop/WindowTop did not.
    Check 'shimmer: ConPTY, prompt on the last line (scrolled) -> no shimmer' ($null -eq (Get-McPanelWindowRow 0 30 0 31 31))
    Check 'shimmer: classic conhost, window moved down -> no shimmer' ($null -eq (Get-McPanelWindowRow 0 40 2 31 3000))
    Check 'shimmer: classic conhost, window not moved -> panel row' ((Get-McPanelWindowRow 5 25 0 31 3000) -eq 5)
    Check 'shimmer: panel taller than the window -> no shimmer' ($null -eq (Get-McPanelWindowRow 0 9 0 8 3000))
    Check 'shimmer: cursor above the panel end (screen cleared) -> no shimmer' ($null -eq (Get-McPanelWindowRow 10 3 0 31 3000))
    Check 'shimmer: unknown panel row -> no shimmer' ($null -eq (Get-McPanelWindowRow $null 25 0 31 31))
    # Read-Host '' throws on PS 5.1 and 7; the menu reader's catch then re-printed the prompt (seen 2026-10-14).
    $emptyReadHostRe = 'Read-Host\s+(''''|"")'
    $emptyReadHost = @(Get-ChildItem (Join-Path $RepoRoot 'lib') -Filter '*.ps1' | Select-String -Pattern $emptyReadHostRe)
    Check "menu prompt: the guard pattern catches Read-Host ''" ("return (Read-Host '')" -match $emptyReadHostRe)
    Check "menu prompt: no Read-Host '' in lib" ($emptyReadHost.Count -eq 0)
    # =======================================================================
    # Node.js security floor (lib/60-health.ps1) - pure, no node needed
    # =======================================================================
    Check 'node: below the line floor is vulnerable' ((Get-NodeSecurityStatus 'v24.18.0').status -eq 'vulnerable')
    Check 'node: vulnerable names the minimum' ((Get-NodeSecurityStatus 'v24.18.0').detail -match '24\.22\.1')
    Check 'node: exactly the floor is ok' ((Get-NodeSecurityStatus 'v24.22.1').status -eq 'ok')
    Check 'node: above the floor is ok (numeric, not string, compare)' ((Get-NodeSecurityStatus 'v24.100.0').status -eq 'ok')
    Check 'node: each listed line has its own floor' ((Get-NodeSecurityStatus 'v22.23.3').status -eq 'vulnerable' -and (Get-NodeSecurityStatus 'v26.12.1').status -eq 'ok')
    Check 'node: a line older than every listed one is end of life' ((Get-NodeSecurityStatus 'v20.19.0').status -eq 'eol')
    Check 'node: an odd line between listed ones is end of life' ((Get-NodeSecurityStatus 'v23.11.0').status -eq 'eol')
    Check 'node: a line newer than every listed one is ok' ((Get-NodeSecurityStatus 'v28.0.0').status -eq 'ok')
    Check 'node: unreadable version is unknown' ((Get-NodeSecurityStatus 'not a version').status -eq 'unknown')
    # fork update mode: the stricter of global and fork (lib/65-updates.ps1) - pure
    Check 'fork mode: global auto + fork check -> check' ((Get-PiForkEffectiveMode 'auto' 'check') -eq 'check')
    Check 'fork mode: both auto -> auto' ((Get-PiForkEffectiveMode 'auto' 'auto') -eq 'auto')
    Check 'fork mode: global off wins' ((Get-PiForkEffectiveMode 'off' 'auto') -eq 'off')
    Check 'fork mode: fork off wins' ((Get-PiForkEffectiveMode 'auto' 'off') -eq 'off')
    Check 'fork mode: unknown or empty fork mode means check' ((Get-PiForkEffectiveMode 'auto' '') -eq 'check' -and (Get-PiForkEffectiveMode 'auto' 'yolo') -eq 'check')
    $sens = @(Get-PiForkSensitivePaths @('package.json', 'packages/ai/package.json', 'package-lock.json', 'scripts/build.mjs', 'packages/ai/scripts/gen.ts', '.npmrc', '.husky/pre-commit', '.github/workflows/ci.yml', 'packages/ai/src/index.ts', 'README.md', 'docs/scripts.md'))
    Check 'fork sensitive: install/build files flagged' ($sens.Count -eq 8)
    Check 'fork sensitive: source and docs not flagged' ($sens -notcontains 'packages/ai/src/index.ts' -and $sens -notcontains 'README.md' -and $sens -notcontains 'docs/scripts.md')
    Check 'node: custom floor table' ((Get-NodeSecurityStatus 'v24.22.1' ([ordered]@{ '24' = '24.30.0' })).status -eq 'vulnerable')
} catch {

    # An exception must fail the run. Without this catch, a crash ended the main block early and the
    # summary still said '0 failed' (exit 0) with half the checks never run.
    $script:Fail++
    Write-Host "FAIL  test run aborted: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
} finally {
    Set-Location $RepoRoot
    Remove-Item $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
# --- agent instruction block (Merge-ManagedBlock is pure) ------------------------------------------
& {
    $blk = "<!-- mission-centre:brain BEGIN x -->`nNEW BLOCK`n<!-- mission-centre:brain END -->"
    Check 'block: empty file gets just the block' ((Merge-ManagedBlock '' $blk).Trim() -eq $blk)
    $oldPara = "# Global rules (pi)`n`nIf ``~/.obsidian-wiki/context-pack.md`` exists, read it before anything else: it is the current`nslice of my knowledge base.`n`n## Other rule`nkeep me"
    $m1 = Merge-ManagedBlock $oldPara $blk
    Check 'block: replaces the old hand-written paragraph, keeps the rest' ($m1 -match 'NEW BLOCK' -and $m1 -notmatch 'slice of my knowledge base' -and $m1 -match 'keep me' -and $m1.StartsWith('# Global rules'))
    $m2 = Merge-ManagedBlock $m1 ($blk -replace 'NEW BLOCK', 'NEWER')
    Check 'block: a second run replaces the managed block in place' ($m2 -match 'NEWER' -and $m2 -notmatch 'NEW BLOCK' -and ([regex]::Matches($m2, 'mission-centre:brain BEGIN')).Count -eq 1)
    Check 'block: idempotent' ((Merge-ManagedBlock $m2 ($blk -replace 'NEW BLOCK', 'NEWER')) -eq $m2)
    $m3 = Merge-ManagedBlock "# Title`r`nbody line`r`n" $blk
    Check 'block: goes under a leading title and keeps CRLF files CRLF' ($m3.StartsWith("# Title`r`n") -and $m3 -match "NEW BLOCK`r`n" -and $m3 -match 'body line')
    Check 'block: plain file gets it on top' ((Merge-ManagedBlock "just text" $blk).StartsWith('<!-- mission-centre:brain BEGIN'))
    $home2 = Join-Path $TestRoot 'agent-home-2'
    New-Item -ItemType Directory -Path (Join-Path $home2 '.pi\agent') -Force | Out-Null
    $tg = @([pscustomobject]@{ agent = 'pi'; file = (Join-Path $home2 '.pi\agent\AGENTS.md') }, [pscustomobject]@{ agent = 'Gemini'; file = (Join-Path $home2 '.gemini\GEMINI.md') })
    Set-AgentInstructionBlocks $tg 6>$null
    $first = Get-Content (Join-Path $home2 '.pi\agent\AGENTS.md') -Raw
    Set-AgentInstructionBlocks $tg 6>$null
    Check 'block: written for an installed agent, unchanged on a second run' ($first -match 'wiki-query' -and (Get-Content (Join-Path $home2 '.pi\agent\AGENTS.md') -Raw) -eq $first)
    Check 'block: not written for an agent that is not installed' (-not (Test-Path (Join-Path $home2 '.gemini')))
}

$summary = "$($script:Pass) passed, $($script:Fail) failed, $($script:Skipped) skipped on PowerShell $($PSVersionTable.PSVersion)"
if ($script:Fail -gt 0) { Write-Host $summary -ForegroundColor Red; exit 1 }
Write-Host $summary -ForegroundColor Green
exit 0
