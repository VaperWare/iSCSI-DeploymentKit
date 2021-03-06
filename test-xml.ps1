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
param(
   [parameter(Mandatory=$false)][string]$configFilePath = (Join-Path -Path (get-location).Path -ChildPath 'Storage-Deployment.xml'),
   [parameter(Mandatory=$false)][string]$ScriptFolder = (get-location).Path
   
)

function local:Get-DiskFromXML([xml.XmlElement]$XMLFrag, [string]$DiskLabel="PhyDisk"){
   [int]$NumOfDisks = [int]$XMLFrag.count
   [int]$SizeOfDisk = [int]$XMLFrag.SizesInGB

   $Disks = @()
   for($i=0; $i -lt $NumOfDisks; $i++)
   {$Disks += @($DiskLabel + $i.ToString().PadLeft((10).ToString().Length, '0')+ ":" + $SizeOfDisk.ToString().trim())}
   return $Disks
}

Function local:Get-DiskFromString([string]$DiskString){
## Collect the Disk configuration
   $Disks = @()
   if(-not [string]::IsNullOrEmpty($DiskString)){
   foreach($diskEntry in $DiskString.Split(';'))
   {$Disks += @($diskEntry)}}
   return $Disks
}

function local:Set-NetworkValues([xml.XmlElement]$NetParent, [xml.XmlElement]$NetServer) {

   $Network = $null
   if(-not [string]::IsNullOrEmpty($NetParent)){
      $vNet = $NetParent.name 
      $Subnet = $NetParent.Subnet
      if(-not [string]::IsNullOrEmpty($NetServer)){
         if(-not [string]::IsNullOrEmpty($NetServer.Name)){ $vNet = $NetServer.name }
         if(-not [string]::IsNullOrEmpty($NetServer.Subnet)){ $Subnet = $NetServer.Subnet }
      }
      $Network = $vNet + ":" + $Subnet
      
   }   
   return $Network
}

function local:Get-VMConfig
{

param ($VM, $VMConfigs, [string]$configId)
   $return = $null 
   $return = $VMConfigs.VMConfig | ?{$_.id -eq $VM.configId}
   if ((-not [string]::IsNullOrEmpty($return)))
   {
      Write-Host "VMSize in Get-Config $($VMConfigs.VMSize)"
      if ((-not [string]::IsNullOrEmpty($VM.CloudService))){
         $return.CloudService = $VM.CloudService
      }
      if ((-not [string]::IsNullOrEmpty($vm.StorageAccount))){
         $return.StorageAccount = $VM.StorageAccount
      }
      if ((-not [string]::IsNullOrEmpty($vm.DataDiskSizesInGB))){
         $return.DataDiskSizesInGB = $VM.DataDiskSizesInGB
      }
      if ((-not [string]::IsNullOrEmpty($vm.StorageDisk.Ct))){
         $return.StorageDisk.Ct = $VM.StorageDisk.Ct
      }
      if ((-not [string]::IsNullOrEmpty($vm.StorageDisk.SizesInGB))){
         $return.StorageDisk.SizesInGB = $VM.StorageDisk.SizesInGB
      }
      
   }
   else {Write-Host "Configuration <$($config.id)> not found" -ForegroundColor Red}
   return $return
}


cls
set-variable -name SharedFunctions -value "DeploymentFunctions" -option constant -Visibility Public
set-variable -name LocalFunctions -value "iSCSIFunctions" -option constant -Visibility Public

Import-Module (Join-Path -Path $scriptFolder -ChildPath $SharedFunctions) -AsCustomObject -Force -DisableNameChecking -Verbose:$false -ErrorAction Stop

$config = [xml](gc $configFilePath -ErrorAction Stop)

$dcServiceName = $config.Azure.Connections.ActiveDirectory.ServiceName
$dcVmName = $config.Azure.Connections.ActiveDirectory.DomainControllerVM
$domainInstallerUserName = $config.Azure.Connections.ActiveDirectory.ServiceAccountName
$domainInstallerPassword = GetPasswordByUserName $domainInstallerUserName $config.Azure.ServiceAccounts.ServiceAccount
$domain = $config.Azure.Connections.ActiveDirectory.Domain
$dnsDomainName = $config.Azure.Connections.ActiveDirectory.DnsDomain
$VMConfigs = $config.Azure.VMConfigs

Write-Host "Domain <$($domain)>"
Write-Host "DnsDomainName <$($dnsDomainName)>"

#Write-Host $dcServiceName
#Write-Host $dcVmName
#Write-Host $domainInstallerUserName
#Write-Host $domainInstallerPassword

## Query DC and star if needed... DC must be up and running
#Get the hosted service WinRM Uri

#[System.Uri]$uris = (Get-VMConnection -ServiceName $dcServiceName -vmName $dcVmName -AzurePack $AzurePack)
#if ($uris -eq $null){return}
#
#$domainCredential = (Set-Credential -Username $domainInstallerUsername -Password $domainInstallerPassword)

