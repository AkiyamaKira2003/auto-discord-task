$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Helper = Join-Path $RepoRoot 'tools\audisk-devbuild-installer\installer-common.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-False([bool]$Condition, [string]$Message) {
    if ($Condition) { throw $Message }
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "$Message`nExpected: $Expected`nActual:   $Actual" }
}

Assert-True (Test-Path -LiteralPath $Helper -PathType Leaf) 'installer-common.ps1 is required.'
. $Helper

$gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $gitCommand) {
    Write-Host '  SKIP: companion rewrite regression needs git on PATH.' -ForegroundColor Yellow
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

$temp = Join-Path ([IO.Path]::GetTempPath()) ("audisk-companion-rewrite-test-" + [guid]::NewGuid().ToString('N'))
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
    $oldRemoteHead = Read-GitValue -Path $upstream -Arguments @('rev-parse', 'HEAD')

    # A local-ahead checkout already contains the tracked upstream, so there is no remote update
    # to apply. This remains true when the checkout is dirty: UPDATE must not ask a destructive
    # Keep/Discard question for work that is already current.
    $aheadInstall = Join-Path $temp 'ahead-install'
    $aheadUserplugins = Join-Path $aheadInstall 'src\userplugins'
    New-Item -ItemType Directory -Force -Path $aheadUserplugins | Out-Null

    $ahead = Join-Path $aheadUserplugins 'LocalAheadCurrent'
    Invoke-TestGit @('clone', '--quiet', $upstream, $ahead)
    Invoke-TestGit @('-C', $ahead, 'config', 'user.email', 'test@example.invalid')
    Invoke-TestGit @('-C', $ahead, 'config', 'user.name', 'installer regression')
    Set-Content -LiteralPath (Join-Path $ahead 'local.txt') -Value 'local ahead' -Encoding ASCII
    Invoke-TestGit @('-C', $ahead, 'add', '-A')
    Invoke-TestGit @('-C', $ahead, 'commit', '--quiet', '-m', 'local ahead')
    $aheadHead = Read-GitValue -Path $ahead -Arguments @('rev-parse', 'HEAD')

    $aheadDirty = Join-Path $aheadUserplugins 'LocalAheadDirtyCurrent'
    Invoke-TestGit @('clone', '--quiet', $upstream, $aheadDirty)
    Invoke-TestGit @('-C', $aheadDirty, 'config', 'user.email', 'test@example.invalid')
    Invoke-TestGit @('-C', $aheadDirty, 'config', 'user.name', 'installer regression')
    Set-Content -LiteralPath (Join-Path $aheadDirty 'local-commit.txt') -Value 'local ahead' -Encoding ASCII
    Invoke-TestGit @('-C', $aheadDirty, 'add', '-A')
    Invoke-TestGit @('-C', $aheadDirty, 'commit', '--quiet', '-m', 'local ahead')
    Set-Content -LiteralPath (Join-Path $aheadDirty 'work-in-progress.txt') -Value 'do not discard' -Encoding ASCII
    $aheadDirtyHead = Read-GitValue -Path $aheadDirty -Arguments @('rev-parse', 'HEAD')

    $aheadDecisionCalls = 0
    $aheadResults = @(Update-CompanionUserplugins -InstallDir $aheadInstall -DecisionProvider {
        param($context)
        $script:aheadDecisionCalls++
        return 'discard'
    })
    $aheadByName = @{}
    foreach ($row in $aheadResults) { $aheadByName[$row.Name] = $row }

    Assert-Equal $aheadByName['LocalAheadCurrent'].Status 'current' 'A clean local-ahead checkout with unchanged upstream must be current, not updated.'
    Assert-Equal (Read-GitValue -Path $ahead -Arguments @('rev-parse', 'HEAD')) $aheadHead 'Checking a clean local-ahead checkout must not move its HEAD.'
    Assert-True ($aheadByName['LocalAheadCurrent'].Detail -match 'local commits kept') 'The current result should explain that local commits were kept.'

    Assert-Equal $aheadByName['LocalAheadDirtyCurrent'].Status 'current' 'A dirty local-ahead checkout that already contains upstream must also be current.'
    Assert-Equal (Read-GitValue -Path $aheadDirty -Arguments @('rev-parse', 'HEAD')) $aheadDirtyHead 'A dirty local-ahead checkout must keep its local commit.'
    Assert-True (Test-Path -LiteralPath (Join-Path $aheadDirty 'work-in-progress.txt') -PathType Leaf) 'A dirty local-ahead checkout must keep its working file.'
    Assert-Equal $aheadDecisionCalls 0 'Already-current local-ahead checkouts must never be offered a destructive Discard decision.'

    $userplugins = Join-Path $temp 'install\src\userplugins'
    New-Item -ItemType Directory -Force -Path $userplugins | Out-Null
    $names = @(
        'RewriteClean', 'RewriteDirty', 'RewriteStaged', 'RewriteUntracked', 'RewriteLocalCommit',
        'RewriteDiscard', 'RewriteDecisionRace', 'audisk'
    )
    foreach ($name in $names) {
        Invoke-TestGit @('clone', '--quiet', $upstream, (Join-Path $userplugins $name))
    }

    # Separate fixtures are cloned before the remote rewrite so their remembered origin/main is
    # exactly the old SHA an installed companion would have seen.
    $defaultKeepInstall = Join-Path $temp 'default-keep-install'
    $defaultKeepUserplugins = Join-Path $defaultKeepInstall 'src\userplugins'
    New-Item -ItemType Directory -Force -Path $defaultKeepUserplugins | Out-Null
    $defaultKeep = Join-Path $defaultKeepUserplugins 'RewriteDefaultKeep'
    Invoke-TestGit @('clone', '--quiet', $upstream, $defaultKeep)
    Set-Content -LiteralPath (Join-Path $defaultKeep 'index.tsx') -Value 'noninteractive local edit' -Encoding ASCII
    $defaultKeepHead = Read-GitValue -Path $defaultKeep -Arguments @('rev-parse', 'HEAD')

    $raceInstall = Join-Path $temp 'race-install'
    $raceUserplugins = Join-Path $raceInstall 'src\userplugins'
    New-Item -ItemType Directory -Force -Path $raceUserplugins | Out-Null
    $race = Join-Path $raceUserplugins 'RewriteRace'
    Invoke-TestGit @('clone', '--quiet', $upstream, $race)
    $raceHead = Read-GitValue -Path $race -Arguments @('rev-parse', 'HEAD')

    $dirty = Join-Path $userplugins 'RewriteDirty'
    Set-Content -LiteralPath (Join-Path $dirty 'index.tsx') -Value 'local dirty edit' -Encoding ASCII

    $staged = Join-Path $userplugins 'RewriteStaged'
    Set-Content -LiteralPath (Join-Path $staged 'staged.txt') -Value 'staged work' -Encoding ASCII
    Invoke-TestGit @('-C', $staged, 'add', 'staged.txt')

    $untracked = Join-Path $userplugins 'RewriteUntracked'
    Set-Content -LiteralPath (Join-Path $untracked 'untracked.txt') -Value 'untracked work' -Encoding ASCII

    $localCommit = Join-Path $userplugins 'RewriteLocalCommit'
    Invoke-TestGit @('-C', $localCommit, 'config', 'user.email', 'test@example.invalid')
    Invoke-TestGit @('-C', $localCommit, 'config', 'user.name', 'installer regression')
    Set-Content -LiteralPath (Join-Path $localCommit 'local.txt') -Value 'local commit' -Encoding ASCII
    Invoke-TestGit @('-C', $localCommit, 'add', '-A')
    Invoke-TestGit @('-C', $localCommit, 'commit', '--quiet', '-m', 'local only')
    $localCommitHead = Read-GitValue -Path $localCommit -Arguments @('rev-parse', 'HEAD')

    $discard = Join-Path $userplugins 'RewriteDiscard'
    Set-Content -LiteralPath (Join-Path $discard 'index.tsx') -Value 'discard me' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $discard 'remove-me.txt') -Value 'untracked discard' -Encoding ASCII
    Add-Content -LiteralPath (Join-Path $discard '.git\info\exclude') -Value 'ignored-local.txt'
    Set-Content -LiteralPath (Join-Path $discard 'ignored-local.txt') -Value 'keep ignored local data' -Encoding ASCII

    $decisionRace = Join-Path $userplugins 'RewriteDecisionRace'
    Set-Content -LiteralPath (Join-Path $decisionRace 'index.tsx') -Value 'original local edit' -Encoding ASCII

    # Rewrite upstream from the first commit so the old second commit is no longer an ancestor.
    # Every untouched clone still has HEAD == its pre-fetch origin/main at oldRemoteHead.
    Invoke-TestGit @('-C', $upstream, 'reset', '--hard', '--quiet', $first)
    Set-Content -LiteralPath (Join-Path $upstream 'index.tsx') -Value 'rewritten second' -Encoding ASCII
    Invoke-TestGit @('-C', $upstream, 'add', '-A')
    Invoke-TestGit @('-C', $upstream, 'commit', '--quiet', '-m', 'rewritten second')
    $newRemoteHead = Read-GitValue -Path $upstream -Arguments @('rev-parse', 'HEAD')
    Assert-False ($newRemoteHead -eq $oldRemoteHead) 'The fixture must actually rewrite upstream history.'

    $decisionCalls = New-Object System.Collections.Generic.List[string]
    $decisionProvider = {
        param($context)
        [void]$decisionCalls.Add([string]$context.Name)
        if ($context.Name -eq 'RewriteDiscard') { return 'discard' }
        if ($context.Name -eq 'RewriteDecisionRace') {
            # Simulate the checkout changing after the summary was shown but before the user
            # answered. Explicit consent for the old snapshot must not discard this new work.
            Set-Content -LiteralPath (Join-Path $context.Path 'arrived-during-decision.txt') -Value 'new work' -Encoding ASCII
            return 'discard'
        }
        return 'keep'
    }

    $results = @(Update-CompanionUserplugins -InstallDir (Join-Path $temp 'install') -DecisionProvider $decisionProvider)
    $byName = @{}
    foreach ($row in $results) { $byName[$row.Name] = $row }

    Assert-False ($byName.ContainsKey('audisk')) 'audisk must stay outside the companion updater.'

    $clean = Join-Path $userplugins 'RewriteClean'
    Assert-Equal $byName['RewriteClean'].Status 'updated' 'A clean untouched checkout must recover automatically from an upstream rewrite.'
    Assert-Equal (Read-GitValue -Path $clean -Arguments @('rev-parse', 'HEAD')) $newRemoteHead 'Clean rewrite recovery must land exactly on the fetched upstream.'
    Assert-Equal (Get-Content -LiteralPath (Join-Path $clean 'index.tsx') -Raw).Trim() 'rewritten second' 'Clean rewrite recovery must install the rewritten content.'
    Assert-True ($byName['RewriteClean'].Detail -match 'history was rewritten') 'Clean rewrite recovery should explain why a reset was safe.'
    Assert-False ($decisionCalls.Contains('RewriteClean')) 'An untouched checkout must never prompt for a rewrite it can prove is upstream-only.'

    Assert-Equal $byName['RewriteDirty'].Status 'failed' 'An unstaged edit must be kept unless the user explicitly discards it.'
    Assert-Equal (Read-GitValue -Path $dirty -Arguments @('rev-parse', 'HEAD')) $oldRemoteHead 'Keeping an unstaged edit must not move HEAD.'
    Assert-Equal (Get-Content -LiteralPath (Join-Path $dirty 'index.tsx') -Raw).Trim() 'local dirty edit' 'Keeping an unstaged edit must preserve its contents.'
    Assert-True ($decisionCalls.Contains('RewriteDirty')) 'An unstaged edit must require a user decision when an update is actually pending.'

    Assert-Equal $byName['RewriteStaged'].Status 'failed' 'A staged edit must be protected by default.'
    Assert-Equal (Read-GitValue -Path $staged -Arguments @('rev-parse', 'HEAD')) $oldRemoteHead 'Keeping staged work must not move HEAD.'
    Assert-True (Test-Path -LiteralPath (Join-Path $staged 'staged.txt') -PathType Leaf) 'Keeping staged work must preserve the file.'
    Assert-True ($decisionCalls.Contains('RewriteStaged')) 'Staged work must require a user decision when an update is actually pending.'

    Assert-Equal $byName['RewriteUntracked'].Status 'failed' 'An untracked file must be protected by default.'
    Assert-Equal (Read-GitValue -Path $untracked -Arguments @('rev-parse', 'HEAD')) $oldRemoteHead 'Keeping untracked work must not move HEAD.'
    Assert-True (Test-Path -LiteralPath (Join-Path $untracked 'untracked.txt') -PathType Leaf) 'Keeping untracked work must preserve the file.'
    Assert-True ($decisionCalls.Contains('RewriteUntracked')) 'Untracked work must require a user decision when an update is actually pending.'

    Assert-Equal $byName['RewriteLocalCommit'].Status 'failed' 'A clean local-only commit must never be mistaken for an untouched checkout.'
    Assert-Equal (Read-GitValue -Path $localCommit -Arguments @('rev-parse', 'HEAD')) $localCommitHead 'Keeping a local commit must preserve its HEAD.'
    Assert-True (Test-Path -LiteralPath (Join-Path $localCommit 'local.txt') -PathType Leaf) 'Keeping a local commit must preserve its content.'
    Assert-True ($byName['RewriteLocalCommit'].Detail -match '1 local commit') 'The updater should summarize local history without counting the remote rewrite itself.'
    Assert-True ($decisionCalls.Contains('RewriteLocalCommit')) 'A local-only commit must require a user decision when an update is pending.'

    Assert-Equal $byName['RewriteDiscard'].Status 'updated' 'Explicit discard must allow a locally modified checkout to update.'
    Assert-Equal (Read-GitValue -Path $discard -Arguments @('rev-parse', 'HEAD')) $newRemoteHead 'Explicit discard must land exactly on the fetched upstream.'
    Assert-Equal (Get-Content -LiteralPath (Join-Path $discard 'index.tsx') -Raw).Trim() 'rewritten second' 'Explicit discard must restore tracked files from upstream.'
    Assert-False (Test-Path -LiteralPath (Join-Path $discard 'remove-me.txt')) 'Explicit discard must remove non-ignored untracked files.'
    Assert-True (Test-Path -LiteralPath (Join-Path $discard 'ignored-local.txt') -PathType Leaf) 'Explicit discard must preserve ignored local files.'
    $discardStatus = @(& $realGit -C $discard status --short --untracked-files=all 2>$null)
    Assert-Equal $discardStatus.Count 0 'Explicit discard must leave a clean checkout apart from ignored files.'
    Assert-True ($decisionCalls.Contains('RewriteDiscard')) 'A destructive discard must only happen after an explicit decision.'

    Assert-Equal $byName['RewriteDecisionRace'].Status 'failed' 'A checkout that changes while Discard is being decided must be kept instead of reset.'
    Assert-Equal (Read-GitValue -Path $decisionRace -Arguments @('rev-parse', 'HEAD')) $oldRemoteHead 'Decision-time mutation must abort the reset and preserve HEAD.'
    Assert-Equal (Get-Content -LiteralPath (Join-Path $decisionRace 'index.tsx') -Raw).Trim() 'original local edit' 'Decision-time mutation must preserve the original tracked edit.'
    Assert-True (Test-Path -LiteralPath (Join-Path $decisionRace 'arrived-during-decision.txt') -PathType Leaf) 'Decision-time mutation must preserve work created after the summary.'
    Assert-True ($byName['RewriteDecisionRace'].Detail -match 'changed while the discard decision was pending') 'The updater should explain why the destructive decision was cancelled.'

    # Non-interactive callers deliberately have no Read-Host fallback. With local work present,
    # no DecisionProvider means Keep and must never reset either tracked content or HEAD.
    $defaultKeepResults = @(Update-CompanionUserplugins -InstallDir $defaultKeepInstall)
    Assert-Equal $defaultKeepResults.Count 1 'The non-interactive keep fixture should produce one result.'
    Assert-Equal $defaultKeepResults[0].Status 'failed' 'Without a DecisionProvider, local work must be kept and the update skipped.'
    Assert-True ($defaultKeepResults[0].Detail -match 'local work kept') 'The default Keep result should explain why the update was skipped.'
    Assert-Equal (Read-GitValue -Path $defaultKeep -Arguments @('rev-parse', 'HEAD')) $defaultKeepHead 'Default Keep must not move HEAD.'
    Assert-Equal (Get-Content -LiteralPath (Join-Path $defaultKeep 'index.tsx') -Raw).Trim() 'noninteractive local edit' 'Default Keep must preserve local tracked content.'

    # Deterministically inject a new local edit after the non-fast-forward merge fails but before
    # the auto-rewrite recovery reaches reset --hard. The updater must revalidate its old clean
    # proof and preserve this edit instead of relying on the pre-fetch snapshot.
    $global:AudiskRegressionRealGit = $realGit
    $global:AudiskRegressionRaceCheckout = $race
    $global:AudiskRegressionRaceInjected = $false
    function global:git {
        $captured = @($args)
        & $global:AudiskRegressionRealGit @captured
        $code = $LASTEXITCODE
        if (-not $global:AudiskRegressionRaceInjected -and $code -ne 0 -and
            $captured -contains 'merge' -and $captured -contains $global:AudiskRegressionRaceCheckout) {
            Set-Content -LiteralPath (Join-Path $global:AudiskRegressionRaceCheckout 'arrived-before-reset.txt') -Value 'new local work' -Encoding ASCII
            $global:AudiskRegressionRaceInjected = $true
        }
        $global:LASTEXITCODE = $code
    }
    try {
        $raceResults = @(Update-CompanionUserplugins -InstallDir $raceInstall)
    } finally {
        Remove-Item Function:\git -Force -ErrorAction SilentlyContinue
        Remove-Variable AudiskRegressionRealGit -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable AudiskRegressionRaceCheckout -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable AudiskRegressionRaceInjected -Scope Global -ErrorAction SilentlyContinue
    }
    Assert-Equal $raceResults.Count 1 'The reset-race fixture should produce one updater result.'
    Assert-Equal $raceResults[0].Status 'failed' 'New work appearing before auto-reset must invalidate the automatic recovery proof.'
    Assert-Equal (Read-GitValue -Path $race -Arguments @('rev-parse', 'HEAD')) $raceHead 'Auto-reset revalidation must preserve the old HEAD when new work appears.'
    Assert-True (Test-Path -LiteralPath (Join-Path $race 'arrived-before-reset.txt') -PathType Leaf) 'Auto-reset revalidation must preserve work that arrived after merge failed.'

    Assert-Equal @(Update-CompanionUserplugins -InstallDir (Join-Path $temp 'missing')).Count 0 'A missing userplugins directory must still be a no-op.'
} finally {
    Remove-Item Function:\git -Force -ErrorAction SilentlyContinue
    Remove-Variable AudiskRegressionRealGit -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable AudiskRegressionRaceCheckout -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable AudiskRegressionRaceInjected -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Companion rewrite regression passed.' -ForegroundColor Green
