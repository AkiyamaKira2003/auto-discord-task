# Contributing to Audisk

Audisk is maintained by **Kiraa / AkiyamaKira2003**. Contributions should preserve the plugin's current behavior, keep the standalone script and Vencord plugin aligned where they share logic, and avoid weakening cleanup or rollback paths.

## Repository

Clone the Kiraa repository:

```bash
git clone https://github.com/AkiyamaKira2003/auto-discord-task.git
cd auto-discord-task
```

The Vencord plugin entry is `index.tsx`. The engine is `audisk.ts`, task handlers are in `tasks.ts`, and the floating panel is in `dashboardUi.ts`.

## Naming

User-facing branding is **Audisk**. The slash command is `/audisk`. New visible strings, logs, docs, release names, installer text, CSS/DOM identifiers and userplugin folders should use Audisk naming.

Legacy names such as `audisk` or `Audisk` are allowed only inside migration code whose purpose is to detect and remove an older install silently.

## Kiraa identity

The Vencord author metadata uses:

- name: `Kiraa`
- Discord username: `akiyamakira2003`
- Discord user ID: `581419585249607710`

The dashboard profile button must continue to use Discord's native profile modal rather than an external browser link.

## Development workflow

Before changing behavior, identify whether the code path is shared with the standalone script. Keep task selection, retry rules, account identity handling, traffic metadata, scheduler state and cleanup semantics consistent.

For plugin work:

1. Edit the root TypeScript files.
2. Run the regression tests in a Vencord environment.
3. Stage the plugin under `src/userplugins/audisk`.
4. Build Vencord.
5. Verify `dist/renderer.js` contains `Audisk`.
6. Test the dashboard, commands and teardown in Discord Canary.

For installer work, run the scripts in `tools/tests/` and verify rollback behavior before using `INSTALL.cmd` against a real client.

## Safety-sensitive behavior

Changes around OAuth authorization, activity-backend requests, account switching, reward claims, heartbeat spoofing or request retry logic need extra review. Never log Discord tokens, OAuth authorization codes, private account secrets or raw credentials.

Do not turn an explicit opt-in risk setting into an automatic default without a clear reason and matching documentation.

## Pull requests

A useful pull request includes:

- what changed
- why it changed
- files/modules affected
- regression tests run
- Discord/Vencord build used for integration testing
- screenshots for UI changes when relevant

Keep unrelated refactors separate from behavior changes so regressions are easier to locate.

## License and attribution

Audistask are maintained by Kiraa. The original MIT notice remains in `LICENSE` because the license requires it. Vencord and bundled third-party libraries keep their own notices and must not be re-attributed to Audistask.