$vmServers = $config.Azure.StorageServers
$vmDefRegion = $config.Azure.StorageServers.Region
$vmDefSize = $config.Azure.StorageServers.Size
$AvailabilitySet = $config.Azure.StorageServers.AvailabilitySet
$LocalAdminUserName = $config.Azure.StorageServers.AdminUsername
$LocalAdminPwd = GetPasswordByUserName $LocalAdminUserName $config.Azure.ServiceAccounts.ServiceAccount

Write-Host "Local Admin <$($LocalAdminUserName)>"
Write-Host "Lccal Password <$($LocalAdminPwd)>"
Write-Host "Region <$($vmDefRegion)>"
Write-Host "Size <$($vmDefSize)>"
Write-Host "AS <$($AvailabilitySet)>"
Write-Host 
Write-Host 
$ServerNetCFG = $vmServers.Network 
foreach($vmServer in $vmServers.AzureVM)
{
Write-Host "<$($vmServer.Name)>"

   $localDataDisk = (Get-DiskFromString $vmServer.DataDiskSizesInGB)
   $region = $vmDefRegion ; if (-not [string]::IsNullOrEmpty($vmServer.Region)){$region=$vmServer.Region}
   $vmSize = $vmDefSize ; if (-not [string]::IsNullOrEmpty($vmServer.Size)){$region=$vmServer.Size}
   Write-Host "Network CFG" ; (Set-NetworkValues -NetParent $vmServers.Network -NetServer $vmServer.Network)
#   [int]$NumOfStorageDisks = [int]$vmServer.StorageDisk.count
#   [int]$SizeOfStorageDisks = [int]$vmServer.StorageDisk.SizesInGB
   
   Write-Host "<Region $($region)>"
   Write-Host "<VMSize $($vmSize)>"
#   Write-Host "<$($NumOfStorageDisks)>"
#   Write-Host "<$($SizeOfStorageDisks)>"
   Write-Host "`nlocal disk";$localDataDisk
   $StorageDisks = (Get-DiskFromXML $vmServer.StorageDisk)
   Write-Host "`nStorage"; $StorageDisks
#   Write-Host "`nwait`n"; sleep 3
}


Write-Host "`n`nAS Testing"
$AS = $config.Azure.AS
#foreach($AvailabilitySet in $config.Azure.AvailabilitySet){
foreach($AvailabilitySet in $as.AvailabilitySet){
Write-Host $AvailabilitySet.name
      Write-Host "VMSize in B4 call Get-Config $($AvailabilitySet.VMSize)"
Write-Host "pausing";sleep 2
   foreach($StorageServer in $AvailabilitySet.AzureVM){
      Write-Host $StorageServer.name
      Write-Host "<$($StorageServer.ConfigId)>"
      if ((-not [string]::IsNullOrEmpty($StorageServer.ConfigId))){
      
      $VMConfig = (Get-VMConfig -VM $StorageServer -VMConfigs $VMConfigs -ConfigId $StorageServer.ConfigId)
#      if (){
#      }
      Write-Host "`nServer Config"
      Write-Host $VMConfig.Cloudservice
      Write-Host $VMConfig.StorageAccount
      Write-Host $VMConfig.DataDiskSizesInGB
      Write-Host $VMConfig.StorageDisk.Count
      Write-Host $VMConfig.StorageDisk.SizesInGB
      }
   }
}

##    [parameter(Mandatory=$true)][string]$vmName,
##    [parameter(Mandatory=$false)][string]$CloudService = "",
##    [parameter(Mandatory=$false)][string]$storageAccountName = "",
##    [parameter(Mandatory=$false)][string]$AffinityGroup = "LabAG01",
##    [parameter(Mandatory=$false)][string]$Region = "East US",
##    [parameter(Mandatory=$false)][string]$VmSize = "Large",
##    [parameter(Mandatory=$false)][string]$vnetName = "VWNet01",
##    [parameter(Mandatory=$false)][string]$subnetName = "StorageNet",
##    [parameter(Mandatory=$false)][string]$availabilitySet = "StorageAvailSet",
##    [parameter(Mandatory=$false)][int]$NumOfDataDisks = 1,
##    [parameter(Mandatory=$false)][int]$SizeOfDataDisks = 500,
##    [parameter(Mandatory=$false)][int]$NumOfStorageDisks = 4,
##    [parameter(Mandatory=$false)][int]$SizeOfStorageDisks = 500,
##    [parameter(Mandatory=$false)][string]$LocalAdminUserName = "netadmin",
##    [parameter(Mandatory=$false)][string]$LocalAdminPwd = "SSimple0",
##    [parameter(Mandatory=$false)][string]$dcInstallMode = "domain",
##    [parameter(Mandatory=$false)][string]$domainDnsName = "vaperware.com",
##    [parameter(Mandatory=$false)][string]$domainNetBiosName = "vaperware",
##    [parameter(Mandatory=$false)][string]$ScriptFolder = (get-location).Path
##