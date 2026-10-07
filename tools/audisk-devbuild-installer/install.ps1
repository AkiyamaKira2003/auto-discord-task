param(
    [switch]$SkipInject,
    [switch]$DryRun,
    [string]$LocalPluginSource,
    [ValidateSet('stable', 'canary', 'ptb')][string[]]$DiscordBranch
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

function Resolve-FlavorSelection([string]$Answer) {
    $tokens = @($Answer -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($tokens.Count -eq 0) { return @() }

    $seen = @{}
    $resolved = @()
    foreach ($token in $tokens) {
        $candidate = $flavors | Where-Object Number -eq $token | Select-Object -First 1
        if (-not $candidate) { return @() }
        if (-not $seen.ContainsKey($candidate.Number)) {
            $seen[$candidate.Number] = $true
            $resolved += $candidate
        }
    }
    return @($resolved)
}

function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host '==============================================================' -ForegroundColor DarkCyan
    Write-Host '                 Audisk by Kiraa - Installer' -ForegroundColor Cyan
    Write-Host '==============================================================' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host 'Choose the Discord client(s) to install Audisk into:' -ForegroundColor White
    Write-Host ''
    foreach ($flavor in $flavors) {
        $installed = Test-FlavorInstalled $flavor
        $state = if ($installed) { 'installed' } else { 'not installed' }
        $color = if ($installed) { 'Green' } else { 'DarkGray' }
        Write-Host ("  {0}. {1,-18} [{2}]" -f $flavor.Number, $flavor.Label, $state) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host 'Multi-select is supported.' -ForegroundColor Cyan
    Write-Host 'Examples: 1 3    1,3    1 2 3' -ForegroundColor DarkCyan
    Write-Host ''
}

$selected = @()
if ($DiscordBranch -and $DiscordBranch.Count -gt 0) {
    $seenBranches = @{}
    foreach ($branch in $DiscordBranch) {
        $candidate = $flavors | Where-Object Branch -eq $branch | Select-Object -First 1
        if (-not $candidate) { throw "Unsupported Discord branch: $branch" }
        if (-not (Test-FlavorInstalled $candidate)) {
            throw "$($candidate.Label) is not installed on this PC."
        }
        if (-not $seenBranches.ContainsKey($candidate.Branch)) {
            $seenBranches[$candidate.Branch] = $true
            $selected += $candidate
        }
    }
} else {
    while ($selected.Count -eq 0) {
        Show-Menu
        $answer = (Read-Host 'Select one or more clients').Trim()
        $candidates = @(Resolve-FlavorSelection $answer)
        if ($candidates.Count -eq 0) {
            Write-Host 'Choose 1, 2, 3, or combine them, for example: 1 3' -ForegroundColor Yellow
            Start-Sleep -Milliseconds 900
            continue
        }

        $missing = @($candidates | Where-Object { -not (Test-FlavorInstalled $_) })
        if ($missing.Count -gt 0) {
            Write-Host ("Not installed: {0}. Choose only installed clients." -f (($missing | ForEach-Object Label) -join ', ')) -ForegroundColor Yellow
            Start-Sleep -Milliseconds 1200
            continue
        }
        $selected = $candidates
    }
}

Write-Host ''
Write-Host ("Selected: {0}" -f (($selected | ForEach-Object Label) -join ', ')) -ForegroundColor Cyan
Write-Host ''

if ($DryRun) {
    foreach ($target in $selected) {
        Write-Output ("BRANCH={0}" -f $target.Branch)
        Write-Output ("CLIENT={0}" -f $target.Label)
    }
    exit 0
}

for ($i = 0; $i -lt $selected.Count; $i++) {
    $target = $selected[$i]
    Write-Host ("[{0}/{1}] Installing Audisk into {2}..." -f ($i + 1), $selected.Count, $target.Label) -ForegroundColor Cyan
    Write-Host ''

    $arguments = @{
        DiscordBranch = $target.Branch
    }
    if ($SkipInject) { $arguments.SkipInject = $true }
    if (-not [string]::IsNullOrWhiteSpace($LocalPluginSource)) {
        $arguments.LocalPluginSource = $LocalPluginSource
    }

    & $Backend @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Audisk installation failed for $($target.Label) with exit code $LASTEXITCODE."
    }
    Write-Host ''
}

Write-Host ("Audisk installation completed for: {0}" -f (($selected | ForEach-Object Label) -join ', ')) -ForegroundColor Green
exit 0
