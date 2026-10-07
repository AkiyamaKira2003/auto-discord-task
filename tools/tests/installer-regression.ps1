$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$DevbuildDir = Join-Path $RepoRoot 'tools\audisk-devbuild-installer'
$BundleDir = Join-Path $RepoRoot 'tools\audisk-vencord-bundle'
$Helper = Join-Path $DevbuildDir 'installer-common.ps1'
$BundleVerifier = Join-Path $BundleDir 'verify-vencord-target.ps1'
$Workflow = Join-Path $RepoRoot '.github\workflows\installer.yml'
$Packager = Join-Path $RepoRoot 'tools\package-release.ps1'
$RuntimeUninstall = Join-Path $DevbuildDir 'uninstall-runtime.ps1'
$RuntimeUninstallLauncher = Join-Path $DevbuildDir 'uninstall-runtime.cmd'
$RootInstallCmd = Join-Path $RepoRoot 'INSTALL.cmd'
$RootInstall = Join-Path $RepoRoot 'install.ps1'
$MenuInstallCmd = Join-Path $DevbuildDir 'INSTALL.cmd'
$MenuInstall = Join-Path $DevbuildDir 'install.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-False([bool]$Condition, [string]$Message) {
    if ($Condition) { throw $Message }
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "$Message`nExpected: $Expected`nActual:   $Actual" }
}
function Assert-SequenceEqual([object[]]$Actual, [object[]]$Expected, [string]$Message) {
    $a = @($Actual); $e = @($Expected)
    if ($a.Count -ne $e.Count) { throw "$Message`nExpected: $($e -join ', ')`nActual:   $($a -join ', ')" }
    for ($i = 0; $i -lt $e.Count; $i++) {
        if ($a[$i] -ne $e[$i]) { throw "$Message`nExpected: $($e -join ', ')`nActual:   $($a -join ', ')" }
    }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

Assert-True (Test-Path $Helper) 'installer-common.ps1 is required so install/update/uninstall share one tested Discord/toolchain implementation.'
Assert-True (Test-Path $RuntimeUninstall) 'The dashboard uninstall runtime helper must ship with the devbuild installer.'
Assert-True (Test-Path $RuntimeUninstallLauncher) 'The dashboard uninstall launcher must ship with the devbuild installer.'
Assert-True (Test-Path $RootInstallCmd) 'INSTALL.cmd must be the canonical repository installer entrypoint.'
Assert-True (Test-Path $RootInstall) 'Root install.ps1 must delegate to the canonical 1/2/3 installer menu.'
Assert-True (Test-Path $MenuInstallCmd) 'The packaged devbuild installer must expose INSTALL.cmd.'
Assert-True (Test-Path $MenuInstall) 'The packaged devbuild installer must expose the same 1/2/3 menu logic.'
$oldRunCmd = ('R' + 'UN.cmd')
$oldRunScript = ('r' + 'un.ps1')
$oldBackendCmd = ('INSTALL-auto' + 'update.cmd')
Assert-False (Test-Path (Join-Path $RepoRoot $oldRunCmd)) 'The obsolete public installer CMD entrypoint must not return.'
Assert-False (Test-Path (Join-Path $RepoRoot $oldRunScript)) 'The obsolete public installer script wrapper must not return.'
Assert-False (Test-Path (Join-Path $DevbuildDir $oldBackendCmd)) 'The backend-only installer must not be exposed as a second public CMD entrypoint.'
. $Helper

Assert-Equal (Resolve-DiscordFlavor -Installed @('stable', 'canary') -Running @('canary')) 'canary' 'Running Canary must win when Stable is also installed.'
Assert-Equal (Resolve-DiscordFlavor -Installed @('stable', 'ptb') -Running @('ptb')) 'ptb' 'Running PTB must win when Stable is also installed.'
Assert-Equal (Resolve-DiscordFlavor -Installed @('canary') -Running @()) 'canary' 'A single installed flavor is unambiguous even when Discord is closed.'
Assert-Equal (Resolve-DiscordFlavor -Installed @('stable', 'canary') -Running @() -PreferredBranch 'canary') 'canary' 'An explicit installed branch must be honored.'
Assert-Equal (Resolve-DiscordFlavor -Installed @('stable', 'canary') -Running @('canary') -PreferredBranch '') 'canary' 'An omitted Discord branch forwarded as an empty string must still use automatic selection.'
Assert-Throws { Resolve-DiscordFlavor -Installed @('stable') -Running @() -PreferredBranch 'beta' } 'Unsupported explicit Discord branches must still be rejected.'
Assert-Throws { Resolve-DiscordFlavor -Installed @('stable', 'canary') -Running @() } 'Multiple installed flavors with none running must not silently fall back to Stable.'
Assert-Throws { Resolve-DiscordFlavor -Installed @('stable', 'canary') -Running @('stable', 'canary') } 'Multiple running flavors are ambiguous and must not be guessed.'

Assert-SequenceEqual (Get-DiscordReopenSet -RunningBefore @('canary') -TargetBranch 'stable') @('canary', 'stable') 'Patch Stable while Canary was running must reopen both Canary and the patched Stable target.'
Assert-SequenceEqual (Get-DiscordReopenSet -RunningBefore @('canary') -TargetBranch 'canary') @('canary') 'The target must not be duplicated in the reopen set.'
Assert-SequenceEqual (Get-DiscordReopenSet -RunningBefore @() -TargetBranch 'ptb') @('ptb') 'A closed client install must reopen the target that was patched.'

$roots = @('C:\Users\ci\AppData\Local\Discord','C:\Users\ci\AppData\Local\DiscordCanary','C:\Users\ci\AppData\Local\DiscordPTB')
Assert-True (Test-IsDiscordUpdaterPath -Path 'C:\Users\ci\AppData\Local\DiscordCanary\Update.exe' -DiscordRoots $roots) 'Discord Canary updater must be recognized as Discord-owned.'
Assert-False (Test-IsDiscordUpdaterPath -Path 'C:\Program Files\SomeOtherApp\Update.exe' -DiscordRoots $roots) 'An unrelated Update.exe must never be classified as Discord-owned.'

$temp = Join-Path ([IO.Path]::GetTempPath()) ("audisk-installer-test-" + [guid]::NewGuid().ToString('N'))
try {
    $discordRoot = Join-Path $temp 'DiscordCanary'
    $oldResources = Join-Path $discordRoot 'app-1.0.100\resources'
    $newResources = Join-Path $discordRoot 'app-1.0.200\resources'
    New-Item -ItemType Directory -Force -Path $oldResources, $newResources | Out-Null
    (Get-Item (Split-Path $oldResources -Parent)).LastWriteTime = (Get-Date).AddMinutes(10)
    (Get-Item (Split-Path $newResources -Parent)).LastWriteTime = (Get-Date).AddMinutes(-10)
    Assert-Equal (Select-VencordDiscordResourcesPath -DiscordRoot $discordRoot) $newResources 'Verification must select the same app-* target rule as Vencord Installer.'
} finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }

