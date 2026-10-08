AUDISK BY KIRAA - VEN CORD AUTO-UPDATE INSTALLER
==================================================

Owner / maintainer: Kiraa (AkiyamaKira2003)
Version: v4.11.8
Project: https://github.com/AkiyamaKira2003/auto-discord-task
Plugin name: Audisk
Plugin folder: src\userplugins\audisk
Default build folder: %LOCALAPPDATA%\AudiskVencord

QUICK INSTALL
-------------
From the repository root, INSTALL.cmd is the preferred clean-install path. It asks which Discord client(s) to target: 1 Stable, 2 Canary, or 3 PTB. Multi-select is supported with inputs such as 1 3, 1,3, or 1 2 3.

INSTALL installs Audisk from the current repository and contains no migration behavior for earlier product names.

Packaged users run INSTALL.cmd and get the same 1/2/3 client selector.

WHAT THE INSTALLER DOES
-----------------------
1. Selects the target Discord branch.
2. Prepares Node.js 22+ and Git automatically. Existing installs are reused; otherwise portable copies are downloaded into %LOCALAPPDATA%\AudiskBootstrap. No winget, administrator rights, or reboot is required.
3. Clones or updates upstream Vencord.
4. Installs Audisk under src\userplugins\audisk.
5. Runs pnpm install.
6. Builds Vencord transactionally.
7. Verifies the required runtime files and checks renderer.js for Audisk.
8. Injects the verified Vencord build into Discord.
9. Reopens the Discord clients that need to be restored.

LOCAL DEVELOPMENT SOURCE
------------------------
install-autoupdate.ps1 remains the internal backend. The root INSTALL passes the current repository through -LocalPluginSource, while the packaged INSTALL uses its staged plugin source. Both paths share the same branch selector and full install pipeline.

UPDATE
------
Run UPDATE.cmd. It refreshes Vencord and Audisk, then builds and verifies before replacing the active dist. A failed build restores the last verified runtime when one exists.

UNINSTALL
---------
Run UNINSTALL.cmd for the standalone installer path, or use the darker-red Uninstall action in the Audisk dashboard. The dashboard confirmation remembers whether Vencord existed before Audisk: it keeps a pre-existing Vencord by default, while a clean machine that received Vencord through Audisk defaults to removing Vencord too. Do not manually delete AudiskVencord while Discord still points at it.

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
