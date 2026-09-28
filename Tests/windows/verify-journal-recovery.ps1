[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ImagePath,
    [Parameter(Mandatory = $true)]
    [string] $ArtifactDirectory,
    [Parameter(Mandatory = $true)]
    [string] $ExpectedImageSha256,
    [Parameter(Mandatory = $true)]
    [string] $PreMountSelfHealingEvidence,
    [string[]] $SyntheticPath = @()
)

$ErrorActionPreference = 'Stop'
$mounted = $false
$diskImage = $null
$workingImage = $null
$failure = $null
$result = [ordered]@{
    schema = 'openhdd.windows-journal-verification.v1'
    status = 'INCONCLUDENTE'
    repair_commands = @('none')
    chkdsk = $null
    files = @()
}

New-Item -ItemType Directory -Force -Path $ArtifactDirectory | Out-Null
$resolvedImage = (Resolve-Path -LiteralPath $ImagePath -ErrorAction Stop).Path
try {
    if ([IO.Path]::GetExtension($resolvedImage).ToLowerInvariant() -ne '.vhd') {
        throw 'REFUSED: only fixed-size VHD is supported; VHDX and raw images are refused'
    }
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedImage).Hash.ToLowerInvariant()
    if ($actualHash -ne $ExpectedImageSha256.ToLowerInvariant()) {
        throw 'REFUSED: received image hash does not match expected hash'
    }
    $result.source_image_sha256 = $actualHash
    Copy-Item -LiteralPath $resolvedImage -Destination (Join-Path $ArtifactDirectory 'received.vhd') -Force
    if (-not (Test-Path -LiteralPath $PreMountSelfHealingEvidence -PathType Leaf)) {
        $result.reason = 'pre-mount self-healing control is not evidenced'
    }
    else {
        Copy-Item -LiteralPath $PreMountSelfHealingEvidence -Destination (Join-Path $ArtifactDirectory 'self-healing-evidence.txt') -Force
        $workingImage = Join-Path $ArtifactDirectory 'working.vhd'
        Copy-Item -LiteralPath $resolvedImage -Destination $workingImage -Force
        $result.working_image_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $workingImage).Hash.ToLowerInvariant()

        $diskImage = Mount-DiskImage -ImagePath $workingImage -StorageType VHD -Access ReadWrite -PassThru
        $mounted = $true
        $disk = $null
        $partitions = @()
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            Start-Sleep -Milliseconds 500
            $disk = @($diskImage | Get-Disk)[0]
            if ($null -ne $disk -and -not $disk.IsSystem -and $null -ne $disk.Number) {
                $partitions = @($disk | Get-Partition | Where-Object { $_.Type -ne 'Reserved' })
                if ($partitions.Count -eq 1) { break }
            }
        }
        if ($null -eq $disk -or $disk.IsSystem -or $null -eq $disk.Number) { throw 'REFUSED: ambiguous or system disk' }
        if ($partitions.Count -ne 1) { throw 'REFUSED: image must expose exactly one data partition after retry' }
        $volumes = @($partitions | Get-Volume)
        if ($volumes.Count -ne 1 -or $volumes[0].FileSystem -ne 'NTFS' -or -not $volumes[0].DriveLetter) {
            throw 'REFUSED: mounted partition is not one NTFS volume'
        }
        $letter = '{0}:' -f $volumes[0].DriveLetter

        & chkdsk $letter 2>&1 | Tee-Object -FilePath (Join-Path $ArtifactDirectory 'chkdsk.txt')
        $result.chkdsk = [ordered]@{ exit_code = $LASTEXITCODE; command = "chkdsk $letter" }
        foreach ($path in $SyntheticPath) {
            $resolved = Join-Path $letter $path
            if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "missing synthetic file: $path" }
            $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $resolved
            $result.files += [ordered]@{ path = $path; length = (Get-Item -LiteralPath $resolved).Length; sha256 = $hash.Hash.ToLowerInvariant() }
        }
        $result.reason = 'offline structure validation and recovery-causality proof are still required'
    }
}
catch {
    $failure = $_.Exception.Message
    $result.status = 'ERRORE'
    $result.reason = $failure
}
finally {
    if ($mounted) {
        try { Dismount-DiskImage -ImagePath $workingImage -ErrorAction Stop }
        catch { $result.dismount_error = $_.Exception.Message }
    }
    try {
        if ($null -ne $workingImage -and (Test-Path -LiteralPath $workingImage -PathType Leaf)) {
            $result.working_image_sha256_after_unmount = (Get-FileHash -Algorithm SHA256 -LiteralPath $workingImage).Hash.ToLowerInvariant()
        }
        if (Test-Path -LiteralPath $resolvedImage -PathType Leaf) {
            $sourceAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedImage).Hash.ToLowerInvariant()
            $result.source_image_sha256_after = $sourceAfter
            $result.source_image_unchanged = ($sourceAfter -eq $result.source_image_sha256)
        }
    }
    catch { $result.post_mount_hash_error = $_.Exception.Message }
    $result | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $ArtifactDirectory 'result.json')
}

Write-Output ($result | ConvertTo-Json -Depth 8)
if ($null -ne $failure) { exit 1 }
exit 77