$temp = Join-Path ([IO.Path]::GetTempPath()) ("audisk-health-stamp-test-" + [guid]::NewGuid().ToString('N'))
try {
    $dist = Join-Path $temp 'dist'
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    Set-Content -LiteralPath (Join-Path $dist 'patcher.js') -Value "// Vencord deadbeef`npatcher" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $dist 'preload.js') -Value "// Vencord deadbeef`npreload" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $dist 'renderer.js') -Value "// Vencord deadbeef`nAudisk" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $dist 'renderer.css') -Value 'first-css' -Encoding ASCII

    Write-AudiskVencordHealthStamp -InstallDir $temp -DistPath $dist
    $stamp = Get-AudiskVencordHealthStampPath -InstallDir $temp
    $firstStamp = Get-Content -LiteralPath $stamp -Raw

    Set-Content -LiteralPath (Join-Path $dist 'renderer.css') -Value 'second-css' -Encoding ASCII
    Write-AudiskVencordHealthStamp -InstallDir $temp -DistPath $dist
    $secondStamp = Get-Content -LiteralPath $stamp -Raw

    Assert-True ($firstStamp -ne $secondStamp) 'Rewriting an existing health stamp must persist the new runtime hashes.'
    Assert-True (Test-AudiskVencordDistHealthy -DistPath $dist -HealthStampPath $stamp) 'The rewritten health stamp must verify the current Vencord runtime.'
    Assert-Equal @((Get-ChildItem -LiteralPath $temp -Filter '.audisk-dist-health.sha256.replace-*' -ErrorAction SilentlyContinue)).Count 0 'Health-stamp replacement must not leave its disposable backup behind.'
} finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host '  SKIP: companion userplugin update test needs git on PATH.' -ForegroundColor Yellow
} else {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("audisk-companion-test-" + [guid]::NewGuid().ToString('N'))
    try {
        $git = { param([string[]]$GitArgs) & git @GitArgs 2>$null | Out-Null }
        $upstream = Join-Path $temp 'upstream'
        New-Item -ItemType Directory -Force -Path $upstream | Out-Null
        & $git @('-C', $upstream, 'init', '--quiet', '--initial-branch=main')
        & $git @('-C', $upstream, 'config', 'user.email', 'test@example.invalid')
        & $git @('-C', $upstream, 'config', 'user.name', 'installer regression')
        Set-Content -LiteralPath (Join-Path $upstream 'index.tsx') -Value 'first' -Encoding ASCII
        & $git @('-C', $upstream, 'add', '-A')
        & $git @('-C', $upstream, 'commit', '--quiet', '-m', 'first')

        $userplugins = Join-Path $temp 'install\src\userplugins'
        New-Item -ItemType Directory -Force -Path $userplugins | Out-Null
        & $git @('clone', '--quiet', $upstream, (Join-Path $userplugins 'Companion'))
        & $git @('clone', '--quiet', $upstream, (Join-Path $userplugins 'Diverged'))
        # audisk has its own update path above this one and must never be touched twice
        & $git @('clone', '--quiet', $upstream, (Join-Path $userplugins 'audisk'))
        New-Item -ItemType Directory -Force -Path (Join-Path $userplugins 'CopiedPlugin') | Out-Null
        Set-Content -LiteralPath (Join-Path $userplugins 'CopiedPlugin\index.tsx') -Value 'hand copied' -Encoding ASCII

        # a commit only the local clone has, so a fast-forward is impossible
        $diverged = Join-Path $userplugins 'Diverged'
        & $git @('-C', $diverged, 'config', 'user.email', 'test@example.invalid')
        & $git @('-C', $diverged, 'config', 'user.name', 'installer regression')
        Set-Content -LiteralPath (Join-Path $diverged 'local.txt') -Value 'local work' -Encoding ASCII
        & $git @('-C', $diverged, 'add', '-A')
        & $git @('-C', $diverged, 'commit', '--quiet', '-m', 'local only')
        $divergedHead = (& git -C $diverged rev-parse HEAD)

        Set-Content -LiteralPath (Join-Path $upstream 'index.tsx') -Value 'second' -Encoding ASCII
        & $git @('-C', $upstream, 'add', '-A')
        & $git @('-C', $upstream, 'commit', '--quiet', '-m', 'second')

        $results = @(Update-CompanionUserplugins -InstallDir (Join-Path $temp 'install'))
        $byName = @{}
        foreach ($r in $results) { $byName[$r.Name] = $r }

        Assert-False ($byName.ContainsKey('audisk')) 'audisk has its own update path and must be excluded from the companion sweep.'
        Assert-Equal $byName['Companion'].Status 'updated' 'A companion plugin behind its upstream must be fast-forwarded.'
        Assert-Equal (Get-Content -LiteralPath (Join-Path $userplugins 'Companion\index.tsx') -Raw).Trim() 'second' 'The fast-forwarded companion must have the new upstream content on disk.'
        Assert-Equal $byName['CopiedPlugin'].Status 'skipped' 'A hand-copied plugin folder is not a checkout and must be reported as left alone.'
        Assert-Equal $byName['Diverged'].Status 'failed' 'A plugin that cannot fast-forward must be reported as failed rather than reset.'
        Assert-Equal (& git -C $diverged rev-parse HEAD) $divergedHead 'A failed fast-forward must leave the companion checkout exactly where it was.'
        Assert-True (Test-Path -LiteralPath (Join-Path $diverged 'local.txt')) 'Local work in a companion checkout must survive an update run.'

        $again = @(Update-CompanionUserplugins -InstallDir (Join-Path $temp 'install'))
        $companionAgain = $again | Where-Object { $_.Name -eq 'Companion' }
        Assert-Equal $companionAgain.Status 'current' 'A companion already at upstream must report current rather than updated.'

        Assert-Equal @(Update-CompanionUserplugins -InstallDir (Join-Path $temp 'no-such-install')).Count 0 'A missing userplugins directory must return nothing instead of throwing.'
    } finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("audisk-asar-test-" + [guid]::NewGuid().ToString('N'))
try {
    $resources = Join-Path $temp 'resources'
    New-Item -ItemType Directory -Force -Path $resources | Out-Null
    $asar = Join-Path $resources 'app.asar'
    $backup = Join-Path $resources '_app.asar'
    $ours = Join-Path $temp 'AudiskVencord\dist\patcher.js'
    $other = Join-Path $temp 'OtherVencord\dist\patcher.js'
    $collision = $ours + '.backup'

    $serializedCollision = ([IO.Path]::GetFullPath($collision)).Replace('\', '\\')
    Set-Content -LiteralPath $asar -Value ("require(`"$serializedCollision`")") -Encoding UTF8
    Assert-False (Test-AppAsarPointsToPatcher -AppAsar $asar -PatcherPath $ours) 'A path whose text merely starts with our patcher path must be rejected.'

    $serializedOurs = ([IO.Path]::GetFullPath($ours)).Replace('\', '\\')
    Set-Content -LiteralPath $asar -Value ("require(`"$serializedOurs`")") -Encoding UTF8
    Assert-True (Test-AppAsarPointsToPatcher -AppAsar $asar -PatcherPath $ours) 'Exact AudiskVencord patcher path must be accepted.'
    Assert-False (Test-AppAsarPointsToPatcher -AppAsar $asar -PatcherPath $other) 'A different checkout must not be treated as ours.'

    Set-Content -LiteralPath $backup -Value 'original discord app.asar' -Encoding UTF8
    Assert-True (Restore-VencordAppAsar -AppAsar $asar -PatcherPath $ours) 'Restore helper must replace the Audisk stub with _app.asar.'
    Assert-True (Test-Path -LiteralPath $asar -PathType Leaf) 'Restore helper must leave app.asar present.'
    Assert-False (Test-Path -LiteralPath $backup -PathType Leaf) 'Successful restore must consume _app.asar.'
    Assert-False (Test-AppAsarPointsToPatcher -AppAsar $asar -PatcherPath $ours) 'Restored app.asar must no longer point at AudiskVencord.'

    Set-Content -LiteralPath $asar -Value ("require(`"$serializedOurs`")") -Encoding UTF8
    Assert-False (Restore-VencordAppAsar -AppAsar $asar -PatcherPath $ours) 'Restore must fail when _app.asar is missing instead of reporting success.'
    Assert-True (Test-AppAsarPointsToPatcher -AppAsar $asar -PatcherPath $ours) 'A failed restore with no backup must leave the current Audisk stub untouched.'
} finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }

$tempPackage = Join-Path ([IO.Path]::GetTempPath()) ("audisk-package-" + [guid]::NewGuid().ToString('N') + '.json')
try {
    '{"packageManager":"pnpm@11.9.0","engines":{"node":">=22"}}' | Set-Content -Path $tempPackage -Encoding UTF8
    $pnpm = Get-PnpmInvocation -PackageJsonPath $tempPackage
    Assert-True (-not [string]::IsNullOrWhiteSpace($pnpm.Command)) 'A pnpm command must be resolved.'
    Assert-True ($null -ne (Get-Command $pnpm.Command -ErrorAction SilentlyContinue)) "Resolved pnpm launcher '$($pnpm.Command)' must exist on PATH."
    $nodeMajor = [int]((node -v).TrimStart('v').Split('.')[0])
    if ($nodeMajor -ge 25) {
        Assert-True ($null -ne (Get-Command npx -ErrorAction SilentlyContinue)) 'Node 25 fallback requires npx from the normal Node distribution.'
        $actualPnpmVersion = (& npx --yes pnpm@11.9.0 --version | Select-Object -Last 1).Trim()
        Assert-Equal $actualPnpmVersion '11.9.0' 'The Node 25 npx fallback must execute the exact pnpm version declared by Vencord.'
        if (-not (Get-Command corepack -ErrorAction SilentlyContinue)) { Assert-Equal $pnpm.Command 'npx' 'Without Corepack the resolver must select npx.' }
    }
} finally { Remove-Item $tempPackage -Force -ErrorAction SilentlyContinue }

$temp = Join-Path ([IO.Path]::GetTempPath()) ("audisk-bundle-test-" + [guid]::NewGuid().ToString('N'))
try {
    $vencordRoot = Join-Path $temp 'Roaming\Vencord'
    $customRoot = Join-Path $temp 'Local\OtherVencord'
    New-Item -ItemType Directory -Force -Path $vencordRoot, $customRoot | Out-Null
    $asar = Join-Path $temp 'app.asar'
    $expected = [IO.Path]::GetFullPath((Join-Path $vencordRoot 'dist\patcher.js'))

    $collision = $expected + '.backup'
    $serializedCollision = $collision.Replace('\', '\\')
    Set-Content -LiteralPath $asar -Value ("binary-header require(`"$serializedCollision`") tail") -Encoding UTF8
    & powershell -NoProfile -ExecutionPolicy Bypass -File $BundleVerifier -AppAsar $asar -VencordRoot $vencordRoot
    Assert-Equal $LASTEXITCODE 1 'Bundle verifier must reject a prefix collision instead of substring-matching our patcher path.'

    $serialized = $expected.Replace('\', '\\')
    Set-Content -LiteralPath $asar -Value ("binary-header require(`"$serialized`") tail") -Encoding UTF8
    & powershell -NoProfile -ExecutionPolicy Bypass -File $BundleVerifier -AppAsar $asar -VencordRoot $vencordRoot
    Assert-Equal $LASTEXITCODE 0 'Bundle verifier must accept a stub pointing at the shared Vencord dist.'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $BundleVerifier -AppAsar $asar -VencordRoot $customRoot
    Assert-Equal $LASTEXITCODE 1 'Bundle verifier must reject a stub pointing at a different Vencord checkout.'
    $global:LASTEXITCODE = 0
} finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }

$temp = Join-Path ([IO.Path]::GetTempPath()) ("audisk-bundle-cmd-test-" + [guid]::NewGuid().ToString('N'))
$oldAppData = $env:APPDATA
$oldLocalAppData = $env:LOCALAPPDATA
$oldNoDefaultCurrentDirectory = $env:NoDefaultCurrentDirectoryInExePath
$oldTestStable = $env:AUDISK_TEST_RUNNING_Discord
$oldTestCanary = $env:AUDISK_TEST_RUNNING_DiscordCanary
$oldTestPtb = $env:AUDISK_TEST_RUNNING_DiscordPTB
$oldTestSystemHelper = $env:AUDISK_TEST_RUNNING_DiscordSystemHelper
try {
    $roaming = Join-Path $temp 'Roaming'
    $local = Join-Path $temp 'Local'
    $bundleCopy = Join-Path $temp 'bundle'
    $vencordDist = Join-Path $roaming 'Vencord\dist'
    $stableResources = Join-Path $local 'Discord\app-1.0.100\resources'
    $canaryResources = Join-Path $local 'DiscordCanary\app-1.0.200\resources'
    New-Item -ItemType Directory -Force -Path $bundleCopy, $vencordDist, $stableResources, $canaryResources | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $bundleCopy 'dist') | Out-Null

    Copy-Item (Join-Path $BundleDir 'INSTALL.cmd') $bundleCopy
    Copy-Item $BundleVerifier $bundleCopy

    # The smoke fixture must not observe or kill Discord processes from the host
    # developer machine. Rewrite process/launch calls only in this temporary copy.
    $bundleScriptPath = Join-Path $bundleCopy 'INSTALL.cmd'
    $bundleScript = Get-Content -LiteralPath $bundleScriptPath -Raw
    $bundleScript = $bundleScript.Replace("`r`n", "`n")
    $bundleScript = [regex]::Replace($bundleScript, '(?m)^tasklist /FI "IMAGENAME eq ([^"]+)"[^\r\n]*$', 'call :audisk_test_is_running $1')
    $bundleScript = [regex]::Replace($bundleScript, '(?m)^taskkill /F /IM ([^ >]+)[^\r\n]*$', 'call :audisk_test_kill $1')
    # Leading whitespace matters: the start inside :startFallback sits in a parenthesised if
    # block and is indented, so an anchor of ^start left it in the fixture unrewritten.
    $bundleScript = [regex]::Replace($bundleScript, '(?m)^[ \t]*start "" "[^"]+\\Update\.exe" --processStart ([^\r\n]+)$', 'call :audisk_test_start $1')
    $bundleScript += @'

:: test-only process harness injected into the fixture copy
:audisk_test_is_running
if /I "%~n1"=="Discord" if "%AUDISK_TEST_RUNNING_Discord%"=="1" exit /b 0
if /I "%~n1"=="DiscordCanary" if "%AUDISK_TEST_RUNNING_DiscordCanary%"=="1" exit /b 0
if /I "%~n1"=="DiscordPTB" if "%AUDISK_TEST_RUNNING_DiscordPTB%"=="1" exit /b 0
if /I "%~n1"=="DiscordSystemHelper" if "%AUDISK_TEST_RUNNING_DiscordSystemHelper%"=="1" exit /b 0
exit /b 1

:audisk_test_kill
if /I "%~n1"=="Discord" set "AUDISK_TEST_RUNNING_Discord=0"
if /I "%~n1"=="DiscordCanary" set "AUDISK_TEST_RUNNING_DiscordCanary=0"
if /I "%~n1"=="DiscordPTB" set "AUDISK_TEST_RUNNING_DiscordPTB=0"
if /I "%~n1"=="DiscordSystemHelper" set "AUDISK_TEST_RUNNING_DiscordSystemHelper=0"
exit /b 0

:audisk_test_start
exit /b 0
'@
    Assert-False ($bundleScript -match '(?m)^(tasklist|taskkill)\b') 'Bundle smoke fixture must not use the host process table or kill host Discord processes.'
    # The process lookups were guarded and start was not, which is how the indented one went
    # unnoticed. It never fired because this fixture installs two flavors and :startFallback
    # only runs with exactly one, but a one-install fixture would have launched a real client
    # from a test whose whole contract is that it launches nothing.
    Assert-False ($bundleScript -match '(?m)^[ \t]*start "" "[^"]+\\Update\.exe"') 'Bundle smoke fixture must not launch a real Discord client.'
    Set-Content -LiteralPath $bundleScriptPath -Value $bundleScript -Encoding ASCII

    Set-Content -LiteralPath (Join-Path $bundleCopy 'dist\patcher.js') -Value "// Vencord deadbeef`n// Standalone: true`n// Updater Disabled: true`naudisk-patcher" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $bundleCopy 'dist\preload.js') -Value "// Vencord deadbeef`naudisk-preload" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $bundleCopy 'dist\renderer.js') -Value "// Vencord deadbeef`nAudisk`naudisk-renderer" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $bundleCopy 'dist\renderer.css') -Value 'audisk-css' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $vencordDist 'patcher.js') -Value 'official-patcher' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $vencordDist 'preload.js') -Value 'official-preload' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $vencordDist 'renderer.js') -Value 'official-renderer' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $vencordDist 'renderer.css') -Value 'official-css' -Encoding ASCII

    New-Item -ItemType File -Force -Path (Join-Path $local 'Discord\Update.exe'), (Join-Path $local 'DiscordCanary\Update.exe') | Out-Null
    Set-Content -LiteralPath (Join-Path $stableResources 'app.asar') -Value 'plain discord app' -Encoding UTF8
    $sharedPatcher = [IO.Path]::GetFullPath((Join-Path $vencordDist 'patcher.js'))
    $serializedSharedPatcher = $sharedPatcher.Replace('\', '\\')
    Set-Content -LiteralPath (Join-Path $canaryResources 'app.asar') -Value ("require(`"$serializedSharedPatcher`")") -Encoding UTF8

    $env:APPDATA = $roaming
    $env:LOCALAPPDATA = $local
    $env:NoDefaultCurrentDirectoryInExePath = '1'
    $env:AUDISK_TEST_RUNNING_Discord = '0'
    $env:AUDISK_TEST_RUNNING_DiscordCanary = '1'
    $env:AUDISK_TEST_RUNNING_DiscordPTB = '0'
    $env:AUDISK_TEST_RUNNING_DiscordSystemHelper = '0'
    Push-Location $bundleCopy
    try {
        & cmd.exe /d /c '.\INSTALL.cmd <nul'
        $bundleExit = $LASTEXITCODE
    } finally { Pop-Location }

    Assert-Equal $bundleExit 0 'Simple bundle INSTALL.cmd must complete successfully in the isolated Canary smoke test.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $vencordDist 'patcher.js') -Raw).Contains('audisk-patcher')) 'Bundle installer must copy the bundled patcher into the shared Vencord dist.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $vencordDist 'renderer.js') -Raw).Contains('audisk-renderer')) 'Bundle installer must copy the bundled renderer into the shared Vencord dist.'
    $backupDist = Join-Path $roaming 'Vencord\dist.audisk-backup'
    Assert-Equal ((Get-Content -LiteralPath (Join-Path $backupDist 'patcher.js') -Raw).Trim()) 'official-patcher' 'Bundle installer must preserve the original patcher in its recovery backup.'
    Assert-Equal ((Get-Content -LiteralPath (Join-Path $backupDist 'renderer.js') -Raw).Trim()) 'official-renderer' 'Bundle installer must preserve the original renderer in its recovery backup.'
} finally {
    $env:APPDATA = $oldAppData
    $env:LOCALAPPDATA = $oldLocalAppData
    $env:NoDefaultCurrentDirectoryInExePath = $oldNoDefaultCurrentDirectory
    $env:AUDISK_TEST_RUNNING_Discord = $oldTestStable
    $env:AUDISK_TEST_RUNNING_DiscordCanary = $oldTestCanary
    $env:AUDISK_TEST_RUNNING_DiscordPTB = $oldTestPtb
    $env:AUDISK_TEST_RUNNING_DiscordSystemHelper = $oldTestSystemHelper
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("audisk-runtime-uninstall-test-" + [guid]::NewGuid().ToString('N'))
$oldLocalAppData = $env:LOCALAPPDATA
$oldAppData = $env:APPDATA
try {
    $runtimeRoot = Join-Path $temp 'AudiskVencord'
    $local = Join-Path $temp 'local'
    $roaming = Join-Path $temp 'roaming'
    $resources = Join-Path $local 'DiscordCanary\app-1.0.200\resources'
    New-Item -ItemType Directory -Force -Path $runtimeRoot, $resources, $roaming | Out-Null
    Copy-Item -LiteralPath $RuntimeUninstall -Destination (Join-Path $runtimeRoot '.audisk-uninstall.ps1') -Force
    Set-Content -LiteralPath (Join-Path $resources 'app.asar') -Value 'official-discord' -Encoding ASCII
    $env:LOCALAPPDATA = $local
    $env:APPDATA = $roaming
    $runtimeCopy = Join-Path $runtimeRoot '.audisk-uninstall.ps1'
    $shellExe = (Get-Process -Id $PID).Path
    $statePath = Join-Path $runtimeRoot '.audisk-install-state.json'

    @{ stateVersion = 1; branch = 'canary'; hadVencordBefore = $false } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    $keepPlain = @(& $shellExe -NoProfile -ExecutionPolicy Bypass -File $runtimeCopy -DryRun)
    Assert-True ($keepPlain -contains 'PLAN=keep_plain_vencord') 'A clean-machine install must keep plain Vencord when the uninstall checkbox is cleared.'

    $removeAll = @(& $shellExe -NoProfile -ExecutionPolicy Bypass -File $runtimeCopy -DryRun -RemoveVencord)
    Assert-True ($removeAll -contains 'PLAN=remove_vencord') 'Checking Uninstall Vencord too must select the full Vencord removal path.'

    $oldPatcher = Join-Path $temp 'preexisting-vencord\dist\patcher.js'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $oldPatcher) | Out-Null
    Set-Content -LiteralPath $oldPatcher -Value '// old Vencord patcher' -Encoding ASCII
    $serializedOldPatcher = $oldPatcher.Replace('\', '\\')
    [IO.File]::WriteAllText((Join-Path $runtimeRoot '.audisk-preinstall-app.asar'), "require(`"$serializedOldPatcher`")", (New-Object Text.UTF8Encoding($false)))
    @{ stateVersion = 1; branch = 'canary'; hadVencordBefore = $true } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    $restorePrevious = @(& $shellExe -NoProfile -ExecutionPolicy Bypass -File $runtimeCopy -DryRun)
    Assert-True ($restorePrevious -contains 'PLAN=restore_previous_vencord') 'A valid saved pre-Audisk Vencord patch must be restored when Vencord originally existed.'
} finally {
    $env:LOCALAPPDATA = $oldLocalAppData
    $env:APPDATA = $oldAppData
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
}

