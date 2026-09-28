<#
.SYNOPSIS
    G1/T03 — controlled $LogFile acquisition and replay/self-healing observation.

.DESCRIPTION
    Acquires the NTFS $LogFile of a fixed-size VHD offline, by parsing the
    image bytes directly (VHD footer, MBR, NTFS boot sector, MFT runlists).
    Nothing is mounted to take the "before" snapshot, so the capture is
    coherent: the image is at rest and no driver is holding the volume.

    Unless -OfflineOnly is given, the script then mounts a private working
    copy read/write (never the original), records every signal that can tell
    NTFS journal replay apart from self-healing (fsutil repair state and
    corruption logs, NTFS/disk events, dirty bit), unmounts, acquires the
    "after" $LogFile offline, and diffs the image in 4 KiB blocks. Each
    changed block is attributed to the file that owns it, using a full MFT
    scan taken before and after the mount.

    Explicit non-goals, required by docs/specifica-recupero-transazionale-ntfs.md:
    - no chkdsk of any kind, no fsutil repair set/initiate, no ntfsfix;
    - the original image and the optional control image are only opened
      with FileAccess.Read and are never attached;
    - no writer, no crash simulation, no global setting is changed.

    Self-healing cannot be disabled before the first Windows access with the
    tools used here (fsutil repair set needs a mounted volume). The script
    therefore never reports the replay/self-healing distinction as proven:
    the best possible outcome is INCONCLUDENTE with a complete observation.
    G1 cannot pass from this script.

    Exit codes: 77 = INCONCLUDENTE (expected), 1 = ERRORE or REFUSED.

