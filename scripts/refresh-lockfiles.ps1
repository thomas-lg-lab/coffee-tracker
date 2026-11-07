<#
.SYNOPSIS
    Regenerates the backend packages.lock.json files after a NuGet version change.

.DESCRIPTION
    backend/Directory.Build.props sets RestorePackagesWithLockFile, and CI restores
    with --locked-mode (see .github/workflows/ci.yml) so a dependency bump cannot land
    without a reviewed lock file. NuGet writes one lock file per project, so bumping a
    package in Application or Infrastructure also invalidates the lock files of Api and
    Tests, which reference them transitively. A bump that only refreshes the lock file of
    the project whose .csproj it edited fails with:

        error NU1004: The project references coffeetracker.infrastructure whose
        dependencies has changed. The packages lock file is inconsistent with the
        project dependencies so restore can't be run in locked mode.

    Renovate restores every dependent project on its own PRs, so this is for changes made
    by hand: a solution-wide `dotnet restore --force-evaluate`, which
    re-resolves every graph and rewrites every lock file. It runs natively when a .NET
    SDK is on PATH, and otherwise inside the same SDK container image the Dockerfile
    uses, so it works on a host with no SDK installed as well as in the dev container.

    It refuses to leave behind changes to anything other than the lock files: a modified
    .csproj would mean the restore resolved something the version bump did not intend.

.PARAMETER Check
    Verify only. Runs the CI restore (--locked-mode) and fails if the lock files are
    inconsistent, without rewriting anything.

.EXAMPLE
    ./scripts/refresh-lockfiles.ps1
    Refresh the lock files, then `git add backend/*/packages.lock.json` and commit.

.EXAMPLE
    ./scripts/refresh-lockfiles.ps1 -Check
    Reproduce the CI restore locally to confirm the committed lock files are consistent.
#>
[CmdletBinding()]
param(
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$solution = 'CoffeeTracker.sln'
$restoreArgs = if ($Check) { '--locked-mode' } else { '--force-evaluate' }

# Read the SDK image straight out of ./Dockerfile rather than repeating the digest here.
# Renovate bumps that digest regularly, so a copy in this file would silently go stale
# and start resolving against a different SDK (and a different bundled NuGet) than the
# image builds with -- which is exactly the class of drift this script exists to prevent.
function Get-SdkImage {
    $dockerfile = Join-Path $repoRoot 'Dockerfile'
    $match = Select-String -Path $dockerfile -Pattern '^FROM\s+(mcr\.microsoft\.com/dotnet/sdk:\S+)' |
        Select-Object -First 1
    if (-not $match) {
        throw "Could not find the .NET SDK 'FROM' line in $dockerfile."
    }
    return $match.Matches[0].Groups[1].Value
}

# Windows PowerShell 5.1 wraps every line a native command writes to stderr in an
# ErrorRecord, so with $ErrorActionPreference = 'Stop' ordinary progress output turns
# fatal -- docker's "Unable to find image ... locally" pull message did exactly that on
# the first run, before the SDK image is cached. Run natives with the preference relaxed
# and judge them by their exit code instead.
function Invoke-Native {
    param([Parameter(Mandatory)][string[]]$Command)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command[0] @($Command[1..($Command.Length - 1)])
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function Test-Sdk {
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) { return $false }
    # The dotnet *host* is present on many machines without any SDK; only an SDK can restore.
    $sdks = Invoke-Native @($dotnet.Source, '--list-sdks') 2>$null
    return [bool]$sdks
}

# Hash every tracked file under backend/ so we can tell exactly what the restore
# touched. Comparing `git status` before/after would misfire: the .csproj edits that
# prompted the refresh are themselves uncommitted in the normal workflow, and unrelated
# work elsewhere in the tree is none of this script's business.
function Get-BackendHashes {
    $hashes = @{}
    foreach ($file in & git ls-files backend) {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $hashes[$file] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        }
    }
    return $hashes
}

Push-Location $repoRoot
try {
    $before = if ($Check) { $null } else { Get-BackendHashes }

    if (Test-Sdk) {
        Write-Host "Restoring $solution with a local SDK ($restoreArgs)..."
        Invoke-Native @('dotnet', 'restore', $solution, $restoreArgs)
    }
    else {
        Write-Host 'No .NET SDK on PATH; falling back to the SDK container.'
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            throw 'Neither a .NET SDK nor docker is available. Install the .NET 10 SDK or start Docker.'
        }
        $sdkImage = Get-SdkImage
        Write-Host "Restoring $solution in $sdkImage ($restoreArgs)..."
        Invoke-Native @(
            'docker', 'run', '--rm', '-v', "${repoRoot}:/src", '-w', '/src',
            $sdkImage, 'dotnet', 'restore', $solution, $restoreArgs
        )
    }
    if ($LASTEXITCODE -ne 0) { throw "dotnet restore failed with exit code $LASTEXITCODE." }

    if ($Check) {
        Write-Host 'Lock files are consistent with the projects.' -ForegroundColor Green
        exit 0
    }

    # Restore rewrites the lock files on every run, so timestamps prove nothing; compare
    # content hashes to see what actually changed as a result of THIS restore.
    $after = Get-BackendHashes
    $changed = @(
        $after.Keys | Where-Object { -not $before.ContainsKey($_) -or $before[$_] -ne $after[$_] } | Sort-Object
    )
    $unexpected = @($changed | Where-Object { $_ -notmatch '^backend/[^/]+/packages\.lock\.json$' })

    if ($unexpected.Count -gt 0) {
        Write-Host 'The restore changed files other than the lock files:' -ForegroundColor Red
        $unexpected | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw 'Refusing to continue. A .csproj changed by the restore means it resolved something unintended.'
    }

    if ($changed.Count -eq 0) {
        Write-Host 'Lock files were already up to date; nothing to commit.' -ForegroundColor Green
    }
    else {
        Write-Host 'Refreshed:' -ForegroundColor Green
        $changed | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
        Write-Host 'Commit these, e.g. git commit -am "deps: refresh packages.lock.json"'
    }
}
finally {
    Pop-Location
}
