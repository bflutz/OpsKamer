# 30-discovery.ps1 - Project discovery, registry I/O, lifecycle
# Split from Mission-Centre.ps1. Dot-sourced by the root script; relies on the
# script-scoped config globals ($ScanRoot, $Pi*, etc.) defined there.

function Test-SkipDir {
    param([string]$DirName)
    foreach ($pat in $SkipDirNames) {
        if ($DirName -like $pat) { return $true }
    }
    return $false
}

function Test-MarkerSet {
    param([string]$DirPath, [string[]]$Markers)
    foreach ($marker in $Markers) {
        if ($marker.Contains('*')) {
            $found = Get-ChildItem -Path $DirPath -Filter $marker -ErrorAction SilentlyContinue |
                     Select-Object -First 1
            if ($found) { return $true }
        } else {
            if (Test-Path (Join-Path $DirPath $marker)) { return $true }
        }
    }
    return $false
}

function Test-AnyChildHasMarkers {
    param([string]$DirPath)
    try {
        $kids = Get-ChildItem -Path $DirPath -Directory -ErrorAction SilentlyContinue
        foreach ($kid in $kids) {
            if (-not (Test-SkipDir $kid.Name)) {
                if (Test-MarkerSet $kid.FullName $ProjectMarkers) { return $true }
            }
        }
    } catch { }
    return $false
}

function Find-ProjectDirs {
    param([string]$Path, [int]$Depth)

    if ($Depth -gt $MaxDepth)                        { return }
    if (-not (Test-Path $Path -PathType Container))  { return }

    $leaf = Split-Path $Path -Leaf
    if (Test-SkipDir $leaf)        { return }
    # Never offer Mission Centre itself as a project. Must be the ROOT global: in this dot-sourced
    # file $PSScriptRoot is lib/, which silently broke this guard after the monolith split.
    if ($Path -ieq $MissionRootDir) { return }

    # Definitive marker: this is unambiguously a project root
    if (Test-MarkerSet $Path $DefinitiveMarkers) {
        $Path
        return
    }

    # Suggestive marker: could be a project, or could be a workspace container
    # Prefer children if any child also has markers (i.e. we're in a container)
    if (Test-MarkerSet $Path $SuggestiveMarkers) {
        if (Test-AnyChildHasMarkers $Path) {
            # This dir is a container — recurse to find the real projects inside
        } else {
            $Path
            return
        }
    }

    try {
        $kids = Get-ChildItem -Path $Path -Directory -ErrorAction SilentlyContinue
        foreach ($kid in $kids) {
            Find-ProjectDirs $kid.FullName ($Depth + 1)
        }
    } catch { }
}

function Import-ProjectConfig {
    # projects.json is this device's registry - or, with sharedState on, its offline
    # cache of the shared registry (lib/35-sharedstate.ps1 merges the two).
    $list = @()
    if (Test-Path $ConfigPath) {
        try {
            $raw  = Get-Content $ConfigPath -Raw -Encoding UTF8
            $parsed = $raw | ConvertFrom-Json
            if ($null -ne $parsed) { $list = @($parsed) }
        } catch {
            Write-Host 'WARN: Could not parse projects.json - starting fresh.' -ForegroundColor Yellow
            $list = @()
        }
    }
    if (Test-SharedStateEnabled) {
        try { $list = @(Sync-ProjectsWithSharedState $list) }
        catch {
            $script:SharedStateStatus = "error: $_"
            Write-MissionLog 'WARN' "shared state sync failed: $_"
        }
    }
    return $list
}

function Save-Config {
    param([object[]]$Projects)
    if (Test-SharedStateEnabled) {
        # First: assigns ids to new projects, so the cache below stores them too.
        try { Save-ProjectsToSharedState $Projects }
        catch {
            $script:SharedStateStatus = "error: $_"
            Write-MissionLog 'WARN' "shared state save failed: $_"
        }
    }
    Save-LocalProjectCache $Projects
}

function Save-LocalProjectCache {
    param([object[]]$Projects)
    $dir = Split-Path $ConfigPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # @() + -InputObject forces a JSON array even for a single project (stable across PS 5.1/7).
    ConvertTo-Json -InputObject @($Projects) -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
}

function Get-GlobalJigProfilesDir {
    if ($HOME) { return (Join-Path (Join-Path $HOME '.jig') 'profiles') }
    return (Join-Path (Join-Path $env:USERPROFILE '.jig') 'profiles')
}

function Get-JigProfileDrift {
    # Pure: compare each bundled starter profile against the installed copy.
    # Returns one object per bundled yaml: @{ name; status } with status
    # 'missing' | 'identical' | 'differs'. Line endings and trailing whitespace
    # are normalized so a CRLF checkout never reads as drift. A stale installed
    # profile can silently invert launch behavior (a plan-mode profile replaced
    # by an old bypassPermissions one), so 'differs' is worth surfacing loudly.
    param([string]$BundledDir, [string]$InstalledDir)
    if (-not (Test-Path $BundledDir -PathType Container)) { return @() }
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($f in @(Get-ChildItem -Path $BundledDir -Filter '*.yaml' -File -ErrorAction SilentlyContinue)) {
        $target = Join-Path $InstalledDir $f.Name
        $status = 'missing'
        if (Test-Path $target -PathType Leaf) {
            try {
                $a = ((Get-Content $f.FullName -Raw -Encoding UTF8) -replace "`r`n", "`n").TrimEnd()
                $b = ((Get-Content $target -Raw -Encoding UTF8) -replace "`r`n", "`n").TrimEnd()
                $status = if ($a -ceq $b) { 'identical' } else { 'differs' }
            } catch { $status = 'differs' }
        }
        $results.Add([PSCustomObject]@{ name = $f.BaseName; status = $status })
    }
    return $results.ToArray()
}