.EXAMPLE
    $Lab = "C:\OpenHDD-Lab"
    & "$Lab\acquire-logfile-replay_claude.ps1" `
        -ImagePath "$Lab\baseline-a.vhd" `
        -ExpectedImageSha256 "C91B09D575DFEC0D754E099760ABEC2E8455A46F040112EEDDBC68DC7C312E95" `
        -ControlImagePath "$Lab\baseline-b.vhd" `
        -ExpectedControlSha256 "FA087101EE9BA1F8946BEBD04B5E6F715B2C4A6C81E45246D34CBF1FF0776826" `
        -PreMountSelfHealingEvidence "$Lab\baseline-a-repair.txt" `
        -ArtifactDirectory "$Lab\t03-a-claude" `
        -SyntheticPath @("empty.bin","one.bin","sentinel-8MiB.bin")
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ImagePath,
    [Parameter(Mandatory = $true)]
    [string] $ArtifactDirectory,
    [Parameter(Mandatory = $true)]
    [string] $ExpectedImageSha256,
    [string] $ControlImagePath,
    [string] $ExpectedControlSha256,
    [string] $PreMountSelfHealingEvidence,
    [string[]] $SyntheticPath = @(),
    [ValidateRange(0, 600)]
    [int] $SettleSeconds = 10,
    [switch] $OfflineOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$BlockSize = 4096
$UInt32Max = [uint32]::MaxValue
# Event IDs that the Windows NTFS driver is known to log when it detects or
# repairs corruption. The mapping is an operational hypothesis, not a spec:
# every NTFS event in the window is kept in events.json regardless.
$RepairEventIds = @(55, 57, 98, 130, 131, 133, 134, 136, 137, 140, 141, 142)
$SystemFileNames = @{
    0 = '$MFT'; 1 = '$MFTMirr'; 2 = '$LogFile'; 3 = '$Volume'; 4 = '$AttrDef'
    5 = '.'; 6 = '$Bitmap'; 7 = '$Boot'; 8 = '$BadClus'; 9 = '$Secure'
    10 = '$UpCase'; 11 = '$Extend'
}

$result = [ordered]@{
    schema = 'openhdd.windows-logfile-acquisition.v1'
    script = 'acquire-logfile-replay_claude.ps1'
    status = 'INCONCLUDENTE'
    gate = [ordered]@{ G1 = 'INCONCLUDENTE'; T03_acquisition = 'NON_ESEGUITO'; T03_distinction = 'NON_ESEGUITO' }
    mode = $(if ($OfflineOnly) { 'offline-only' } else { 'offline-acquire+mount-copy' })
    repair_commands = @('none')
    host = $null
    source = $null
    control = $null
    self_healing = $null
    logfile_before = $null
    logfile_after = $null
    volume_before = $null
    volume_after = $null
    mount = $null
    changes = $null
    files = @()
    reasons = @()
}

# ---------------------------------------------------------------------------
# Binary helpers
# ---------------------------------------------------------------------------

function Read-Bytes([IO.Stream] $Stream, [long] $Offset, [int] $Count) {
    if ($Offset -lt 0 -or $Offset + $Count -gt $Stream.Length) { throw "read outside image: offset $Offset count $Count" }
    $buffer = New-Object byte[] $Count
    $null = $Stream.Seek($Offset, [IO.SeekOrigin]::Begin)
    $done = 0
    while ($done -lt $Count) {
        $n = $Stream.Read($buffer, $done, $Count - $done)
        if ($n -le 0) { throw "short read at offset $Offset" }
        $done += $n
    }
    return ,$buffer
}

function U16([byte[]] $B, [long] $O) { [BitConverter]::ToUInt16($B, $O) }
function U32([byte[]] $B, [long] $O) { [BitConverter]::ToUInt32($B, $O) }
function U64([byte[]] $B, [long] $O) { [BitConverter]::ToUInt64($B, $O) }
function I16([byte[]] $B, [long] $O) { [BitConverter]::ToInt16($B, $O) }
function Ascii([byte[]] $B, [long] $O, [int] $N) { [Text.Encoding]::ASCII.GetString($B, $O, $N) }
function Test-PowerOfTwo([long] $V) { $V -gt 0 -and ($V -band ($V - 1)) -eq 0 }

# NTFS multi-sector protection: the last two bytes of every 512-byte stride
# hold the update sequence number; the real bytes live in the array.
function Undo-Fixup([byte[]] $Buffer, [string] $What) {
    $usaOffset = U16 $Buffer 4
    $usaCount = U16 $Buffer 6
    if ($usaCount -lt 2 -or ($usaCount - 1) * 512 -gt $Buffer.Length -or $usaOffset + 2 * $usaCount -gt $Buffer.Length) {
        throw "${What}: invalid update sequence array"
    }
    $usn = U16 $Buffer $usaOffset
    for ($i = 1; $i -lt $usaCount; $i++) {
        $end = $i * 512 - 2
        if ((U16 $Buffer $end) -ne $usn) { throw "${What}: fixup mismatch in stride $i (torn or incomplete write)" }
        $Buffer[$end] = $Buffer[$usaOffset + 2 * $i]
        $Buffer[$end + 1] = $Buffer[$usaOffset + 2 * $i + 1]
    }
}

function ConvertFrom-Runlist([byte[]] $B, [int] $Pos, [int] $End, [long] $StartVcn) {
    $runs = New-Object System.Collections.ArrayList
    $vcn = $StartVcn
    $lcn = [long]0
    while ($Pos -lt $End) {
        $header = $B[$Pos]
        if ($header -eq 0) { break }
        $lengthSize = $header -band 0x0F
        $offsetSize = ($header -shr 4) -band 0x0F
        if ($lengthSize -lt 1 -or $lengthSize -gt 8 -or $offsetSize -gt 7 -or $Pos + 1 + $lengthSize + $offsetSize -gt $End) {
            throw ("invalid runlist header 0x{0:x2}" -f $header)
        }
        $length = [long]0
        for ($i = $lengthSize - 1; $i -ge 0; $i--) { $length = ($length -shl 8) -bor $B[$Pos + 1 + $i] }
        if ($length -le 0) { throw 'invalid runlist length' }
        if ($offsetSize -eq 0) {
            $null = $runs.Add([pscustomobject]@{ Vcn = $vcn; Lcn = -1; Length = $length; Sparse = $true })
        }
        else {
            $delta = [long]0
            for ($i = $offsetSize - 1; $i -ge 0; $i--) { $delta = ($delta -shl 8) -bor $B[$Pos + 1 + $lengthSize + $i] }
            if ($B[$Pos + $lengthSize + $offsetSize] -band 0x80) { $delta -= ([long]1 -shl (8 * $offsetSize)) }
            $lcn += $delta
            if ($lcn -lt 0) { throw 'runlist points before the volume' }
            $null = $runs.Add([pscustomobject]@{ Vcn = $vcn; Lcn = $lcn; Length = $length; Sparse = $false })
        }
        $vcn += $length
        $Pos += 1 + $lengthSize + $offsetSize
    }
    return ,$runs.ToArray()
}

# ---------------------------------------------------------------------------
# Image geometry: fixed VHD -> single MBR NTFS partition -> boot sector
# ---------------------------------------------------------------------------

function Open-NtfsImage([string] $Path) {
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $length = $stream.Length
        if ($length -lt 1MB -or ($length % 512) -ne 0) { throw 'REFUSED: image size is not a whole number of sectors' }
        $footer = Read-Bytes $stream ($length - 512) 512
        if ((Ascii $footer 0 8) -ne 'conectix') { throw 'REFUSED: VHD footer cookie missing' }
        $diskType = ([uint32]$footer[60] -shl 24) -bor ([uint32]$footer[61] -shl 16) -bor ([uint32]$footer[62] -shl 8) -bor [uint32]$footer[63]
        if ($diskType -ne 2) { throw "REFUSED: VHD disk type $diskType is not fixed" }
        $dataBytes = $length - 512

        $mbr = Read-Bytes $stream 0 512
        if ($mbr[510] -ne 0x55 -or $mbr[511] -ne 0xAA) { throw 'REFUSED: MBR signature missing' }
        $entries = @()
        for ($i = 0; $i -lt 4; $i++) {
            $e = 446 + 16 * $i
            if ($mbr[$e + 4] -ne 0) { $entries += [pscustomobject]@{ Type = $mbr[$e + 4]; Lba = (U32 $mbr ($e + 8)); Sectors = (U32 $mbr ($e + 12)) } }
        }
        if ($entries.Count -ne 1 -or $entries[0].Type -ne 0x07) { throw 'REFUSED: image must hold exactly one MBR partition of type 0x07' }
        $partitionOffset = [long]$entries[0].Lba * 512
        $partitionBytes = [long]$entries[0].Sectors * 512
        if ($partitionOffset -le 0 -or $partitionOffset + $partitionBytes -gt $dataBytes) { throw 'REFUSED: partition exceeds the VHD data area' }

        $boot = Read-Bytes $stream $partitionOffset 512
        if ((Ascii $boot 3 8) -ne 'NTFS    ') { throw 'REFUSED: partition boot sector is not NTFS' }
        $bytesPerSector = [long](U16 $boot 11)
        $spcRaw = [int]$boot[13]
        $sectorsPerCluster = $(if ($spcRaw -le 0x80) { [long]$spcRaw } else { [long]1 -shl (256 - $spcRaw) })
        $clusterSize = $bytesPerSector * $sectorsPerCluster
        $recordRaw = [int]$boot[64]
        $recordSize = $(if ($recordRaw -ge 0x80) { [long]1 -shl (256 - $recordRaw) } else { [long]$recordRaw * $clusterSize })
        if (-not (Test-PowerOfTwo $bytesPerSector) -or $bytesPerSector -lt 512 -or $bytesPerSector -gt 4096) { throw 'REFUSED: unsupported bytes per sector' }
        if (-not (Test-PowerOfTwo $clusterSize) -or $clusterSize -gt 2MB) { throw 'REFUSED: unsupported cluster size' }
        if ($recordSize -ne 1024 -and $recordSize -ne 4096) { throw 'REFUSED: unsupported MFT record size' }

        $ctx = [pscustomobject]@{
            Path = $Path; Stream = $stream; Length = $length
            PartitionOffset = $partitionOffset; PartitionBytes = $partitionBytes
            BytesPerSector = $bytesPerSector; ClusterSize = $clusterSize; RecordSize = $recordSize
            TotalSectors = (U64 $boot 40); MftLcn = [long](U64 $boot 48); MftMirrLcn = [long](U64 $boot 56)
            VolumeSerial = ('{0:X16}' -f (U64 $boot 72))
            MftRuns = $null; MftDataSize = 0
        }
        # Record 0 sits at the boot-sector LCN; its $DATA runlist maps the rest.
        $record0 = Read-MftRecordAt $ctx ($partitionOffset + $ctx.MftLcn * $clusterSize) 0
        $data = @(Get-Attributes $record0.Bytes | Where-Object { $_.Type -eq 0x80 -and $_.Name -eq '' })
        if ($data.Count -ne 1 -or -not $data[0].NonResident -or $data[0].StartVcn -ne 0) { throw 'REFUSED: $MFT $DATA must be one non-resident extent set' }
        $ctx.MftRuns = $data[0].Runs
        $ctx.MftDataSize = [long]$data[0].DataSize
        return $ctx
    }
    catch {
        $stream.Dispose()
        throw
    }
}

function Get-ImageOffsetForVcnByte($Ctx, $Runs, [long] $ByteOffset) {
    $vcn = [long][Math]::Floor($ByteOffset / $Ctx.ClusterSize)
    foreach ($run in $Runs) {
        if ($vcn -ge $run.Vcn -and $vcn -lt $run.Vcn + $run.Length) {
            if ($run.Sparse) { return -1 }
            return $Ctx.PartitionOffset + ($run.Lcn + ($vcn - $run.Vcn)) * $Ctx.ClusterSize + ($ByteOffset % $Ctx.ClusterSize)
        }
    }
    throw "byte offset $ByteOffset is not mapped by the runlist"
}

function Read-MftRecordAt($Ctx, [long] $ImageOffset, [long] $Number) {
    $bytes = Read-Bytes $Ctx.Stream $ImageOffset $Ctx.RecordSize
    $magic = Ascii $bytes 0 4
    $record = [pscustomobject]@{ Number = $Number; ImageOffset = $ImageOffset; Magic = $magic; Valid = $false; Error = $null; Bytes = $bytes }
    if ($magic -ne 'FILE') { $record.Error = 'no FILE signature'; return $record }
    try { Undo-Fixup $bytes "MFT record $Number"; $record.Valid = $true }
    catch { $record.Error = $_.Exception.Message }
    return $record
}

function Read-MftRecord($Ctx, [long] $Number) {
    $offset = Get-ImageOffsetForVcnByte $Ctx $Ctx.MftRuns ($Number * $Ctx.RecordSize)
    if ($offset -lt 0) { throw "MFT record $Number is sparse" }
    return Read-MftRecordAt $Ctx $offset $Number
}

function Get-Attributes([byte[]] $Record) {
    $list = New-Object System.Collections.ArrayList
    $pos = [int](U16 $Record 20)
    while ($pos + 8 -le $Record.Length) {
        $type = U32 $Record $pos
        if ($type -eq $UInt32Max) { break }
        $len = [int](U32 $Record ($pos + 4))
        if ($len -lt 16 -or $pos + $len -gt $Record.Length) { throw 'attribute length out of bounds' }
        $nonResident = $Record[$pos + 8] -ne 0
        $nameLength = [int]$Record[$pos + 9]
        $nameOffset = [int](U16 $Record ($pos + 10))
        $name = $(if ($nameLength -gt 0) { [Text.Encoding]::Unicode.GetString($Record, $pos + $nameOffset, 2 * $nameLength) } else { '' })
        $attr = [ordered]@{ Type = $type; Name = $name; NonResident = $nonResident; Offset = $pos; Length = $len }
        if ($nonResident) {
            $attr.StartVcn = [long](U64 $Record ($pos + 16))
            $attr.LastVcn = [long](U64 $Record ($pos + 24))
            $attr.AllocatedSize = [long](U64 $Record ($pos + 40))
            $attr.DataSize = [long](U64 $Record ($pos + 48))
            $attr.InitializedSize = [long](U64 $Record ($pos + 56))
            $attr.Runs = ConvertFrom-Runlist $Record ($pos + (U16 $Record ($pos + 32))) ($pos + $len) $attr.StartVcn
        }
        else {
            $attr.ValueLength = [int](U32 $Record ($pos + 16))
            $attr.ValueOffset = $pos + [int](U16 $Record ($pos + 20))
            if ($attr.ValueOffset + $attr.ValueLength -gt $pos + $len) { throw 'resident value out of bounds' }
        }
        $null = $list.Add([pscustomobject]$attr)
        $pos += $len
    }
    return $list.ToArray()
}

function Read-NonResidentData($Ctx, $Attr, [long] $MaxBytes) {
    if ($Attr.StartVcn -ne 0) { throw 'attribute spans several extents; attribute lists are not supported' }
    if ($Attr.DataSize -gt $MaxBytes) { throw "attribute larger than $MaxBytes bytes" }
    $out = New-Object byte[] $Attr.DataSize
    foreach ($run in $Attr.Runs) {
        $start = $run.Vcn * $Ctx.ClusterSize
        if ($start -ge $Attr.DataSize) { break }
        $count = [Math]::Min($run.Length * $Ctx.ClusterSize, $Attr.DataSize - $start)
        if ($run.Sparse) { continue }
        $chunk = Read-Bytes $Ctx.Stream ($Ctx.PartitionOffset + $run.Lcn * $Ctx.ClusterSize) $count
        [Array]::Copy($chunk, 0, $out, $start, $count)
    }
    return ,$out
}

function Get-ImageExtents($Ctx, $Runs) {
    @($Runs | Where-Object { -not $_.Sparse } | ForEach-Object {
        [pscustomobject]@{ Start = $Ctx.PartitionOffset + $_.Lcn * $Ctx.ClusterSize; Length = $_.Length * $Ctx.ClusterSize }
    })
}

# ---------------------------------------------------------------------------
# MFT scan: every record, its names and the image bytes it owns
# ---------------------------------------------------------------------------

function Get-MftInventory($Ctx) {
    $count = [long][Math]::Floor($Ctx.MftDataSize / $Ctx.RecordSize)
    $records = @{}
    for ($n = [long]0; $n -lt $count; $n++) {
        $rec = Read-MftRecord $Ctx $n
        $entry = [ordered]@{
            number = $n; valid = $rec.Valid; error = $rec.Error; in_use = $false; directory = $false
            lsn = 0; sequence = 0; base_record = 0; parent = $null; name = $null
            image_offset = $rec.ImageOffset; extents = @(); attributes = @()
        }
        if ($rec.Valid) {
            $b = $rec.Bytes
            $flags = U16 $b 22
            $entry.in_use = ($flags -band 1) -ne 0
            $entry.directory = ($flags -band 2) -ne 0
            $entry.lsn = U64 $b 8
            $entry.sequence = U16 $b 16
            $entry.base_record = [long]((U64 $b 32) -band 0xFFFFFFFFFFFF)
            if ($entry.in_use) {
                try {
                    $attrs = @(Get-Attributes $b)
                    $best = $null
                    foreach ($a in $attrs) {
                        $entry.attributes += ('0x{0:X2}{1}{2}' -f $a.Type, $(if ($a.Name) { ':' + $a.Name } else { '' }), $(if ($a.NonResident) { ' nonresident' } else { '' }))
                        if ($a.Type -eq 0x20) { $entry.error = 'attribute list present (extents may be incomplete)' }
                        if ($a.Type -eq 0x30 -and -not $a.NonResident) {
                            $v = $a.ValueOffset
                            $namespace = $b[$v + 65]
                            $fname = [Text.Encoding]::Unicode.GetString($b, $v + 66, 2 * $b[$v + 64])
                            # Prefer the Win32 or POSIX name over the DOS 8.3 alias.
                            if ($null -eq $best -or $namespace -ne 2) {
                                $best = $fname
                                $entry.parent = [long]((U64 $b $v) -band 0xFFFFFFFFFFFF)
                            }
                        }
                        if ($a.NonResident) {
                            foreach ($x in (Get-ImageExtents $Ctx $a.Runs)) {
                                $entry.extents += [pscustomobject]@{ Start = $x.Start; Length = $x.Length; Stream = ('0x{0:X2}{1}' -f $a.Type, $(if ($a.Name) { ':' + $a.Name } else { '' })) }
                            }
                        }
                    }
                    $entry.name = $best
                }
                catch { $entry.error = $_.Exception.Message }
            }
        }
        if ($SystemFileNames.ContainsKey([int]$n) -and $n -lt 12) { $entry.name = $SystemFileNames[[int]$n] }
        $records[$n] = [pscustomobject]$entry
    }
    foreach ($r in $records.Values) { $r | Add-Member -NotePropertyName path -NotePropertyValue (Get-RecordPath $records $r.number) }
    return $records
}

function Get-RecordPath($Records, [long] $Number) {
    $parts = @()
    $seen = @{}
    $current = $Number
    while ($current -ne 5 -and -not $seen.ContainsKey($current)) {
        $seen[$current] = $true
        if (-not $Records.ContainsKey($current)) { return '?\' + ($parts -join '\') }
        $r = $Records[$current]
        if ($null -ne $r.base_record -and $r.base_record -ne 0 -and $r.base_record -ne $current) { $current = $r.base_record; continue }
        if ($null -eq $r.name) { return ('<record {0}>' -f $Number) }
        $parts = ,$r.name + $parts
        if ($null -eq $r.parent) { break }
        $current = $r.parent
    }
    return '\' + ($parts -join '\')
}

function Get-OwnerIndex($Ctx, $Inventory) {
    $owners = New-Object System.Collections.ArrayList
    foreach ($r in $Inventory.Values) {
        $null = $owners.Add([pscustomobject]@{ Start = $r.image_offset; End = $r.image_offset + $Ctx.RecordSize; Owner = ('MFT record {0} ({1})' -f $r.number, $r.path); Kind = 'mft-record'; Record = $r.number })
        foreach ($x in $r.extents) {
            # $MFT's own data is covered record by record above.
            if ($r.number -eq 0 -and $x.Stream -eq '0x80') { continue }
            $null = $owners.Add([pscustomobject]@{ Start = $x.Start; End = $x.Start + $x.Length; Owner = ('{0} {1}' -f $r.path, $x.Stream); Kind = 'stream'; Record = $r.number })
        }
    }
    $null = $owners.Add([pscustomobject]@{ Start = 0; End = $Ctx.PartitionOffset; Owner = 'MBR and pre-partition gap'; Kind = 'container'; Record = -1 })
    $null = $owners.Add([pscustomobject]@{ Start = $Ctx.PartitionOffset; End = $Ctx.PartitionOffset + 8192; Owner = '$Boot sectors'; Kind = 'boot'; Record = 7 })
    $null = $owners.Add([pscustomobject]@{ Start = $Ctx.Length - 512; End = $Ctx.Length; Owner = 'VHD footer'; Kind = 'container'; Record = -1 })
    return ,$owners.ToArray()
}

# ---------------------------------------------------------------------------
# $LogFile and $Volume decoding (offsets from ntfs-3g logfile.h / layout.h)
# ---------------------------------------------------------------------------

function Read-RestartPage([byte[]] $Log, [long] $Offset) {
    $r = [ordered]@{ offset = $Offset; magic = $null; valid = $false; error = $null }
    if ($Offset + 512 -gt $Log.Length) { $r.error = 'beyond end of $LogFile'; return $r }
    $r.magic = Ascii $Log $Offset 4
    if ($r.magic -ne 'RSTR' -and $r.magic -ne 'CHKD') { $r.error = 'unexpected magic'; return $r }
    $systemPage = [long](U32 $Log ($Offset + 16))
    if (-not (Test-PowerOfTwo $systemPage) -or $systemPage -lt 512 -or $systemPage -gt 65536 -or $Offset + $systemPage -gt $Log.Length) {
        $r.error = 'invalid system page size'; return $r
    }
    $page = New-Object byte[] $systemPage
    [Array]::Copy($Log, $Offset, $page, 0, $systemPage)
    try { Undo-Fixup $page "restart page at $Offset" } catch { $r.error = $_.Exception.Message; return $r }
    $areaOffset = [int](U16 $page 24)
    if ($areaOffset % 8 -ne 0 -or $areaOffset + 48 -gt $systemPage) { $r.error = 'restart area out of bounds'; return $r }
    $r.chkdsk_lsn = U64 $page 8
    $r.system_page_size = $systemPage
    $r.log_page_size = [long](U32 $page 20)
    $r.restart_area_offset = $areaOffset
    $r.version = '{0}.{1}' -f (I16 $page 28), (I16 $page 26)
    $a = $areaOffset
    $flags = U16 $page ($a + 14)
    $r.area = [ordered]@{
        current_lsn = U64 $page $a
        log_clients = U16 $page ($a + 8)
        client_free_list = U16 $page ($a + 10)
        client_in_use_list = U16 $page ($a + 12)
        flags = ('0x{0:X4}' -f $flags)
        volume_is_clean = ($flags -band 0x0002) -ne 0
        seq_number_bits = U32 $page ($a + 16)
        restart_area_length = U16 $page ($a + 20)
        client_array_offset = U16 $page ($a + 22)
        file_size = U64 $page ($a + 24)
        last_lsn_data_length = U32 $page ($a + 32)
        log_record_header_length = U16 $page ($a + 36)
        log_page_data_offset = U16 $page ($a + 38)
        restart_log_open_count = U32 $page ($a + 40)
        clients = @()
    }
    for ($i = 0; $i -lt $r.area.log_clients -and $i -lt 8; $i++) {
        $c = $a + $r.area.client_array_offset + 160 * $i
        if ($c + 160 -gt $systemPage) { break }
        $nameBytes = [Math]::Min([int](U32 $page ($c + 28)), 128)
        $r.area.clients += [ordered]@{
            index = $i
            oldest_lsn = U64 $page $c
            client_restart_lsn = U64 $page ($c + 8)
            prev_client = U16 $page ($c + 16)
            next_client = U16 $page ($c + 18)
            seq_number = U16 $page ($c + 20)
            name = [Text.Encoding]::Unicode.GetString($page, $c + 32, $nameBytes)
        }
    }
    $r.valid = $true
    return $r
}

function Get-LogFileSummary([byte[]] $Log) {
    $first = Read-RestartPage $Log 0
    $systemPage = $(if ($first.valid) { $first.system_page_size } else { 4096 })
    $second = Read-RestartPage $Log $systemPage
    $logPage = $(if ($first.valid) { $first.log_page_size } elseif ($second.valid) { $second.log_page_size } else { 4096 })
    $stats = [ordered]@{ RCRD = 0; RSTR = 0; CHKD = 0; empty = 0; other = 0; rcrd_fixup_errors = 0; max_last_end_lsn = [uint64]0 }
    if ((Test-PowerOfTwo $logPage) -and $logPage -ge 512) {
        for ($o = 2 * $systemPage; $o + $logPage -le $Log.Length; $o += $logPage) {
            $magic = Ascii $Log $o 4
            switch ($magic) {
                'RCRD' {
                    $stats.RCRD++
                    $page = New-Object byte[] $logPage
                    [Array]::Copy($Log, $o, $page, 0, $logPage)
                    try {
                        Undo-Fixup $page "RCRD at $o"
                        $end = U64 $page 32
                        if ($end -gt $stats.max_last_end_lsn) { $stats.max_last_end_lsn = $end }
                    }
                    catch { $stats.rcrd_fixup_errors++ }
                }
                'RSTR' { $stats.RSTR++ }
                'CHKD' { $stats.CHKD++ }
                default {
                    $allSame = $true
                    for ($k = 1; $k -lt 16; $k++) { if ($Log[$o + $k] -ne $Log[$o]) { $allSame = $false; break } }
                    if ($allSame -and ($Log[$o] -eq 0xFF -or $Log[$o] -eq 0)) { $stats.empty++ } else { $stats.other++ }
                }
            }
        }
    }
    $selected = $null
    if ($first.valid -and $second.valid) {
        $selected = $(if ($second.area.current_lsn -gt $first.area.current_lsn) { 'second' } else { 'first' })
    }
    elseif ($first.valid) { $selected = 'first' }
    elseif ($second.valid) { $selected = 'second' }
    $chosen = $(if ($selected -eq 'second') { $second } elseif ($selected -eq 'first') { $first } else { $null })
    return [ordered]@{
        length = $Log.Length
        sha256 = $null
        restart_pages = @($first, $second)
        # Higher current_lsn wins: same rule as ntfs-3g; Windows' rule is still to be confirmed (protocol doc, G1).
        selected_restart = $selected
        selection_rule = 'higher current_lsn (ntfs-3g behaviour, unverified for Windows)'
        current_lsn = $(if ($chosen) { $chosen.area.current_lsn } else { $null })
        volume_is_clean = $(if ($chosen) { $chosen.area.volume_is_clean } else { $null })
        pages = $stats
    }
}

function Get-VolumeState($Ctx) {
    $rec = Read-MftRecord $Ctx 3
    if (-not $rec.Valid) { throw "`$Volume record invalid: $($rec.Error)" }
    $info = @(Get-Attributes $rec.Bytes | Where-Object { $_.Type -eq 0x70 -and -not $_.NonResident })
    if ($info.Count -ne 1) { throw '$Volume has no resident VOLUME_INFORMATION' }
    $v = $info[0].ValueOffset
    $flags = U16 $rec.Bytes ($v + 10)
    [ordered]@{
        ntfs_version = '{0}.{1}' -f $rec.Bytes[$v + 8], $rec.Bytes[$v + 9]
        flags = ('0x{0:X4}' -f $flags)
        dirty = ($flags -band 0x0001) -ne 0
        mft_record_lsn = U64 $rec.Bytes 8
        serial = $Ctx.VolumeSerial
    }
}

