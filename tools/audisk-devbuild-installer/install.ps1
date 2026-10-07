param(
    [switch]$SkipInject,
    [switch]$DryRun,
    [string]$LocalPluginSource,
    [ValidateSet('stable', 'canary', 'ptb')][string]$DiscordBranch
)

$ErrorActionPreference = 'Stop'
$Backend = Join-Path $PSScriptRoot 'install-autoupdate.ps1'
if (-not (Test-Path -LiteralPath $Backend -PathType Leaf)) {
    throw "Audisk install backend was not found: $Backend"
}

$flavors = @(
    [pscustomobject]@{ Number = '1'; Branch = 'stable'; Label = 'Discord Stable'; Root = (Join-Path $env:LOCALAPPDATA 'Discord') },
    [pscustomobject]@{ Number = '2'; Branch = 'canary'; Label = 'Discord Canary'; Root = (Join-Path $env:LOCALAPPDATA 'DiscordCanary') },
    [pscustomobject]@{ Number = '3'; Branch = 'ptb'; Label = 'Discord PTB'; Root = (Join-Path $env:LOCALAPPDATA 'DiscordPTB') }
)

function Test-FlavorInstalled($flavor) {
    Test-Path -LiteralPath (Join-Path $flavor.Root 'Update.exe') -PathType Leaf
}

function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host '==============================================================' -ForegroundColor DarkCyan
    Write-Host '                 Audisk by Kiraa - Installer' -ForegroundColor Cyan
    Write-Host '==============================================================' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host 'Choose the Discord client to install Audisk into:' -ForegroundColor White
    Write-Host ''
    foreach ($flavor in $flavors) {
        $installed = Test-FlavorInstalled $flavor
        $state = if ($installed) { 'installed' } else { 'not installed' }
        $color = if ($installed) { 'Green' } else { 'DarkGray' }
        Write-Host ("  {0}. {1,-18} [{2}]" -f $flavor.Number, $flavor.Label, $state) -ForegroundColor $color
    }
    Write-Host ''
}

$selected = $null
if ($DiscordBranch) {
    $selected = $flavors | Where-Object Branch -eq $DiscordBranch | Select-Object -First 1
    if (-not (Test-FlavorInstalled $selected)) {
        throw "$($selected.Label) is not installed on this PC."
    }
} else {
    while (-not $selected) {
        Show-Menu
        $answer = (Read-Host 'Select 1, 2 or 3').Trim()
        $candidate = $flavors | Where-Object Number -eq $answer | Select-Object -First 1
        if (-not $candidate) {
            Write-Host 'Please choose 1, 2 or 3.' -ForegroundColor Yellow
            Start-Sleep -Milliseconds 700
            continue
        }
        if (-not (Test-FlavorInstalled $candidate)) {
            Write-Host "$($candidate.Label) is not installed. Choose another client." -ForegroundColor Yellow
            Start-Sleep -Milliseconds 1000
            continue
        }
        $selected = $candidate
    }
}

Write-Host ''
Write-Host ("Installing Audisk into {0}..." -f $selected.Label) -ForegroundColor Cyan
Write-Host ''

if ($DryRun) {
    Write-Output ("BRANCH={0}" -f $selected.Branch)
    Write-Output ("CLIENT={0}" -f $selected.Label)
    exit 0
}

$args = @{
    DiscordBranch = $selected.Branch
}
if ($SkipInject) { $args.SkipInject = $true }
if (-not [string]::IsNullOrWhiteSpace($LocalPluginSource)) {
    $args.LocalPluginSource = $LocalPluginSource
}

& $Backend @args
exit $LASTEXITCODE
