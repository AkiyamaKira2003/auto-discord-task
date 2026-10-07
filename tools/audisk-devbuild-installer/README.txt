AUDISK BY KIRAA - VEN CORD AUTO-UPDATE INSTALLER
==================================================

Owner / maintainer: Kiraa (AkiyamaKira2003)
Version: v4.11.4
Project: https://github.com/AkiyamaKira2003/auto-discord-task
Plugin name: Audisk
Plugin folder: src\userplugins\audisk
Default build folder: %LOCALAPPDATA%\AudiskVencord

QUICK INSTALL
-------------
From the repository root, RUN.cmd is the preferred clean-install path for Discord Canary.

RUN installs Audisk from the current repository and contains no migration behavior for earlier product names.

Packaged users can run INSTALL-autoupdate.cmd directly.

WHAT THE INSTALLER DOES
-----------------------
1. Selects the target Discord branch.
2. Checks Node.js 22+ and Git.
3. Clones or updates upstream Vencord.
4. Installs Audisk under src\userplugins\audisk.
5. Runs pnpm install.
6. Builds Vencord transactionally.
7. Verifies the required runtime files and checks renderer.js for Audisk.
8. Injects the verified Vencord build into Discord.
9. Reopens the Discord clients that need to be restored.

LOCAL DEVELOPMENT SOURCE
------------------------
install-autoupdate.ps1 accepts -LocalPluginSource. RUN passes the current repository root, which lets a fresh clone install the current Audisk source directly.

UPDATE
------
Run UPDATE.cmd. It refreshes Vencord and Audisk, then builds and verifies before replacing the active dist. A failed build restores the last verified runtime when one exists.

UNINSTALL
---------
Run UNINSTALL.cmd. The uninstaller restores Discord only when its app.asar points at this AudiskVencord patcher. Do not manually delete AudiskVencord while Discord still points at it.

CANARY
------
RUN explicitly targets Discord Canary. After install, open Settings -> Vencord -> Plugins, search Audisk, and enable it if necessary. The command is /audisk.

RECOVERY ROOTS
--------------
Stable: %LOCALAPPDATA%\Discord
Canary: %LOCALAPPDATA%\DiscordCanary
PTB:    %LOCALAPPDATA%\DiscordPTB

If recovery cannot be verified, keep AudiskVencord in place and use the official Vencord installer to Repair the affected Discord flavor before deleting anything.

LEGAL
-----
Audistask's branding and documentation are maintained by Kiraa. The root LICENSE preserves the required MIT upstream notice. Vencord and bundled libraries keep their own licenses and copyright notices.
