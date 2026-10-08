# Audisk Vencord plugin

Version: v4.11.8

Audisk is a Vencord userplugin for Discord Quest automation maintained by **Kiraa / AkiyamaKira2003**.

Repository: https://github.com/AkiyamaKira2003/auto-discord-task

## Install

For the repository, double-click `INSTALL.cmd`. A clean machine does not need Node.js or Git preinstalled; the installer prepares portable copies automatically under `%LOCALAPPDATA%\AudiskBootstrap` when necessary. Choose `1` Stable, `2` Canary, or `3` PTB; multiple installed clients can be selected in one run with input such as `1 3`, `1,3`, or `1 2 3`. The installer builds Vencord with the local Audisk source under `src/userplugins/audisk` before patching each selected client.

For a packaged installer, use `tools/audisk-devbuild-installer/INSTALL.cmd`; it uses the same 1/2/3 client menu and the same full backend.

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

The plugin mounts a floating dashboard with START/STOP, PAUSE/RESUME, health, Quest progress and structured logs. `Shift + .` toggles visibility, `Ctrl + Shift + S` starts/stops, and `Ctrl + Shift + P` pauses/resumes.

The footer keeps a Discord-colored `akiyamakira2003` button on the left and a `?` hotkey helper on the right. Clicking the profile button opens Kiraa's native Discord profile modal inside the client.

Audisk also attaches a compact status marker to Discord's native Quests entry. Idle is one green dot; an actively running quest is three Kiraa-blue dots with a soft overlapping brightness wave. The dots are preserved across ordinary Discord DOM mutations so their CSS animation is not restarted every frame.

## Settings

The plugin exposes settings for auto start, auto enroll, Orb-only runs, watching for enrollments, achievement bypass consent, reward claim attempts, hidden activity, game-session tail, concurrency, sounds and verbose logging.

The dashboard gear menu controls those same settings rather than maintaining a second configuration. It writes through Vencord's smart settings proxy and subscribes to `plugins.Audisk`, so the menu and Vencord's plugin settings stay synchronized in both directions. The dropdown is capped at 365px and scrolls internally, keeping the main Audisk panel compact while every setting remains reachable.

Orb quests only is off by default. When enabled, a quest is eligible only when at least one entry in rewardsConfig.rewards carries a positive Orb payout. Non-Orb quests are not enrolled or started and are reported as left out rather than failed. The filter is intentionally revocable: it does not add quests to the permanent skipped set, so turning the setting off returns them to the next scan. Work already queued or running when the setting is enabled is allowed to finish normally.

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
- enabling Orb quests only leaves non-Orb quests unenrolled and unstarted
- profile button opens user ID `581419585249607710`
- dashboard settings stay synchronized with Vencord plugin settings
- Quests navigation shows the Audisk idle/running status marker
- uninstall confirmation uses the recorded pre-install Vencord state for its default
- disabling the plugin removes watchers, patches and dashboard elements

## License

Audistask is a project maintained by Kiraa. The MIT notice required by the base code is preserved in the repository `LICENSE`. Vencord remains under GPL-3.0-or-later and retains its own notices.