function Save-LogFile($Ctx, [string] $Destination) {
    $rec = Read-MftRecord $Ctx 2
    if (-not $rec.Valid) { throw "`$LogFile record invalid: $($rec.Error)" }
    $data = @(Get-Attributes $rec.Bytes | Where-Object { $_.Type -eq 0x80 -and $_.Name -eq '' })
    if ($data.Count -ne 1 -or -not $data[0].NonResident) { throw '$LogFile $DATA must be one non-resident attribute' }
    $bytes = Read-NonResidentData $Ctx $data[0] 256MB
    [IO.File]::WriteAllBytes($Destination, $bytes)
    $summary = Get-LogFileSummary $bytes
    $summary.sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
    $summary.extents = @(Get-ImageExtents $Ctx $data[0].Runs | ForEach-Object { [ordered]@{ image_offset = $_.Start; length = $_.Length } })
    $summary.mft_record_lsn = U64 $rec.Bytes 8
    return $summary
}

function Get-OfflineSnapshot([string] $Path, [string] $Label) {
    $ctx = Open-NtfsImage $Path
    try {
        $snapshot = [ordered]@{
            geometry = [ordered]@{
                partition_offset = $ctx.PartitionOffset; partition_bytes = $ctx.PartitionBytes
                bytes_per_sector = $ctx.BytesPerSector; cluster_size = $ctx.ClusterSize; mft_record_size = $ctx.RecordSize
                mft_lcn = $ctx.MftLcn; mftmirr_lcn = $ctx.MftMirrLcn; mft_records = [long][Math]::Floor($ctx.MftDataSize / $ctx.RecordSize)
            }
            logfile = Save-LogFile $ctx (Join-Path $ArtifactDirectory "logfile-$Label.bin")
            volume = Get-VolumeState $ctx
            inventory = Get-MftInventory $ctx
            owners = $null
        }
        $snapshot.owners = Get-OwnerIndex $ctx $snapshot.inventory
        $snapshot.inventory.Values | Sort-Object number | Select-Object number, in_use, directory, lsn, sequence, path, error, attributes |
            ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $ArtifactDirectory "structure-$Label.json")
        return $snapshot
    }
    finally { $ctx.Stream.Dispose() }
}

