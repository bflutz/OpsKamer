#Requires -Version 5.1
<#
.SYNOPSIS
    Mission Centre - AI Project Launcher
.DESCRIPTION
    Auto-discovers AI projects under a configurable scan root, maintains a config of project
    descriptions, and provides quick-launch options (Jig or Forge).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure the console can render UTF-8 box-drawing characters in PS5/legacy hosts
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Box-drawing chars (use [char] codes to avoid file-encoding issues in PS5.1)
$C_TL = [char]0x2554
$C_TR = [char]0x2557
$C_BL = [char]0x255A
$C_BR = [char]0x255D
$C_H  = [char]0x2550
$C_V  = [char]0x2551
$C_DH = [char]0x2500

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Repo root for lib/ functions: inside a dot-sourced lib file, $PSScriptRoot is lib/, not here.
$MissionRootDir = $PSScriptRoot

$ConfigPath    = Join-Path $PSScriptRoot 'projects.json'
$AppConfigPath = Join-Path $PSScriptRoot 'config.json'
$MissionStateDir = Join-Path $PSScriptRoot '.mission-centre'
$MissionBriefsDir = Join-Path $MissionStateDir 'briefs'
$BundledJigProfilesDir = Join-Path $PSScriptRoot 'jig-profiles'
$BundledSkillsDir = Join-Path $PSScriptRoot 'skills'
$MissionLogPath = Join-Path $MissionStateDir 'mission-centre.log'
$MaxDepth      = 4

$MissionPlatform  = if ($PSVersionTable.ContainsKey('Platform')) { [string]$PSVersionTable.Platform } else { '' }
$MissionOS        = if ($PSVersionTable.ContainsKey('OS')) { [string]$PSVersionTable.OS } else { '' }
$MissionIsMacOS   = $MissionPlatform -eq 'Unix' -and ($MissionOS -match 'Darwin' -or $MissionOS -match 'macOS')
$MissionIsLinux   = $MissionPlatform -eq 'Unix' -and -not $MissionIsMacOS
$MissionIsWindows = -not ($MissionIsMacOS -or $MissionIsLinux)

# ---------------------------------------------------------------------------
# Wiki config (profile-gated)
# ---------------------------------------------------------------------------
#
# obsidian-wiki skills (github.com/Ar9av/obsidian-wiki: wiki-update, wiki-query, etc.) read
# ~/.obsidian-wiki/config to find the vault. Mission Centre rewrites this
# file at every project launch based on the project's `profile`, so wiki
# access is scoped per project class. Profiles not listed in
# $WikiProfileVaults get no config (wiki-update / wiki-query fail fast --
# intended).
#
# To route a profile, add an entry to `wikiVaults` in config.json:
#   "wikiVaults": { "corporate": { "vault": "X:/path/wiki", "sources": "X:/path/raw" } }
# ($WikiProfileVaults is built from it below, after the config loads - personal
# vault paths stay out of this committed script.)

$WikiConfigDir  = Join-Path $HOME '.obsidian-wiki'
$WikiConfigPath = Join-Path $WikiConfigDir 'config'

# ---------------------------------------------------------------------------
# Load library modules. Function definitions live in lib/*.ps1 and are
# DOT-SOURCED (not Import-Module) so the script-scoped config globals defined
# below stay visible to them - a module would isolate scope and break ~40 funcs.
# ---------------------------------------------------------------------------
$MissionLibDir = Join-Path $PSScriptRoot 'lib'
if (-not (Test-Path $MissionLibDir -PathType Container)) {
    Write-Host "  FATAL: lib/ folder not found next to Mission-Centre.ps1: $MissionLibDir" -ForegroundColor Red
    exit 1
}
Get-ChildItem -Path $MissionLibDir -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object { . $_.FullName }