function Install-StarterJigProfiles {
    if (-not (Test-Path $BundledJigProfilesDir -PathType Container)) {
        Write-Host "  ERROR: Bundled Jig profiles folder not found: $BundledJigProfilesDir" -ForegroundColor Red
        return
    }

    $targetDir = Get-GlobalJigProfilesDir
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    Write-Host ''
    Write-Host "  Installing starter Jig profiles to $targetDir" -ForegroundColor Cyan
    $driftMap = @{}
    foreach ($d in @(Get-JigProfileDrift $BundledJigProfilesDir $targetDir)) { $driftMap[$d.name] = $d.status }
    $profiles = @(Get-ChildItem -Path $BundledJigProfilesDir -Filter '*.yaml' -File -ErrorAction SilentlyContinue)
    foreach ($profileName in $profiles) {
        $target = Join-Path $targetDir $profileName.Name
        $status = $driftMap[$profileName.BaseName]
        if ($status -eq 'identical') {
            Write-Host "   up to date $($profileName.Name)" -ForegroundColor DarkGray
            continue
        }
        if ($status -eq 'differs') {
            # Default Y here ([G] is an explicit request): the installed copy of a *starter* profile that
            # differs from bundled is usually stale, and stale profiles have inverted launch semantics
            # before (vibe: plan-mode rewrite vs old full-autonomy copy). Your copy is backed up first.
            Write-Host "   $($profileName.Name) differs from the bundled copy (installed may be stale)." -ForegroundColor Yellow
            if (-not (Read-YesNo "   Update $($profileName.Name) to the bundled version?" 'Y')) {
                Write-Host "   kept existing $($profileName.Name)" -ForegroundColor DarkGray
                continue
            }
        }
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            # Your copy is kept next to it (Jig reads only *.yaml, so the backup is not loaded as a profile).
            $bak = "$target.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item -LiteralPath $target -Destination $bak -Force
            Write-Host "   backed up your $($profileName.Name) -> $(Split-Path $bak -Leaf)" -ForegroundColor DarkGray
        }
        Copy-Item -Path $profileName.FullName -Destination $target -Force
        Write-Host "   installed $($profileName.Name)" -ForegroundColor Green
    }

    if (Get-Command 'jig' -ErrorAction SilentlyContinue) {
        Write-Host ''
        Write-Host '  Validating starter profiles ...' -ForegroundColor DarkGray
        foreach ($name in $StarterProfiles) {
            try {
                & jig profiles validate $name
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "   $name OK" -ForegroundColor DarkGreen
                } else {
                    Write-Host "   WARN: $name did not validate" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "   WARN: $name validation failed: $_" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  WARN: 'jig' is not in PATH; profiles copied but not validated." -ForegroundColor Yellow
    }
}

function Get-GlobalClaudeSkillsDir {
    # Claude Code's user skills root (also what jig-launched sessions read).
    if ($HOME) { return (Join-Path (Join-Path $HOME '.claude') 'skills') }
    return (Join-Path (Join-Path $env:USERPROFILE '.claude') 'skills')
}

function Get-GlobalAgentsSkillsDir {
    # Shared Agent Skills root. pi reads it regardless of PI_CODING_AGENT_DIR, and Codex
    # reads it too. pi does NOT read ~/.claude/skills unless its settings list it.
    if ($HOME) { return (Join-Path (Join-Path $HOME '.agents') 'skills') }
    return (Join-Path (Join-Path $env:USERPROFILE '.agents') 'skills')
}

function Get-SkillInstallTargets {
    # Every harness Mission Centre launches must see the bundled skills.
    return @(
        [pscustomobject]@{ harness = 'Claude Code'; dir = (Get-GlobalClaudeSkillsDir) },
        [pscustomobject]@{ harness = 'pi/Codex';    dir = (Get-GlobalAgentsSkillsDir) }
    )
}

function Get-BundledSkillNames {
    # Bundled skills are the skills/<name>/ folders that carry a SKILL.md.
    if (-not (Test-Path $BundledSkillsDir -PathType Container)) { return @() }
    return @(Get-ChildItem -Path $BundledSkillsDir -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') -PathType Leaf } |
        Sort-Object Name | ForEach-Object { $_.Name })
}

function Get-SkillDirFingerprint {
    # Sorted "relative/path=sha256" lines; equal fingerprints mean identical trees.
    param([string]$Dir)
    if (-not (Test-Path $Dir -PathType Container)) { return $null }
    $root = (Resolve-Path -LiteralPath $Dir).Path.TrimEnd('\', '/')
    # .NET SHA256, not Get-FileHash: that cmdlet can be unresolvable in Windows PowerShell
    # when it inherits a PowerShell 7 PSModulePath.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $lines = @(Get-ChildItem -LiteralPath $Dir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        $hash = [System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($_.FullName)))
        "$rel=$hash"
    })
    $sha.Dispose()
    return (@($lines | Sort-Object) -join "`n")
}

function Get-BundledSkillStatus {
    # One row per (skill, harness target): status is missing | identical | differs.
    param([string[]]$Names)
    if (-not $PSBoundParameters.ContainsKey('Names')) { $Names = @(Get-BundledSkillNames) }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($name in @($Names)) {
        $srcPrint = Get-SkillDirFingerprint (Get-SkillSourceDir $name)   # newest upstream copy when staged (66-sources)
        foreach ($t in Get-SkillInstallTargets) {
            $dst = Join-Path $t.dir $name
            $status = if (-not (Test-Path (Join-Path $dst 'SKILL.md') -PathType Leaf)) { 'missing' }
                      elseif ((Get-SkillDirFingerprint $dst) -eq $srcPrint) { 'identical' }
                      else { 'differs' }
            $rows.Add([pscustomobject]@{ skill = $name; harness = $t.harness; dir = $dst; status = $status })
        }
    }
    return $rows.ToArray()
}

function Test-BundledSkillInstalled {
    param([string]$Name)
    foreach ($t in Get-SkillInstallTargets) {
        if (-not (Test-Path (Join-Path (Join-Path $t.dir $Name) 'SKILL.md') -PathType Leaf)) { return $false }
    }
    return $true
}

