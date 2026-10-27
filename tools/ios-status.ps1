<#
.SYNOPSIS
    How a build's iOS (TestFlight) run on GitHub is going.

.DESCRIPTION
    tools\build.ps1 -Bump pushes each build's tag (exp-build-<n>, or build-<n> for a stable one); GitHub then builds that commit for iPhone / iPad and
    uploads it to TestFlight (.github\workflows\testflight.yml, about 15-20 minutes). This finds that run and says
    where it is: queued, the step it's on and for how long, or how it ended - and, once uploaded, that Apple still
    processes it for a few minutes before TestFlight offers it.

    Exit codes: 0 = uploaded, 1 = failed or cancelled, 2 = still running or queued, 3 = no run found (the tag not
    pushed, or GitHub hasn't started it yet).

.EXAMPLE
    .\tools\ios-status.ps1               (the newest build, either kind of tag)
    .\tools\ios-status.ps1 -Build 127
#>
param(
    [int]$Build = 0,
    [string]$Ref = ''   # another tag or branch instead (e.g. ios, the branch TestFlight builds came from before)
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$gh = 'C:\Dev\gh\bin\gh.exe'
$repo = 'akajimmy/bedereader'

# one line of numbers for both apps: build <n> is tagged exp-build-<n> (BeDeReader Exp, the everyday build) or
# build-<n> (a stable BeDeReader) - whichever exists
$tags = @(git -C $root tag -l 'build-*' 'exp-build-*' | Where-Object { $_ -match '^(exp-)?build-\d+$' })
if (-not $Build) {
    $Build = ($tags | ForEach-Object { [int]($_ -replace '^(exp-)?build-', '') } | Measure-Object -Maximum).Maximum
}
$tag = if ($Ref) { $Ref } elseif ($tags -contains "build-$Build") { "build-$Build" } else { "exp-build-$Build" }

$runs = & $gh run list --repo $repo --workflow testflight.yml --branch $tag --limit 1 `
    --json databaseId,status,conclusion,createdAt,updatedAt,url | ConvertFrom-Json
if (-not $runs) {
    # (through cmd: PowerShell 5.1 turns gh's "Not Found" on stderr into an error that stops the script)
    cmd /c "`"$gh`" api repos/$repo/git/refs/tags/$tag --silent >nul 2>nul"; $onGitHub = $LASTEXITCODE -eq 0
    if ($onGitHub) { Write-Host "$tag is on GitHub but its TestFlight run hasn't started yet - try again in a minute." }
    else { Write-Host "$tag isn't on GitHub: no TestFlight build (built with -NoIos, or the push failed)." }
    exit 3
}
$run = @($runs)[0]
$minutes = { param($from, $to) [int](([datetime]$to) - ([datetime]$from)).TotalMinutes }

if ($run.status -eq 'completed') {
    $took = & $minutes $run.createdAt $run.updatedAt
    if ($run.conclusion -eq 'success') {
        Write-Host "iOS $tag`: uploaded to TestFlight ($took min). Apple processes it for a few minutes before it shows."
        Write-Host "  $($run.url)"
        exit 0
    }
    $jobs = (& $gh run view $run.databaseId --repo $repo --json jobs | ConvertFrom-Json).jobs
    $failed = $jobs.steps | Where-Object { $_.conclusion -eq 'failure' } | Select-Object -First 1
    $where = if ($failed) { ' - at the step "{0}"' -f $failed.name } else { '' }
    Write-Host ('iOS {0}: {1} after {2} min{3}' -f $tag, $run.conclusion.ToUpper(), $took, $where)
    Write-Host "  $($run.url)"
    exit 1
}

$now = (Get-Date).ToUniversalTime().ToString('o')
$elapsed = & $minutes $run.createdAt $now
if ($run.status -ne 'in_progress') {
    Write-Host "iOS $tag`: $($run.status) for $elapsed min (waiting for a GitHub Mac runner)"
    Write-Host "  $($run.url)"
    exit 2
}
$jobs = (& $gh run view $run.databaseId --repo $repo --json jobs | ConvertFrom-Json).jobs
$steps = @($jobs.steps)
$current = $steps | Where-Object { $_.status -eq 'in_progress' } | Select-Object -First 1
$done = @($steps | Where-Object { $_.status -eq 'completed' }).Count
$on = if ($current) {
    $since = if ($current.startedAt) { ' for {0} min' -f (& $minutes $current.startedAt $now) } else { '' }
    'step {0}/{1} "{2}"{3}' -f ($done + 1), $steps.Count, $current.name, $since
} else { '{0}/{1} steps done' -f $done, $steps.Count }
Write-Host "iOS $tag`: running $elapsed min - $on"
Write-Host "  $($run.url)"
exit 2