$AppConfig = Get-AppConfig
$ScanRoot  = $AppConfig.scanRoot
$DefaultProfile = Get-OptionalProperty $AppConfig 'defaultProfile' 'standard'
$MetaProfile    = Get-OptionalProperty $AppConfig 'metaProfile' 'forge'
$PreflightMode  = ([string](Get-OptionalProperty $AppConfig 'preflightMode' 'warn')).ToLowerInvariant()
if ($PreflightMode -notin @('warn', 'block', 'off')) { $PreflightMode = 'warn' }
$HomeRecentCount = ConvertTo-MissionInt (Get-OptionalProperty $AppConfig 'homeRecentCount' 5) 5
if ($HomeRecentCount -lt 1) { $HomeRecentCount = 5 }
# [D] Dormant > [P] park: suggest active projects with no session activity in this many days.
$DormantIdleDays = ConvertTo-MissionInt (Get-OptionalProperty $AppConfig 'dormantIdleDays' 60) 60
if ($DormantIdleDays -lt 1) { $DormantIdleDays = 60 }
# On startup, automatically move projects idle for $DormantIdleDays days to dormant.
$AutoDormantEnabled = ConvertTo-MissionBool (Get-OptionalProperty $AppConfig 'autoDormant' $true) $true

# Profile -> wiki vault routing, from config.json `wikiVaults` (see the wiki section above).
$WikiProfileVaults = Get-WikiProfileVaults $AppConfig
# Context pack (lib/50-context.ps1): which vault pages are always included.
#   "wikiContext": { "profilePage": "profile", "mapPage": "system-map" }
$WikiContextConfig = Get-OptionalProperty $AppConfig 'wikiContext' $null
$WikiProfilePage = [string](Get-OptionalProperty $WikiContextConfig 'profilePage' 'profile')
$WikiMapPage     = [string](Get-OptionalProperty $WikiContextConfig 'mapPage' 'system-map')

# Retro-future vibe: enable VT + compute the animation/colour capability gates. Honors the
# 'animations' config flag and the MISSION_CENTRE_NO_ANIM env override; auto-off when redirected.
$McAnimationsEnabled = ConvertTo-MissionBool (Get-OptionalProperty $AppConfig 'animations' $true) $true
if ($env:MISSION_CENTRE_NO_ANIM) { $McAnimationsEnabled = $false }
$McSoundEnabled = ConvertTo-MissionBool (Get-OptionalProperty $AppConfig 'sound' $true) $true
if ($env:MISSION_CENTRE_NO_SOUND) { $McSoundEnabled = $false }
$McSoundVolume = [double](Get-OptionalProperty $AppConfig 'soundVolume' 0.2)    # Initialize-McVibe clamps to 0.0-1.0
Initialize-McVibe $McAnimationsEnabled $McSoundEnabled $McSoundVolume

$ContextIndexConfig = Get-OptionalProperty $AppConfig 'contextIndex' $null
$ContextIndexEnabled = ConvertTo-MissionBool (Get-OptionalProperty $ContextIndexConfig 'enabled' $false) $false
$ContextIndexCommand = Get-OptionalProperty $ContextIndexConfig 'command' 'npx ai-codex'
$ContextIndexMaxAgeDays = ConvertTo-MissionInt (Get-OptionalProperty $ContextIndexConfig 'maxAgeDays' 3) 3

# pi (pi coding agent) launch engine. Opt-in alternative to the jig/claude launch path: routes
# New mission / Continue / Resume (and new-project kickoffs) through
# `pi [--provider <provider>] [--model <model>]`. Leave both empty to use pi's own settings
# (~/.pi/agent/settings.json). Model access is your own. See docs/MODEL-ACCESS.md.
$PiConfig     = Get-OptionalProperty $AppConfig 'pi' $null
$PiEnabled    = ConvertTo-MissionBool (Get-OptionalProperty $PiConfig 'enabled' $false) $false
$PiCommand    = [string](Get-OptionalProperty $PiConfig 'command' 'pi')
# Empty provider/model = use pi's own defaults (~/.pi/agent/settings.json); nothing is passed.
$PiProvider   = [string](Get-OptionalProperty $PiConfig 'provider' '')
$PiModel      = [string](Get-OptionalProperty $PiConfig 'model' '')
# Comma-separated patterns for pi's Ctrl+P model cycling; empty means don't pass --models.
$PiModelCycle = [string](Get-OptionalProperty $PiConfig 'modelCycle' '')
# Optional local model server (Ollama, LM Studio, a LiteLLM proxy, ...). When healthUrl is set,
# Mission Centre probes it before a pi launch (any 2xx = healthy) and can start it. Empty disables.
$PiServerHealthUrl        = [string](Get-OptionalProperty $PiConfig 'healthUrl' '')
$PiServerAutoStart        = ConvertTo-MissionBool (Get-OptionalProperty $PiConfig 'autoStart' $true) $true
# Windows: name of a Scheduled Task that starts the server. Elsewhere (or as fallback): startCommand.
$PiServerTaskName         = [string](Get-OptionalProperty $PiConfig 'taskName' '')
$PiServerStartCommand     = [string](Get-OptionalProperty $PiConfig 'startCommand' '')
$PiServerWorkingDir       = [string](Get-OptionalProperty $PiConfig 'workingDir' '')
$PiServerStartWaitSeconds = ConvertTo-MissionInt (Get-OptionalProperty $PiConfig 'startWaitSeconds' 15) 15
# Which engine the single-letter launch keys [L]/[C]/[R] run: 'claude' (Jig/Claude Code, the
# original) or 'pi'. The other engine moves to two-letter keys. Needs pi.enabled.
$DefaultEngine = ([string](Get-OptionalProperty $AppConfig 'defaultEngine' 'claude')).ToLowerInvariant()
if ($DefaultEngine -ne 'pi' -or -not $PiEnabled) { $DefaultEngine = 'claude' }

