<#
  Uninstall the Audisk Quests "auto-update edition".

  This does not depend on the AudiskVencord clone surviving: it restores Discord's
  original app.asar directly for every supported flavor, but only where the stub
  actually points at this AudiskVencord install.
#>
$ErrorActionPreference = 'Continue'
$InstallDir = Join-Path $env:LOCALAPPDATA 'AudiskVencord'
$BootstrapRoot = Join-Path $env:LOCALAPPDATA 'AudiskBootstrap'

$Common = Join-Path $PSScriptRoot 'installer-common.ps1'
if (-not (Test-Path -LiteralPath $Common -PathType Leaf)) {
    Write-Host 'installer-common.ps1 is missing. Re-download/extract the full installer zip.' -ForegroundColor Red
    try { Read-Host 'Press Enter to close' } catch {}
    exit 1
}
. $Common

function Fail($m) {
    Write-Host "ERROR: $m" -ForegroundColor Red
    try { Read-Host 'Press Enter to close' } catch {}
    exit 1
}

Write-Host 'Audisk Quests - uninstalling the auto-update edition...' -ForegroundColor Cyan

$runningBefore = @(Get-RunningDiscordFlavors)
try { Stop-DiscordProcesses } catch { Fail $_.Exception.Message }

$restored = 0; $stuck = 0
$patcherPath = Join-Path $InstallDir 'dist\patcher.js'
foreach ($branch in @('stable', 'canary', 'ptb')) {
    $root = Get-DiscordRoot -Branch $branch
    Get-ChildItem (Join-Path $root 'app-*\resources\app.asar') -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not (Test-AppAsarPointsToPatcher -AppAsar $_.FullName -PatcherPath $patcherPath)) { return }
        if (Restore-VencordAppAsar -AppAsar $_.FullName -PatcherPath $patcherPath) {
            $restored++
        } else {
            $stuck++
        }
    }
}

Write-Host ''
if ($stuck -gt 0) {
    Write-Host "Couldn't fully restore $stuck Discord install(s)." -ForegroundColor Red
    Write-Host 'Discord was left closed because at least one Audisk patch could not be restored safely.' -ForegroundColor Red
    Write-Host 'Run the official Vencord installer (vencord.dev/download) and pick Uninstall/Repair before reopening Discord.' -ForegroundColor Red
    Write-Host "Do NOT delete $InstallDir until Repair/Uninstall has completed successfully." -ForegroundColor Red
    Write-Host ''
    try { Read-Host 'Press Enter to close' } catch {}
    exit 1
} elseif ($restored -gt 0) {
    Write-Host 'Discord restored to its original state.' -ForegroundColor Green
} else {
    Write-Host 'Nothing of ours was patched into Discord (already clean).' -ForegroundColor Green
}

$failedReopen = @(Start-DiscordFlavors -Branches $runningBefore)
if ($failedReopen.Count -gt 0) {
    Write-Host "Uninstall succeeded, but these Discord clients did not reopen automatically: $($failedReopen -join ', ')." -ForegroundColor Yellow
    Write-Host 'Start them manually. If one still will not open, run the official Vencord installer and choose Repair.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "You can now delete this folder if you want: $InstallDir" -ForegroundColor DarkGray
if (Test-Path -LiteralPath $BootstrapRoot -PathType Container) {
    Write-Host "Audisk's portable Node.js/Git cache can also be deleted: $BootstrapRoot" -ForegroundColor DarkGray
}
Write-Host ''
try { Read-Host 'Press Enter to close' } catch {}