$install = Get-Content (Join-Path $DevbuildDir 'install-autoupdate.ps1') -Raw
$update = Get-Content (Join-Path $DevbuildDir 'update.ps1') -Raw
$uninstall = Get-Content (Join-Path $DevbuildDir 'uninstall.ps1') -Raw
$helperText = Get-Content $Helper -Raw
$devReadme = Get-Content (Join-Path $DevbuildDir 'README.txt') -Raw
$bundle = Get-Content (Join-Path $BundleDir 'INSTALL.cmd') -Raw
$workflowText = Get-Content $Workflow -Raw
$packagerText = Get-Content $Packager -Raw
$runtimeUninstallText = Get-Content $RuntimeUninstall -Raw
$runtimeUninstallLauncherText = Get-Content $RuntimeUninstallLauncher -Raw
$rootInstallCmdText = Get-Content $RootInstallCmd -Raw
$rootInstallText = Get-Content $RootInstall -Raw
$menuInstallCmdText = Get-Content $MenuInstallCmd -Raw
$menuInstallText = Get-Content $MenuInstall -Raw

Assert-True ($rootInstallCmdText -match 'install\.ps1.*%\*') 'Root INSTALL.cmd must forward arguments to install.ps1.'
Assert-True ($menuInstallCmdText -match 'install\.ps1.*%\*') 'Packaged INSTALL.cmd must forward arguments to the same menu wrapper.'
Assert-True ($rootInstallText -match 'tools\\audisk-devbuild-installer\\install\.ps1') 'Root install.ps1 must delegate to the packaged canonical menu.'
Assert-True ($menuInstallText -match "Number = '1'.*Branch = 'stable'") 'Installer option 1 must map to Discord Stable.'
Assert-True ($menuInstallText -match "Number = '2'.*Branch = 'canary'") 'Installer option 2 must map to Discord Canary.'
Assert-True ($menuInstallText -match "Number = '3'.*Branch = 'ptb'") 'Installer option 3 must map to Discord PTB.'
Assert-True ($menuInstallText -match 'Multi-select is supported') 'Installer menu must tell users that multiple clients can be selected.'
Assert-True ($menuInstallText -match 'Examples: 1 3') 'Installer menu must show a concrete multi-select example.'
Assert-True ($menuInstallText -match "-split '\[,;\\s\]\+'") 'Installer must parse spaces, commas and semicolons as multi-select separators.'
$retiredBrandPattern = [regex]::Escape(('Audi' + 'stask')) + '|' + [regex]::Escape(('Ori' + 'on'))
Assert-False ($rootInstallCmdText -match $retiredBrandPattern) 'Public root INSTALL.cmd must contain no retired-product migration logic.'
Assert-False ($rootInstallText -match $retiredBrandPattern) 'Public root install.ps1 must contain no retired-product migration logic.'
Assert-False ($menuInstallCmdText -match $retiredBrandPattern) 'Packaged INSTALL.cmd must contain no retired-product migration logic.'
Assert-False ($menuInstallText -match $retiredBrandPattern) 'Packaged install.ps1 must contain no retired-product migration logic.'

