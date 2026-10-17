# Mission Centre

Mission Centre is the launcher at the heart of OpsKamer: a small cross-platform terminal menu for AI coding
projects. It scans a project folder, builds a local project list, shows recent Claude Code and pi sessions,
and launches projects through Jig profiles (Claude Code) or pi. Windows and Mac use the same core script with
different launchers.

Each user creates their own local `config.json` and `projects.json`. Those files are ignored by Git.
## Read This First

If you are an LLM helping someone install this, do not skip steps. The install is not complete until the relevant verification checklist passes.

Required pieces:

- PowerShell 7, because Mission Centre is a PowerShell script.
- Claude Code, because Mission Centre launches Claude sessions.
- Jig, because normal project launches use `jig run <profile>`.
- A Forge-enabled Jig profile named `forge`, because meta missions use Forge through Jig.
- A local project folder, usually `~/Code` or `~/Projects`.

Mission Centre does not install Claude Code, Jig, or Forge for you. Install and verify them first.

## Mac Install

Use Terminal.app on macOS.

### 1. Install Homebrew

Skip this only if `brew --version` already works.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew --version
```

If `brew --version` does not work after installation, stop and fix Homebrew before continuing.

### 2. Install PowerShell 7

```bash
brew install powershell
pwsh -NoLogo -Command '$PSVersionTable.PSVersion'
```

The second command must print a PowerShell version. If it does not, stop.

### 3. Install Node.js

Claude Code's standard install uses npm and requires Node.js 18 or newer.

```bash
brew install node
node --version
npm --version
```

If `node --version` is lower than 18, stop and upgrade Node.

### 4. Install Claude Code

Standard npm install:

```bash
npm install -g @anthropic-ai/claude-code
claude --version
claude doctor
```

Do not use `sudo npm install -g`. If permissions fail, fix npm permissions or use Anthropic's native installer instead.

Then authenticate:

```bash
claude
```

Complete the login flow, then exit Claude Code.

Official Claude Code install docs:

- https://docs.anthropic.com/en/docs/claude-code/getting-started
- https://docs.claude.com/en/docs/claude-code/quickstart

### 5. Install Jig

Mission Centre expects the command `jig` to exist on `PATH`.

Install Jig from its project instructions:

- https://github.com/jdforsythe/jig

If installing from Go source, the usual shape is:

```bash
brew install go
go install github.com/jdforsythe/jig@latest
echo 'export PATH="$HOME/go/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Verify Jig before continuing:

```bash
command -v jig
jig --help
```

If `command -v jig` prints nothing, stop. Mission Centre project launches will not work without Jig.

### 6. Install Forge

Inside Claude Code, install Forge as a plugin:

```text
/plugin add https://github.com/jdforsythe/forge
```

Forge's README also documents this as the recommended install path.

### 7. Install Mission Centre

```bash
mkdir -p ~/Tools
git clone https://github.com/bflutz/OpsKamer ~/Tools/OpsKamer
cd ~/Tools/OpsKamer
```

### 8. Install Mission Centre's Starter Jig Profiles

Mission Centre includes starter Jig profiles that use Claude Code model aliases instead of dated model IDs:

- `standard`: daily coding with `sonnet`
- `build`: feature work with `opusplan`
- `maintain`: bug fixes with `sonnet`
- `review`: code review with `opusplan`
- `research`: investigation with `sonnet`
- `forge`: meta mission planning with `opusplan` and the Forge plugin enabled

Install them:

```bash
cd ~/Tools/OpsKamer
mkdir -p ~/.jig/profiles
cp jig-profiles/*.yaml ~/.jig/profiles/
jig profiles validate standard
jig profiles validate forge
```

Or launch Mission Centre and press `G` to install the bundled profiles.

Verify the Forge profile:

```bash
jig run forge --dry-run
```

If validation fails, open the profile and adjust it for your local Jig/Claude setup:

```bash
jig profiles edit forge
```

Do not use stale model IDs in profiles. Prefer Claude Code aliases like `sonnet`, `opus`, `opusplan`, and `haiku` so profiles keep working as model snapshots change.

