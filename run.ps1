param(
    [switch]$SkipInject
)

$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot
$Installer = Join-Path $RepoRoot 'tools\audisk-devbuild-installer\install-autoupdate.ps1'

if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) {
    throw "Audisk installer was not found: $Installer"
}

Write-Host 'Audisk by Kiraa' -ForegroundColor Magenta
Write-Host 'Installing to Discord Canary...' -ForegroundColor Cyan

$installerArgs = @{
    DiscordBranch = 'canary'
    LocalPluginSource = $RepoRoot
}
if ($SkipInject) { $installerArgs.SkipInject = $true }

& $Installer @installerArgs
if (-not $?) { exit 1 }
exit 0
