# Shared Windows installer helpers for install/update/uninstall.
# Keep Discord discovery and process handling in one place so the three entry
# points cannot silently disagree about Stable / Canary / PTB behavior.

$script:DiscordFlavorInfo = [ordered]@{
    stable = [pscustomobject]@{ Branch = 'stable'; Directory = 'Discord';       Process = 'Discord' }
    canary = [pscustomobject]@{ Branch = 'canary'; Directory = 'DiscordCanary'; Process = 'DiscordCanary' }
    ptb    = [pscustomobject]@{ Branch = 'ptb';    Directory = 'DiscordPTB';    Process = 'DiscordPTB' }
}
$script:VencordDesktopRuntimeFiles = @('patcher.js', 'preload.js', 'renderer.js', 'renderer.css')
$script:VencordRevisionFiles = @('patcher.js', 'preload.js', 'renderer.js')

function Get-DiscordFlavorInfo {
    param([Parameter(Mandatory)][string]$Branch)
    $key = $Branch.ToLowerInvariant()
    if (-not $script:DiscordFlavorInfo.Contains($key)) { throw "Unsupported Discord branch '$Branch'. Expected stable, canary, or ptb." }
    return $script:DiscordFlavorInfo[$key]
}

function Get-DiscordRoot {
    param(
        [Parameter(Mandatory)][string]$Branch,
        [string]$LocalAppData = $env:LOCALAPPDATA
    )
    if ([string]::IsNullOrWhiteSpace($LocalAppData)) { throw 'LOCALAPPDATA is empty; cannot locate Discord.' }
    $info = Get-DiscordFlavorInfo -Branch $Branch
    return Join-Path $LocalAppData $info.Directory
}

function Select-VencordDiscordResourcesPath {
    param([Parameter(Mandatory)][string]$DiscordRoot)

    # Match Vencord Installer's Windows ParseDiscord rule: among valid app-* directories,
    # keep the lexicographically greatest <app>/resources/app path. Do not substitute an
    # mtime heuristic here; verification must inspect the same target the installer chose.
    $bestKey = $null
    $bestResources = $null
    Get-ChildItem -LiteralPath $DiscordRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $_.Name.StartsWith('app-', [StringComparison]::Ordinal)) { return }
        $resources = Join-Path $_.FullName 'resources'
        if (-not (Test-Path -LiteralPath $resources -PathType Container)) { return }
        $key = Join-Path $resources 'app'
        if ($null -eq $bestKey -or [string]::CompareOrdinal($key, $bestKey) -gt 0) {
            $bestKey = $key
            $bestResources = $resources
        }
    }
    return $bestResources
}

function Test-VencordDistComplete {
    param([Parameter(Mandatory)][string]$DistPath)
    foreach ($name in $script:VencordDesktopRuntimeFiles) {
        $path = Join-Path $DistPath $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        try { if ((Get-Item -LiteralPath $path -ErrorAction Stop).Length -le 0) { return $false } }
        catch { return $false }
    }
    return $true
}

function Get-VencordDistRevision {
    param([Parameter(Mandatory)][string]$DistPath)

    $revisions = @()
    foreach ($name in $script:VencordRevisionFiles) {
        $path = Join-Path $DistPath $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        try {
            $line = Select-String -LiteralPath $path -Pattern '^// Vencord ([0-9a-fA-F]+)$' | Select-Object -First 1
            if (-not $line -or $line.Matches.Count -eq 0) { return $null }
            $revisions += $line.Matches[0].Groups[1].Value.ToLowerInvariant()
        } catch {
            return $null
        }
    }

    $unique = @($revisions | Select-Object -Unique)
    if ($unique.Count -ne 1) { return $null }
    return $unique[0]
}

function Test-AudiskVencordDistSemantic {
    param(
        [Parameter(Mandatory)][string]$DistPath,
        [string]$RequiredMarker = 'Audisk'
    )

    if (-not (Test-VencordDistComplete -DistPath $DistPath)) { return $false }
    try {
        if (-not (Select-String -LiteralPath (Join-Path $DistPath 'renderer.js') -Pattern $RequiredMarker -SimpleMatch -Quiet)) { return $false }
    } catch {
        return $false
    }
    return -not [string]::IsNullOrWhiteSpace((Get-VencordDistRevision -DistPath $DistPath))
}

function Get-AudiskVencordHealthStampPath {
    param([Parameter(Mandatory)][string]$InstallDir)
    return Join-Path $InstallDir '.audisk-dist-health.sha256'
}

function Get-VencordDistHashLines {
    param([Parameter(Mandatory)][string]$DistPath)

    foreach ($name in $script:VencordDesktopRuntimeFiles) {
        $path = Join-Path $DistPath $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "runtime file '$name' is missing" }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        "$name=$hash"
    }
}

