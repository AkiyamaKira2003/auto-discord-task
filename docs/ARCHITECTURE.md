# Audisk architecture

Version: v4.11.4

This document describes the current Audisk runtime rather than the historical project layout.

## 1. Runtime surfaces

Audisk has two execution surfaces:

- `index.js`: standalone script pasted into Discord DevTools.
- Vencord userplugin: `index.tsx` plus the root TypeScript modules.

The Vencord build is the primary maintained surface because it can use Vencord stores, native helpers, persistent settings and a native Discord profile modal.

## 2. Plugin lifecycle

`index.tsx` owns plugin lifecycle and command registration. It initializes account watchers, enrollment watchers and the floating dashboard. The public slash command is `/audisk`.

`start()` mounts the dashboard and begins asynchronous plugin initialization. `stop()` invalidates the current generation, removes watchers, disposes the dashboard and stops the engine through the normal cleanup path.

A lifecycle generation prevents stale asynchronous initialization from reviving a plugin instance after it has already been stopped or replaced.

## 3. Engine

`audisk.ts` owns the scheduler, Quest scan loop, dashboard registry, account-scoped runtime state and engine start/stop operations.

Important invariants:

- only one active engine generation owns mutable runtime state
- confirmed account changes invalidate account-owned state
- a transient missing user ID is treated as an observation gap, not proof of account change
- task cleanup is generation-aware
- stopped or replaced tasks cannot publish progress into a newer run

## 4. Task execution

`tasks.ts` contains per-task handlers. It uses `VencordNative.pluginHelpers.Audisk` for native requests that cannot be performed safely from the renderer because of CSP.

Task families are selected from Discord's current Quest configuration. If a Quest offers multiple compatible task families, Audisk prefers a path the current client can actually drive instead of blindly choosing the first configured task.

## 5. Traffic and retries

`traffic.ts` serializes sensitive Quest API operations, tracks retry state and respects cancellation. Retryable failures use bounded backoff. A cancelled generation must not continue issuing requests just because a delayed retry timer fires later.

Traffic metadata fields are copied from Discord state where required. Audisk does not invent executable fingerprints.

## 6. Heartbeat observation

`heartbeatWatchdog.ts` watches Discord's own heartbeat success/failure flow for tasks where Discord is expected to send heartbeats. The watchdog distinguishes real heartbeat failure from simple silence and prevents an endless wait when the expected Discord event never arrives.

## 7. Account identity

`accountIdentity.ts` contains the conservative account-change rule. Runtime state is only declared stale after another confirmed non-null Discord user ID is observed.

On account change, Audisk clears scheduled wakeups and account-owned task state before a new account can inherit them.

## 8. OAuth lifecycle

`oauthLifecycle.ts` records grants Audisk creates for the optional achievement path and removes only grants it can attribute to the current operation. The goal is to avoid deleting unrelated authorizations that already existed on the account.

The achievement path is gated behind explicit settings consent.

## 9. Store patching

`patcher.ts` applies temporary Discord store/runtime changes needed by game- and presence-related tasks. Each patch has a corresponding cleanup path. Cleanup is triggered on task completion, task cancellation, engine stop, account change, and plugin shutdown.

## 10. Scheduler metadata

`schedulerMetadata.ts` publishes a read-only view of the currently scheduled lanes. The dashboard uses this information separately from the task registry so a queued row is not confused with a task that is actively executing.

## 11. Dashboard

`dashboardUi.ts` is a view/control layer over the engine. It subscribes to dashboard entries and structured companion events.

The panel shows Audisk branding, version, health, controls, Quest cards, logs and the Kiraa profile button. The profile button resolves Discord user ID `581419585249607710` and calls Discord's native `openUserProfileModal` with the currently selected guild/channel context.

The dashboard never creates a second engine.

## 12. Standalone script

`index.js` uses Audisk-prefixed DOM IDs and logs. It can use the local relay, the Vencord native helper, or direct fetch depending on environment.

The standalone script and plugin intentionally share product naming and behavior, but they do not share runtime state.

## 13. Installer architecture

`RUN.cmd` calls `run.ps1`, which launches the devbuild installer for Discord Canary using the current repository as the local plugin source.

The devbuild installer uses `%LOCALAPPDATA%\AudiskVencord`, builds before injecting Discord, verifies required Vencord runtime files, checks that `renderer.js` contains the Audisk marker and writes a SHA-256 health stamp.

Transactional build helpers in `tools/audisk-devbuild-installer/installer-common.ps1` preserve a previously verified runtime so a failed build does not replace a known-good dist.

## 14. Clean-install boundary

The public installer contains only Audisk installation and update behavior. `RUN.cmd` is intended for a new machine or a clean Audisk setup and does not perform migration from earlier product names.

## 15. Third-party boundary

Audistask runs inside Vencord but does not own Vencord or its bundled libraries. Third-party copyright/license notices remain untouched. See root `LICENSE`, `NOTICE.md`, and `tools/audisk-vencord-bundle/LICENSE-VENCORD.txt`.
