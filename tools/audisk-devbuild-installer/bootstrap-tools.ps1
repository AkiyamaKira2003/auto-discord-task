# Audisk self-contained Windows build-tool bootstrap.
# Installs portable copies under LOCALAPPDATA when Node.js/Git are missing or unusable.

function Get-AudiskBootstrapRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:AUDISK_BOOTSTRAP_ROOT)) {
        return [IO.Path]::GetFullPath($env:AUDISK_BOOTSTRAP_ROOT)
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is empty; cannot create the Audisk bootstrap directory.' }
    return (Join-Path $env:LOCALAPPDATA 'AudiskBootstrap')
}

function Add-AudiskPathFront {
    param([Parameter(Mandatory)][string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    $full = [IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')
    $parts = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $kept = @($parts | Where-Object {
        try { -not ([IO.Path]::GetFullPath($_).TrimEnd('\', '/').Equals($full, [StringComparison]::OrdinalIgnoreCase)) }
        catch { $true }
    })
    $env:Path = (@($full) + $kept) -join ';'
}

function Get-AudiskWindowsArchitecture {
    $arch = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($arch) {
        '^(AMD64|x86_64)$' { return 'x64' }
        '^ARM64$' { return 'arm64' }
        default { throw "Unsupported Windows architecture '$arch'. Audisk requires x64 or arm64 Windows." }
    }
}

function Initialize-AudiskBootstrapPath {
    $root = Get-AudiskBootstrapRoot
    $nodeHome = Join-Path $root 'node'
    $gitHome = Join-Path $root 'git'

    # A package manager may have installed the tool successfully but the current
    # PowerShell process can still hold a stale PATH. Discover common install paths
    # before downloading another copy.
    $nodeCandidates = @()
    if ($env:ProgramFiles) { $nodeCandidates += (Join-Path $env:ProgramFiles 'nodejs') }
    if (${env:ProgramFiles(x86)}) { $nodeCandidates += (Join-Path ${env:ProgramFiles(x86)} 'nodejs') }
    if ($env:LOCALAPPDATA) { $nodeCandidates += (Join-Path $env:LOCALAPPDATA 'Programs\nodejs') }
    foreach ($candidate in $nodeCandidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'node.exe') -PathType Leaf) { Add-AudiskPathFront $candidate; break }
    }

    $gitCandidates = @()
    if ($env:ProgramFiles) { $gitCandidates += (Join-Path $env:ProgramFiles 'Git\cmd') }
    if (${env:ProgramFiles(x86)}) { $gitCandidates += (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd') }
    if ($env:LOCALAPPDATA) { $gitCandidates += (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd') }
    foreach ($candidate in $gitCandidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'git.exe') -PathType Leaf) { Add-AudiskPathFront $candidate; break }
    }

    # Portable Audisk-managed tools go last so Add-AudiskPathFront gives them
    # precedence over stale/older system installations on future runs.
    if (Test-Path -LiteralPath (Join-Path $nodeHome 'node.exe') -PathType Leaf) { Add-AudiskPathFront $nodeHome }
    if (Test-Path -LiteralPath (Join-Path $gitHome 'cmd\git.exe') -PathType Leaf) { Add-AudiskPathFront (Join-Path $gitHome 'cmd') }
}

function Get-AudiskNodeMajor {
    try {
        $raw = (& node -v 2>$null).Trim()
        if ($raw -match '^v(?<major>\d+)\.') { return [int]$Matches.major }
    } catch { }
    return 0
}

function Invoke-AudiskDownloadFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [hashtable]$Headers
    )
    $parent = Split-Path -Parent $Destination
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $temp = "$Destination.part"
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        $params = @{ Uri = $Uri; OutFile = $temp; UseBasicParsing = $true; ErrorAction = 'Stop' }
        if ($Headers) { $params.Headers = $Headers }
        Invoke-WebRequest @params
        if (-not (Test-Path -LiteralPath $temp -PathType Leaf) -or (Get-Item -LiteralPath $temp).Length -le 0) {
            throw "Download produced an empty file: $Uri"
        }
        Move-Item -LiteralPath $temp -Destination $Destination -Force
    } finally {
        $ProgressPreference = $oldProgress
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Install-AudiskPortableNode {
    $root = Get-AudiskBootstrapRoot
    $arch = Get-AudiskWindowsArchitecture
    New-Item -ItemType Directory -Force -Path $root | Out-Null

    Write-Host '  Downloading a portable Node.js LTS build for Audisk...' -ForegroundColor Yellow
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        $releases = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -ErrorAction Stop
    } finally { $ProgressPreference = $oldProgress }

    $release = @($releases | Where-Object {
        $major = 0
        if ([string]$_.version -match '^v(?<major>\d+)\.') { $major = [int]$Matches.major }
        $isLts = $_.lts -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$_.lts)
        $major -ge 22 -and $isLts -and @($_.files) -contains "win-$arch-zip"
    }) | Select-Object -First 1
    if (-not $release) { throw "Could not find a supported Node.js LTS win-$arch ZIP release." }

    $version = [string]$release.version
    $zipName = "node-$version-win-$arch.zip"
    $zip = Join-Path $env:TEMP ("audisk-" + $zipName)
    $extract = Join-Path $env:TEMP ("audisk-node-" + [guid]::NewGuid().ToString('N'))
    $destination = Join-Path $root 'node'
    try {
        Invoke-AudiskDownloadFile -Uri "https://nodejs.org/dist/$version/$zipName" -Destination $zip
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $payload = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
        if (-not $payload -or -not (Test-Path -LiteralPath (Join-Path $payload.FullName 'node.exe') -PathType Leaf)) {
            throw 'Downloaded Node.js archive did not contain node.exe.'
        }
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
        Move-Item -LiteralPath $payload.FullName -Destination $destination
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    }
    Add-AudiskPathFront $destination
    return $version
}

function Install-AudiskPortableGit {
    $root = Get-AudiskBootstrapRoot
    $arch = Get-AudiskWindowsArchitecture
    New-Item -ItemType Directory -Force -Path $root | Out-Null

    Write-Host '  Downloading portable Git for Audisk...' -ForegroundColor Yellow
    $headers = @{ 'User-Agent' = 'Audisk-Installer' }
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        $release = Invoke-RestMethod -Headers $headers -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -ErrorAction Stop
    } finally { $ProgressPreference = $oldProgress }

    $pattern = if ($arch -eq 'arm64') { '^MinGit-.*-arm64\.zip$' } else { '^MinGit-.*-64-bit\.zip$' }
    $asset = @($release.assets | Where-Object { $_.name -match $pattern }) | Select-Object -First 1
    if (-not $asset) { throw "Could not find a MinGit $arch ZIP in the latest Git for Windows release." }

    $zip = Join-Path $env:TEMP ("audisk-" + [string]$asset.name)
    $extract = Join-Path $env:TEMP ("audisk-git-" + [guid]::NewGuid().ToString('N'))
    $destination = Join-Path $root 'git'
    try {
        Invoke-AudiskDownloadFile -Uri ([string]$asset.browser_download_url) -Destination $zip -Headers $headers
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        if (-not (Test-Path -LiteralPath (Join-Path $extract 'cmd\git.exe') -PathType Leaf)) {
            throw 'Downloaded MinGit archive did not contain cmd\git.exe.'
        }
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
        Move-Item -LiteralPath $extract -Destination $destination
        $extract = $null
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        if ($extract) { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Add-AudiskPathFront (Join-Path $destination 'cmd')
    return [string]$release.tag_name
}

function Ensure-AudiskNode {
    Initialize-AudiskBootstrapPath
    $major = Get-AudiskNodeMajor
    if ($major -lt 22) {
        if ($major -gt 0) { Write-Host "  Node.js $major is too old; Audisk will use its own portable Node.js LTS." -ForegroundColor Yellow }
        else { Write-Host '  Node.js was not found; Audisk will install a portable copy automatically.' -ForegroundColor Yellow }
        [void](Install-AudiskPortableNode)
        $major = Get-AudiskNodeMajor
    }
    if ($major -lt 22) { throw 'Audisk could not prepare Node.js 22 or newer automatically.' }
    if (-not (Get-Command npx -ErrorAction SilentlyContinue)) { throw 'Node.js is available but npx is missing; the Node.js bootstrap is incomplete.' }
    return (& node -v).Trim()
}

function Ensure-AudiskGit {
    Initialize-AudiskBootstrapPath
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host '  Git was not found; Audisk will install a portable copy automatically.' -ForegroundColor Yellow
        [void](Install-AudiskPortableGit)
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Audisk could not prepare Git automatically.' }
    return (& git --version).Trim()
}

function Ensure-AudiskBuildTools {
    $nodeVersion = Ensure-AudiskNode
    $gitVersion = Ensure-AudiskGit
    [pscustomobject]@{ Node = $nodeVersion; Git = $gitVersion; BootstrapRoot = (Get-AudiskBootstrapRoot) }
}

function Invoke-AudiskPortablePnpm {
    param(
        [Parameter(Mandatory)][string]$PackageJsonPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    [void](Ensure-AudiskNode)
    $package = Get-Content -LiteralPath $PackageJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $spec = [string]$package.packageManager
    if ($spec -notmatch '^pnpm@([^+\s]+)') { throw "package.json has no supported pnpm packageManager entry (got '$spec')." }
    $version = $Matches[1]
    if (Get-Command corepack -ErrorAction SilentlyContinue) {
        & corepack pnpm @Arguments
        return
    }
    & npx --yes "pnpm@$version" @Arguments
}