function Install-BundledSkill {
    # Copy skills/<Name> into every harness skills root. -Quiet (lazy launch-time callers)
    # only fills gaps and never touches an existing install; interactive runs skip identical
    # installs and ask before overwriting a different one.
    param([string]$Name, [switch]$Quiet)

    $sourceDir = Get-SkillSourceDir $Name   # newest upstream copy when staged (66-sources), else bundled
    if (-not (Test-Path (Join-Path $sourceDir 'SKILL.md') -PathType Leaf)) {
        Write-Host "  ERROR: Bundled $Name skill not found: $sourceDir" -ForegroundColor Red
        return $false
    }
    $srcPrint = $null
    $ok = $true

    foreach ($t in Get-SkillInstallTargets) {
        $targetDir = Join-Path $t.dir $Name
        if (Test-Path $targetDir) {
            if ($Quiet) { continue }
            if ($null -eq $srcPrint) { $srcPrint = Get-SkillDirFingerprint $sourceDir }
            if ((Get-SkillDirFingerprint $targetDir) -eq $srcPrint) {
                Write-Host "   $Name ($($t.harness)): up to date" -ForegroundColor DarkGray
                continue
            }
            if (-not (Read-YesNo "  $Name skill differs at $targetDir. Overwrite?" 'N')) {
                Write-Host "   skipped $Name ($($t.harness))" -ForegroundColor DarkGray
                continue
            }
            Remove-Item -Path $targetDir -Recurse -Force
        }
        try {
            if (-not (Test-Path $t.dir)) { New-Item -ItemType Directory -Path $t.dir -Force | Out-Null }
            Copy-Item -Path $sourceDir -Destination $targetDir -Recurse -Force
            $color = if ($Quiet) { 'DarkGray' } else { 'Green' }
            Write-Host "  Installed $Name skill to $targetDir" -ForegroundColor $color
        } catch {
            Write-Host "  ERROR: Could not install $Name skill to ${targetDir}: $_" -ForegroundColor Red
            $ok = $false
        }
    }
    return $ok
}

function Install-BundledSkills {
    # Install every bundled skill (used by [G] and, with -Quiet, before each launch).
    param([switch]$Quiet)
    $names = @(Get-BundledSkillNames)
    if ($names.Count -eq 0) {
        if (-not $Quiet) { Write-Host "  WARN: No bundled skills found in $BundledSkillsDir" -ForegroundColor Yellow }
        return $false
    }
    if (-not $Quiet) {
        Write-Host ''
        Write-Host "  Bundled skills ($($names -join ', ')) -> ~/.claude/skills + ~/.agents/skills" -ForegroundColor Cyan
    }
    $ok = $true
    foreach ($n in $names) {
        if (-not (Install-BundledSkill -Name $n -Quiet:$Quiet)) { $ok = $false }
    }
    return $ok
}

function Test-ConfigHasPath {
    param([object[]]$Config, [string]$Path)
    foreach ($e in $Config) {
        if ($e.path -ieq $Path) { return $true }
    }
    return $false
}

function Resolve-ImportablePath {
    # Pure (no prompts): expand/normalize a user-typed path and decide whether it
    # can be imported as a project. Returns a result object so the interactive
    # wrapper - and the test suite - can branch on it.
    #   @{ ok = $bool; path = <normalized full path>; reason = <message if not ok> }
    param([string]$RawPath, [object[]]$Config)

    if ([string]::IsNullOrWhiteSpace($RawPath)) {
        return [PSCustomObject]@{ ok = $false; path = ''; reason = 'cancelled' }
    }

    $expanded = Resolve-UserPath $RawPath.Trim()
    try {
        $normalized = [System.IO.Path]::GetFullPath($expanded)
    } catch {
        return [PSCustomObject]@{ ok = $false; path = $expanded; reason = "invalid path: $expanded" }
    }
    # Drop a trailing separator so dedup is stable (GetFullPath keeps one for roots).
    if ($normalized.Length -gt 3) {
        $normalized = $normalized.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    }

    if (-not (Test-Path -LiteralPath $normalized -PathType Container)) {
        return [PSCustomObject]@{ ok = $false; path = $normalized; reason = "path does not exist: $normalized" }
    }

    if (Test-ConfigHasPath $Config $normalized) {
        return [PSCustomObject]@{ ok = $false; path = $normalized; reason = 'that project is already in your list' }
    }

    return [PSCustomObject]@{ ok = $true; path = $normalized; reason = '' }
}

# Read the description: line out of a Jig profile yaml. Looks at the user's
# installed profile first (since that's what jig actually runs), falls back
# to the bundled copy. Returns '' if the profile is not found.
function Get-ProfileDescription {
    param([string]$ProfileName)
    if ([string]::IsNullOrWhiteSpace($ProfileName)) { return '' }
    $candidates = @(
        (Join-Path (Get-GlobalJigProfilesDir) "$ProfileName.yaml"),
        (Join-Path $BundledJigProfilesDir "$ProfileName.yaml")
    )
    foreach ($candidate in $candidates) {
        if (-not (Test-Path $candidate)) { continue }
        try {
            $content = Get-Content $candidate -Raw -Encoding UTF8
            if ($content -match '(?m)^\s*description\s*:\s*"?([^"\r\n]+?)"?\s*$') {
                return $Matches[1].Trim()
            }
        } catch { }
    }
    return ''
}

function Get-ProfilePermissionMode {
    # Resolve a Jig profile's effective permission_mode, following its 'extends'
    # chain up to 3 levels (installed profile wins over bundled, matching what
    # jig actually runs). Returns '' when the profile or key can't be resolved.
    param([string]$ProfileName, [int]$Depth = 0)
    if ([string]::IsNullOrWhiteSpace($ProfileName) -or $Depth -gt 3) { return '' }
    $candidates = @(
        (Join-Path (Get-GlobalJigProfilesDir) "$ProfileName.yaml"),
        (Join-Path $BundledJigProfilesDir "$ProfileName.yaml")
    )
    foreach ($candidate in $candidates) {
        if (-not (Test-Path $candidate)) { continue }
        try {
            $content = Get-Content $candidate -Raw -Encoding UTF8
            if ($content -match '(?m)^\s*permission_mode\s*:\s*"?([A-Za-z]+)"?\s*$') {
                return $Matches[1]
            }
            if ($content -match '(?m)^\s*extends\s*:\s*"?([A-Za-z0-9-]+)"?\s*$') {
                return (Get-ProfilePermissionMode $Matches[1] ($Depth + 1))
            }
            return ''   # profile found but sets no mode and extends nothing -> jig default
        } catch { }
    }
    return ''
}

