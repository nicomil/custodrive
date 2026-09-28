<#
.SYNOPSIS
    Gate V2 of the v1 copy protocol: Windows checks every case image.

.DESCRIPTION
    Reads cases.tsv and base-files.sha256 produced on the Mac by
    Tests/prepare-windows-v1-cases.sh. For each case it attaches a private
    copy of the VHD read/write, records the dirty state, runs chkdsk without
    repair, then - for cases that must be repaired, or whenever the first
    check is not clean - runs chkdsk /f /x followed by a second read-only
    chkdsk. Finally it hashes the files that existed before OpenHDD wrote and
    the files OpenHDD added.

    Verdicts:
      PASS        clean where expected; after repair the second chkdsk is
                  clean and every pre-existing file is at its path, intact
      PASS_MOVED  as PASS, but chkdsk moved a pre-existing file (for example
                  into found.000); content intact, location changed
      FAIL        anything else

    Only the private copies are attached. The case VHDs are hashed before
    and after and must not change.

.EXAMPLE
    & .\verify-v1-cases.ps1 -CaseDirectory C:\OpenHDD-Lab\v1\cases -ArtifactDirectory C:\OpenHDD-Lab\v1\verify-1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $CaseDirectory,
    [Parameter(Mandatory = $true)]
    [string] $ArtifactDirectory,
    [string[]] $Only = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

if (Test-Path -LiteralPath $ArtifactDirectory) {
    if (@(Get-ChildItem -LiteralPath $ArtifactDirectory -Force).Count -gt 0) { throw 'REFUSED: artifact directory must be new or empty' }
}
New-Item -ItemType Directory -Force -Path $ArtifactDirectory | Out-Null

$cases = @(Import-Csv -LiteralPath (Join-Path $CaseDirectory 'cases.tsv') -Delimiter "`t" -Encoding UTF8)
$baseFiles = @(Get-Content -LiteralPath (Join-Path $CaseDirectory 'base-files.sha256') -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object {
    $parts = $_ -split '  ', 3
    [pscustomobject]@{ Hash = $parts[0].Trim().ToLowerInvariant(); Length = [long]$parts[1]; Path = $parts[2].Trim() }
})

function Invoke-Chkdsk([string] $Letter, [string[]] $Arguments, [string] $LogPath) {
    $output = & chkdsk.exe $Letter @Arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    Set-Content -Encoding UTF8 -LiteralPath $LogPath -Value $output
    [ordered]@{ arguments = ($Arguments -join ' '); exit_code = $code; log = (Split-Path -Leaf $LogPath) }
}

function Wait-Letter($DiskImage) {
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        $disk = @($DiskImage | Get-Disk)[0]
        if ($null -eq $disk -or $disk.IsSystem -or $disk.IsBoot) { continue }
        $partitions = @($disk | Get-Partition | Where-Object { $_.Type -ne 'Reserved' })
        if ($partitions.Count -ne 1) { continue }
        if (-not $partitions[0].DriveLetter -or $partitions[0].DriveLetter -eq [char]0) {
            try { $partitions[0] | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop } catch { }
            continue
        }
        return $partitions[0]
    }
    throw 'working copy did not expose one partition with a drive letter'
}

function Find-ByHash([string] $Root, [string] $Hash, [long] $Length) {
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -eq $Length } |
        Where-Object { (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant() -eq $Hash } |
        Select-Object -First 1
}

