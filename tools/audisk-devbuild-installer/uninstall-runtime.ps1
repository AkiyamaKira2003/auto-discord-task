param(
    [switch]$RemoveVencord,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$InstallDir = $PSScriptRoot
$StatePath = Join-Path $InstallDir '.audisk-install-state.json'
$SnapshotPath = Join-Path $InstallDir '.audisk-preinstall-app.asar'
$RequestPath = Join-Path $InstallDir '.audisk-uninstall-request.json'
$OwnPatcher = Join-Path $InstallDir 'dist\patcher.js'
$LogPath = Join-Path $env:TEMP 'Audisk-uninstall.log'

function Log([string]$Message) {
    try { Add-Content -LiteralPath $LogPath -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) } catch {}
}

function Get-DiscordInfo([string]$Branch) {
    switch ($Branch) {
        'stable' { return [pscustomobject]@{ Directory = 'Discord'; Process = 'Discord' } }
        'ptb'    { return [pscustomobject]@{ Directory = 'DiscordPTB'; Process = 'DiscordPTB' } }
        default  { return [pscustomobject]@{ Directory = 'DiscordCanary'; Process = 'DiscordCanary' } }
    }
}

function Get-Resources([string]$DiscordRoot) {
    $bestKey = $null
    $best = $null
    Get-ChildItem -LiteralPath $DiscordRoot -Directory -Filter 'app-*' -ErrorAction SilentlyContinue | ForEach-Object {
        $resources = Join-Path $_.FullName 'resources'
        if (-not (Test-Path -LiteralPath $resources -PathType Container)) { return }
        $key = Join-Path $resources 'app'
        if ($null -eq $bestKey -or [string]::CompareOrdinal($key, $bestKey) -gt 0) {
            $bestKey = $key
            $best = $resources
        }
    }
    return $best
}

function Test-PointsToOwnPatcher([string]$AppAsar) {
    if (-not (Test-Path -LiteralPath $AppAsar -PathType Leaf)) { return $false }
    try {
        $text = [IO.File]::ReadAllText($AppAsar)
        $full = [IO.Path]::GetFullPath($OwnPatcher)
        return $text.IndexOf($full, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $text.IndexOf($full.Replace('\', '\\'), [StringComparison]::OrdinalIgnoreCase) -ge 0
    } catch {
        return $false
    }
}

function Test-SnapshotPatcherExists([string]$Snapshot) {
    if (-not (Test-Path -LiteralPath $Snapshot -PathType Leaf)) { return $false }
    try {
        $text = [IO.File]::ReadAllText($Snapshot)
        $match = [regex]::Match($text, 'require\("(?<path>[A-Za-z]:\\(?:\\.|[^"\\])+)"\)')
        if (-not $match.Success) { return $false }
        $encoded = $match.Groups['path'].Value
        $decoded = $encoded.Replace('\\', '\')
        return Test-Path -LiteralPath $decoded -PathType Leaf
    } catch {
        return $false
    }
}

function Stop-Discord {
    Get-Process Discord, DiscordCanary, DiscordPTB, DiscordSystemHelper -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 900
}

function Start-Discord([string]$Branch) {
    $info = Get-DiscordInfo $Branch
    $root = Join-Path $env:LOCALAPPDATA $info.Directory
    $update = Join-Path $root 'Update.exe'
    if (Test-Path -LiteralPath $update -PathType Leaf) {
        Start-Process -FilePath $update -ArgumentList '--processStart', ($info.Process + '.exe') -ErrorAction SilentlyContinue | Out-Null
    }
}

function Remove-AudiskSettings {
    $path = Join-Path $env:APPDATA 'Vencord\settings\settings.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    try {
        $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($data.plugins -and $data.plugins.PSObject.Properties['Audisk']) {
            $data.plugins.PSObject.Properties.Remove('Audisk')
            [IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding($false)))
        }
    } catch {
        Log ("Could not clean Vencord settings: " + $_.Exception.Message)
    }
}

function Restore-OfficialDiscord([string]$Branch, [string]$AppAsar) {
    $restored = $false
    Push-Location $InstallDir
    try {
        & node 'scripts\runInstaller.mjs' -- --uninstall -branch $Branch *> $null
        $restored = -not (Test-PointsToOwnPatcher $AppAsar)
    } catch {} finally {
        Pop-Location
    }

    if ($restored) { return }
    $resources = Split-Path -Parent $AppAsar
    $backup = Join-Path $resources '_app.asar'
    if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
        throw 'Could not restore the original Discord app.asar; Vencord backup is missing.'
    }
    if (Test-Path -LiteralPath $AppAsar -PathType Leaf) { Remove-Item -LiteralPath $AppAsar -Force }
    Move-Item -LiteralPath $backup -Destination $AppAsar -Force
    if (Test-PointsToOwnPatcher $AppAsar) { throw 'Discord still points at Audisk after restore.' }
}

function Schedule-Delete([string[]]$Paths) {
    $quoted = @($Paths | Where-Object { $_ } | ForEach-Object { "'" + $_.Replace("'", "''") + "'" })
    if ($quoted.Count -eq 0) { return }
    $command = "Start-Sleep -Seconds 2; foreach(`$p in @(" + ($quoted -join ',') + ")) { if (Test-Path -LiteralPath `$p) { Remove-Item -LiteralPath `$p -Recurse -Force -ErrorAction SilentlyContinue } }"
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command) | Out-Null
}