function Confirm-ProfileLaunchIntent {
    # Guard for semantically-loaded launches: the New App path expects 'vibe' to be
    # plan-mode, and a stale installed profile once inverted that into a
    # bypassPermissions autonomy profile. Only blocks on a positive mismatch -
    # an unknown/absent mode passes without prompting. Returns $true to proceed.
    param([string]$ProfileName, [string]$ExpectedMode)
    $mode = Get-ProfilePermissionMode $ProfileName
    if ([string]::IsNullOrWhiteSpace($mode) -or $mode -ieq $ExpectedMode) { return $true }
    Write-Host "  WARN: profile '$ProfileName' has permission_mode '$mode' but this launch expects '$ExpectedMode'." -ForegroundColor Yellow
    Write-Host '  The installed profile may be stale - run [G] to review starter profile updates.' -ForegroundColor DarkGray
    return (Read-YesNo '  Launch anyway?' 'N')
}

function Sync-NewProjects {
    param([ref]$ConfigRef)

    Write-Host "Scanning $ScanRoot for projects ..." -ForegroundColor DarkGray

    $discovered = @(Find-ProjectDirs $ScanRoot 0)
    $newPaths   = @($discovered | Where-Object { -not (Test-ConfigHasPath $ConfigRef.Value $_) })

    if ($newPaths.Count -eq 0) {
        Write-Host 'No new projects found.' -ForegroundColor DarkGray
        return
    }

    Write-Host ''
    Write-Host "Found $($newPaths.Count) new project(s) not yet in config." -ForegroundColor Yellow
    Write-Divider

    $updated = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $ConfigRef.Value) { $updated.Add($e) }

    foreach ($p in $newPaths) {
        # Already known from another device (same git remote)? Adopt it, no questions.
        if ((Test-SharedStateEnabled) -and $null -ne $script:SharedRecords) {
            $rid = ConvertTo-RemoteId (Get-ProjectGitRemote $p)
            if ($rid -and $script:SharedRecords.Contains($rid)) {
                $known = New-ProjectFromRecord $script:SharedRecords[$rid] $p
                $updated.Add($known)
                Write-Host ''
                Write-Host "  Known from another device: $($known.name)  ($p)" -ForegroundColor DarkGreen
                continue
            }
        }
        $defaultName = Split-Path $p -Leaf
        Write-Host ''
        Write-Host '  New project: ' -NoNewline -ForegroundColor Cyan
        Write-Host $p
        $name = Read-Host "  Name        [$defaultName]"
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $defaultName }
        $desc = Read-Host '  Description (one line, or Enter to skip)'
        if ([string]::IsNullOrWhiteSpace($desc)) { $desc = '- no description yet -' }
        Show-ProfileMenu
        $prof = Read-Host "  Profile     [$DefaultProfile]"
        if ([string]::IsNullOrWhiteSpace($prof)) { $prof = $DefaultProfile }

        $updated.Add([PSCustomObject]@{
            path        = $p
            name        = $name
            description = $desc
            added       = (Get-Date -Format 'yyyy-MM-dd')
            profile     = $prof
        })

        $health = Get-ContextHealth $p
        if (-not $health.hasClaudeMd) {
            Write-Host '  Context     CLAUDE.md missing' -ForegroundColor Yellow
            if (Read-YesNo '  Offer context setup now?' 'N') {
                Invoke-ContextSetup $p
            }
        } else {
            Write-Host '  Context     CLAUDE.md present' -ForegroundColor DarkGreen
        }
    }

    $ConfigRef.Value = $updated.ToArray()
    Save-Config $ConfigRef.Value
    Write-Host ''
    Write-Host '  Config saved.' -ForegroundColor Green
}

function Get-ProjectName {
    param([object]$Project)
    return Get-OptionalProperty $Project 'name' (Split-Path $Project.path -Leaf)
}

function ConvertTo-ProjectIndexSelection {
    # Parse "1,3-5" (1-based project numbers) into distinct 0-based indexes, in input order.
    param([string]$Selection, [int]$Count)
    $selected = [System.Collections.Generic.List[int]]::new()
    $seen = @{}
    if ([string]::IsNullOrWhiteSpace($Selection)) { return @() }

    foreach ($part in ($Selection -split ',')) {
        $piece = $part.Trim()
        if ($piece -match '^(\d+)-(\d+)$') {
            $start = [int]$Matches[1]
            $end = [int]$Matches[2]
            if ($end -lt $start) { $tmp = $start; $start = $end; $end = $tmp }
            # Clamp before iterating: "1-9999999" must not materialize millions of loop turns.
            if ($start -lt 1) { $start = 1 }
            if ($end -gt $Count) { $end = $Count }
            if ($start -gt $end) { continue }
            foreach ($n in $start..$end) {
                $idx = $n - 1
                if ($idx -ge 0 -and $idx -lt $Count -and -not $seen.ContainsKey($idx)) {
                    $selected.Add($idx)
                    $seen[$idx] = $true
                }
            }
        } elseif ($piece -match '^\d+$') {
            $idx = [int]$piece - 1
            if ($idx -ge 0 -and $idx -lt $Count -and -not $seen.ContainsKey($idx)) {
                $selected.Add($idx)
                $seen[$idx] = $true
            }
        }
    }
    return $selected.ToArray()
}

function ConvertTo-ProjectSelection {
    param([string]$Selection, [object[]]$Projects)
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($idx in @(ConvertTo-ProjectIndexSelection $Selection $Projects.Count)) {
        $selected.Add($Projects[$idx])
    }
    return $selected.ToArray()
}

