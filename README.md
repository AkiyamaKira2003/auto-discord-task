# Audisk

Version: v4.11.4

**Audisk by Kiraa** is a Discord Quest automation project for Discord desktop and Vencord. The current build focuses on a native Vencord userplugin, a compact floating dashboard, a one-click Canary installer, and a standalone console script kept in the same repository.

- Project owner / maintainer: **Kiraa (AkiyamaKira2003)**
- GitHub: https://github.com/AkiyamaKira2003/auto-discord-task
- Discord profile shown in the UI: **akiyamakira2003**
- Plugin command: **`/audisk`**
- Default client for `RUN.cmd`: **Discord Canary**

> [!CAUTION]
> Discord can enforce against automated Quest completion. Audisk changes Quest-related client behavior and may create account-level risk. Do not treat automation as undetectable or guaranteed safe. Achievement automation is especially sensitive because it can involve real OAuth authorization for the Quest application. Use the project only on accounts where you accept that risk.

## What Audisk does

Audisk reads Discord's own Quest data and schedules work through the logged-in Discord client. The engine tracks Quest state, progress, retries, pause/resume state, claim state, account changes, and cleanup of temporary spoofed state.

Supported task families in the current engine include:

| Quest family | Audisk behavior |
| --- | --- |
| Video | Sends timed progress updates with retry/backoff handling. |
| Desktop game | Uses Discord's running-game state so Discord drives the normal Quest heartbeat path. |
| Activity | Uses Discord Quest heartbeat state for supported activity tasks. |
| Achievement in activity | Can use the optional achievement bypass path when explicitly enabled. |
| Stream | Pure stream-only Quests can still be limited by Discord's live-stream checks; Audisk prefers another supported task when the same Quest offers one. |

The engine also includes account-change cleanup, request throttling, per-task cancellation, scheduler metadata, heartbeat watchdogs, optional reward claiming, and structured events for the dashboard.

## Fastest install: RUN

For this repository, use:

```text
RUN.cmd
```

`RUN.cmd` is the public clean-install path for **Discord Canary**:

1. Builds/updates Vencord under `%LOCALAPPDATA%\AudiskVencord`.
2. Copies the Audisk plugin from this repository into `src\userplugins\audisk`.
3. Installs dependencies.
4. Builds Vencord transactionally and verifies that the generated renderer contains Audisk.
5. Patches Discord Canary with the verified build and reopens the client.

It is designed to work on a new machine with no previous Audisk installation.

### Other installer entry points

The maintained installer lives in:

```text
tools\audisk-devbuild-installer\
```

Important files:

- `INSTALL-autoupdate.cmd` - normal packaged install.
- `UPDATE.cmd` - updates Vencord and the Audisk plugin.
- `UNINSTALL.cmd` - removes the Audisk Vencord injection safely.
- `install-autoupdate.ps1` - installer implementation.
- `installer-common.ps1` - shared Discord/Vencord discovery, verification and rollback helpers.

The installer points to the Kiraa repository:

```text
https://github.com/AkiyamaKira2003/auto-discord-task.git
```

`RUN.cmd` uses the local source tree directly, so a freshly cloned or downloaded repository can install without a separate plugin checkout.

## Audisk Vencord plugin

After installation, open Discord Canary and go to **Settings -> Vencord -> Plugins**. Search for **Audisk** and enable it if it is not already enabled.

The plugin metadata is owned by Kiraa and uses Discord user ID `581419585249607710` for the author profile.

### Slash command

Use `/audisk` with one of these actions:

```text
/audisk action:start
/audisk action:stop
/audisk action:status
/audisk action:pause
/audisk action:resume
```

For pause/resume, the optional `quest` field accepts a Quest ID, exact name, or a unique part of its name.

## Floating dashboard

When Audisk loads, it mounts a compact Discord-native floating dashboard. The dashboard is only a control/view layer; it does not start a second Quest engine.

The header shows:

- **Audisk**
- **by Kiraa**
- plugin version
- health indicator
- `START / STOP`
- `PAUSE / RESUME`
- hide button
- options menu

Quest cards show state and progress. Logs are capped to a small rolling history to avoid an endlessly growing panel. `Shift + .` toggles the dashboard.

### Kiraa Discord profile button

At the bottom of the Audisk dashboard is a Discord-styled button with the Discord icon and the username:

```text
akiyamakira2003
```

