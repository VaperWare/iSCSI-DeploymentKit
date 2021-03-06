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
    [parameter(Mandatory=$true)][string]$vmName,
    [parameter(Mandatory=$false)][string]$CloudService = "",
    [parameter(Mandatory=$false)][string]$storageAccountName = "",
    [parameter(Mandatory=$false)][string]$AffinityGroup = "LabAG01",
    [parameter(Mandatory=$false)][string]$Region = "East US",
    [parameter(Mandatory=$false)][string]$VmSize = "Large",
    [parameter(Mandatory=$false)][string]$vnetName = "VWNet01",
    [parameter(Mandatory=$false)][string]$subnetName = "StorageNet",
    [parameter(Mandatory=$false)][string]$availabilitySet = "StorageAvailSet",
    [parameter(Mandatory=$false)][int]$NumOfDataDisks = 1,
    [parameter(Mandatory=$false)][int]$SizeOfDataDisks = 500,
    [parameter(Mandatory=$false)][int]$NumOfStorageDisks = 4,
    [parameter(Mandatory=$false)][int]$SizeOfStorageDisks = 500,
    [parameter(Mandatory=$false)][string]$LocalAdminUserName = "netadmin",
    [parameter(Mandatory=$false)][string]$LocalAdminPwd = "SSimple0",
    [parameter(Mandatory=$false)][string]$dcInstallMode = "domain",
    [parameter(Mandatory=$false)][string]$domainDnsName = "vaperware.com",
    [parameter(Mandatory=$false)][string]$domainNetBiosName = "vaperware",
    [parameter(Mandatory=$false)][string]$ScriptFolder = (get-location).Path
)