$summary = @()
foreach ($case in $cases) {
    if ($Only.Count -and $Only -notcontains $case.case) { continue }
    $dir = Join-Path $ArtifactDirectory $case.case
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $source = Join-Path $CaseDirectory ($case.case + '.vhd')
    $work = Join-Path $dir 'working.vhd'
    $r = [ordered]@{ case = $case.case; expect = $case.expect; verdict = 'FAIL'; problems = @() }
    $mounted = $false
    $start = Get-Date
    try {
        $r.source_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant()
        Copy-Item -LiteralPath $source -Destination $work
        $image = Mount-DiskImage -ImagePath $work -StorageType VHD -Access ReadWrite -PassThru
        $mounted = $true
        $partition = Wait-Letter $image
        $letter = '{0}:' -f $partition.DriveLetter
        Start-Sleep -Seconds 2
        $volume = Get-Volume -DriveLetter $partition.DriveLetter
        $r.filesystem_on_attach = [string]$volume.FileSystem
        $r.health_on_attach = [string]$volume.HealthStatus
        $r.dirty_on_attach = (& fsutil dirty query $letter 2>&1 | Out-String).Trim()

        $r.check1 = Invoke-Chkdsk $letter @() (Join-Path $dir 'chkdsk-1.txt')
        $repair = $case.expect -eq 'repair' -or $r.check1.exit_code -ne 0
        if ($case.expect -eq 'clean' -and $r.check1.exit_code -ne 0) { $r.problems += 'first chkdsk not clean on a committed copy' }
        if ($repair) {
            $r.repair = Invoke-Chkdsk $letter @('/f', '/x') (Join-Path $dir 'chkdsk-2-repair.txt')
            Start-Sleep -Seconds 2
            $r.check2 = Invoke-Chkdsk $letter @() (Join-Path $dir 'chkdsk-3.txt')
            if ($r.check2.exit_code -ne 0) { $r.problems += 'chkdsk after repair is not clean' }
        }
        $r.dirty_after = (& fsutil dirty query $letter 2>&1 | Out-String).Trim()
        $rootPath = $letter + '\'

        $moved = 0
        $r.base_files = @()
        foreach ($f in $baseFiles) {
            $path = Join-Path $rootPath $f.Path
            $state = 'missing'
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $state = $(if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() -eq $f.Hash) { 'ok' } else { 'CHANGED' })
            }
            if ($state -ne 'ok') {
                $found = Find-ByHash $rootPath $f.Hash $f.Length
                if ($found) { $state = 'moved:' + $found.FullName.Substring(3); $moved++ }
                else { $r.problems += "pre-existing file $($f.Path) is $state" }
            }
            $r.base_files += [ordered]@{ path = $f.Path; state = $state }
        }

        $r.new_files = @()
        foreach ($spec in ($case.new_files -split ';')) {
            if (-not $spec) { continue }
            if ($spec.StartsWith('absent:') -or $spec.StartsWith('dir:')) {
                # Edits: an entry that must be gone, or a folder that must exist.
                $rel = $spec.Substring($spec.IndexOf(':') + 1)
                $path = Join-Path $rootPath $rel
                $present = Test-Path -LiteralPath $path
                $state = $(if ($spec.StartsWith('absent:')) { if ($present) { 'STILL_PRESENT' } else { 'absent' } }
                          else { if (Test-Path -LiteralPath $path -PathType Container) { 'folder' } else { 'MISSING' } })
                if ($case.expect -eq 'clean' -and ($state -eq 'STILL_PRESENT' -or $state -eq 'MISSING')) {
                    $r.problems += "entry $rel is $state"
                }
                $r.new_files += [ordered]@{ path = $rel; state = $state; optional = ($case.expect -ne 'clean') }
                continue
            }
            $optional = $spec.StartsWith('optional:')
            $spec = $spec -replace '^optional:', ''
            $hash, $rel = $spec -split '\|', 2
            $path = Join-Path $rootPath $rel
            $state = 'absent'
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
                $state = $(if ($hash -eq 'any' -or $actual -eq $hash) { 'ok' } else { 'WRONG_CONTENT' })
            }
            if ($state -eq 'WRONG_CONTENT' -or (-not $optional -and $state -ne 'ok')) { $r.problems += "new file $rel is $state" }
            $r.new_files += [ordered]@{ path = $rel; state = $state; optional = $optional }
        }
        $r.leftovers = @(Get-ChildItem -LiteralPath $rootPath -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '.OpenHDD-pending-*' -or $_.Name -like 'found.*' } | ForEach-Object { $_.Name })

        if ($r.problems.Count -eq 0) { $r.verdict = $(if ($moved) { 'PASS_MOVED' } else { 'PASS' }) }
    }
    catch {
        $r.problems += $_.Exception.Message
    }
    finally {
        if ($mounted) { try { Dismount-DiskImage -ImagePath $work -ErrorAction Stop | Out-Null } catch { $r.problems += 'dismount: ' + $_.Exception.Message } }
        try {
            $r.events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $start.AddSeconds(-1) } -ErrorAction Stop |
                Where-Object { $_.ProviderName -match 'Ntfs|Chkdsk' } |
                ForEach-Object { '{0} {1}: {2}' -f $_.ProviderName, $_.Id, ($_.Message -split "`n")[0].Trim() })
        } catch { $r.events = @() }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant() -ne $r.source_sha256) {
            $r.problems += 'CASE VHD CHANGED'; $r.verdict = 'FAIL'
        }
        Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
        $r | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $dir 'result.json')
    }
    $summary += [pscustomobject]@{
        case = $r.case; expect = $r.expect; verdict = $r.verdict
        attach = $(if ($r.Contains('filesystem_on_attach')) { $r.filesystem_on_attach } else { '' })
        chkdsk1 = $(if ($r.Contains('check1')) { $r.check1.exit_code } else { '' })
        repair = $(if ($r.Contains('repair')) { $r.repair.exit_code } else { '' })
        chkdsk2 = $(if ($r.Contains('check2')) { $r.check2.exit_code } else { '' })
        problems = ($r.problems -join '; ')
    }
    Write-Host ('{0,-24} {1}' -f $r.case, $r.verdict)
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 (Join-Path $ArtifactDirectory 'summary.json')
$summary | Format-Table -AutoSize | Out-String -Width 220
if (@($summary | Where-Object { $_.verdict -eq 'FAIL' }).Count) { exit 1 }
exit 0