function Write-AudiskVencordHealthStamp {
    param(
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][string]$DistPath
    )

    $stamp = Get-AudiskVencordHealthStampPath -InstallDir $InstallDir
    $temporary = "$stamp.new"
    $lines = [string[]]@(Get-VencordDistHashLines -DistPath $DistPath)
    if ($lines.Count -ne $script:VencordDesktopRuntimeFiles.Count) { throw 'could not hash the complete Vencord runtime' }

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllLines($temporary, $lines, $utf8NoBom)
        if (Test-Path -LiteralPath $stamp -PathType Leaf) {
            # PowerShell converts a bare $null into '' when it binds to a [string] method
            # parameter, and File.Replace rejects an empty backup path as malformed. That is
            # what broke every second run of the devbuild installer in v4.10.9 (issue #73).
            # [NullString]::Value passes a genuine null through, so no backup file is created
            # and there is nothing left to clean up if a scanner holds the handle.
            [IO.File]::Replace($temporary, $stamp, [NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $stamp)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Test-AudiskVencordDistHealthy {
    param(
        [Parameter(Mandatory)][string]$DistPath,
        [string]$RequiredMarker = 'Audisk',
        [Parameter(Mandatory)][string]$HealthStampPath
    )

    if (-not (Test-AudiskVencordDistSemantic -DistPath $DistPath -RequiredMarker $RequiredMarker)) { return $false }
    if (-not (Test-Path -LiteralPath $HealthStampPath -PathType Leaf)) { return $false }

    try {
        $expected = [string[]]@(Get-Content -LiteralPath $HealthStampPath -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $actual = [string[]]@(Get-VencordDistHashLines -DistPath $DistPath)
        if ($expected.Count -ne $actual.Count) { return $false }
        for ($i = 0; $i -lt $actual.Count; $i++) {
            if (-not $expected[$i].Equals($actual[$i], [StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Get-InstalledDiscordFlavors {
    param([string]$LocalAppData = $env:LOCALAPPDATA)

    # Audisk must be able to reopen a selected target after patching it. A stale
    # app-* directory without Squirrel's Update.exe is not a usable install for
    # our lifecycle even though Vencord Installer can still parse the directory.
    foreach ($branch in $script:DiscordFlavorInfo.Keys) {
        $root = Get-DiscordRoot -Branch $branch -LocalAppData $LocalAppData
        $update = Join-Path $root 'Update.exe'
        if ((Test-Path -LiteralPath $update -PathType Leaf) -and (Select-VencordDiscordResourcesPath -DiscordRoot $root)) { $branch }
    }
}

function Get-RunningDiscordFlavors {
    foreach ($branch in $script:DiscordFlavorInfo.Keys) {
        $info = Get-DiscordFlavorInfo -Branch $branch
        if (Get-Process -Name $info.Process -ErrorAction SilentlyContinue | Select-Object -First 1) { $branch }
    }
}

function Resolve-DiscordFlavor {
    param(
        [string[]]$Installed,
        [string[]]$Running,
        [string]$PreferredBranch
    )

    $installedSet = @($Installed | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
    $runningSet = @($Running | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Where-Object { $_ -in $installedSet } | Select-Object -Unique)

    if (-not [string]::IsNullOrWhiteSpace($PreferredBranch)) {
        $preferred = (Get-DiscordFlavorInfo -Branch $PreferredBranch).Branch
        if ($preferred -notin $installedSet) { throw "Discord $preferred is not installed or is not launchable." }
        return $preferred
    }

    if ($runningSet.Count -eq 1) { return $runningSet[0] }
    if ($runningSet.Count -gt 1) { throw "More than one Discord flavor is running: $($runningSet -join ', ')." }
    if ($installedSet.Count -eq 1) { return $installedSet[0] }
    if ($installedSet.Count -eq 0) { throw 'No supported launchable Discord desktop install was found.' }
    throw "More than one Discord flavor is installed and none is running: $($installedSet -join ', ')."
}

function Get-DiscordReopenSet {
    param(
        [string[]]$RunningBefore,
        [Parameter(Mandatory)][ValidateSet('stable', 'canary', 'ptb')][string]$TargetBranch
    )

    $result = @()
    foreach ($branch in @($RunningBefore) + @($TargetBranch)) {
        if ([string]::IsNullOrWhiteSpace($branch)) { continue }
        $normalized = (Get-DiscordFlavorInfo -Branch $branch).Branch
        if ($normalized -notin $result) { $result += $normalized }
    }
    return $result
}

function Test-IsDiscordUpdaterPath {
    param(
        [string]$Path,
        [string[]]$DiscordRoots
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $candidate = [IO.Path]::GetFullPath($Path) } catch { return $false }

    foreach ($root in $DiscordRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        try { $fullRoot = [IO.Path]::GetFullPath($root).TrimEnd('\', '/') } catch { continue }
        if ($candidate.Equals((Join-Path $fullRoot 'Update.exe'), [StringComparison]::OrdinalIgnoreCase)) { return $true }
        $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
        if ($candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-AppAsarPointsToPatcher {
    param(
        [Parameter(Mandatory)][string]$AppAsar,
        [Parameter(Mandatory)][string]$PatcherPath
    )

    try {
        if (-not (Test-Path -LiteralPath $AppAsar -PathType Leaf)) { return $false }
        $text = [IO.File]::ReadAllText($AppAsar)
        $expected = [IO.Path]::GetFullPath($PatcherPath)
        $serializedExpected = '"' + $expected.Replace('\', '\\') + '"'
        return $text.IndexOf($serializedExpected, [StringComparison]::OrdinalIgnoreCase) -ge 0
    } catch {
        return $false
    }
}

function Restore-VencordAppAsar {
    param(
        [Parameter(Mandatory)][string]$AppAsar,
        [Parameter(Mandatory)][string]$PatcherPath
    )

    $resources = Split-Path -Parent $AppAsar
    $backupAsar = Join-Path $resources '_app.asar'
    if (-not (Test-Path -LiteralPath $backupAsar -PathType Leaf)) { return $false }
    try { if ((Get-Item -LiteralPath $backupAsar -ErrorAction Stop).Length -le 0) { return $false } }
    catch { return $false }
    if (Test-AppAsarPointsToPatcher -AppAsar $backupAsar -PatcherPath $PatcherPath) { return $false }

    $hadCurrent = Test-Path -LiteralPath $AppAsar -PathType Leaf
    $temporaryAsar = Join-Path $resources ("app.asar.audisk-rollback-" + [guid]::NewGuid().ToString('N'))
    $movedCurrent = $false
    $movedBackup = $false

    try {
        if ($hadCurrent) {
            Rename-Item -LiteralPath $AppAsar -NewName (Split-Path -Leaf $temporaryAsar) -ErrorAction Stop
            $movedCurrent = $true
        }

        Rename-Item -LiteralPath $backupAsar -NewName 'app.asar' -ErrorAction Stop
        $movedBackup = $true

        $restored = (Test-Path -LiteralPath $AppAsar -PathType Leaf) -and
            ((Get-Item -LiteralPath $AppAsar -ErrorAction Stop).Length -gt 0) -and
            -not (Test-AppAsarPointsToPatcher -AppAsar $AppAsar -PatcherPath $PatcherPath)
        if (-not $restored) { throw 'restored app.asar did not verify' }

        if ($movedCurrent -and (Test-Path -LiteralPath $temporaryAsar -PathType Leaf)) {
            Remove-Item -LiteralPath $temporaryAsar -Force -ErrorAction SilentlyContinue
        }
        return $true
    } catch {
        if ($movedBackup -and (Test-Path -LiteralPath $AppAsar -PathType Leaf) -and
            -not (Test-Path -LiteralPath $backupAsar -PathType Leaf)) {
            try { Rename-Item -LiteralPath $AppAsar -NewName '_app.asar' -ErrorAction Stop } catch {}
        }
        if ($movedCurrent -and (Test-Path -LiteralPath $temporaryAsar -PathType Leaf) -and
            -not (Test-Path -LiteralPath $AppAsar -PathType Leaf)) {
            try { Rename-Item -LiteralPath $temporaryAsar -NewName 'app.asar' -ErrorAction Stop } catch {}
        }
        return $false
    }
}

function Get-DiscordUpdaterProcesses {
    $roots = @($script:DiscordFlavorInfo.Keys | ForEach-Object { Get-DiscordRoot -Branch $_ })
    Get-Process Update -ErrorAction SilentlyContinue | ForEach-Object {
        $path = $null
        try { $path = $_.Path } catch {}
        if (Test-IsDiscordUpdaterPath -Path $path -DiscordRoots $roots) { $_ }
    }
}

function Stop-DiscordProcesses {
    Get-Process Discord, DiscordCanary, DiscordPTB, DiscordSystemHelper -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Get-DiscordUpdaterProcesses | Stop-Process -Force -ErrorAction SilentlyContinue

    $deadline = (Get-Date).AddSeconds(15)
    do {
        $remainingClients = @(Get-Process Discord, DiscordCanary, DiscordPTB, DiscordSystemHelper -ErrorAction SilentlyContinue)
        $remainingUpdaters = @(Get-DiscordUpdaterProcesses)
        if ($remainingClients.Count -eq 0 -and $remainingUpdaters.Count -eq 0) { return }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 500
    } while ($true)

    $remaining = @($remainingClients | ForEach-Object { $_.ProcessName }) + @($remainingUpdaters | ForEach-Object { $_.ProcessName })
    throw "Discord did not fully exit within 15 seconds. Still running: $($remaining -join ', '). Close it manually and retry."
}

function Start-DiscordFlavors {
    param(
        [string[]]$Branches,
        [string]$LocalAppData = $env:LOCALAPPDATA
    )

    $requested = @($Branches | Where-Object { $_ } | ForEach-Object { (Get-DiscordFlavorInfo -Branch $_).Branch } | Select-Object -Unique)
    $failed = @()

    foreach ($branch in $requested) {
        $info = Get-DiscordFlavorInfo -Branch $branch
        $update = Join-Path (Get-DiscordRoot -Branch $branch -LocalAppData $LocalAppData) 'Update.exe'
        if (-not (Test-Path -LiteralPath $update -PathType Leaf)) {
            $failed += $branch
            continue
        }
        try {
            Start-Process $update -ArgumentList '--processStart', "$($info.Process).exe" -ErrorAction Stop
        } catch {
            $failed += $branch
        }
    }

    $pending = @($requested | Where-Object { $_ -notin $failed })
    $deadline = (Get-Date).AddSeconds(20)
    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        $next = @()
        foreach ($branch in $pending) {
            $info = Get-DiscordFlavorInfo -Branch $branch
            if (-not (Get-Process -Name $info.Process -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                $next += $branch
            }
        }
        $pending = @($next)
        if ($pending.Count -gt 0) { Start-Sleep -Milliseconds 500 }
    }

    $failed += $pending
    return @($failed | Select-Object -Unique)
}

function Get-GitCheckoutFingerprint {
    <#
      Content-aware snapshot for a destructive companion decision.

      `git status --short` is intentionally not enough: editing the same already-dirty file keeps
      exactly the same status line, and changing an existing untracked file keeps the same path.
      Capture the index plus the bytes of every tracked and non-ignored untracked file instead.
      Ignored files are excluded because `git clean -fd` deliberately preserves them.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $indexState = (& git -C $Path ls-files --stage -z 2>$null) -join ''
        if ($LASTEXITCODE -ne 0) { return $null }
        $trackedRaw = (& git -C $Path ls-files -z 2>$null) -join ''
        if ($LASTEXITCODE -ne 0) { return $null }
        $untrackedRaw = (& git -C $Path ls-files --others --exclude-standard -z 2>$null) -join ''
        if ($LASTEXITCODE -ne 0) { return $null }

        $trackedPaths = @($trackedRaw -split [char]0 | Where-Object { $_.Length -gt 0 })
        $untrackedPaths = @($untrackedRaw -split [char]0 | Where-Object { $_.Length -gt 0 })
        $rows = New-Object System.Collections.Generic.List[string]
        $utf8 = New-Object System.Text.UTF8Encoding($false)

        foreach ($kindAndPath in @(
            @($trackedPaths | ForEach-Object { [pscustomobject]@{ Kind = 'T'; Relative = [string]$_ } }),
            @($untrackedPaths | ForEach-Object { [pscustomobject]@{ Kind = 'U'; Relative = [string]$_ } })
        )) {
            foreach ($entry in @($kindAndPath)) {
                $relative = [string]$entry.Relative
                $pathToken = [Convert]::ToBase64String($utf8.GetBytes($relative))
                $full = Join-Path $Path $relative
                if (Test-Path -LiteralPath $full -PathType Leaf) {
                    try {
                        $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                        $rows.Add("$($entry.Kind):$pathToken:F:$hash")
                    } catch {
                        return $null
                    }
                } elseif (Test-Path -LiteralPath $full -PathType Container) {
                    # Gitlinks/submodules are directories in the parent worktree. The index state
                    # above carries their gitlink SHA; the marker keeps path/type changes visible.
                    $rows.Add("$($entry.Kind):$pathToken:D")
                } else {
                    $rows.Add("$($entry.Kind):$pathToken:MISSING")
                }
            }
        }

        $orderedRows = @($rows | Sort-Object)
        $indexToken = [Convert]::ToBase64String($utf8.GetBytes($indexState))
        $payload = "index=$indexToken`n" + ($orderedRows -join "`n")
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $digest = $sha.ComputeHash($utf8.GetBytes($payload))
            return ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Update-CompanionUserplugins {
    <#
      Update every other git-checked-out userplugin sitting beside audisk.

      A normal behind checkout still fast-forwards. The extra case handled here is a companion
      whose upstream rewrote history after the user cloned it. Auto-recovery is deliberately
      narrow: the checkout must have been clean with HEAD exactly equal to its pre-fetch upstream,
      and that same proof is revalidated immediately before reset --hard. Local edits, untracked
      files, staged changes, or local commits are never reset automatically.

      A local-ahead checkout that already contains the fetched upstream is already current, even
      when its worktree is dirty, so it is left alone without asking a destructive question.

      Interactive callers may supply DecisionProvider. It receives one context object and returns
      "keep" or "discard". With no provider the safe default is keep. Before honoring Discard, the
      checkout HEAD, upstream ref and a content-aware local-work fingerprint are revalidated so
      consent for one snapshot cannot discard bytes that changed while the decision was pending.
      Discard resets tracked state and removes non-ignored untracked files; ignored files are never
      cleaned.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallDir,
        [scriptblock]$DecisionProvider
    )

    $root = Join-Path $InstallDir 'src\userplugins'
    $results = @()
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $results }

    foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue) {
        if ($dir.Name -eq 'audisk') { continue }

        if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName '.git'))) {
            $results += [pscustomobject]@{ Name = $dir.Name; Status = 'skipped'; Detail = 'not a git checkout' }
            continue
        }

        $before = ((& git -C $dir.FullName rev-parse HEAD 2>$null) -join '').Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($before)) {
            $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = 'could not read checkout HEAD' }
            continue
        }

        $upstreamRef = ((& git -C $dir.FullName rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null) -join '').Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($upstreamRef)) {
            $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = 'current branch has no tracked upstream' }
            continue
        }

        $beforeUpstream = ((& git -C $dir.FullName rev-parse '@{u}' 2>$null) -join '').Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($beforeUpstream)) {
            $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = "could not resolve tracked upstream $upstreamRef" }
            continue
        }

        $changesBeforeFetch = @(& git -C $dir.FullName status --short --untracked-files=all 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($LASTEXITCODE -ne 0) {
            $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = 'could not inspect local changes' }
            continue
        }

        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $fetchOutput = (& git -C $dir.FullName fetch --quiet 2>&1) -join ' '
        $fetchCode = $LASTEXITCODE
        $ErrorActionPreference = $prev
        if ($fetchCode -ne 0) {
            $detail = $fetchOutput.Trim()
            if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'git fetch failed' }
            $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = $detail }
            continue
        }

        $afterUpstream = ((& git -C $dir.FullName rev-parse '@{u}' 2>$null) -join '').Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($afterUpstream)) {
            $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = "tracked upstream $upstreamRef disappeared after fetch" }
            continue
        }

        # Everything destructive below reasons from a fresh post-fetch snapshot, not the status
        # captured before a potentially slow network operation.
        $currentHead = ((& git -C $dir.FullName rev-parse HEAD 2>$null) -join '').Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentHead)) {
            $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = 'could not re-read checkout HEAD after fetch' }
            continue
        }
        $changes = @(& git -C $dir.FullName status --short --untracked-files=all 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($LASTEXITCODE -ne 0) {
            $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = 'could not re-read local changes after fetch' }
            continue
        }

        $shortCurrent = if ($currentHead.Length -gt 7) { $currentHead.Substring(0, 7) } else { $currentHead }
        $shortAfter = if ($afterUpstream.Length -gt 7) { $afterUpstream.Substring(0, 7) } else { $afterUpstream }

        # If fetched upstream is already an ancestor of local HEAD, no update is pending. This is
        # the important local-ahead case: dirty work must not be offered a pointless Discard path.
        & git -C $dir.FullName merge-base --is-ancestor $afterUpstream $currentHead 2>$null
        $ancestorCode = $LASTEXITCODE
        if ($ancestorCode -gt 1) {
            $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = 'could not compare checkout history with its fetched upstream' }
            continue
        }
        if ($ancestorCode -eq 0) {
            $detail = $shortCurrent
            if ($currentHead -ne $afterUpstream) { $detail += ' (local commits kept; tracked upstream already contained)' }
            if ($changes.Count -gt 0) { $detail += ' (local changes kept)' }
            $results += [pscustomobject]@{ Name = $dir.Name; Status = 'current'; Detail = $detail }
            continue
        }

        if ($changes.Count -eq 0) {
            # Try the ordinary non-destructive path first. A checkout merely behind the tracked
            # upstream lands here and fast-forwards without any special recovery logic.
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $mergeOutput = (& git -C $dir.FullName merge --ff-only --quiet $afterUpstream 2>&1) -join ' '
            $mergeCode = $LASTEXITCODE
            $ErrorActionPreference = $prev

            if ($mergeCode -eq 0) {
                $mergeHead = ((& git -C $dir.FullName rev-parse HEAD 2>$null) -join '').Trim()
                if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($mergeHead)) {
                    $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = 'fast-forward completed but the resulting HEAD could not be read' }
                } elseif ($mergeHead -eq $afterUpstream) {
                    $results += [pscustomobject]@{ Name = $dir.Name; Status = 'updated'; Detail = "$shortCurrent -> $shortAfter" }
                } else {
                    $shortMergeHead = if ($mergeHead.Length -gt 7) { $mergeHead.Substring(0, 7) } else { $mergeHead }
                    $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = "fast-forward ended at unexpected HEAD $shortMergeHead" }
                }
                continue
            }

            # A remote rewrite is the one case where automatic reset is allowed. Revalidate the
            # complete proof after the failed merge and immediately before reset so work created
            # during fetch/merge cannot be destroyed by a stale clean snapshot.
            if ($before -eq $beforeUpstream -and $changesBeforeFetch.Count -eq 0 -and $afterUpstream -ne $beforeUpstream) {
                $preResetHead = ((& git -C $dir.FullName rev-parse HEAD 2>$null) -join '').Trim()
                $headOk = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($preResetHead)
                $preResetChanges = @(& git -C $dir.FullName status --short --untracked-files=all 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $statusOk = $LASTEXITCODE -eq 0
                $preResetUpstream = ((& git -C $dir.FullName rev-parse '@{u}' 2>$null) -join '').Trim()
                $upstreamOk = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($preResetUpstream)

                if ($headOk -and $statusOk -and $upstreamOk -and
                    $preResetHead -eq $before -and $preResetChanges.Count -eq 0 -and $preResetUpstream -eq $afterUpstream) {
                    $prev = $ErrorActionPreference
                    $ErrorActionPreference = 'Continue'
                    $resetOutput = (& git -C $dir.FullName reset --hard --quiet $afterUpstream 2>&1) -join ' '
                    $resetCode = $LASTEXITCODE
                    $ErrorActionPreference = $prev
                    $resetHead = ((& git -C $dir.FullName rev-parse HEAD 2>$null) -join '').Trim()

                    if ($resetCode -eq 0 -and $resetHead -eq $afterUpstream) {
                        $results += [pscustomobject]@{
                            Name = $dir.Name
                            Status = 'updated'
                            Detail = "$shortCurrent -> $shortAfter (upstream history was rewritten; clean checkout recovered)"
                        }
                    } else {
                        $detail = $resetOutput.Trim()
                        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'could not reset clean checkout to rewritten upstream' }
                        $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = $detail }
                    }
                    continue
                }
            }
        }

        # The checkout cannot be updated non-destructively. Refresh once more after the merge
        # attempt/rewrite proof so the summary and any decision describe the state that exists now.
        $currentHead = ((& git -C $dir.FullName rev-parse HEAD 2>$null) -join '').Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentHead)) {
            $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = 'could not read checkout HEAD before local-work decision' }
            continue
        }
        $changes = @(& git -C $dir.FullName status --short --untracked-files=all 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($LASTEXITCODE -ne 0) {
            $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = 'could not inspect local changes before local-work decision' }
            continue
        }

        # A concurrent/manual update may have made the checkout current while we were trying the
        # safe paths above. Never prompt if the fetched upstream is already contained now.
        & git -C $dir.FullName merge-base --is-ancestor $afterUpstream $currentHead 2>$null
        $ancestorCode = $LASTEXITCODE
        if ($ancestorCode -gt 1) {
            $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = 'could not compare checkout history before local-work decision' }
            continue
        }
        if ($ancestorCode -eq 0) {
            $shortCurrent = if ($currentHead.Length -gt 7) { $currentHead.Substring(0, 7) } else { $currentHead }
            $detail = $shortCurrent
            if ($currentHead -ne $afterUpstream) { $detail += ' (local commits kept; tracked upstream already contained)' }
            if ($changes.Count -gt 0) { $detail += ' (local changes kept)' }
            $results += [pscustomobject]@{ Name = $dir.Name; Status = 'current'; Detail = $detail }
            continue
        }

        # Summarize local history against the pre-fetch upstream so the remote rewrite itself is
        # never counted as a pile of local commits.
        $localCommitCount = 0
        $countText = ((& git -C $dir.FullName rev-list --count "$beforeUpstream..$currentHead" 2>$null) -join '').Trim()
        if ($LASTEXITCODE -eq 0) {
            $parsedCount = 0
            if ([int]::TryParse($countText, [ref]$parsedCount)) { $localCommitCount = $parsedCount }
        }

        $summaryParts = @()
        if ($changes.Count -gt 0) {
            $shown = @($changes | Select-Object -First 5 | ForEach-Object { ([string]$_).Trim() })
            $extra = if ($changes.Count -gt $shown.Count) { ", +$($changes.Count - $shown.Count) more" } else { '' }
            $summaryParts += "changes: $($shown -join ', ')$extra"
        }
        if ($localCommitCount -gt 0) { $summaryParts += "$localCommitCount local commit(s)" }
        if ($summaryParts.Count -eq 0) { $summaryParts += 'history differs from the tracked upstream' }
        $summary = $summaryParts -join '; '

        $decisionFingerprint = Get-GitCheckoutFingerprint -Path $dir.FullName
        if ([string]::IsNullOrWhiteSpace($decisionFingerprint)) {
            $results += [pscustomobject]@{
                Name = $dir.Name
                Status = 'failed'
                Detail = 'local work kept; could not fingerprint the checkout safely before a destructive decision'
            }
            continue
        }

        $context = [pscustomobject]@{
            Name = $dir.Name
            Path = $dir.FullName
            Summary = $summary
            Changes = [string[]]$changes
            LocalCommitCount = $localCommitCount
            HeadBefore = $currentHead
            UpstreamBefore = $beforeUpstream
            UpstreamAfter = $afterUpstream
            UpstreamRef = $upstreamRef
        }

        $decision = 'keep'
        if ($DecisionProvider) {
            try {
                $provided = [string](& $DecisionProvider $context)
                if (-not [string]::IsNullOrWhiteSpace($provided)) { $decision = $provided.Trim().ToLowerInvariant() }
            } catch {
                $decision = 'keep'
            }
        }

        if ($decision -in @('discard', 'd', 'reset')) {
            # Consent applies only to the exact content snapshot that existed when the caller was
            # asked. Status letters are insufficient: M stays M when the same file is edited again.
            $decisionHead = ((& git -C $dir.FullName rev-parse HEAD 2>$null) -join '').Trim()
            $decisionHeadOk = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($decisionHead)
            $decisionUpstream = ((& git -C $dir.FullName rev-parse '@{u}' 2>$null) -join '').Trim()
            $decisionUpstreamOk = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($decisionUpstream)
            $decisionFingerprintNow = Get-GitCheckoutFingerprint -Path $dir.FullName
            $decisionFingerprintOk = -not [string]::IsNullOrWhiteSpace($decisionFingerprintNow)

            if (-not ($decisionHeadOk -and $decisionUpstreamOk -and $decisionFingerprintOk) -or
                $decisionHead -ne $context.HeadBefore -or $decisionUpstream -ne $context.UpstreamAfter -or
                $decisionFingerprintNow -cne $decisionFingerprint) {
                $results += [pscustomobject]@{
                    Name = $dir.Name
                    Status = 'failed'
                    Detail = 'local work kept; checkout changed while the discard decision was pending, so nothing was reset'
                }
                continue
            }

            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $resetOutput = (& git -C $dir.FullName reset --hard --quiet $afterUpstream 2>&1) -join ' '
            $resetCode = $LASTEXITCODE
            $cleanOutput = ''
            $cleanCode = 1
            if ($resetCode -eq 0) {
                $cleanOutput = (& git -C $dir.FullName clean -fd --quiet 2>&1) -join ' '
                $cleanCode = $LASTEXITCODE
            }
            $ErrorActionPreference = $prev

            $resetHead = ((& git -C $dir.FullName rev-parse HEAD 2>$null) -join '').Trim()
            $remaining = @(& git -C $dir.FullName status --short --untracked-files=all 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($resetCode -eq 0 -and $cleanCode -eq 0 -and $resetHead -eq $afterUpstream -and $remaining.Count -eq 0) {
                $shortCurrent = if ($currentHead.Length -gt 7) { $currentHead.Substring(0, 7) } else { $currentHead }
                $results += [pscustomobject]@{
                    Name = $dir.Name
                    Status = 'updated'
                    Detail = "$shortCurrent -> $shortAfter (local work discarded by request)"
                }
            } else {
                $detail = (@($resetOutput.Trim(), $cleanOutput.Trim()) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
                if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'discard was requested but the checkout could not be made clean at the tracked upstream' }
                $results += [pscustomobject]@{ Name = $dir.Name; Status = 'failed'; Detail = $detail }
            }
            continue
        }

        $results += [pscustomobject]@{
            Name = $dir.Name
            Status = 'failed'
            Detail = "local work kept; update skipped ($summary)"
        }
    }

    # No unary comma here. Wrapping the array makes the caller's @() see one nested element
    # instead of the rows, and every call site already wraps, so a bare return is what works
    # for zero, one and many.
    return $results
}