function local:Create-iSCSiStorage
{
   param(
      [parameter(Mandatory=$true)][string]$CloudSvc,
      [parameter(Mandatory=$true)][string]$vmName,
      [parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential,
      [parameter(Mandatory=$true)][string]$StoragePoolName,
      [parameter(Mandatory=$true)][string]$VirtualDiskName,
      [parameter(Mandatory=$true)][string]$VolumeLabel,
      [parameter(Mandatory=$true)][string]$iSCSIVirtualDisk,
      [parameter(Mandatory=$true)][string]$iSCSITargetName,
      [parameter(Mandatory=$true)][string]$iSCSIDNSInit
   )
      
   Write-Host "`nCreating Storage Pool" -ForegroundColor Yellow
   $PoolResults = (Create-StoragePool -CloudSvc $CloudSvc -vmName $vmName -Credential $Credential -StoragePoolName $StoragePoolName `
   -VirtualDiskName $VirtualDiskName -VolumeLabel $VolumeLabel)

   Write-Host "`nCreating Virtual Disk" -ForegroundColor Yellow
   $DiskResults = (Create-ISCSIVirtualDisk -CloudSvc $CloudSvc -vmName $vmName -Credential $credential `
   -iSCSIVirtualDrive $PoolResults.DriveLetter -iSCSIVirtualDisk $iSCSIVirtualDisk -iSCSIVirtualDiskSize $PoolResults.SizeRemaining)

   Write-Host "`nSetting iSCSI Target" -ForegroundColor Yellow
   Create-ISCSITargetDNS -CloudSvc $CloudSvc -vmName $vmName -Credential $credential `
   -iSCSIDevicePath $DiskResults.Path -iSCSITargetName $iSCSITargetName -iSCSIDNSInit $iSCSIDNSInit

}

##Load the functions
Import-Module $scriptFolder\DeploymentFunctions.psm1 -AsCustomObject -Force -DisableNameChecking -Verbose:$false

###
##
##  Need to add Commandline validation
##
###

###
##
##  parameterize these hard coded values
##

##$vnetName = "VWNet01"
##$subnetName = "StorageNet"
##$availabilitySet = "StorageAvailSet"

##$dataDisks = @()
##$dataDisks += @("PhyDisk01:500")
$dataDisks = @()
for($i=0; $i -lt $NumOfDataDisks; $i++)
{$dataDisks += @("PhyDisk" + $i.ToString().PadLeft((10).ToString().Length, '0')+ ":" + $SizeOfDataDisks.ToString().trim())}



$endPoints = @()

$iSCSIDNSInit = "DNSName:SQL1.vaperware.com"
$iSCSITargetName = "iSCSITargetSQL"
$imageFamilyName = "Windows Server 2012 R2 Datacenter"

##SharePoint Deployment

##$ImageFamilyName = "SharePoint Server 2013 Trial"
##$subnetName = "ServerNet"
##$availabilitySet = "SharePointAvailSet"
##$endPoints = @()
#### Localized EndPoints
##$xEndpoints = [xml]('<Endpoint Name="web" Protocol="tcp" LocalPort="80" PublicPort="80" LBSetName="" ProbePort="" ProbeProtocol="" ProbePath=""/>')
##$Endpoints = @($xEndpoints.endpoint)

##
##
###

##Start overall stop watch
$oa_stopWatch = New-Object System.Diagnostics.Stopwatch;$oa_stopWatch.Start()

##Get latest Win 2012 r2 image
$imageName = (get-latestimage -imageFamily $ImageFamilyName)

##Creates Affinity group
$AffinityGroup = (Set-AffinityGroup -AffinityGroup $AffinityGroup -Region $Region)

##Set Cloud Service
$CloudService = (Set-Cloud -CloudSvc $CloudService -AffinityGroup $AffinityGroup -Region $Region)

##Create Virtual Network
##Create-VNet "$scriptFolder\Storage_NetworkConfig.xml"

##Set/Create Storage account
$storageAccountName = (Set-Storage -AffinityGroup $AffinityGroup -storageAccountName $storageAccountName -Region $Region)

Write-Host "   Setting storage account $($storageAccountName) as default" -NoNewline
Set-AzureSubscription -SubscriptionName (Get-AzureSubscription -Default).SubscriptionName -CurrentStorageAccountName $storageAccountName
Write-host -ForegroundColor Green "... Completed`n"

## Deploy th Storage Server
if ($vmName.length -gt 15){$vmName = $vmName.SubString(0,15)}

Create-AzureVmIfNotExists `
   -serviceName $CloudService  `
   -vmName $vmName  `
   -size $VmSize  `
   -imageName $imageName  `
   -availabilitySetName $availabilitySet  `
   -dataDisks ($dataDisks) `
   -vnetName $vnetName  `
   -subnetName $subnetName  `
   -affinityGroup $affinityGroup  `
   -adminUsername $LocalAdminUserName  `
   -adminPassword $LocalAdminPwd  `
   -dcInstallMode $dcInstallMode `
   -domainDnsName $domainDnsName `
   -domainNetBiosName $domainNetBiosName `
   -endPoints $endPoints

#Get the hosted service WinRM Uri
[System.Uri]$uris = (Get-VMConnection -ServiceName $CloudService -vmName $vmName)
if ($uris -eq $null){return}

$Credential = (Set-Credential -UserName $LocalAdminUserName -Password $LocalAdminPwd)

## Format the Data disk that will hold the iSCSI VHD files
Write-Host "`nFormating local disk" -ForegroundColor Yellow
FormatDisk `
   -uris $uris `
   -Credential $Credential

## Add Additional iSCSI Storage disks
Write-Host "`nAdding disk(s) for iSCSI deployment" -ForegroundColor Yellow
Add-StorageDisks -CloudSvc $CloudService -vmName $vmName -NumOfDisks $NumOfStorageDisks -SizeGB $SizeOfStorageDisks

Write-Host "`nEnable iSCSIFeatures" -ForegroundColor Yellow
$FeaturesReult = (Enable-iSCSIFeatures -CloudSvc $CloudService -vmName $vmName -Credential $credential)

[int]$nPoolCt = [System.Math]::truncate($NumOfStorageDisks / 2)
Write-Host "`nCreating $($nPoolCt) Storage Pool(s)" -ForegroundColor Yellow
for($i=1; $i -le $nPoolCt; $i++)
{
   $StringCt = $i.ToString().PadLeft(([int]10).ToString().Length, '0')
   Create-iSCSiStorage `
      -CloudSvc $CloudService  `
      -vmName $vmName  `
      -Credential $Credential `
      -StoragePoolName "StoragePool$($StringCt)" `
      -VirtualDiskName "VirtualDisk$($StringCt)" `
      -VolumeLabel "Volume$($StringCt)" `
      -iSCSIVirtualDisk "iSCSIvDisk$($StringCt)" `
      -iSCSITargetName $iSCSITargetName `
      -iSCSIDNSInit $iSCSIDNSInit
}

$oa_stopWatch.Stop();$ts = $oa_stopWatch.Elapsed
write-host ("`nTotal deployment completed in {0} hours {1} minutes, {2} seconds`n" -f $ts.Hours, $ts.Minutes, $ts.Seconds)


#.\DeployStorage.ps1 -vmName "Storage01" -CloudService "gspcloud003" -storageAccountName "gspstore003"
#.\DeployStorage.ps1 -vmName "Storage02" -CloudService "gspcloud004" -storageAccountName "gspstore004"

## .\DeployStorage.ps1 -vmName "Storage01" -CloudService "gspcloud02" -storageAccountName "gspstorage02"
##$Results = (Create-StoragePool -CloudSvc "gspcloud01" -vmName "storage01" -Credential $Credential -Sto
##ragePoolName "MyStoragePool02" -VirtualDiskName "MyVirtualDisk02" -VolumeLabel "Volume02")
##
##$res2 = (Create-ISCSIVirtualDisk -CloudSvc gspcloud01 -vmName Storage01 -Credential $credential -iSCSI
##VirtualDrive $Results.DriveLetter -iSCSIVirtualDisk "iSCSIvDisk01" -iSCSIVirtualDiskSize $Results.SizeRemaining)
##
##Create-ISCSITargetDNS -CloudSvc gspcloud01 -vmName Storage01 -Credential $credential -iSCSIDevicePath
##$res2.Path -iSCSITargetName iSCSITargetSQL -iSCSIDNSInit 

## End Script