function Test-ProjectDormant {
    # Dormant projects stay registered (stable numbers, no re-discovery by [S] Scan) but are
    # hidden from the home recents, the [A] list, and the meta-mission picker.
    param([object]$Project)
    return (ConvertTo-MissionBool (Get-OptionalProperty $Project 'dormant' $false) $false)
}

function Set-ProjectDormant {
    # Mark ($Dormant = $true) or reactivate ($false) the projects at the given 0-based indexes,
    # then save. Reactivating removes the flags entirely so active entries stay clean.
    # Returns the number of entries whose state actually changed.
    param([ref]$ConfigRef, [int[]]$Indexes, [bool]$Dormant)

    $changed = 0
    foreach ($idx in @($Indexes)) {
        if ($idx -lt 0 -or $idx -ge @($ConfigRef.Value).Count) { continue }
        $p = $ConfigRef.Value[$idx]
        if ((Test-ProjectDormant $p) -eq $Dormant) { continue }
        # reactivatedOn restarts the idle clock, so auto-dormant does not re-hide a project
        # the moment it is woken up (it would still be idle by session activity alone).
        $today = Get-Date -Format 'yyyy-MM-dd'
        $set = @{}
        if ($Dormant) {
            $set['dormant'] = $true; $set['dormantSince'] = $today
            $remove = @('reactivatedOn')
        } else {
            $set['reactivatedOn'] = $today
            $remove = @('dormant', 'dormantSince')
        }
        foreach ($name in @($set.Keys)) {
            if ($p.PSObject.Properties[$name]) { $p.$name = $set[$name] }
            else { $p | Add-Member -NotePropertyName $name -NotePropertyValue $set[$name] }
        }
        foreach ($name in $remove) {
            if ($p.PSObject.Properties[$name]) { $p.PSObject.Properties.Remove($name) }
        }
        $changed++
    }
    if ($changed -gt 0) { Save-Config $ConfigRef.Value }
    return $changed
}

function Get-IdleProjectCandidates {
    # Active projects idle for $Days days. The idle clock starts at the newest of: Claude Code /
    # pi session activity, the 'added' date, and the 'reactivatedOn' date - so a freshly
    # registered or just-reactivated project is never suggested. A project with none of those
    # is skipped (nothing to measure from). Oldest activity first.
    param([object[]]$Projects, [int]$Days)
    $cutoff = [DateTimeOffset]::UtcNow.AddDays(-$Days).ToUnixTimeMilliseconds()
    $out = @()
    for ($i = 0; $i -lt @($Projects).Count; $i++) {
        $p = $Projects[$i]
        if (Test-ProjectDormant $p) { continue }
        $ms = [long](Get-ProjectLastActivityMs $p.path)
        $ref = $ms
        foreach ($field in @('added', 'reactivatedOn')) {
            $d = [datetime]::MinValue
            if ([datetime]::TryParse([string](Get-OptionalProperty $p $field ''), [ref]$d)) {
                $dMs = ([DateTimeOffset]$d.ToUniversalTime()).ToUnixTimeMilliseconds()
                if ($dMs -gt $ref) { $ref = $dMs }
            }
        }
        if ($ref -le 0 -or $ref -ge $cutoff) { continue }
        $out += [PSCustomObject]@{ Num = $i + 1; Index = $i; Project = $p; Ms = $ms }
    }
    return @($out | Sort-Object Ms, Index)   # Index tiebreak: PS 5.1 sort is not stable
}

function Invoke-AutoDormant {
    # Startup sweep: move every active project idle for $Days days to dormant. Quiet unless it
    # moved something. Returns the number of projects moved.
    param([ref]$ConfigRef, [int]$Days)
    $cands = @(Get-IdleProjectCandidates $ConfigRef.Value $Days)
    if ($cands.Count -eq 0) { return 0 }
    $n = Set-ProjectDormant $ConfigRef @($cands | ForEach-Object { $_.Index }) $true
    if ($n -gt 0) {
        $names = ($cands | ForEach-Object { Get-ProjectName $_.Project }) -join ', '
        Write-Host "  Auto-dormant: $n project(s) idle $Days+ days moved to [D] dormant." -ForegroundColor DarkGray
        Write-MissionLog 'INFO' "Auto-dormant ($Days days): $names"
    }
    return $n
}

function Resume-DormantProject {
    # Launching a dormant project means it is in use again: reactivate it so it shows on home.
    param([ref]$ConfigRef, [int]$Index)
    if (-not (Test-ProjectDormant $ConfigRef.Value[$Index])) { return }
    if ((Set-ProjectDormant $ConfigRef @($Index) $false) -gt 0) {
        Write-Host '  Reactivated (was dormant).' -ForegroundColor Green
    }
}

function Invoke-ParkIdleProjects {
    # Bulk "make dormant": suggest idle projects, let the user pick (numbers/ranges or ALL).
    param([ref]$ConfigRef, [int]$Days)

    $cands = @(Get-IdleProjectCandidates $ConfigRef.Value $Days)
    Write-Host ''
    if ($cands.Count -eq 0) {
        Write-Host "  No active projects idle for $Days+ days." -ForegroundColor DarkGray
        return
    }
    Write-Host "  Active projects idle for $Days+ days ($($cands.Count)):" -ForegroundColor Cyan
    foreach ($c in $cands) {
        $age = if ($c.Ms -gt 0) { 'last active ' + (Format-EpochMsAge $c.Ms) } else { 'never launched' }
        Write-ProjectRow $c.Num $c.Project $age
    }
    Write-Host ''
    $sel = Read-Host '  Make dormant: numbers (e.g. 3,5-7), [ALL], or Enter to cancel'
    if ([string]::IsNullOrWhiteSpace($sel)) { Write-Host '  Cancelled.' -ForegroundColor DarkGray; return }
    $candIdx = @($cands | ForEach-Object { $_.Index })
    if ($sel.Trim().ToUpper() -eq 'ALL') {
        $pick = $candIdx
    } else {
        # Any active project number is accepted, not just the suggestions.
        $pick = @(ConvertTo-ProjectIndexSelection $sel @($ConfigRef.Value).Count)
    }
    $n = Set-ProjectDormant $ConfigRef $pick $true
    Write-Host "  $n project(s) moved to dormant." -ForegroundColor Green
}