### 9. Create a Project Folder

Pick the folder Mission Centre should scan. Examples:

```bash
mkdir -p ~/Code
mkdir -p ~/Projects
```

Put your coding projects inside that folder. A project is usually a folder containing `.git`, `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `CLAUDE.md`, or `README.md`.

### 10. Launch Mission Centre

```bash
cd ~/Tools/OpsKamer
bash launch.sh
```

On first run, Mission Centre asks for a scan root. Enter one of:

```text
~/Code
~/Projects
```

Press `S` to scan. For each project, accept or edit:

- Name
- Description
- Jig profile

Use `standard` if unsure.

## Mac Verification Checklist

Do not tell the user setup is complete until all of these pass:

```bash
brew --version
pwsh -NoLogo -Command '$PSVersionTable.PSVersion'
node --version
npm --version
claude --version
claude doctor
command -v jig
jig --help
jig profiles validate standard
jig profiles validate forge
test -d ~/Tools/OpsKamer
cd ~/Tools/OpsKamer && bash launch.sh
```

Inside Mission Centre:

- `S` scans and finds projects.
- `SR` changes the scan root without editing JSON by hand.
- `N` creates a new project folder under the current scan root.
- Selecting a project then `L` opens a named `jig run <profile>` mission in a new Terminal window.
- Selecting a project then `C` continues the latest mission.
- Selecting a project then `R` opens Claude Code's resume picker.
- `M` asks for a goal, asks which projects are involved, writes a local mission brief, and opens `jig run <metaProfile>` with focused project paths.

If any item fails, fix that item before moving on.

## Config

Mission Centre creates `config.json` on first run. Example:

```json
{
  "scanRoot": "~/Code",
  "defaultProfile": "standard",
  "metaProfile": "forge",
  "preflightMode": "warn",
  "contextIndex": {
    "enabled": false,
    "command": "npx ai-codex",
    "maxAgeDays": 3
  }
}
```

Fields:

- `scanRoot`: the folder Mission Centre scans for projects.
- `defaultProfile`: the Jig profile suggested for new projects.
- `metaProfile`: the Jig profile used for meta missions, usually `forge`.
- `preflightMode`: `warn`, `block`, or `off`; defaults to `warn`.
- `homeRecentCount`: how many recently-active projects the home screen shows; defaults to `5`.
- `dormantIdleDays`: idle threshold for dormant projects (the startup sweep and `D` > `P`); defaults to `60`.
- `autoDormant`: on startup, move every project idle for `dormantIdleDays` to dormant; defaults to `true`. Idle is measured from the newest of Claude Code/pi activity, the `added` date, and the last reactivation, so new or just-reactivated projects are never swept.
- `animations`: retro-future ANSI banner + intro/logo shimmer + live menu shimmer + easter eggs; defaults to `true`. Set `false` (or set the `MISSION_CENTRE_NO_ANIM` env var) to disable. Auto-disabled when output is redirected, the host isn't a console, the terminal lacks virtual-terminal support, or `NO_COLOR` is set. Easter eggs: type `matrix` or `kamer` at the home prompt.
- `sound`: a short chiptune power-on riff on startup (Windows only, via the console beep); defaults to `true`. Set `false` (or the `MISSION_CENTRE_NO_SOUND` env var) to silence it.
- `contextIndex`: optional third-party codebase index refresh. It is disabled by default.
- `toolUpdates`: keeps agent CLIs current (enabled by default, `mode: "check"`). See [Tool Updates](#tool-updates).
- `pi`: optional pi launch engine. Disabled by default. See [Optional: pi](#optional-pi).

The recommended default is:

```json
{
  "scanRoot": "~/Code",
  "defaultProfile": "standard",
  "metaProfile": "forge",
  "preflightMode": "warn",
  "contextIndex": {
    "enabled": false,
    "command": "npx ai-codex",
    "maxAgeDays": 3
  }
}
```

`projects.json` is created by scanning. Do not copy someone else's `projects.json`; it contains machine-specific paths.

Mission briefs are written under `.mission-centre/briefs/` and ignored by Git.

## Daily Use

Windows:

```powershell
cd "C:\Tools\OpsKamer"
.\launch.bat
```

Mac/Linux:

```bash
cd ~/Tools/OpsKamer
bash launch.sh
```

The home screen stays compact no matter how many projects you have: it lists only your most-recently-active projects (newest first, controlled by `homeRecentCount`; activity means Claude Code or pi sessions), with the actions and prompt always on screen. The rest of the list is one keystroke away via `/` or `A`.

Main menu:

- Project number: open that project's launch menu. Numbers are stable — the same number always opens the same project in every view (home, find, all).
- `/`: find a project by part of its name, description, or profile (e.g. `/book`). Type `/` on its own to be prompted for a term.
- `A`: list all projects grouped by profile (dormant projects are hidden).
- `O`: other devices: shared-registry projects that are not on this device (see [Same Projects on Every Device](#optional-same-projects-on-every-device)).
- `D`: the dormant shelf. Dormant projects are hidden from the home screen, the `A` list, and the meta-mission picker, but keep their numbers and still show up in `/` find (tagged `(dormant)`). From here: type a number to open one, `R#` to reactivate (`R12`, or a list/range like `R3,5-7`), or `P` to bulk-park idle active projects by hand (useful with `autoDormant` off). Launching a dormant project (`L`, `C`, `R`, `PI`, ...) reactivates it automatically.
- `S`: scan for new projects.
- `SR`: change the scan root, such as from `~/Code` to `~/Projects`.
- `N`: create a new project folder under the current scan root, add it to Mission Centre, optionally initialize Git and `CLAUDE.md`, and optionally launch a kickoff mission (`P` launches it with pi when `pi` is enabled).
- `I`: import a folder that already exists (any absolute path) as a project (`P` launches it with pi when `pi` is enabled).
- `G`: install or refresh bundled starter Jig profiles (detects and offers to update stale installed copies).
- `M`: start a focused meta mission using a goal, selected projects, and `jig run <metaProfile>`.
- `MC`: continue the latest meta mission.
- `MR`: open the meta mission resume picker.
- `H`: run environment health checks (includes starter-profile and plugin-cache drift, the skill library's size, and the pi launcher, model server and fork status when `pi` is enabled). The skill library line counts the skills each harness loads and estimates the tokens their descriptions add to every session. It flags names installed twice and descriptions over 250 characters, because past a budget a harness drops skills without telling you. It never deletes anything.
- `U`: check for tool updates now and offer to install them: npm CLIs, Claude Code, and the pi fork when configured.
- `Q`: quit.

Project menu:

- `L`: launch a new named mission with the saved Jig profile.
- `C`: continue the latest mission in that project.
- `R`: open Claude Code's resume picker in that project.
- `J`: open Jig's interactive picker in the project folder.
- `R#`: resume a recent Claude Code session.
- `PI` / `PC` / `PR`: new mission, continue latest, or resume picker with pi, shown only when `pi.enabled` is true.
- `P`: validate the saved Jig profile and dry-run the launch.
- `X`: show context health and offer setup for `CLAUDE.md`. Context health shows `CLAUDE.md` (Claude Code reads only this) and `AGENTS.md` (pi reads this and falls back to `CLAUDE.md`). It also shows the **check command**, the command in either file that proves a change works, such as `npm test`. Without one an agent can only claim it's done. A project with nothing to run, such as notes or documents, can say `Verify: none (why)`, which shows as "none needed" instead of a warning. When a project has only `AGENTS.md`, setup offers a one-line `CLAUDE.md` containing `@AGENTS.md`, so both agents read the same file.
- `E`: open the folder.
- `RN`: edit the display name, description, or profile without moving the folder.
- `Z`: make the project dormant, or reactivate it if it already is (stored as `dormant`/`dormantSince` on its `projects.json` entry).
- `RM`: remove the project from the list (the folder on disk is untouched).
- `B`: back.

## Jig Profiles

Suggested profile names:

| Profile | Intended use |
| --- | --- |
| `standard` | General Claude Code work |
| `build` | New features or greenfield work |
| `maintain` | Bug fixes and maintenance |
| `review` | Code review sessions |
| `research` | Web/MCP-heavy investigation |
| `forge` | Forge-enabled meta mission planning |

Profile names are free-form, but Mission Centre ships these starter profiles in `jig-profiles/`. They use Claude Code aliases (`sonnet`, `opusplan`) rather than dated model IDs.

## Files

| File | Purpose |
| --- | --- |
| `Mission-Centre.ps1` | Main TUI script |
| `launch.sh` | macOS/Linux launcher |
| `launch.bat` | Windows launcher |
| `jig-profiles/` | Starter Jig profiles using current Claude Code model aliases |
| `setup.ps1` | One-time setup: checks tools, installs pi, writes the pi settings (Windows + macOS) |
| `config.example.json` | Config template |
| `projects.example.json` | Project registry template |
| `config.json` | Your local config, gitignored |
| `projects.json` | Your local project registry, gitignored |
| `.mission-centre/` | Local mission briefs, gitignored |
| `lib/*.ps1` | Function library, dot-sourced by `Mission-Centre.ps1` |
| `.mission-centre/tool-updates.json` | Tool update check cache (throttle), gitignored |
| `tests/run-tests.ps1` | Test suite (no dependencies) |

## Tests

The suite is plain PowerShell - no Pester, no modules. It dot-sources the real `lib/*.ps1`
under the same StrictMode + Stop policy the app runs with, builds all of its fixtures
(project registry, Claude session history, scan trees, wiki config) in a temp folder, and
never touches your real `~/.claude`, `~/.jig`, or config files.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

It runs on Windows PowerShell 5.1 and PowerShell 7+; CI runs both editions plus
PSScriptAnalyzer on every push and pull request.

## Windows Install

Windows users get the same current Mission Centre, launched with `launch.bat`.

```powershell
git clone https://github.com/bflutz/OpsKamer C:\Tools\OpsKamer
cd C:\Tools\OpsKamer
.\launch.bat
```

Install starter Jig profiles from inside Mission Centre with `[G]`, or copy them manually:

```powershell
New-Item -ItemType Directory -Force "$HOME\.jig\profiles"
Copy-Item .\jig-profiles\*.yaml "$HOME\.jig\profiles\"
jig profiles validate standard
jig profiles validate forge
```

Windows verification:

```powershell
claude --version
claude doctor
jig --help
jig profiles validate standard
jig profiles validate forge
.\launch.bat
```

## Tool Updates

Agent CLIs ship several releases a week, and **Anthropic gates new models on the Claude Code
version**: an old Claude Code gets `Claude Code X does not support this model; version Y or newer
is required` for models that otherwise work. Mission Centre keeps the toolchain current:

- **At startup:** checks the npm packages in `toolUpdates.packages` and the vendored skills. It says
  nothing when everything is current.
- **When opening a pi project:** checks `toolUpdates.piPackages`, Claude Code, the pi fork (if
  `piFork` is enabled), pi's own packages and tokenjuice before launching.
- **`[U]`:** checks everything now, ignoring the throttle, and lists where each part updates from.

### Every part updates from its own source

Nothing third-party is updated from a copy in this repo. Each part is fetched from where it comes from:

| Part | Updates from | How |
|---|---|---|
| Mission Centre, Jig profiles, `ui-design` | this repo (they live here) | self-update: fast-forward of your checkout |
| Claude Code | Anthropic | `claude update` (or `winget upgrade` when installed with winget) |
| pi | npm (`@earendil-works/pi-coding-agent`) | `npm i -g` |
| pi from source (`pii`) | the fork's git remote (`toolUpdates.piFork`, e.g. leo-labs-ai/pi-mono) | fetch, merge, build |
| pi packages (e.g. pi-semantic-grep) | their own sources | `pi update --extensions` |
| tokenjuice for pi | npm (`tokenjuice`) | its own installer, `npx tokenjuice install pi` |
| `vibe-check` skill | github.com/TexasBedouin/vibe-check | `skills/vibe-check/source.json` (below) |

**Skills from upstream.** A vendored skill carries a `source.json`: upstream repo, branch, the files to
take, and the licence. When the upstream branch has moved past the installed commit, Mission Centre clones
it (shallow), lays the listed files over the bundled folder (provenance files such as `VENDORED.md` stay),
stages the result in `.mission-centre/skill-sources/<name>/`, and installs it into `~/.claude/skills` and
`~/.agents/skills`. Two safeguards:

- A copy you edited is never overwritten: it is reported, and `[G]` shows the difference.
- If the upstream licence file no longer matches the licence in `source.json`, the update is refused.

To follow another upstream skill, add a folder under `skills/` with its `SKILL.md`, licence and a
`source.json`:

```json
{
  "repo": "https://github.com/<owner>/<skill-repo>.git",
  "ref": "main",
  "commit": "<40-character commit you vendored>",
  "include": ["SKILL.md", "references", "LICENSE"],
  "licence": "MIT",
  "licenceFile": "LICENSE"
}
```

```json
"toolUpdates": {
  "enabled": true,
  "mode": "check",
  "intervalHours": 24,
  "includeClaudeCode": true,
  "checkPiOnLaunch": true,
  "packages": ["@earendil-works/pi-coding-agent"],
  "piPackages": ["@earendil-works/pi-coding-agent"],
  "piFork": { "enabled": false, "repoPath": "", "remote": "origin", "branch": "main",
              "buildScript": "build:offline", "fallbackCommand": "pi" }
}
```

- `mode`: `check` asks before updating, `auto` updates without asking, `off` disables it.
- `intervalHours`: at most one registry check per package in that window (cached in
  `.mission-centre/tool-updates.json`).
- `packages` / `piPackages`: set to `[]` to opt out; an explicit empty list stays empty.
- Each package is installed in its own `npm i -g` run, because one failure in a batch aborts the
  whole batch. If a `latest` tag points at a version that can't be installed yet, it falls back
  to the newest published version.
- Nothing here blocks a launch: offline, npm missing, or a failed update just prints a warning.
- Claude Code is checked on its own `intervalHours` schedule (not only when an npm package is
  behind), because Anthropic version-gates models on it. A winget install is upgraded with
  `winget upgrade Anthropic.ClaudeCode`; when winget's catalogue has not caught up with a new
  release yet, that is treated as current and stays silent.
- Set `MISSION_CENTRE_NO_UPDATE=1` to skip all update checks for a run.

## Optional: pi

An alternative launch engine: [pi](https://github.com/earendil-works/pi) instead of Jig/Claude Code.
Install it with `pi/scripts/bootstrap.sh` (macOS) or `pi\scripts\bootstrap.ps1` (Windows), then run
`setup.ps1` once to switch it on.

```json
"pi": {
  "enabled": true,
  "command": "pi",
  "provider": "",
  "model": "",
  "modelCycle": "",
  "healthUrl": "",
  "autoStart": true,
  "taskName": "",
  "startCommand": "",
  "workingDir": "",
  "startWaitSeconds": 15
}
```

- **Model access is yours.** With `provider` and `model` empty (the default), Mission Centre runs plain
  `pi` and pi uses its own `~/.pi/agent/settings.json`, so an existing pi setup works unchanged. Set them
  (or run `setup.ps1 -Provider <p> -Model <m>`) to pass `--provider` / `--model` for Mission Centre's
  launches only. See [MODEL-ACCESS.md](MODEL-ACCESS.md).
- `modelCycle` is the Ctrl+P list. Plain ids are sent as `<provider>/<id>`, because pi matches a bare id
  against every provider and could pick the wrong one. Entries that already name a provider
  (`anthropic/...`) and globs (`*sonnet*`) are passed through unchanged.
- **Local model server** (optional): set `healthUrl` (e.g. `http://localhost:11434/` for Ollama). Before a pi
  launch Mission Centre probes it (any 2xx answer is healthy). When it is down and `autoStart` is on, it
  starts it through a Windows Scheduled Task (`taskName`) or a shell command (`startCommand`, run in
  `workingDir`), waits up to `startWaitSeconds`, and asks before launching without it. Register the
  server's models in `~/.pi/agent/models.json`; `pi/pi-config/models.local-example.json` shows the shape.

**Running pi from source (`pii`).** To run a pi fork from a local clone (by default the public
[leo-labs-ai/pi-mono](https://github.com/leo-labs-ai/pi-mono)), run `setup.ps1 -WithFork`. It clones the
fork, writes a `pii` launcher next to npm's global commands, and enables `toolUpdates.piFork`. Mission
Centre then updates the fork from git: fetch, merge, `npm install --ignore-scripts`, model data if stale,
`npm run build:offline`. Safeguards:

- It refuses to merge if the clone has uncommitted tracked changes, aborts a conflicting merge (naming the
  files), and never resets or cleans.
- It refuses if `merge.ours.driver` is registered in the clone. A fork's `merge=ours` attributes suit its
  maintainers, but in a downstream clone they keep stale generated model tables. Don't run a fork's
  merge-driver setup script in your clone.
- If the build is missing (e.g. a failed rebuild), launches fall back to `piFork.fallbackCommand`
  (vanilla `pi`).

## Optional: pi as the Default Engine

With `pi` enabled, `"defaultEngine": "pi"` makes the single-letter launch keys
`[L]`/`[C]`/`[R]` run pi; Claude Code moves to `[CL]`/`[CC]`/`[CR]`. The profile still
decides the wiki vault and the context pack. Default is `claude` (the original layout).

### Kickoff: plan in Claude Code, build in pi

New work starts with a plan. Forge is a Claude Code plugin, so planning runs in Claude Code
(`jig run forge`, plan mode) and building in pi. The handoff is a file pi loads by itself:

1. `[N] New project` -> `[L]`, or `[I] Import` -> `[L]` on a folder without a plan: Claude Code
   plans with Forge's mission-planner. Once you approve, it writes `PLAN.md` (goal, scope and
   non-goals, tech stack, numbered steps with how to check each, open questions) and points to
   it from `CLAUDE.md`, then stops.
2. Exit Claude (`/exit`). In the same window: *Plan saved to PLAN.md. Start building in pi?
   [Y/n]*. Yes starts pi on the first step; it marks steps done in `PLAN.md` as it goes. No
   `PLAN.md` written means pi is not started.
3. From then on, `[L]` on the project opens pi directly.

`[NA] New App` and `[V]` do the same with vibe-check (beginner planning) instead of Forge.
`[P]` starts pi without planning, `[CK]` runs a Claude-only Forge kickoff.

On an existing project without `PLAN.md`, `[L]` offers the kickoff once; pressing Enter starts
pi and remembers the choice for that project on every device (`kickoff: skipped` in the shared
registry).

Forge sometimes designs a team of agents (`.claude/agents/`, `.claude/teams/`). pi cannot run
those; the kickoff asks Forge for a plan a single agent can follow, and a project that really
needs a team runs it in Claude Code (`[CL]`). Jig profiles only apply to the Claude Code lane;
meta missions (`[M]`) stay on Claude Code. A device needs `jig` and the Forge plugin for
kickoffs (`setup.ps1` checks both); without Jig the kickoff falls back to plain Claude Code.

## Setting Up a Device

Close Mission Centre (start it once first, so `config.json` exists) and run:

```bash
pwsh ./setup.ps1                                          # macOS
powershell -ExecutionPolicy Bypass -File .\setup.ps1      # Windows
```

It checks git, Node, Claude Code, Jig and the Forge plugin; installs pi if you agree; warns when pi has no
model access yet; then asks four questions and writes the answers into `config.json`:

| Question | Default | Flag |
|---|---|---|
| Make pi the default engine? (`[L]`/`[C]`/`[R]` start pi; Claude Code on `[CL]`/`[CC]`/`[CR]`) | yes, when pi is installed | `-PiDefault` |
| Install updates automatically, without asking? | yes | `-AutoUpdate auto` or `check` |
| Also run pi from source as `pii` (a fork)? | no | `-WithFork` (`-ForkUrl`, `-ForkPath`) |
| Same project list on several computers? (needs a private repo you own) | no | `-RegistryUrl <url>` |

`-Yes` accepts the defaults without asking. Settings you already have (pi as default, a fork, a
registry) are kept on every re-run. It backs up every file it changes, never rewrites a `pii` launcher
that pi sessions are running from, and re-running only fixes drift. After that, every launch keeps the
device current.

## Optional: Same Projects on Every Device

Two features keep several computers in step:

- **Self-update** (on by default): at launch, Mission Centre fast-forwards its own
  checkout to its upstream and restarts into the new code. It only touches a clean
  tree that is purely behind; with local commits or edits it just tells you.
  Turn off with `"selfUpdate": { "enabled": false }` or `MISSION_CENTRE_NO_UPDATE=1`.
- **Shared registry** (opt-in): the project list lives in a **private** git repository you
  control (it holds your project names and remotes), one JSON file per project under `projects/`. A project is identified by
  its git remote, so the same repository is the same project on every device, and
  each device keeps **its own folder path**. Name, description, profile and
  dormancy are shared. `projects.json` becomes this device's offline cache.

```json
"deviceName": "LAPTOP",
"sharedState": {
    "enabled": true,
    "remote": "https://github.com/<you>/<private-registry>.git",
    "sshKey": ""
}
```

- `[O] Other devices` lists shared projects that are not on this device and clones
  one with a keystroke (or shows where it lives, if it has no git remote).
- `[S] Scan` adopts a folder silently when its git remote is already in the registry.
- A project without a git remote is matched by name the first time a second device
  sees it.
- Offline is fine: Mission Centre uses its last copy and pushes on the next sync.
  On a clash the device saving last wins, per project.
- Removing a project on one device removes only that device's path; the record goes
  when no device has it.
- Headless sync (e.g. a server, or the first migration):
  `MISSION_CENTRE_SYNC_ONLY=1 pwsh -File Mission-Centre.ps1`

The remote can be any git repository you can push to non-interactively: HTTPS GitHub
with `gh auth login` done once per device (no SSH key needed), or SSH
(`git@server:repo` plus `sshKey`). Remote URLs are stored with any embedded credentials
stripped.

## Context Pack for the Agent

When a profile has a wiki vault (`wikiVaults` in `config.json`; the vault is an Obsidian-style folder of
Markdown pages, as used by the [obsidian-wiki](https://github.com/Ar9av/obsidian-wiki) skills), every launch:

1. **Updates the vault** when it is a git checkout (`git pull --ff-only`, 20 s, at most every 10 minutes;
   offline keeps the local copy).
2. Writes `~/.obsidian-wiki/context-pack.md`: your profile page, the **system map** page (what runs where and
   what already exists), the pages most related to the project (by name), and a one-line index of every
   page. The profile and map page slugs are set in `wikiContext` (defaults `profile` and `system-map`).
3. Keeps a managed "read this first" block (between `<!-- mission-centre:brain BEGIN -->` and `END`) in the
   global instructions of every installed agent: Claude Code `~/.claude/CLAUDE.md`, pi `~/.pi/agent/AGENTS.md`,
   Codex `~/.codex/AGENTS.md`, Gemini `~/.gemini/GEMINI.md`. Only folders that exist are touched; the first
   change keeps a `.bak-mc` copy; text outside the markers is yours.

Without a vault configured, none of this runs.

## Optional Codebase Index

Mission Centre can optionally check `.ai-codex/` before launching a project and offer to refresh it when missing or stale. This is disabled by default because it is not required by Claude Code, Jig, or Forge.

Enable it in `config.json`:

```json
{
  "contextIndex": {
    "enabled": true,
    "command": "npx ai-codex",
    "maxAgeDays": 3
  }
}
```

When enabled, Mission Centre runs:

```bash
npx ai-codex
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).