function Get-PnpmInvocation {
    param([Parameter(Mandatory)][string]$PackageJsonPath)

    if (-not (Test-Path -LiteralPath $PackageJsonPath -PathType Leaf)) { throw "package.json not found at $PackageJsonPath" }
    $package = Get-Content -LiteralPath $PackageJsonPath -Raw | ConvertFrom-Json
    $spec = [string]$package.packageManager
    if ($spec -notmatch '^pnpm@([^+\s]+)') { throw "Vencord package.json has no supported pnpm packageManager entry (got '$spec')." }
    $version = $Matches[1]

    if (Get-Command npx -ErrorAction SilentlyContinue) {
        return [pscustomobject]@{ Command = 'npx'; Arguments = @('--yes', "pnpm@$version"); Version = $version }
    }

    if (Get-Command corepack -ErrorAction SilentlyContinue) {
        return [pscustomobject]@{ Command = 'corepack'; Arguments = @('pnpm'); Version = $version }
    }

    throw 'Neither corepack nor npx is available. Reinstall a normal Node.js distribution and re-run.'
}

function Invoke-Pnpm {
    param(
        [Parameter(Mandatory)]$Invocation,
        [string[]]$Arguments
    )
    $all = @($Invocation.Arguments) + @($Arguments)
    & $Invocation.Command @all
}