function Set-ScanRoot {
    Write-Host ''
    Write-Host "  Current scan root: $ScanRoot" -ForegroundColor DarkGray
    $newRoot = Read-Host '  New scan root path'
    if ([string]::IsNullOrWhiteSpace($newRoot)) {
        Write-Host '  Cancelled.' -ForegroundColor DarkGray
        return
    }

    $newRoot = Resolve-UserPath $newRoot.Trim()
    if (-not (Test-Path $newRoot -PathType Container)) {
        Write-Host "  ERROR: Path does not exist: $newRoot" -ForegroundColor Red
        return
    }

    # Routine menu action: parse/write failures must warn, not bubble up to the root
    # Stop handler and kill the app. Mirrors Get-AppConfig (backup before overwriting).
    $cfg = $null
    if (Test-Path $AppConfigPath) {
        try {
            $cfg = Get-Content $AppConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            try { Copy-Item -LiteralPath $AppConfigPath -Destination "$AppConfigPath.bak" -Force } catch { }
            Write-Host '  WARN: config.json could not be parsed; backed up to config.json.bak and rewriting.' -ForegroundColor Yellow
        }
    }
    if ($null -eq $cfg) { $cfg = [PSCustomObject]@{} }
    if (-not $cfg.PSObject.Properties['scanRoot']) {
        $cfg | Add-Member -NotePropertyName 'scanRoot' -NotePropertyValue $newRoot
    } else {
        $cfg.scanRoot = $newRoot
    }
    try {
        $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $AppConfigPath -Encoding UTF8
    } catch {
        Write-Host "  ERROR: Could not write config.json: $_" -ForegroundColor Red
        Write-Host '  Scan root changed for this session only.' -ForegroundColor DarkYellow
    }
    $script:ScanRoot = $newRoot

    Write-Host "  Scan root updated to: $newRoot" -ForegroundColor Green
    Write-Host '  Press [S] to scan the new root for projects.' -ForegroundColor DarkGray
}

function New-ScaffoldedProject {
    # Prompts for a new folder under $ScanRoot, creates it, registers it in the
    # project list, and offers git init / CLAUDE.md. Returns the new project object
    # (PSCustomObject with path/name/description/added/profile) or $null if cancelled.
    param(
        [ref]$ConfigRef,
        [string]$DefaultProfileName = $DefaultProfile
    )

    if (-not (Assert-DirExists $ScanRoot)) { return $null }

    $folderName = Read-Host '  New folder name'
    if ([string]::IsNullOrWhiteSpace($folderName)) {
        Write-Host '  Cancelled.' -ForegroundColor DarkGray
        return $null
    }
    $folderName = $folderName.Trim()
    $resolvedPath = Join-Path $ScanRoot $folderName

    Write-Host "  Will create: $resolvedPath" -ForegroundColor DarkGray

    if (Test-ConfigHasPath $ConfigRef.Value $resolvedPath) {
        Write-Host '  That project is already in your list.' -ForegroundColor Yellow
        return $null
    }

    if (-not (Test-Path $resolvedPath -PathType Container)) {
        try {
            New-Item -ItemType Directory -Path $resolvedPath -Force | Out-Null
            Write-Host '  Folder created.' -ForegroundColor Green
        } catch {
            Write-Host "  ERROR: Could not create folder: $_" -ForegroundColor Red
            return $null
        }
    }

    $name = Read-Host "  Display name [$folderName]"
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $folderName }

    $desc = Read-Host '  Description (one line, or Enter to skip)'
    if ([string]::IsNullOrWhiteSpace($desc)) { $desc = '- no description yet -' }

    Show-ProfileMenu
    $prof = Read-Host "  Profile [$DefaultProfileName]"
    if ([string]::IsNullOrWhiteSpace($prof)) { $prof = $DefaultProfileName }

    $project = [PSCustomObject]@{
        path        = $resolvedPath
        name        = $name
        description = $desc
        added       = (Get-Date -Format 'yyyy-MM-dd')
        profile     = $prof
    }

    $updated = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $ConfigRef.Value) { $updated.Add($e) }
    $updated.Add($project)
    $ConfigRef.Value = $updated.ToArray()
    # This function returns $project: any stray output (e.g. git from the shared-state sync)
    # would turn the return value into an array, so keep everything off the pipeline.
    $null = Save-Config $ConfigRef.Value

    Write-Host ''
    Write-Host "  Project '$name' added." -ForegroundColor Green

    if (-not (Test-Path (Join-Path $resolvedPath '.git'))) {
        if (Read-YesNo '  No git repo found. Run git init?' 'N') {
            if (Get-Command 'git' -ErrorAction SilentlyContinue) {
                # Discard git's output: anything written here would become part of the return value.
                $null = Invoke-InDirectory $resolvedPath { & git init }
                Write-Host '  Git repo initialized.' -ForegroundColor Green
            } else {
                Write-Host '  WARN: git not found in PATH, skipping.' -ForegroundColor Yellow
            }
        }
    }

    if (-not (Test-Path (Join-Path $resolvedPath 'CLAUDE.md'))) {
        if (Read-YesNo '  No CLAUDE.md found. Create one?' 'Y') {
            $null = New-MinimalClaudeMd $resolvedPath
            Write-Host '  CLAUDE.md created.' -ForegroundColor Green
        }
    }

    return $project
}