# ---------------------------------------------------------------------------
# Block diff (compiled: a PowerShell byte loop over 1 GiB is too slow)
# ---------------------------------------------------------------------------

if (-not ('OpenHdd.BlockDiff' -as [type])) {
    Add-Type -TypeDefinition @'
namespace OpenHdd {
    using System;
    using System.Collections.Generic;
    using System.IO;
    public static class BlockDiff {
        public static long[] Changed(string left, string right, int blockSize) {
            var changed = new List<long>();
            using (var a = new FileStream(left, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20))
            using (var b = new FileStream(right, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20)) {
                if (a.Length != b.Length) throw new InvalidOperationException("images differ in length");
                var ba = new byte[blockSize];
                var bb = new byte[blockSize];
                long index = 0;
                while (true) {
                    int na = Fill(a, ba), nb = Fill(b, bb);
                    if (na != nb) throw new InvalidOperationException("short read");
                    if (na == 0) break;
                    for (int i = 0; i < na; i++) {
                        if (ba[i] != bb[i]) { changed.Add(index); break; }
                    }
                    index++;
                }
            }
            return changed.ToArray();
        }
        static int Fill(Stream s, byte[] buffer) {
            int done = 0;
            while (done < buffer.Length) {
                int n = s.Read(buffer, done, buffer.Length - done);
                if (n <= 0) break;
                done += n;
            }
            return done;
        }
    }
}
'@
}