function Invoke-VencordBuildTransactional {
    param(
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)]$Invocation,
        [string]$RequiredMarker = 'Audisk'
    )

    $dist = Join-Path $InstallDir 'dist'
    $healthStamp = Get-AudiskVencordHealthStampPath -InstallDir $InstallDir
    $snapshot = Join-Path ([IO.Path]::GetTempPath()) ("audisk-vencord-dist-" + [guid]::NewGuid().ToString('N'))
    $hadKnownGood = Test-AudiskVencordDistHealthy -DistPath $dist -RequiredMarker $RequiredMarker -HealthStampPath $healthStamp

    if ($hadKnownGood) {
        New-Item -ItemType Directory -Force -Path $snapshot | Out-Null
        Copy-Item (Join-Path $dist '*') $snapshot -Recurse -Force -ErrorAction Stop
    }

    $buildCode = 1
    $buildException = $null
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        try { Invoke-Pnpm -Invocation $Invocation -Arguments @('run', 'build') }
        catch { $buildException = $_.Exception.Message }
        $buildCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }

    $semantic = Test-AudiskVencordDistSemantic -DistPath $dist -RequiredMarker $RequiredMarker
    if (-not $buildException -and $buildCode -eq 0 -and $semantic) {
        try {
            Write-AudiskVencordHealthStamp -InstallDir $InstallDir -DistPath $dist
            if (Test-AudiskVencordDistHealthy -DistPath $dist -RequiredMarker $RequiredMarker -HealthStampPath $healthStamp) {
                Remove-Item -LiteralPath $snapshot -Recurse -Force -ErrorAction SilentlyContinue
                return
            }
            $buildException = 'the Vencord runtime health stamp did not verify after it was written'
        } catch {
            $buildException = "could not persist the Vencord runtime health stamp: $($_.Exception.Message)"
        }
    }

    $restoreOk = $true
    try {
        if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force -ErrorAction Stop }
        if ($hadKnownGood) {
            New-Item -ItemType Directory -Force -Path $dist | Out-Null
            Copy-Item (Join-Path $snapshot '*') $dist -Recurse -Force -ErrorAction Stop
            $restoreOk = Test-AudiskVencordDistHealthy -DistPath $dist -RequiredMarker $RequiredMarker -HealthStampPath $healthStamp
        } else {
            Remove-Item -LiteralPath $healthStamp -Force -ErrorAction SilentlyContinue
        }
    } catch {
        $restoreOk = $false
    }

    if (-not $restoreOk) {
        if ($hadKnownGood -and (Test-Path -LiteralPath $snapshot -PathType Container)) {
            throw "Vencord build failed and the previous stamped healthy dist could not be restored automatically. A recovery snapshot was kept at $snapshot. Leave Discord open if it is still running; before the next restart, run the official Vencord installer and choose Repair."
        }
        throw 'Vencord build failed and the partial dist could not be cleaned up. No stamped healthy Audisk dist existed to snapshot. Leave Discord open if it is still running; before the next restart, run the official Vencord installer and choose Repair.'
    }

    Remove-Item -LiteralPath $snapshot -Recurse -Force -ErrorAction SilentlyContinue
    $recovery = if ($hadKnownGood) { 'The previous stamped healthy Audisk dist was restored.' } else { 'The partial build dist was removed; no unverified pre-existing dist was used as rollback.' }
    if ($buildException) { throw "Vencord build failed: $buildException $recovery" }
    if ($buildCode -ne 0) { throw "Vencord build failed (exit code $buildCode). $recovery" }
    throw "Vencord build output failed semantic verification: it must contain the four Discord runtime files, the $RequiredMarker plugin, and one consistent Vencord revision across patcher/preload/renderer. $recovery"
}