function Import-ExistingProject {
    # Registers a folder that already exists - anywhere on disk, not just under
    # $ScanRoot - into projects.json. Never creates the folder and never runs
    # git init; the directory is pre-existing and may already be set up.
    param([ref]$ConfigRef)

    Write-Host ''
    Write-Host '  Import Existing Project' -ForegroundColor Cyan
    Write-Host '  Registers a folder you already have (any path) as a project.' -ForegroundColor DarkGray
    Write-Host ''

    $raw = Read-Host '  Folder path to import'
    $resolved = Resolve-ImportablePath $raw $ConfigRef.Value
    if (-not $resolved.ok) {
        Write-Host "  $($resolved.reason)" -ForegroundColor Yellow
        return
    }
    $resolvedPath = $resolved.path
    Write-Host "  Will import: $resolvedPath" -ForegroundColor DarkGray

    $defaultName = Split-Path $resolvedPath -Leaf
    $name = Read-Host "  Display name [$defaultName]"
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $defaultName }

    $desc = Read-Host '  Description (one line, or Enter to skip)'
    if ([string]::IsNullOrWhiteSpace($desc)) { $desc = '- no description yet -' }

    Show-ProfileMenu
    $prof = Read-Host "  Profile [$DefaultProfile]"
    if ([string]::IsNullOrWhiteSpace($prof)) { $prof = $DefaultProfile }

    $project = [PSCustomObject]@{
        path        = $resolvedPath
        name        = $name
        description = $desc
        added       = (Get-Date -Format 'yyyy-MM-dd')
        profile     = $prof
    }

    $updated = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $ConfigRef.Value) { $updated.Add($e) }
    $updated.Add($project)
    $ConfigRef.Value = $updated.ToArray()
    Save-Config $ConfigRef.Value

    Write-Host ''
    Write-Host "  Project '$name' imported." -ForegroundColor Green

    $health = Get-ContextHealth $resolvedPath
    if (-not $health.hasClaudeMd) {
        Write-Host '  Context     CLAUDE.md missing' -ForegroundColor Yellow
        if (Read-YesNo '  Offer context setup now?' 'N') {
            Invoke-ContextSetup $resolvedPath
        }
    } else {
        Write-Host '  Context     CLAUDE.md present' -ForegroundColor DarkGreen
    }

    Write-Host ''
    Write-Host '  Start a mission in this project now?' -ForegroundColor Cyan
    if (Test-PiDefaultEngine) {
        # Same layout as the project menu: single letters run pi, Claude moves to CL/CC.
        $hasPlan = Test-ProjectHasPlan $resolvedPath
        if ($hasPlan) {
            Write-Host "  [L]  Launch with pi ($(Get-PiModelLabel))" -ForegroundColor Green
        } else {
            Write-Host "  [L]  Kickoff: $(Get-KickoffPlannerLabel), then build in pi" -ForegroundColor Green
            Write-Host '  [P]  Start in pi now (no planning)'                           -ForegroundColor Green
        }
        Write-Host '  [C]  Continue latest (pi)'                  -ForegroundColor Green
        Write-Host "  [CL] Launch with Claude (profile $prof)"   -ForegroundColor Blue
        Write-Host '  [CC] Continue latest (Claude)'              -ForegroundColor Blue
        Write-Host '  [N]  Skip'                                  -ForegroundColor DarkGray
        $go = (Read-Host '  Choice').Trim().ToUpper()
        switch ($go) {
            'L'  { if ($hasPlan) { Start-PiNew $resolvedPath $prof $name } else { Start-KickoffThenPi $resolvedPath $name $prof 'forge' } }
            'P'  { Start-PiNew $resolvedPath $prof $name }
            'C'  { Start-PiContinue $resolvedPath $prof }
            'CL' { Start-WithProfile $resolvedPath $prof $name }
            'CC' { Start-ContinueMission $resolvedPath $prof }
        }
        return
    }
    Write-Host "  [L]  Launch with project profile ($prof)" -ForegroundColor Green
    Write-Host '  [C]  Continue latest mission'              -ForegroundColor Magenta
    if ($PiEnabled) {
        Write-Host "  [P]  Launch with pi ($(Get-PiModelLabel))" -ForegroundColor Blue
    }
    Write-Host '  [N]  Skip'                                 -ForegroundColor DarkGray
    $go = (Read-Host '  Choice').Trim().ToUpper()
    if ($go -eq 'L') {
        Start-WithProfile $resolvedPath $prof $name
    } elseif ($go -eq 'C') {
        Start-ContinueMission $resolvedPath $prof
    } elseif ($go -eq 'P' -and $PiEnabled) {
        Start-PiNew $resolvedPath $prof $name
    }
}

function Test-PiDefaultEngine {
    # pi is the default engine only when the pi lane is enabled (same rule as the project menu).
    return ($PiEnabled -and $DefaultEngine -eq 'pi')
}

function Get-KickoffPrompt {
    param([string]$Name)
    return "You are starting a brand-new project called '$Name'. Read CLAUDE.md if present, then help plan the project structure, goals, and first implementation steps."
}

function Start-ClaudeKickoff {
    # Kickoff mission on Claude Code via the meta (Forge) Jig profile.
    param([string]$Path, [string]$Name)
    $claudeArgs = @('--name', (New-MissionName $Name), (Get-KickoffPrompt $Name))
    if (Get-Command 'jig' -ErrorAction SilentlyContinue) {
        Start-TerminalCommand $Path (New-JigRunCommand $MetaProfile $claudeArgs)
    } elseif (Get-Command 'claude' -ErrorAction SilentlyContinue) {
        Start-TerminalCommand $Path (New-ClaudeCommand $claudeArgs)
    } else {
        Write-Host "  ERROR: Neither 'jig' nor 'claude' found in PATH." -ForegroundColor Red
    }
}

