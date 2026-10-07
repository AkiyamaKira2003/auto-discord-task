# Audisk Vencord plugin

Version: v4.11.4

Audisk is a Vencord userplugin for Discord Quest automation maintained by **Kiraa / AkiyamaKira2003**.

Repository: https://github.com/AkiyamaKira2003/auto-discord-task

## Install

For the repository, double-click `RUN.cmd`. It targets Discord Canary, installs the local Audisk source under `src/userplugins/audisk`, builds Vencord and patches Canary.

For a packaged installer, use `tools/audisk-devbuild-installer/INSTALL-autoupdate.cmd`.

## Plugin identity

- plugin name: `Audisk`
- author: `Kiraa`
- Discord ID: `581419585249607710`
- command: `/audisk`
- native helper: `VencordNative.pluginHelpers.Audisk`

## Commands

```text
/audisk action:start
/audisk action:stop
/audisk action:status
/audisk action:pause
/audisk action:pause quest:<name-or-id>
/audisk action:resume
/audisk action:resume quest:<name-or-id>
```

Pause/resume state is account- and session-scoped. A resumed Quest is scheduled from the progress Discord already recorded; Audisk does not resurrect a cancelled task generation.

## Dashboard

The plugin mounts a floating dashboard with START/STOP, PAUSE/RESUME, health, Quest progress and structured logs. `Shift + .` toggles visibility.

The footer has a Discord-colored button with the Discord icon and `akiyamakira2003`. Clicking it opens Kiraa's native Discord profile modal inside the client.

## Settings

The plugin exposes settings for auto start, auto enroll, watching for enrollments, achievement bypass consent, reward claim attempts, hidden activity, game-session tail, concurrency, sounds and verbose logging.

`watchForEnrollments` is owned by the plugin lifecycle rather than the engine run. It stays armed after a natural queue drain when enabled, but `/audisk stop` disarms it until the next start.

## Source layout

```text
index.tsx        plugin metadata, lifecycle, commands
audisk.ts     engine / Quest scan / dashboard registry
dashboardUi.ts   floating UI and Kiraa profile button
tasks.ts         task handlers
traffic.ts       request queue / retry / cancellation
patcher.ts       store/runtime patches
native.ts        main-process HTTP helpers
settings.ts      Vencord settings
```

## Achievement path

Achievement-in-activity automation can require OAuth authorization for the Quest application and activity-backend progress reporting. It is intentionally opt-in. Audisk tracks the grants it creates and cleans them up through `oauthLifecycle.ts`.

## Build verification

A valid production build should satisfy all of the following:

- plugin folder is `src/userplugins/audisk`
- `index.tsx` metadata name is `Audisk`
- generated `dist/renderer.js` contains `Audisk`
- dashboard mounts without a second engine
- `/audisk status` responds
- profile button opens user ID `581419585249607710`
- disabling the plugin removes watchers, patches and dashboard elements

## License

Audistask is a project maintained by Kiraa. The MIT notice required by the base code is preserved in the repository `LICENSE`. Vencord remains under GPL-3.0-or-later and retains its own notices.