The button uses Discord/Vencord's native `openUserProfileModal` flow. Pressing it resolves user ID `581419585249607710` and opens Kiraa's profile inside Discord Canary, like opening another user's profile normally. It does not launch an external browser.

## Plugin settings

Audisk exposes Vencord settings for:

- auto start
- auto enroll
- watch for newly accepted Quests
- achievement bypass consent
- automatic reward claim attempts
- hiding the temporary game activity presence
- game-session tail duration
- game concurrency
- video concurrency
- completion sound
- verbose diagnostic logging

Risk-sensitive behavior is off by default where practical. In particular, the achievement bypass requires explicit opt-in.

## Standalone script

`index.js` is the standalone Audisk script. It uses the same product name, Audisk DOM IDs, Audisk logging prefixes and the same Kiraa-oriented project links.

The standalone path can use three transports for activity-backend requests, depending on environment:

1. local Audisk relay
2. Vencord Audisk native helper
3. direct fetch where the environment permits it

The native helper name is now `VencordNative.pluginHelpers.Audisk`.

## Audisk relay

The optional local relay is in:

```text
tools\audisk-relay\
```

It is only needed for the standalone script when the renderer cannot directly reach the required activity backend and the Vencord native helper is unavailable. The relay listens on loopback only and requires the Audisk request marker header.

See `tools/audisk-relay/README.md` for usage and security notes.

## Update behavior

`UPDATE.cmd` updates the Vencord source, refreshes Audisk when possible, builds transactionally, verifies the generated runtime, and restores the previously verified build if a build fails.

The health marker for the Audisk Vencord build is stored under the Audisk install directory and contains SHA-256 hashes for the required Vencord runtime files.

Other git-backed userplugins can be updated by the companion updater, but the `audisk` plugin directory is excluded from that sweep because Audisk has its own update path.

## Failure recovery

The installer deliberately builds before injecting Discord. It verifies the Vencord runtime and keeps rollback information so a partial build is not silently treated as healthy.

If Discord cannot reopen after a failed injection or recovery:

1. Leave the current Vencord/Audisk folders in place until recovery is complete.
2. Run the official Vencord installer and choose Repair if necessary.
3. Re-run `RUN.cmd` after Discord Canary is healthy again.

Do not delete a Vencord folder while Discord's `app.asar` still points at its patcher.

## Repository layout

```text
auto-discord-task/
|-- RUN.cmd                     # one-click Canary setup
|-- run.ps1                     # public clean-install launcher
|-- index.tsx                   # Vencord plugin entry / commands / lifecycle
|-- audisk.ts                   # engine, scheduler and dashboard registry
|-- dashboardUi.ts              # floating UI + Kiraa Discord profile button
|-- tasks.ts                    # per-task execution logic
|-- traffic.ts                  # request scheduling / retry / cancellation
|-- patcher.ts                  # Discord store/runtime patch helpers
|-- settings.ts                 # Vencord plugin settings
|-- native.ts                   # native requests outside renderer CSP
|-- index.js                    # standalone Audisk script
|-- tests/                      # engine regression tests
|-- docs/                       # architecture and plugin documentation
`-- tools/
    |-- audisk-devbuild-installer/
    |-- audisk-relay/
    |-- audisk-vencord-bundle/
    `-- tests/
```

## Development checks

The repository includes regression tests for account identity, heartbeat behavior, OAuth cleanup, Quest configuration compatibility, reward parsing, target selection, scheduler state, task cancellation, traffic handling, installer rollback and relay behavior.

For a full integration check, copy the root `.ts/.tsx` plugin files into a Vencord checkout under `src/userplugins/audisk`, run the relevant tests, then build Vencord and verify the generated `renderer.js` contains `Audisk`.

## Reporting bugs

A useful report includes:

- Audisk version
- Discord branch and version
- Vencord build/revision
- Quest name and task type
- current dashboard state
- relevant Audisk log lines
- whether the problem reproduces after a clean stop/start

Never post account tokens, OAuth codes, session secrets, or private Discord credentials.

## Legal

Audistask branding, UI, installer behavior, and documentation in this tree are maintained by Kiraa / AkiyamaKira2003.

Licensed under MIT. The original MIT copyright notice is kept in `LICENSE`, with a separate copyright notice for the Audistask project by Kiraa / AkiyamaKira2003.
Third-party components keep their own notices. Vencord is GPL-3.0-or-later; full license text in `tools/audisk-vencord-bundle/LICENSE-VENCORD.txt`.

See `NOTICE.md` for the attribution boundary between Audistask and third-party components.
