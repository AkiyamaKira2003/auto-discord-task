$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Helper = Join-Path $RepoRoot 'tools\audisk-devbuild-installer\installer-common.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "$Message`nExpected: $Expected`nActual:   $Actual" }
}

Assert-True (Test-Path -LiteralPath $Helper -PathType Leaf) 'installer-common.ps1 is required.'
. $Helper

$gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $gitCommand) {
    Write-Host '  SKIP: companion fingerprint regression needs git on PATH.' -ForegroundColor Yellow
    exit 0
}
$realGit = $gitCommand.Source

function Invoke-TestGit {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & $realGit @Arguments 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git failed: git $($Arguments -join ' ')" }
}

function Read-GitValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $value = ((& $realGit -C $Path @Arguments 2>$null) -join '').Trim()
    if ($LASTEXITCODE -ne 0) { throw "git failed in ${Path}: git $($Arguments -join ' ')" }
    return $value
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("audisk-companion-fingerprint-test-" + [guid]::NewGuid().ToString('N'))
try {
    $upstream = Join-Path $temp 'upstream'
    New-Item -ItemType Directory -Force -Path $upstream | Out-Null
    Invoke-TestGit @('-C', $upstream, 'init', '--quiet', '--initial-branch=main')
    Invoke-TestGit @('-C', $upstream, 'config', 'user.email', 'test@example.invalid')
    Invoke-TestGit @('-C', $upstream, 'config', 'user.name', 'installer regression')

    Set-Content -LiteralPath (Join-Path $upstream 'index.tsx') -Value 'first' -Encoding ASCII
    Invoke-TestGit @('-C', $upstream, 'add', '-A')
    Invoke-TestGit @('-C', $upstream, 'commit', '--quiet', '-m', 'first')
    $first = Read-GitValue -Path $upstream -Arguments @('rev-parse', 'HEAD')

    Set-Content -LiteralPath (Join-Path $upstream 'index.tsx') -Value 'old second' -Encoding ASCII
    Invoke-TestGit @('-C', $upstream, 'add', '-A')
    Invoke-TestGit @('-C', $upstream, 'commit', '--quiet', '-m', 'old second')

    $install = Join-Path $temp 'install'
    $userplugins = Join-Path $install 'src\userplugins'
    New-Item -ItemType Directory -Force -Path $userplugins | Out-Null
    $checkout = Join-Path $userplugins 'SameFileDecisionRace'
    Invoke-TestGit @('clone', '--quiet', $upstream, $checkout)

    Set-Content -LiteralPath (Join-Path $checkout 'index.tsx') -Value 'dirty before decision' -Encoding ASCII
    $headBefore = Read-GitValue -Path $checkout -Arguments @('rev-parse', 'HEAD')

    # Rewrite upstream so the dirty checkout needs a Keep/Discard decision.
    Invoke-TestGit @('-C', $upstream, 'reset', '--hard', '--quiet', $first)
    Set-Content -LiteralPath (Join-Path $upstream 'index.tsx') -Value 'rewritten second' -Encoding ASCII
    Invoke-TestGit @('-C', $upstream, 'add', '-A')
    Invoke-TestGit @('-C', $upstream, 'commit', '--quiet', '-m', 'rewritten second')

    $decisionCalls = 0
    $results = @(Update-CompanionUserplugins -InstallDir $install -DecisionProvider {
        param($context)
        $script:decisionCalls++
        if ($context.Name -eq 'SameFileDecisionRace') {
            # Keep the same `M index.tsx` status line but change the bytes after consent context
            # was captured. A status-only revalidation would miss this and reset the new edit.
            Set-Content -LiteralPath (Join-Path $context.Path 'index.tsx') -Value 'mutated during decision' -Encoding ASCII
            return 'discard'
        }
        return 'keep'
    })

    Assert-Equal $results.Count 1 'The fingerprint fixture should produce exactly one updater result.'
    Assert-Equal $decisionCalls 1 'The pending rewrite should ask exactly one local-work decision.'
    Assert-Equal $results[0].Status 'failed' 'Changing the same dirty file during Discard must invalidate the destructive decision.'
    Assert-True ($results[0].Detail -match 'changed while the discard decision was pending') 'The updater should explain why Discard was cancelled.'
    Assert-Equal (Read-GitValue -Path $checkout -Arguments @('rev-parse', 'HEAD')) $headBefore 'Cancelled Discard must preserve the original HEAD.'
    Assert-Equal (Get-Content -LiteralPath (Join-Path $checkout 'index.tsx') -Raw).Trim() 'mutated during decision' 'Cancelled Discard must preserve the bytes written after the decision context was shown.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Companion destructive-decision fingerprint regression passed.' -ForegroundColor Green