function Get-ChangeReport([long[]] $Blocks, $OwnersBefore, $OwnersAfter, $Before, $After) {
    $ranges = New-Object System.Collections.ArrayList
    foreach ($blk in $Blocks) {
        $start = $blk * $BlockSize
        if ($ranges.Count -gt 0 -and $ranges[$ranges.Count - 1].End -eq $start) { $ranges[$ranges.Count - 1].End = $start + $BlockSize }
        else { $null = $ranges.Add([pscustomobject]@{ Start = $start; End = $start + $BlockSize }) }
    }
    $byOwner = @{}
    foreach ($range in $ranges) {
        for ($p = $range.Start; $p -lt $range.End; $p += $BlockSize) {
            $names = @()
            foreach ($o in @($OwnersBefore) + @($OwnersAfter)) {
                if ($o.Start -lt $p + $BlockSize -and $o.End -gt $p) { $names += $o.Owner }
            }
            $names = @($names | Sort-Object -Unique)
            $key = $(if ($names.Count -eq 0) { 'UNATTRIBUTED (free space before and after)' } else { $names -join ' | ' })
            if (-not $byOwner.ContainsKey($key)) { $byOwner[$key] = 0 }
            $byOwner[$key]++
        }
    }
    $recordsBefore = $Before.inventory
    $recordsAfter = $After.inventory
    $created = @(); $removed = @(); $lsnChanged = @()
    foreach ($n in $recordsAfter.Keys) {
        $a = $recordsAfter[$n]
        $b = $(if ($recordsBefore.ContainsKey($n)) { $recordsBefore[$n] } else { $null })
        if ($a.in_use -and ($null -eq $b -or -not $b.in_use)) { $created += [ordered]@{ record = $n; path = $a.path; attributes = $a.attributes } }
        if ($null -ne $b -and $b.in_use -and -not $a.in_use) { $removed += [ordered]@{ record = $n; path = $b.path } }
        if ($null -ne $b -and $a.lsn -ne $b.lsn) { $lsnChanged += [ordered]@{ record = $n; path = $a.path; lsn_before = $b.lsn; lsn_after = $a.lsn } }
    }
    [ordered]@{
        block_size = $BlockSize
        changed_blocks = $Blocks.Count
        changed_ranges = @($ranges | ForEach-Object { [ordered]@{ image_offset = $_.Start; length = $_.End - $_.Start } })
        blocks_by_owner = $byOwner
        mft_records_created = $created
        mft_records_released = $removed
        mft_records_lsn_changed = @($lsnChanged | Sort-Object { $_.record })
    }
}

