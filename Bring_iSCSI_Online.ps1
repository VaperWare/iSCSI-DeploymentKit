<#
 * Copyright Microsoft Corporation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
#>

[CmdletBinding()]
Param(
    [parameter(Mandatory=$true)][string]$TargetPortalAddress,
    [parameter(Mandatory=$false)][string]$iSCSIVolumePrefix="iSCSI",
    [parameter(Mandatory=$false)][string]$ScriptFolder = (get-location).Path
    )

##Load the functions
Import-Module $scriptFolder\iSCSIFunctions.psm1 -AsCustomObject -Force -DisableNameChecking -Verbose:$false

cls
$ProgressPreference = "SilentlyContinue"

if ($TargetPortalAddress.Split(".").count -lt 3)
{
   Write-Host "Invalid format - Target server address (FQDN)"
   exit
}

$iSCSIVolumePrefix = $iSCSIVolumePrefix + "_" + (Get-Culture).textinfo.totitlecase($TargetPortalAddress.Split(".")[0].tolower()) + "_"

Write-Host "`nQuerying Portal $($TargetPortalAddress)" -NoNewline
$Portal = get-IscsiTargetPortal –TargetPortalAddress $TargetPortalAddress -ErrorAction SilentlyContinue
if ($Portal -eq $null) {
   Write-Host -ForegroundColor Yellow "...Creating" -NoNewline
   $Portal = New-IscsiTargetPortal –TargetPortalAddress $TargetPortalAddress -ErrorAction Stop
}
else {Write-Host -ForegroundColor Yellow "...Already exists" -NoNewline}
Write-Host -ForegroundColor Green "...Complete"

## Connect a iSCSI connection - Target Server
Write-Host "Querying connection to $($TargetPortalAddress)" -NoNewline
if(!($portal | Get-IscsiTarget).IsConnected){
   Write-Host -ForegroundColor Yellow "...Connecting" -NoNewline
   $Portal | Get-IscsiTarget | Connect-IscsiTarget  -ErrorAction SilentlyContinue | Out-Null
}
else {Write-Host -ForegroundColor Yellow "...Already connected" -NoNewline}
Write-Host -ForegroundColor Green "...Complete" 

## Register Connection - ALL
Write-Host "Registering Connection(s)" -NoNewline
Get-IscsiSession | Register-IscsiSession  
sleep -Seconds 15 ; Write-Host -ForegroundColor Green "...Complete"

## Gets disk assocatied with a Target server
Write-Host "Gathering disk(s) for $($TargetPortalAddress)" -NoNewline
$iSCSISessionDisks = $Portal | Get-IscsiTarget | Get-IscsiConnection | Get-Disk -ErrorAction Stop
sleep -Seconds 15 
Write-Host -ForegroundColor Yellow "...Found $($iSCSISessionDisks.count) Disk(s)" -NoNewline
Write-Host -ForegroundColor Green "...Complete" 

#Bring all Session Disks online
Write-Host "Bringing Disk(s) Online" -NoNewline
$iSCSISessionDisks | ?{$_.operationalstatus -eq "offline"} | Set-Disk -IsOffline 0
Write-Host -ForegroundColor Green "...Complete"

#Make all Session disks RW
Write-Host "Setting Disk(s) Read/Write" -NoNewline
$iSCSISessionDisks | Set-Disk -IsReadOnly 0
Write-Host -ForegroundColor Green "...Complete"

#Initialize all Session disks GPT
Write-Host "Initializing Disk(s) to GPT" -NoNewline
$iSCSISessionDisks | Initialize-Disk -PartitionStyle GPT -ErrorAction SilentlyContinue 
Write-Host -ForegroundColor Green "...Complete"

#Turn off annoying File Explorer POP-ups
Stop-Service -Name ShellHWDetection

Write-Host "`nCreating $($iSCSISessionDisks.count) iSCSI connected volume(s)"
[int]$iVolumeCt = 0 ; [int]$iDriveLetterCt = 0
$freeletters = Get-FreeDriveLetters
foreach ($iSCSISessionDisk in $iSCSISessionDisks) {
   $Volumelabel = $iSCSIVolumePrefix + $iVolumeCt.ToString().PadLeft(([int]10).ToString().Length, '0')
   $DriveLetter = $freeletters[$iDriveLetterCt]
   $RetStatus = (New-ISCSIVolume -iSCSISessionDisk $iSCSISessionDisks[$iVolumeCt] -DriveLetter $DriveLetter -VolumeLabel $Volumelabel)
   $iVolumeCt++ ; if ($RetStatus -eq $null) {$iDriveLetterCt++}
}

#Turn on annoying File Explorer POP-ups
start-Service -Name ShellHWDetection

##End of Script