function Add-NewProject {
    param([ref]$ConfigRef)

    Write-Host ''
    Write-Host '  New Project' -ForegroundColor Cyan
    Write-Host "  Projects are created in: $ScanRoot" -ForegroundColor DarkGray
    Write-Host ''

    $project = New-ScaffoldedProject -ConfigRef $ConfigRef
    if ($null -eq $project) { return }

    $resolvedPath = $project.path
    $name = $project.name
    $prof = $project.profile

    Write-Host ''
    Write-Host '  Setup complete. Launch a kickoff mission now?' -ForegroundColor Cyan
    if (Test-PiDefaultEngine) {
        Write-Host "  [L]  Kickoff: $(Get-KickoffPlannerLabel), then build in pi"    -ForegroundColor Green
        Write-Host '  [V]  Plan with vibe-check in Claude Code, then build in pi'        -ForegroundColor Cyan
        Write-Host "  [P]  Start in pi now (no planning, $(Get-PiModelLabel))" -ForegroundColor Green
        Write-Host "  [CK] Claude only: Forge kickoff (jig run $MetaProfile)"            -ForegroundColor Blue
        Write-Host '  [N]  Skip'                                                         -ForegroundColor DarkGray
        $kick = (Read-Host '  Choice').Trim().ToUpper()
        switch ($kick) {
            'L'  { Start-KickoffThenPi $resolvedPath $name $prof 'forge' }
            'V'  { Start-VibeKickoff $resolvedPath $name }
            'P'  { Start-PiNew $resolvedPath $prof $name (Get-KickoffPrompt $name) }
            'CK' { Start-ClaudeKickoff $resolvedPath $name }
        }
        return
    }
    Write-Host "  [K]  Launch kickoff with jig run $MetaProfile" -ForegroundColor Magenta
    Write-Host "  [S]  Launch with project profile ($prof)" -ForegroundColor Green
    Write-Host '  [V]  Plan with vibe-check (jig run vibe)' -ForegroundColor Cyan
    if ($PiEnabled) {
        Write-Host "  [P]  Launch with pi ($(Get-PiModelLabel))" -ForegroundColor Blue
    }
    Write-Host '  [N]  Skip' -ForegroundColor DarkGray
    $kick = (Read-Host '  Choice').Trim().ToUpper()

    if ($kick -eq 'K') {
        Start-ClaudeKickoff $resolvedPath $name
    } elseif ($kick -eq 'S') {
        Start-WithProfile $resolvedPath $prof $name
    } elseif ($kick -eq 'V') {
        Start-VibeKickoff $resolvedPath $name
    } elseif ($kick -eq 'P' -and $PiEnabled) {
        Start-PiNew $resolvedPath $prof $name
    }
}

function Edit-Project {
    # Edit a registered project's display name, description, and profile in place.
    # Enter keeps the current value for each field. The path is immutable.
    param([ref]$ConfigRef, [int]$Index)

    $project = $ConfigRef.Value[$Index]
    $curName = Get-ProjectName $project
    $curDesc = Get-OptionalProperty $project 'description' ''
    $curProf = Get-OptionalProperty $project 'profile' $DefaultProfile
    Write-Host ''
    Write-Host "  Editing '$curName' (Enter keeps the current value)" -ForegroundColor Cyan
    Write-Host "  Path is unchanged: $($project.path)" -ForegroundColor DarkGray

    $newName = Read-Host "  Display name [$curName]"
    if ([string]::IsNullOrWhiteSpace($newName)) { $newName = $curName } else { $newName = $newName.Trim() }

    $newDesc = Read-Host "  Description  [$curDesc]"
    if ([string]::IsNullOrWhiteSpace($newDesc)) { $newDesc = $curDesc } else { $newDesc = $newDesc.Trim() }

    Show-ProfileMenu
    $newProf = Read-Host "  Profile      [$curProf]"
    if ([string]::IsNullOrWhiteSpace($newProf)) { $newProf = $curProf } else { $newProf = $newProf.Trim() }

    if ($newName -eq $curName -and $newDesc -eq $curDesc -and $newProf -eq $curProf) {
        Write-Host '  No changes.' -ForegroundColor DarkGray
        return
    }

    $ConfigRef.Value[$Index].name = $newName
    # Older registry entries may predate optional fields; add them when first set.
    foreach ($pair in @(@('description', $newDesc), @('profile', $newProf))) {
        if ($ConfigRef.Value[$Index].PSObject.Properties[$pair[0]]) {
            $ConfigRef.Value[$Index].($pair[0]) = $pair[1]
        } else {
            $ConfigRef.Value[$Index] | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1]
        }
    }
    Save-Config $ConfigRef.Value
    Write-Host "  Saved '$newName' [$newProf]." -ForegroundColor Green
}

function Remove-ProjectEntry {
    # Remove a project from the registry (projects.json only - never touches disk).
    # Returns $true if the entry was removed.
    param([ref]$ConfigRef, [int]$Index)

    $project = $ConfigRef.Value[$Index]
    $name = Get-ProjectName $project
    Write-Host ''
    Write-Host "  Remove '$name' from the project list?" -ForegroundColor Yellow
    Write-Host "  The folder on disk is NOT touched: $($project.path)" -ForegroundColor DarkGray
    if (-not (Read-YesNo '  Remove from list?' 'N')) {
        Write-Host '  Cancelled.' -ForegroundColor DarkGray
        return $false
    }

    $updated = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $ConfigRef.Value.Count; $i++) {
        if ($i -ne $Index) { $updated.Add($ConfigRef.Value[$i]) }
    }
    $ConfigRef.Value = $updated.ToArray()
    Save-Config $ConfigRef.Value
    Write-Host "  Removed '$name' from the list." -ForegroundColor Green
    return $true
}

function Open-ProjectFolder {
    param([string]$ProjectPath)
    if (-not (Assert-DirExists $ProjectPath)) { return }
    try {
        if ($MissionIsWindows) {
            # Not Start-Process explorer.exe $Path: PS 5.1 passes ArgumentList unquoted, so a
            # path with spaces splits into multiple args and Explorer opens the wrong window.
            Invoke-Item -LiteralPath $ProjectPath
        } elseif ($MissionIsMacOS) {
            & open $ProjectPath
        } else {
            & xdg-open $ProjectPath
        }
    } catch {
        Write-Host "  ERROR: Could not open folder: $_" -ForegroundColor Red
        Write-MissionLog 'ERROR' "Open-ProjectFolder failed for ${ProjectPath}: $_"
    }
}
