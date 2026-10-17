# Lessons

What broke while building and running this setup, and the rule each problem left behind. Most of these
are written into the code as comments next to the fix; this page collects them.

## Keeping tools current

- **A stale CLI quietly loses models.** Anthropic only serves new models to recent Claude Code versions:
  an old build gets *"Claude Code X does not support this model; version Y or newer is required"* for a
  model that otherwise works. Keeping tools current is about correctness, not tidiness. Check daily, and
  check again right before launching an agent.
- **Update every part from its own source.** A copy re-published by someone in between goes stale the
  moment they stop. Record where each part comes from (`source.json` for skills, the fork's remote, the npm
  package) and fetch from there.
- **Check the licence on every update, not only the first time.** Upstream can relicense. Refuse the
  update when the licence text no longer matches, and never drop the licence file when vendoring: an
  over-broad exclude once removed one, and only a test caught it.
- **Throttle the checks, and never block a launch on them.** Version probes hit the network, so cache the
  result (`.mission-centre/tool-updates.json`) and probe at most every `intervalHours`. Offline, a missing
  npm or a failed update prints a warning and the launch continues.
- **One package per `npm i -g`.** A batch install aborts entirely when one package fails, so a single bad
  package silently skips every other update.
- **`latest` is not always installable.** A dist-tag can point at a version the registry cannot serve yet.
  Fall back to the newest version that is actually published.
- **"Up to date" must mean installed.** The update report said "up to date" while listing pi as not
  installed, because that pi came from another package. Only claim it for what you actually manage, and
  say where an unmanaged copy on PATH comes from.
- **A failure must stay visible.** A throttled check that only warns once hid a fork that fell 100+ commits
  behind. Save the failure as a note and repeat it on every launch until a later check clears it.
- **Updates need a schedule outside the app.** Mission Centre updates when you open it. A machine where it
  stays closed falls behind, so a weekly scheduled health check is worth having.

## Updating a fork from source

- **Never reset, never clean.** Merge, and abort a conflicting merge. Untracked files in the checkout are
  someone's work.
- **Name the conflicting files.** "Resolve manually" alone is not actionable. Read them from the merge
  output first: `git status` and `git diff --diff-filter=U` came back empty after a conflict on one git
  version.
- **`merge=ours` is inverted downstream.** A fork's `.gitattributes` may mark generated files `merge=ours`.
  That is right for the fork merging from *its* upstream, but in your clone every sync then keeps *your*
  stale copies. Refuse to auto-merge while the driver is registered.
- **Treat an unknown exit code as failure.** Treating a `$null` exit code as success once made a
  conflicting merge look clean, and the half-merged tree got built.
- **Detect a stale build.** A build older than the checked-out commit (after a manual pull) still "exists"
  but runs old code. Compare timestamps.
- **Always keep a fallback.** If the source build is missing, launch the npm release instead of a terminal
  that dies at once.

## Self-update

- Fast-forward only, and only a clean tree that is purely behind. With local commits or edits, say so and
  leave it alone.
- Re-exec into the new code once, with an environment guard so it cannot loop.

## Windows and PowerShell

- **`npm` resolves to `npm.ps1`,** which `Start-Process` cannot run. Use `npm.cmd`.
- **`Start-Process` does not quote arguments.** `-m 'fork edit'` arrives as two words. Build the command
  line yourself with Windows quoting rules.
- **Exit codes go missing.** Touch `$proc.Handle` right after starting, and call `WaitForExit()` with no
  arguments after the timed wait, or `ExitCode` can be `$null`.
- **Windows PowerShell 5.1 differs from PowerShell 7,** so test on both:
  - Under `Set-StrictMode`, `.Count` on a single object throws. Wrap results in `@()`.
  - With `$ErrorActionPreference = 'Stop'`, `2>&1` on a native command turns any stderr line into a
    terminating error, even when the command succeeds.
  - `Get-FileHash` is missing on some installs. Hash with .NET.
  - Scripts with non-ASCII characters need a UTF-8 BOM, or 5.1 misreads them.