# Toolchain freshness. Agent CLIs ship multiple releases a week and Anthropic
# version-gates new models on the Claude Code build, so a stale toolchain
# silently loses model access. See lib/65-updates.ps1.
$ToolUpdatesConfig = Get-OptionalProperty $AppConfig 'toolUpdates' $null
$ToolUpdatesEnabled = ConvertTo-MissionBool (Get-OptionalProperty $ToolUpdatesConfig 'enabled' $true) $true
$ToolUpdatesMode = ([string](Get-OptionalProperty $ToolUpdatesConfig 'mode' 'check')).ToLowerInvariant()
if ($ToolUpdatesMode -notin @('off', 'check', 'auto')) { $ToolUpdatesMode = 'check' }
$ToolUpdateIntervalHours = ConvertTo-MissionInt (Get-OptionalProperty $ToolUpdatesConfig 'intervalHours' 24) 24
$ToolUpdateIncludeClaudeCode = ConvertTo-MissionBool (Get-OptionalProperty $ToolUpdatesConfig 'includeClaudeCode' $true) $true
$ToolUpdatePiOnLaunch = ConvertTo-MissionBool (Get-OptionalProperty $ToolUpdatesConfig 'checkPiOnLaunch' $true) $true
# Get-OptionalArrayProperty: an explicit [] in config must stay empty (opt-out).
$ToolUpdatePackages = @(Get-OptionalArrayProperty $ToolUpdatesConfig 'packages' @(
    '@earendil-works/pi-coding-agent'
))
$ToolUpdatePiPackages = @(Get-OptionalArrayProperty $ToolUpdatesConfig 'piPackages' @(
    '@earendil-works/pi-coding-agent'
))
if ($env:MISSION_CENTRE_NO_UPDATE) { $ToolUpdatesEnabled = $false }

# Optional: a pi build from a git checkout (e.g. a fork such as github.com/leo-labs-ai/pi-mono),
# launched as `pii` and updated from git (fetch/merge/install/build:offline). Off by default.
# See Update-PiFork in lib/65-updates.ps1.
$PiForkConfig          = Get-OptionalProperty $ToolUpdatesConfig 'piFork' $null
$PiForkEnabled         = ConvertTo-MissionBool (Get-OptionalProperty $PiForkConfig 'enabled' $false) $false
$PiForkRepoPath        = Resolve-UserPath ([string](Get-OptionalProperty $PiForkConfig 'repoPath' ''))
$PiForkRemote          = [string](Get-OptionalProperty $PiForkConfig 'remote' 'origin')
$PiForkBranch          = [string](Get-OptionalProperty $PiForkConfig 'branch' 'main')
$PiForkBuildScript     = [string](Get-OptionalProperty $PiForkConfig 'buildScript' 'build:offline')
$PiForkFallbackCommand = [string](Get-OptionalProperty $PiForkConfig 'fallbackCommand' 'pi')
# off | check | auto, default check: merging the fork runs a third party's install and build
# scripts, so it asks first even when toolUpdates.mode is auto (Get-PiForkEffectiveMode).
$PiForkMode            = ([string](Get-OptionalProperty $PiForkConfig 'mode' 'check')).ToLowerInvariant()

