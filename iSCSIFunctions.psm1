#Region Functions

function local:Register-iSCSIConnections
{
   param()
   Write-Host "Register-iSCSIConnections"
   return
}

function local:Check-ISCSIVolume
{
   param($VolumeLabel)
   
   Write-Host "Checking for $($VolumeLabel)" -NoNewline

   $return=$null
   $Volume = Get-Volume -FileSystemLabel $VolumeLabel -ErrorAction SilentlyContinue
   if ($Volume -ne $null) {
      $disk = (Get-Partition -DriveLetter $Volume.DriveLetter -ErrorAction SilentlyContinue | Get-Disk)
      if($disk -ne $null -and $Disk.BusType.ToLower() -eq "iscsi" ){
         Write-Host "...Found ...Removing from drive ($($Volume.DriveLetter))" -NoNewline
         Remove-Partition -DriveLetter $Volume.DriveLetter -Confirm:$false ; sleep -Seconds 15
         Write-Host -ForegroundColor Green "...Complete"
         $return=$Volume.DriveLetter
      } else {Write-Host -ForegroundColor Red "...Error - Duplicate volume labels" ; exit}
   } else {Write-Host "...not found"}
   return $return
}

function local:New-ISCSIVolume
{
   param($iSCSISessionDisk, [string]$DriveLetter, [string]$VolumeLabel)
   $RetStatus = (Check-ISCSIVolume -VolumeLabel $VolumeLabel)
   if ($RetStatus -ne $null)
   { 
      if ($DriveLetter -ne $RetStatus) 
      {
         Write-Host -ForegroundColor Yellow "   Resetting requested drive letter <$($DriveLetter)> to <$($RetStatus)>"
         $DriveLetter = $RetStatus
      } 
      else 
      {$RetStatus = $null}
   }

   Write-Host "Creating Volume $($VolumeLabel) ($($DriveLetter))" -NoNewline
   $result = $iSCSISessionDisk | New-Partition -DriveLetter $DriveLetter -UseMaximumSize | Format-Volume -AllocationUnitSize 65536 -NewFileSystemLabel $VolumeLabel -Confirm:$false
#   Write-Host -ForegroundColor Yellow " $($result.FileSystemLabel) ($($result.DriveLetter))" -NoNewline
   Write-Host -ForegroundColor Green "...Complete"
   return $RetStatus
}

function local:Get-FreeDriveLetters
{
   Write-Host "Collecting 'Available' Drive letter(s) for assignment" -NoNewline
   $freeletters = 70..89 | ForEach-Object { ([char]$_) } | Where-Object { (New-Object System.IO.DriveInfo($_)).DriveType -eq 'NoRootDirectory' }
   Write-Host -ForegroundColor Green "...Complete" -NoNewline
   Write-Host -ForegroundColor Yellow "...Found $($freeletters.count) Available drive letter(s)"
   return $freeletters
}

#endRegion