$tempMenu = Join-Path ([IO.Path]::GetTempPath()) ("audisk-install-selector-test-" + [guid]::NewGuid().ToString('N'))
$oldMenuLocalAppData = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = $tempMenu
    foreach ($name in @('Discord', 'DiscordCanary', 'DiscordPTB')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $tempMenu $name) | Out-Null
        Set-Content -LiteralPath (Join-Path $tempMenu "$name\Update.exe") -Value '' -Encoding ASCII
    }
    foreach ($case in @(
        @{ Branch = 'stable'; Expected = 'BRANCH=stable' },
        @{ Branch = 'canary'; Expected = 'BRANCH=canary' },
        @{ Branch = 'ptb'; Expected = 'BRANCH=ptb' }
    )) {
        $output = @(& $RootInstall -DryRun -DiscordBranch $case.Branch)
        Assert-True ($output -contains $case.Expected) "Canonical installer failed selector mapping for $($case.Branch)."
    }

    $multiOutput = @(& $RootInstall -DryRun -DiscordBranch @('stable', 'ptb'))
    Assert-True ($multiOutput -contains 'BRANCH=stable') 'Multi-select must include Stable when Stable is selected.'
    Assert-True ($multiOutput -contains 'BRANCH=ptb') 'Multi-select must include PTB when PTB is selected.'
    Assert-False ($multiOutput -contains 'BRANCH=canary') 'Multi-select must not install an unselected branch.'
    Assert-Equal @($multiOutput | Where-Object { $_ -like 'BRANCH=*' }).Count 2 'Multi-select must emit each selected branch exactly once.'
} finally {
    $env:LOCALAPPDATA = $oldMenuLocalAppData
    Remove-Item $tempMenu -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($pair in @(@{Name='install-autoupdate.ps1';Text=$install},@{Name='update.ps1';Text=$update},@{Name='uninstall.ps1';Text=$uninstall})) {
    Assert-True ($pair.Text -match 'installer-common\.ps1') "$($pair.Name) must use the shared tested installer helpers."
    Assert-False ($pair.Text -match 'Get-Process[^\r\n]*\bUpdate\b') "$($pair.Name) must not kill every process named Update.exe."
}

Assert-True ($helperText -match 'remaining' -and $helperText -match 'throw') 'Stop-DiscordProcesses must fail if Discord is still alive after its timeout.'
Assert-True ($helperText -match 'serializedExpected') 'app.asar ownership verification must compare the complete JSON-quoted patcher path.'
Assert-True ($helperText -match 'Restore-VencordAppAsar') 'Shared helper must expose a verified app.asar restore path.'
Assert-True ($helperText -match 'Write-AudiskVencordHealthStamp') 'Managed Vencord builds must persist a runtime health stamp after semantic verification.'
Assert-True ($helperText -match 'Test-AudiskVencordDistHealthy') 'Transactional rollback must require a previously stamped healthy dist.'
Assert-True ($helperText -match 'Get-FileHash[^\r\n]*SHA256') 'The Vencord health stamp must bind the runtime files with SHA-256 hashes.'
Assert-True ($install -match 'Get-DiscordReopenSet') 'Install must derive its reopen set from the patched target plus previously running clients.'
Assert-True ($install -match 'Test-AppAsarPointsToPatcher') 'Install verification must use the exact AudiskVencord patcher path.'
Assert-False ($install -match "-like '\*AudiskVencord\*'") 'Install verification must not use a loose AudiskVencord substring.'
Assert-False ($install -match 'corepack is missing') 'Install must not reject supported Node versions solely because bundled Corepack is absent.'
Assert-True ($install -match 'Invoke-Pnpm') 'Install must use the shared pnpm invocation that supports Node 25+.'
Assert-True ($install -match 'Restore-VencordAppAsar') 'Install rollback must use the checked restore helper when Vencord unpatch does not verify.'
Assert-True ($install -match 'rollback could not be verified') 'Install must fail closed when rollback cannot be verified.'
Assert-True ($install -match 'hadVencordBefore') 'Install must record whether Vencord existed before Audisk so dashboard uninstall can choose a safe default.'
Assert-True ($install -match '\.audisk-install-state\.json') 'Install must persist the original-client state for dashboard uninstall.'
Assert-True ($install -match 'uninstall-runtime\.ps1') 'Install must deploy the dashboard uninstall helper.'
Assert-True ($runtimeUninstallText -match 'Test-SnapshotPatcherExists') 'Dashboard uninstall must verify a saved pre-Audisk Vencord target still exists before restoring it.'
Assert-True ($runtimeUninstallText -match 'corepack pnpm build') 'Keeping Vencord on a clean-machine install must rebuild plain Vencord after removing Audisk.'
Assert-True ($runtimeUninstallText -match 'Restore-OfficialDiscord') 'Removing Vencord too must restore the official Discord client.'
Assert-True ($runtimeUninstallLauncherText -match 'audisk-uninstall-request\.json') 'The dashboard launcher must consume the confirmed uninstall options written by the native helper.'
Assert-True ($update -match '\$fetchCode') 'Plugin update fallback must record git fetch success explicitly.'
Assert-True ($update -match '\$resetCode') 'Plugin update fallback must record git reset success explicitly.'
Assert-True ($update -match '\$fetchCode\s*-eq\s*0\s*-and\s*\$resetCode\s*-eq\s*0') 'A stale FETCH_HEAD reset must not be reported as a successful plugin update.'
Assert-True ($update -match 'keeping the existing checkout') 'A transient GitHub failure must preserve an existing usable plugin checkout instead of deleting it.'
Assert-True ($update -match '\$existingCheckoutUsable') 'Update must explicitly gate preservation on a usable existing plugin checkout.'
Assert-True ($update -match 'Get-RunningDiscordFlavors') 'Update must remember which Discord flavor(s) were running before restart.'
Assert-True ($update -match 'Start-DiscordFlavors') 'Update must reopen the same running flavor(s), not the first installed flavor.'
Assert-True ($uninstall -match 'Restore-VencordAppAsar') 'Uninstall must only count a restore after the checked restore helper succeeds.'
Assert-False ($uninstall -match "-notlike '\*AudiskVencord\*'") 'Uninstall must not use a loose AudiskVencord substring.'
Assert-True ($uninstall -match 'Do NOT delete') 'A partial uninstall must warn users not to delete AudiskVencord before Repair/Uninstall succeeds.'
Assert-True ($uninstall -match 'Discord was left closed') 'A partial uninstall must fail closed instead of reopening a potentially broken client.'
Assert-True ($uninstall -match 'Get-RunningDiscordFlavors') 'Uninstall must remember which Discord flavor(s) were running before restart.'
Assert-True ($uninstall -match 'Start-DiscordFlavors') 'Successful uninstall must reopen the same running flavor(s), not the first installed flavor.'
Assert-True ($devReadme -match 'DiscordCanary') 'Recovery documentation must include the Canary install root.'
Assert-True ($devReadme -match 'DiscordPTB') 'Recovery documentation must include the PTB install root.'
Assert-False ($packagerText.Contains("StartsWith('_')")) 'Release packaging must not ignore underscore-prefixed userplugin entries because native discovery still scans them.'
Assert-False ($packagerText.Contains("StartsWith('.')")) 'Release packaging must not ignore dot-prefixed userplugin entries because native discovery still scans them.'
Assert-True ($packagerText.Contains('additional Vencord userplugin entries are present')) 'Release packaging must fail closed on foreign userplugin entries instead of relying on a marker blacklist.'

foreach ($needle in @('Discord.exe','DiscordCanary.exe','DiscordPTB.exe','WAS_CANARY','WAS_PTB','PATCHED_STABLE','PATCHED_CANARY','PATCHED_PTB','check_vencord_target','verify-vencord-target.ps1','discord_still_running','backup_failed','copy_failed','restore_failed','invalid_backup')) {
    Assert-True ($bundle.Contains($needle)) "Simple bundle installer is missing '$needle'."
}
Assert-True ($bundle -match 'WAS_CANARY.+PATCHED_CANARY') 'Running Canary must be rejected when Canary itself does not point at the shared Vencord build.'
Assert-True ($bundle -match 'WAS_PTB.+PATCHED_PTB') 'Running PTB must be rejected when PTB itself does not point at the shared Vencord build.'
Assert-True ($bundle.Contains('goto :discord_still_running')) 'Bundle must verify taskkill actually closed Discord before copying Vencord files.'
Assert-True ($bundle.Contains('Could not create a complete Vencord backup')) 'Bundle must fail safely when its first backup cannot be completed.'
Assert-True ($bundle.Contains('Automatic rollback also failed')) 'Bundle must surface rollback failure instead of claiming the original Vencord was restored.'
Assert-True ($bundle.Contains('call :check_dist_complete "%APPDATA%\Vencord\dist.audisk-backup"')) 'Bundle recovery validation must apply the complete runtime manifest to its saved backup.'
Assert-True ($workflowText.Contains('tools/package-release.ps1')) 'Installer CI must run when release packaging changes.'
Assert-True ($workflowText.Contains('shell: powershell')) 'Installer CI must exercise Windows PowerShell 5.1, which the shipped CMD wrappers use.'
Assert-True ($workflowText.Contains('shell: pwsh')) 'Installer CI must also exercise PowerShell 7.'

Write-Host 'Installer regression tests passed.' -ForegroundColor Green
exit 0