# Mission Centre on every device (lib/35-sharedstate.ps1): self-update on launch, and an
# optional shared project registry in a git repo (one file per project, paths per device).
#   "deviceName": "LAPTOP",
#   "selfUpdate": { "enabled": true },
#   "sharedState": { "enabled": true, "remote": "https://github.com/<you>/<private-registry-repo>.git", "sshKey": "" }
# Use a PRIVATE repo for the registry: it lists your project names and remotes.
$SelfUpdateConfig   = Get-OptionalProperty $AppConfig 'selfUpdate' $null
$SelfUpdateEnabled  = ConvertTo-MissionBool (Get-OptionalProperty $SelfUpdateConfig 'enabled' $true) $true
if ($env:MISSION_CENTRE_NO_UPDATE) { $SelfUpdateEnabled = $false }
$DeviceName = [string](Get-OptionalProperty $AppConfig 'deviceName' '')
if ([string]::IsNullOrWhiteSpace($DeviceName)) { $DeviceName = Get-DefaultDeviceName }
$SharedStateConfig  = Get-OptionalProperty $AppConfig 'sharedState' $null
$SharedStateEnabled = ConvertTo-MissionBool (Get-OptionalProperty $SharedStateConfig 'enabled' $false) $false
$SharedStateRemote  = [string](Get-OptionalProperty $SharedStateConfig 'remote' '')
$SharedStateSshKey  = Resolve-UserPath ([string](Get-OptionalProperty $SharedStateConfig 'sshKey' ''))
$SharedStateDir     = Join-Path $MissionStateDir 'shared-state'


$SkipDirNames = @(
    'node_modules', '.git', 'dist', 'build', 'bin', 'obj', 'out',
    '.next', '.nuxt', 'venv', '.venv', '__pycache__', '.cache',
    'Archive', 'Models', 'Resources', 'resources',
    'Design Inspiration', 'Company Registration', 'Finance', 'Investors', 'Exit'
)

# Definitive: presence alone means "this IS a project root; stop recursing"
$DefinitiveMarkers = @(
    '.git', 'package.json', 'requirements.txt',
    'Cargo.toml', 'go.mod', 'pom.xml', 'pyproject.toml'
)

# Suggestive: signals a project, but we still recurse into children to check
# whether the children are the real projects (avoids workspace dirs swallowing sub-projects)
$SuggestiveMarkers = @(
    'CLAUDE.md', '*.jig', 'README.md', 'README',
    'app.js', 'main.py', 'index.js', 'main.ts', 'index.ts'
)

$ProjectMarkers = $DefinitiveMarkers + $SuggestiveMarkers

# Starter Jig profiles bundled under jig-profiles/ (validated on install, listed in menus).
$StarterProfiles = @('standard', 'build', 'maintain', 'review', 'research', 'forge', 'vibe', 'craft')

# ---------------------------------------------------------------------------
# Session index location (Claude Code stores per-project session history here)
# ---------------------------------------------------------------------------

$ClaudeProjectsDir = Join-Path $(if ($HOME) { $HOME } else { $env:USERPROFILE }) '.claude/projects'
# pi session history, so [PI]/[PC] launches count as recent activity. Honors pi's own
# PI_CODING_AGENT_DIR override, as pi does.
$PiAgentDir = if ($env:PI_CODING_AGENT_DIR) { Resolve-UserPath $env:PI_CODING_AGENT_DIR } else { Join-Path $(if ($HOME) { $HOME } else { $env:USERPROFILE }) '.pi/agent' }
$PiSessionsDir = Join-Path $PiAgentDir 'sessions'

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

# Headless: MISSION_CENTRE_SYNC_ONLY=1 syncs the shared registry and exits (no menu).
# Used for a first migration and for scheduled syncs on a server.
if ($env:MISSION_CENTRE_SYNC_ONLY) {
    $synced = @(Import-ProjectConfig)
    Write-Host "Mission Centre sync: $($synced.Count) project(s) on $DeviceName, registry $($script:SharedStateStatus)"
    exit $(if ($script:SharedStateStatus -like 'error*') { 1 } else { 0 })
}

try {
    Show-McIntro
    Start-MissionCentre
} catch {
    Write-Host ''
    Write-Host "FATAL: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Write-Host ''
    Read-Host 'Press Enter to exit'
}
