<#
.SYNOPSIS
    Safely removes the USB device that holds an NTFS volume, like "Safely
    Remove Hardware", so the Mac receives it with a closed journal.

.DESCRIPTION
    Unplugging without this, or dismounting the volume only, leaves the NTFS
    journal open: Windows remounts at once. The script finds the disk behind
    the volume label, walks up the device tree to the USB device (works for
    both USB mass storage and UAS disks) and calls CM_Request_Device_Eject.

.EXAMPLE
    & .\eject-usb.ps1 -Label OPENHDD-V4
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)] [string] $Label)

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class OpenHDDEject {
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    public static extern int CM_Locate_DevNodeW(out uint devInst, string deviceId, int flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    public static extern int CM_Request_Device_EjectW(uint devInst, out int vetoType, StringBuilder vetoName, int length, int flags);
}
'@

$volume = Get-Volume | Where-Object FileSystemLabel -eq $Label
if (@($volume).Count -ne 1) { throw "expected one volume labelled $Label" }
$disk = Get-Partition -DriveLetter $volume.DriveLetter | Get-Disk
if ($disk.IsSystem -or $disk.IsBoot) { throw 'REFUSED: system disk' }
# Disk path "\\?\usbstor#disk&ven_...#serial#{guid}" carries the instance id.
$id = ($disk.Path -replace '^\\\\\?\\', '' -replace '#\{[^}]+\}$', '') -replace '#', '\'
if (-not (Get-PnpDevice -InstanceId $id -ErrorAction SilentlyContinue)) { throw "no device for disk path $($disk.Path)" }
while ($id -and -not $id.StartsWith('USB\VID', [StringComparison]::OrdinalIgnoreCase)) {
    $id = (Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_Parent').Data
}
if (-not $id) { throw 'no USB parent device found' }

$node = 0
if ([OpenHDDEject]::CM_Locate_DevNodeW([ref]$node, $id, 0) -ne 0) { throw "cannot locate $id" }
$veto = 0
$name = New-Object System.Text.StringBuilder 260
$result = [OpenHDDEject]::CM_Request_Device_EjectW($node, [ref]$veto, $name, 260, 0)
if ($result -ne 0 -or $veto -ne 0) { throw "eject refused: result $result veto $veto $($name.ToString())" }
Write-Host "EJECTED: $Label ($id)"
