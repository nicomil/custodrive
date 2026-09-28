[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ImagePath,
    [Parameter(Mandatory = $true)]
    [string] $ArtifactDirectory,
    [Parameter(Mandatory = $true)]
    [string] $ExpectedImageSha256
)

$ErrorActionPreference = 'Stop'
$mounted = $false
$workingImage = $null
$diskImage = $null
$failure = $null
$result = [ordered]@{
    schema = 'openhdd.windows-ntfs-partition-export.v1'
    status = 'INCONCLUDENTE'
    writer = 'REFUSED_G1_NOT_PASSED'
    source_image_sha256 = $null
    source_image_sha256_after = $null
    source_image_unchanged = $null
    working_image_sha256 = $null
    working_image_sha256_after_unmount = $null
    partition = $null
    output = $null
    raw_read_only = $true
}

New-Item -ItemType Directory -Force -Path $ArtifactDirectory | Out-Null
$resultPath = Join-Path $ArtifactDirectory 'result.json'

try {
    $source = Get-Item -LiteralPath $ImagePath -Force
    if (-not $source.PSIsContainer -and ($source.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'REFUSED: source is a reparse point or symlink'
    }
    if ($source.PSIsContainer -or $source.Extension.ToLowerInvariant() -ne '.vhd') {
        throw 'REFUSED: only a regular VHD is supported'
    }

    $resolvedSource = $source.FullName
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedSource).Hash.ToLowerInvariant()
    if ($sourceHash -ne $ExpectedImageSha256.ToLowerInvariant()) {
        throw 'REFUSED: source VHD hash does not match expected hash'
    }
    $result.source_image_sha256 = $sourceHash

    Copy-Item -LiteralPath $resolvedSource -Destination (Join-Path $ArtifactDirectory 'received.vhd') -Force
    $workingImage = Join-Path $ArtifactDirectory 'working.vhd'
    Copy-Item -LiteralPath $resolvedSource -Destination $workingImage -Force
    $result.working_image_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $workingImage).Hash.ToLowerInvariant()

    $diskImage = Mount-DiskImage -ImagePath $workingImage -StorageType VHD -Access ReadOnly -PassThru
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
    if ($null -eq $disk -or $disk.IsSystem -or $null -eq $disk.Number) {
        throw 'REFUSED: ambiguous or system disk'
    }
    if ($partitions.Count -ne 1) {
        throw 'REFUSED: VHD must expose exactly one data partition after retry'
    }

    $partition = $partitions[0]
    $volume = @($partition | Get-Volume)
    if ($volume.Count -ne 1 -or $volume[0].FileSystem -ne 'NTFS') {
        throw 'REFUSED: partition is not exactly one NTFS volume'
    }

    $partitionImage = Join-Path $ArtifactDirectory 'partition.img'
    $devicePath = "\\.\PhysicalDrive$($disk.Number)"
    $inputStream = $null
    $outputStream = $null
    try {
        $inputStream = [IO.File]::Open($devicePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $inputStream.Seek([int64]$partition.Offset, [IO.SeekOrigin]::Begin) | Out-Null
        $outputStream = [IO.File]::Open($partitionImage, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] (4MB)
        $remaining = [int64]$partition.Size
        while ($remaining -gt 0) {
            $requested = [int][Math]::Min($buffer.Length, $remaining)
            $read = $inputStream.Read($buffer, 0, $requested)
            if ($read -le 0) { throw 'raw partition read ended before expected size' }
            $outputStream.Write($buffer, 0, $read)
            $remaining -= $read
        }
    }
    finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
    }

    $result.partition = [ordered]@{
        disk_number = [int]$disk.Number
        offset = [int64]$partition.Offset
        size = [int64]$partition.Size
        filesystem = $volume[0].FileSystem
    }
    $result.output = [ordered]@{
        path = $partitionImage
        size = (Get-Item -LiteralPath $partitionImage).Length
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $partitionImage).Hash.ToLowerInvariant()
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
        if (Test-Path -LiteralPath $ImagePath -PathType Leaf) {
            $result.source_image_sha256_after = (Get-FileHash -Algorithm SHA256 -LiteralPath $ImagePath).Hash.ToLowerInvariant()
            $result.source_image_unchanged = ($result.source_image_sha256_after -eq $result.source_image_sha256)
        }
    }
    catch { $result.post_mount_hash_error = $_.Exception.Message }
    $result | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $resultPath
}

Write-Output ($result | ConvertTo-Json -Depth 8)
if ($null -ne $failure) { exit 1 }
exit 77
