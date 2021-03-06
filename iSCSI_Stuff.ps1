$cloudSvcName = "disd-cloud"
Get-AzureVM -ServiceName $cloudSvcName | foreach { 
	$rdpfile = "C:\temp\$($cloudSvcName)_" + $_.Name + '.rdp' ;
	Get-AzureRemoteDesktopFile -ServiceName $cloudSvcName -Name $_.Name -LocalPath $rdpfile }

$TargetName = "iSCSITargetSQL"
New-IscsiServerTarget -TargetName $TargetName –InitiatorID "DNSName:SQL1.vaperware.com"

$DevicePath = "E:\iSCSIVirtualDisks\iSCSIVdisk01.vhdx"
New-IscsiServerTarget -TargetName $TargetName –InitiatorID "IPAddress:192.168.3.21"
Add-IscsiVirtualDiskTargetMapping –TargetName $TargetName –DevicePath $DevicePath


Remove-IscsiVirtualDiskTargetMapping –TargetName $TargetName –DevicePath $DevicePath
Remove-IscsiServerTarget –TargetName $TargetName

##Removes all iSCSI Targets
$iSCSITargets = Get-IscsiServerTarget
foreach ($iSCSITarget in $iSCSITargets) {
   foreach ($LunMap in $iSCSITarget.LunMappings){
      Remove-IscsiVirtualDiskTargetMapping –TargetName $iSCSITarget.TargetName –DevicePath $LunMap.Path
   }
   Remove-IscsiServerTarget –TargetName $iSCSITarget.TargetName
}

##Removes all iSCSI Virtual disks
Get-IscsiVirtualDisk | foreach { Remove-IscsiVirtualDisk $_.path}

$iSCSIVirtualDrive = "E"
$iSCSIVirtualDisk = "iSCSIVdisk01"
$iSCSIDevicePath = "$($iSCSIVirtualDrive)`:\iSCSIVirtualDisks\$($iSCSIVirtualDisk).vhdx"
New-IscsiVirtualDisk –Path $iSCSIDevicePath –Size 998GB
Add-IscsiVirtualDiskTargetMapping –TargetName $TargetName –DevicePath $iSCSIDevicePath

## Target Server Stuff

##Register iSCSI server (Portal)
$TargetPortalAddress = "storage02.vaperware.com"
$Portal = New-IscsiTargetPortal –TargetPortalAddress $TargetPortalAddress

## Create a iSCSI Connection - Specfic one
Connect-IscsiTarget -NodeAddress (Get-IscsiTarget).NodeAddress

## Connect a iSCSI connection - Target Server
(Get-IscsiTargetPortal -TargetPortalAddress storage02.vaperware.com) | Get-IscsiTarget | Connect-IscsiTarget
$Portal | Get-IscsiTarget | Connect-IscsiTarget

## Register Connection - ALL
Get-IscsiSession | Register-IscsiSession

## Process disk
$Disks = Get-Disk | ?{$_.FriendlyName -like "*MSFT Virtual HD SCSI*"}
Get-Disk | ?{$_.operationalstatus -eq "offline"} | Set-Disk -IsOffline 0

## Gets disk assocatied with a Target server
(Get-IscsiTargetPortal -TargetPortalAddress storage02.vaperware.com) | Get-IscsiTarget | Get-IscsiConnection | Get-Disk
$iSCSISessionDisks = $Portal | Get-IscsiTarget | Get-IscsiConnection | Get-Disk

## Processing stuff
#Bring all Session Disks online
$iSCSISessionDisks | ?{$_.operationalstatus -eq "offline"} | Set-Disk -IsOffline 0

#Make all Session disks RW
$iSCSISessionDisks | Set-Disk -IsReadOnly 0

#Initialize all Session disks GPT
$iSCSISessionDisks | Initialize-Disk -PartitionStyle GPT -ErrorAction SilentlyContinue

#Format all Session disks - Random Drive Letters, no volume labels
$iSCSISessionDisks | New-Partition -AssignDriveLetter -UseMaximumSize | Format-Volume -AllocationUnitSize 65536 -confirm:$false

$iSCSISessionDisks[0] | New-Partition -DriveLetter "H" -UseMaximumSize | Format-Volume -AllocationUnitSize 65536 -NewFileSystemLabel "Volume01" -confirm:$false
$iSCSISessionDisks[1] | New-Partition -DriveLetter "I" -UseMaximumSize | Format-Volume -AllocationUnitSize 65536 -NewFileSystemLabel "Volume02" -confirm:$false