# ---------------------------------------------------------------------------
# Windows-side observation helpers (read-only queries)
# ---------------------------------------------------------------------------

function Invoke-Captured([string] $Name, [scriptblock] $Command) {
    $file = Join-Path $ArtifactDirectory ("windows\{0}.txt" -f $Name)
    $output = & $Command 2>&1 | Out-String
    $code = $LASTEXITCODE
    Set-Content -Encoding UTF8 -LiteralPath $file -Value $output
    [ordered]@{ command = $Name; exit_code = $code; output = $output.Trim() }
}

function Get-HexState([string] $Text) {
    $m = [regex]::Matches($Text, '0x[0-9A-Fa-f]+')
    if ($m.Count -eq 0) { return $null }
    return $m[0].Value.ToLowerInvariant()
}

function Get-NtfsEvents([datetime] $Since) {
    $events = @()
    foreach ($log in @('System', 'Application', 'Microsoft-Windows-Ntfs/Operational')) {
        try {
            $events += @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $Since } -ErrorAction Stop |
                Where-Object { $_.ProviderName -match 'Ntfs|disk|volmgr|partmgr|vhdmp|Chkdsk|Wininit|VDS' } |
                ForEach-Object {
                    [ordered]@{
                        log = $log; time = $_.TimeCreated.ToString('o'); provider = $_.ProviderName; id = $_.Id
                        level = $_.LevelDisplayName; message = $_.Message
                        repair_candidate = ($_.ProviderName -match 'Ntfs|Chkdsk' -and $RepairEventIds -contains $_.Id)
                    }
                })
        }
        catch {
            if ($_.Exception.Message -notmatch 'No events|Nessun evento') { $events += [ordered]@{ log = $log; error = $_.Exception.Message } }
        }
    }
    return ,$events
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$failure = $null
$mounted = $false
$workingImage = $null
$resolvedImage = $null
$resolvedControl = $null
$before = $null
$after = $null