- **But JSON for other tools must not have a BOM.** `Set-Content -Encoding UTF8` in 5.1 writes one, and some
  JSON readers then fail on the first byte. Write with `UTF8Encoding($false)`.
- **Native output leaks into return values.** `git init` inside a function adds its stdout to what the
  function returns. Assign it to `$null`.
- **Windows commits lose the executable bit.** A shell script committed from Windows arrives on macOS as
  `Permission denied`. Set it in git (`git update-index --chmod=+x <file>`) and have CI check it.
- **Check install commands on the real platform.** A Homebrew cask that once existed (`--cask powershell`)
  was gone; the formula (`brew install powershell`) is what works now.
- **macOS Terminal types a launch command, and a typed line is capped at 1024 bytes** (`MAX_CANON`).
  `do script` with a long command (the kickoff is about 1650 characters) was cut off mid-word and nothing
  ran. Write the command to a script file and type only `pwsh -File <path>`.
- **Common ports get squatted.** A vendor utility held a port the local server wanted. Check who owns a port
  before using it, and make the port configurable.

## Running agents safely

- **Never stop a process in your own ancestry.** Agents run under the launcher, and some run through local
  services. A "clean up stale processes" step can kill the session doing the work. A process is stale only
  when it has no live parent and no recent activity.
- **Defer restarts while requests are in flight.** Restarting a local service mid-reply cuts off every
  session using it. Try again at the next launch.
- **Don't nag, and don't default to overwriting.** A start-up prompt that defaulted to *yes* replaced
  hand-tuned profiles without a backup. Default to *no*, back up first, ask once per change, and stay quiet
  about tools that aren't installed.
- **Back up before every change** (`*.bak-<timestamp>`), and never treat backups as clean-up candidates.
- **Check secrets by location and permissions only.** Never read or print them.

## Planning with one agent, building with another

- Hand off through files the next agent loads itself: a `PLAN.md` (goal, scope and non-goals, steps with how
  to check each) and a pointer to it in `CLAUDE.md`. No plan written means no build is started.
- Ask the planner for a plan a single agent can follow. Agent teams that only one tool supports do not
  transfer.
- Give agents a **system map**: a page of what runs where and what already exists. Without it, agents kept
  rebuilding things that already worked.
- Qualify model ids with their provider (`anthropic/claude-sonnet-5`). A bare id that exists under several
  providers can silently resolve to the wrong one.

## Tests

- **A crash must fail the run.** A `try/finally` without `catch` let an exception end the test block early,
  and the summary still said "0 failed". Count the exception as a failure, and watch the test count too.
- **Hermetic or nothing.** Every fixture lives in a temp folder. The tests never read or write the real
  `~/.claude`, `~/.pi`, config or registry.
- **Shadow, don't mock frameworks.** A PowerShell function with a cmdlet's name (`Invoke-WebRequest`,
  `Read-Host`, `claude`) takes precedence, so tests can stub anything without dependencies.
- **Pure functions for the rules.** Merge rules, id normalisation and screen layout are pure and unit
  tested. Git end-to-end runs against a local bare repo.

## Publishing a setup like this

- **Your project list is private data.** Names and remotes reveal clients and plans. Keep the shared
  registry in a private repo, and never commit `projects.json`.
- **Check everything that would be published:** files, file names, commit messages and commit emails. Use
  your forge's no-reply address for public commits.
- **Know the identities GitHub adds.** The test merge of every pull request (and a merge on the website) is
  committed by `noreply@github.com`. An identity check that only allowed personal noreply addresses failed
  the first outside pull request. Allow GitHub's own identity; it names no one.
- **Keep the denylist outside the repo.** A list of names you must never publish is itself private. The
  public check (`tools/privacy-check.ps1`) covers generic patterns; a local `.local/denylist.txt` covers the
  rest, and a pre-push hook runs both.
- **Licences travel with the code.** Keep third-party licence files next to what you vendor, link instead of
  vendoring when you can, and leave out anything whose licence you cannot confirm.
- **Respect provider terms.** If a shortcut depends on reusing a login outside the app it was issued for,
  leave it out.