try {
    Log ("Uninstall requested. RemoveVencord=" + [bool]$RemoveVencord)
    $state = if (Test-Path -LiteralPath $StatePath -PathType Leaf) { Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } else { $null }
    $branch = if ($state -and $state.branch) { [string]$state.branch } else { 'canary' }
    $hadVencordBefore = $state -and $state.hadVencordBefore -eq $true
    $info = Get-DiscordInfo $branch
    $discordRoot = Join-Path $env:LOCALAPPDATA $info.Directory
    $resources = Get-Resources $discordRoot
    if (-not $resources) { throw "Could not locate Discord $branch resources." }
    $appAsar = Join-Path $resources 'app.asar'

    $plan = if ($RemoveVencord) {
        'remove_vencord'
    } elseif ($hadVencordBefore -and (Test-SnapshotPatcherExists $SnapshotPath)) {
        'restore_previous_vencord'
    } else {
        'keep_plain_vencord'
    }
    if ($DryRun) {
        Write-Output ("PLAN=" + $plan)
        Write-Output ("BRANCH=" + $branch)
        Write-Output ("HAD_VENCORD_BEFORE=" + [bool]$hadVencordBefore)
        exit 0
    }

    Stop-Discord

    if ($RemoveVencord) {
        Restore-OfficialDiscord -Branch $branch -AppAsar $appAsar
        Remove-AudiskSettings
        Start-Discord $branch
        Schedule-Delete @($InstallDir)
        Log 'Audisk and Vencord injection removed; Discord restored.'
        exit 0
    }

    if ($hadVencordBefore -and (Test-SnapshotPatcherExists $SnapshotPath)) {
        Copy-Item -LiteralPath $SnapshotPath -Destination $appAsar -Force
        Remove-AudiskSettings
        Start-Discord $branch
        Schedule-Delete @($InstallDir)
        Log 'Audisk removed and the pre-existing Vencord patch restored.'
        exit 0
    }

    # No Vencord existed before Audisk and the user chose to keep Vencord. Remove the
    # userplugin source and rebuild this checkout as plain Vencord.
    $pluginDir = Join-Path $InstallDir 'src\userplugins\audisk'
    $pluginBackup = Join-Path $env:TEMP ("audisk-plugin-backup-" + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $pluginDir -PathType Container) {
        Move-Item -LiteralPath $pluginDir -Destination $pluginBackup -Force
    }
    Push-Location $InstallDir
    try {
        & corepack pnpm build
        if ($LASTEXITCODE -ne 0) { throw "Vencord rebuild failed with exit code $LASTEXITCODE." }
    } catch {
        if (Test-Path -LiteralPath $pluginBackup -PathType Container) { Move-Item -LiteralPath $pluginBackup -Destination $pluginDir -Force }
        throw
    } finally {
        Pop-Location
    }
    if (Test-Path -LiteralPath $pluginBackup) { Remove-Item -LiteralPath $pluginBackup -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-AudiskSettings
    Start-Discord $branch
    Schedule-Delete @($StatePath, $SnapshotPath, $RequestPath, (Join-Path $InstallDir '.audisk-uninstall.ps1'), (Join-Path $InstallDir '.audisk-uninstall.cmd'))
    Log 'Audisk plugin removed; plain Vencord kept installed.'
    exit 0
} catch {
    Log ("ERROR: " + $_.Exception.Message)
    try { Start-Discord $(if ($branch) { $branch } else { 'canary' }) } catch {}
    exit 1
}