try {
    $resolvedImage = (Resolve-Path -LiteralPath $ImagePath).Path
    if ([IO.Path]::GetExtension($resolvedImage).ToLowerInvariant() -ne '.vhd') { throw 'REFUSED: only fixed-size .vhd images are supported' }
    if ((Get-Item -LiteralPath $resolvedImage).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'REFUSED: image is a reparse point' }
    if (Test-Path -LiteralPath $ArtifactDirectory) {
        if (@(Get-ChildItem -LiteralPath $ArtifactDirectory -Force).Count -gt 0) { throw 'REFUSED: artifact directory must be new or empty' }
    }
    New-Item -ItemType Directory -Force -Path $ArtifactDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $ArtifactDirectory 'windows') | Out-Null
    $artifactRoot = (Resolve-Path -LiteralPath $ArtifactDirectory).Path
    if ($resolvedImage.StartsWith($artifactRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'REFUSED: image lives inside the artifact directory' }
    if ((Get-DiskImage -ImagePath $resolvedImage).Attached) { throw 'REFUSED: image is already attached' }

    $os = Get-CimInstance Win32_OperatingSystem
    $result.host = [ordered]@{
        computer = $env:COMPUTERNAME; os = $os.Caption; version = $os.Version; build = $os.BuildNumber
        ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).UBR
        powershell = $PSVersionTable.PSVersion.ToString(); started = (Get-Date).ToString('o')
    }

    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedImage).Hash.ToLowerInvariant()
    if ($sourceHash -ne $ExpectedImageSha256.ToLowerInvariant()) { throw 'REFUSED: image hash does not match the expected hash' }
    $result.source = [ordered]@{ path = $resolvedImage; bytes = (Get-Item -LiteralPath $resolvedImage).Length; sha256_before = $sourceHash; sha256_after = $null; unchanged = $null }

    if ($ControlImagePath) {
        $resolvedControl = (Resolve-Path -LiteralPath $ControlImagePath).Path
        if ($resolvedControl -eq $resolvedImage) { throw 'REFUSED: control image and image are the same file' }
        if ((Get-DiskImage -ImagePath $resolvedControl).Attached) { throw 'REFUSED: control image is attached' }
        $controlHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedControl).Hash.ToLowerInvariant()
        if ($ExpectedControlSha256 -and $controlHash -ne $ExpectedControlSha256.ToLowerInvariant()) { throw 'REFUSED: control image hash does not match the expected hash' }
        $result.control = [ordered]@{ path = $resolvedControl; sha256_before = $controlHash; sha256_after = $null; unchanged = $null; opened_for_write = $false }
    }

    # Self-healing: the only pre-mount evidence available is what the operator
    # recorded earlier. Its state value is decoded, not trusted blindly.
    $premount = [ordered]@{ evidence_file = $null; recorded_state = $null; disabled_before_first_access = $false }
    if ($PreMountSelfHealingEvidence) {
        $evidencePath = (Resolve-Path -LiteralPath $PreMountSelfHealingEvidence).Path
        Copy-Item -LiteralPath $evidencePath -Destination (Join-Path $ArtifactDirectory 'windows\premount-self-healing-evidence.txt')
        $premount.evidence_file = $evidencePath
        $premount.recorded_state = Get-HexState (Get-Content -Raw -LiteralPath $evidencePath)
        # 0x0 and 0x10 are the documented "general repair disabled" values.
        $premount.disabled_before_first_access = $premount.recorded_state -in @('0x0', '0x00', '0x10')
    }
    $hostRepair = Invoke-Captured 'host-fsutil-repair-query-systemdrive' { fsutil repair query $env:SystemDrive }
    $result.self_healing = [ordered]@{
        premount = $premount
        host_system_drive_state = Get-HexState $hostRepair.output
        can_disable_before_first_access = $false
        can_disable_before_first_access_reason = 'fsutil repair set needs a mounted volume; persistence of a per-volume setting across detach and remount is unproven (spec 9.2, Q03)'
        mounted_state = $null
        mounted_corruption_state = $null
        corrupt_log = $null
        verify_log = $null
    }

    # Offline acquisition of the untouched image (read-only handle).
    $before = Get-OfflineSnapshot $resolvedImage 'before'
    $result.logfile_before = $before.logfile
    $result.volume_before = $before.volume
    $result.geometry = $before.geometry
    $firstOk = $before.logfile.restart_pages[0].valid
    $secondOk = $before.logfile.restart_pages[1].valid
    $result.gate.T03_acquisition = $(if ($firstOk -and $secondOk) { 'PASS' } else { 'FAIL' })
    if (-not ($firstOk -and $secondOk)) { $result.reasons += 'one or both $LogFile restart pages failed validation before mount' }

    $replayExpected = ($before.logfile.volume_is_clean -ne $true) -or $before.volume.dirty
    $result.replay_expected = $replayExpected

    if ($OfflineOnly) {
        $result.gate.T03_distinction = 'NON_ESEGUITO'
        $result.reasons += 'offline-only run: no Windows mount was observed'
    }
    else {
        $free = (Get-PSDrive -Name ($artifactRoot.Substring(0, 1))).Free
        if ($free -lt 2 * $result.source.bytes) { throw 'REFUSED: not enough free space for a working copy plus margin' }
        $workingImage = Join-Path $artifactRoot 'working.vhd'
        Copy-Item -LiteralPath $resolvedImage -Destination $workingImage
        $workingPre = (Get-FileHash -Algorithm SHA256 -LiteralPath $workingImage).Hash.ToLowerInvariant()
        if ($workingPre -ne $sourceHash) { throw 'working copy hash differs from the source' }

        $mountStart = Get-Date
        $diskImage = Mount-DiskImage -ImagePath $workingImage -StorageType VHD -Access ReadWrite -PassThru
        $mounted = $true
        $volume = $null
        for ($attempt = 1; $attempt -le 20 -and $null -eq $volume; $attempt++) {
            Start-Sleep -Milliseconds 500
            $disk = @($diskImage | Get-Disk)[0]
            if ($null -eq $disk -or $disk.IsSystem -or $disk.IsBoot) { continue }
            $partitions = @($disk | Get-Partition | Where-Object { $_.Type -ne 'Reserved' })
            if ($partitions.Count -ne 1) { continue }
            $candidate = @($partitions | Get-Volume)
            if ($candidate.Count -eq 1 -and $candidate[0].FileSystem -eq 'NTFS' -and $candidate[0].DriveLetter) { $volume = $candidate[0] }
        }
        if ($null -eq $volume) { throw 'REFUSED: working copy did not expose exactly one NTFS volume with a drive letter' }
        $letter = '{0}:' -f $volume.DriveLetter
        $result.mount = [ordered]@{
            started = $mountStart.ToString('o'); disk_number = $disk.Number; drive_letter = $letter
            volume_health = [string]$volume.HealthStatus; operational_status = [string]$volume.OperationalStatus
            settle_seconds = $SettleSeconds
        }

        Start-Sleep -Seconds $SettleSeconds
        $q = Invoke-Captured 'fsutil-repair-query' { fsutil repair query $letter }
        $s = Invoke-Captured 'fsutil-repair-state' { fsutil repair state $letter }
        $c = Invoke-Captured 'fsutil-repair-enumerate-corrupt' { fsutil repair enumerate $letter '$Corrupt' }
        $v = Invoke-Captured 'fsutil-repair-enumerate-verify' { fsutil repair enumerate $letter '$Verify' }
        $d = Invoke-Captured 'fsutil-dirty-query' { fsutil dirty query $letter }
        $result.self_healing.mounted_state = Get-HexState $q.output
        $result.self_healing.mounted_corruption_state = Get-HexState $s.output
        # A corruption log entry carries a 16-hex-digit file reference.
        $result.self_healing.corrupt_log = [ordered]@{ exit_code = $c.exit_code; entries = @([regex]::Matches($c.output, '\b[0-9a-fA-F]{16}\b')).Count }
        $result.self_healing.verify_log = [ordered]@{ exit_code = $v.exit_code; entries = @([regex]::Matches($v.output, '\b[0-9a-fA-F]{16}\b')).Count }
        $result.mount.dirty_query = $d.output

        foreach ($path in $SyntheticPath) {
            $resolved = Join-Path $letter $path
            if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "missing synthetic file: $path" }
            $result.files += [ordered]@{
                path = $path; length = (Get-Item -LiteralPath $resolved).Length
                sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolved).Hash.ToLowerInvariant()
            }
        }

        Dismount-DiskImage -ImagePath $workingImage | Out-Null
        $mounted = $false
        $result.mount.dismounted = (Get-Date).ToString('o')
        Start-Sleep -Seconds 2
        $events = Get-NtfsEvents $mountStart.AddSeconds(-2)
        $events | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $ArtifactDirectory 'windows\events.json')
        $result.mount.events_total = @($events).Count
        $result.mount.repair_candidate_events = @($events | Where-Object { $_.Contains('repair_candidate') -and $_['repair_candidate'] } | ForEach-Object { '{0}/{1}' -f $_['provider'], $_['id'] })

        $after = Get-OfflineSnapshot $workingImage 'after'
        $result.logfile_after = $after.logfile
        $result.volume_after = $after.volume
        $result.working_image_sha256_after_unmount = (Get-FileHash -Algorithm SHA256 -LiteralPath $workingImage).Hash.ToLowerInvariant()

        $blocks = [OpenHdd.BlockDiff]::Changed($resolvedImage, $workingImage, $BlockSize)
        $changes = Get-ChangeReport $blocks $before.owners $after.owners $before $after
        $changes | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $ArtifactDirectory 'changes.json')
        $result.changes = [ordered]@{
            changed_blocks = $changes.changed_blocks
            owners = $changes.blocks_by_owner
            mft_records_created = @($changes.mft_records_created | ForEach-Object { '{0} {1}' -f $_.record, $_.path })
            mft_records_released = @($changes.mft_records_released | ForEach-Object { '{0} {1}' -f $_.record, $_.path })
            mft_records_lsn_changed = @($changes.mft_records_lsn_changed).Count
            detail = 'changes.json'
        }

        # Signals. None of them alone proves replay or repair; together they
        # describe what this mount did and what is still unexplained.
        $signals = [ordered]@{
            log_clean_before = $before.logfile.volume_is_clean
            log_clean_after = $after.logfile.volume_is_clean
            volume_dirty_before = $before.volume.dirty
            volume_dirty_after = $after.volume.dirty
            current_lsn_advanced = ($after.logfile.current_lsn -gt $before.logfile.current_lsn)
            repair_candidate_events = @($result.mount.repair_candidate_events).Count
            corrupt_log_entries = $result.self_healing.corrupt_log.entries
            verify_log_entries = $result.self_healing.verify_log.entries
            corruption_state_nonzero = ($null -ne $result.self_healing.mounted_corruption_state -and $result.self_healing.mounted_corruption_state -notin @('0x0', '0x00'))
            unattributed_changed_blocks = $(if ($changes.blocks_by_owner.ContainsKey('UNATTRIBUTED (free space before and after)')) { $changes.blocks_by_owner['UNATTRIBUTED (free space before and after)'] } else { 0 })
        }
        $result.signals = $signals
        $repairSeen = $signals.repair_candidate_events -gt 0 -or $signals.corrupt_log_entries -gt 0 -or $signals.verify_log_entries -gt 0 -or $signals.corruption_state_nonzero

        if (-not $replayExpected) {
            $result.observation = $(if ($repairSeen) { 'clean-log baseline, but repair signals present: investigate before any further run' } else { 'clean-log baseline mounted: no replay expected, no repair signal observed; this is the healthy-mount noise profile' })
        }
        elseif ($repairSeen) {
            $result.observation = 'replay expected and repair signals present: replay and self-healing are confounded'
        }
        else {
            $result.observation = 'replay expected, no repair signal observed: replay candidate only (absence of signals is not proof)'
        }
        $result.gate.T03_distinction = 'INCONCLUDENTE'
        if (-not $replayExpected) { $result.reasons += 'baseline log was clean before mount: this run cannot observe a replay, only the noise of a healthy mount' }
    }

    if (-not $result.self_healing.premount.disabled_before_first_access) {
        $result.reasons += ('self-healing was not proven disabled before the first Windows access (recorded state: {0})' -f $(if ($result.self_healing.premount.recorded_state) { $result.self_healing.premount.recorded_state } else { 'none' }))
    }
    $result.reasons += 'G1 needs decoded Windows examples of the target operation; this script only acquires and observes'
}
catch {
    $failure = $_.Exception.Message
    $result.status = 'ERRORE'
    $result.reasons += $failure
}
finally {
    if ($mounted) {
        try { Dismount-DiskImage -ImagePath $workingImage -ErrorAction Stop | Out-Null }
        catch { $result.dismount_error = $_.Exception.Message }
    }
    try {
        if ($resolvedImage -and $result.source) {
            $result.source.sha256_after = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedImage).Hash.ToLowerInvariant()
            $result.source.unchanged = ($result.source.sha256_after -eq $result.source.sha256_before)
            if (-not $result.source.unchanged) { $result.status = 'ERRORE'; $result.reasons += 'SOURCE IMAGE CHANGED' }
        }
        if ($resolvedControl -and $result.control) {
            $result.control.sha256_after = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedControl).Hash.ToLowerInvariant()
            $result.control.unchanged = ($result.control.sha256_after -eq $result.control.sha256_before)
            if (-not $result.control.unchanged) { $result.status = 'ERRORE'; $result.reasons += 'CONTROL IMAGE CHANGED' }
        }
    }
    catch { $result.post_hash_error = $_.Exception.Message }
    $result.finished = (Get-Date).ToString('o')
    if (Test-Path -LiteralPath $ArtifactDirectory) {
        $result | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 (Join-Path $ArtifactDirectory 'result.json')
        try {
            Get-ChildItem -LiteralPath $ArtifactDirectory -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS' } | ForEach-Object {
                '{0}  {1}' -f (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant(), $_.FullName.Substring($ArtifactDirectory.TrimEnd('\').Length + 1)
            } | Set-Content -Encoding ASCII (Join-Path $ArtifactDirectory 'SHA256SUMS')
        }
        catch { }
    }
}

Write-Output ($result | ConvertTo-Json -Depth 10)
if ($result.status -eq 'ERRORE') { exit 1 }
exit 77
