param(
    [switch]$SkipInject,
    [switch]$DryRun,
    [ValidateSet('stable', 'canary', 'ptb')][string]$DiscordBranch
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
$MenuInstaller = Join-Path $RepoRoot 'tools\audisk-devbuild-installer\install.ps1'

if (-not (Test-Path -LiteralPath $MenuInstaller -PathType Leaf)) {
    throw "Audisk installer was not found: $MenuInstaller"
}

$arguments = @{
    LocalPluginSource = $RepoRoot
}
if ($SkipInject) { $arguments.SkipInject = $true }
if ($DryRun) { $arguments.DryRun = $true }
if ($DiscordBranch) { $arguments.DiscordBranch = $DiscordBranch }

& $MenuInstaller @arguments
exit $LASTEXITCODE
