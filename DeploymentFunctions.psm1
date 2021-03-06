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


#Region Utility Functions

Function local:Wait 
{
param([string]$msg="Pausing",[int]$InSeconds=60)
   $Sleep = $InSeconds ; $delay = 1

    if ($inSeconds -ge 60) {
      [int]$delay = $InSeconds / 60 ; $Sleep = 60
    }
    elseif ($inSeconds -lt 60){
      [int]$delay = 1 ; $Sleep = $InSeconds
    }
    else {
      [int]$delay = 1 ; $Sleep = $InSeconds
    }
    
    [int]$Count = 0 ; Write-Host "$($msg) ($($InSeconds.ToString().Trim()) seconds)" -NoNewline
    while ($Count -lt $delay){write-host -NoNewline "."; sleep $Sleep;$count += 1};Write-Host ".. Resuming"
}

function local:randomstring 
{
   param([int]$length = 6)
   
   $digits = 48..57
   $letters = 65..90 + 97..122
   $rstring = get-random -count $length `
      -input ($digits + $letters) |
      % -begin { $aa = $null } `
      -process {$aa += [char]$_} `
      -end {$aa}
   return $rstring.ToString().ToLower()
}

function local:get-latestimage 
{
   param([string]$imageFamily = "Windows Server 2012 R2 Datacenter") 
   
   Write-Host "Getting latest $($imageFamily) image"
   $retString = (Get-AzureVMImage | Where { $_.ImageFamily -eq $imageFamily } | sort PublishedDate -Descending | Select-Object -First 1).ImageName
   return $retString
}

function local:Set-Credential 
{
param (
   [parameter(Mandatory=$true)][string]$UserName,
   [parameter(Mandatory=$true)][string]$Password)
   
   $oPassword = ConvertTo-SecureString $password -AsPlainText -Force
   return (New-Object System.Management.Automation.PSCredential($UserName, $oPassword))

}

function local:MergeXmlChildren 
{
   Param([System.Xml.XmlElement] $elem1, [System.Xml.XmlElement] $elem2, [string] $keyAttributeName)
	$elemCombined = $elem1

	# Get key values from $elem1
	$childNodeHash = @{}
	foreach($childNode in $elem1.ChildNodes)
	{
		$childNodeHash.Add($childNode.$keyAttributeName, $childNode)
	}
	
	foreach($childNode in $elem2.ChildNodes)
	{
		if(-not ($childNodeHash.Keys -contains $childNode.$keyAttributeName))
		{
			# Append children from $elem2 if there is no key conflict
			$importedNode = $elemCombined.AppendChild($elemCombined.OwnerDocument.ImportNode($childNode, $true))
		}
		elseif(-not $childNodeHash.Item($childNode.$keyAttributeName).OuterXml.Equals($childNode.OuterXml))
		{
			# Otherwise throw Exception
			Throw Write-Error ("Failed to merge XML element {0} because non-identical child elements with the same {1} are found." -f $elem1.Name, $keyAttributeName)
		}
	}
	
	$elemCombined
}

#EndRegion

#Region Virtual Machine Functions

Function local:FormatDisk
{
	Param([System.Uri]$uris, [System.Management.Automation.PSCredential]$credential)

    $maxRetry = 5
    For($retry = 0; $retry -le $maxRetry; $retry++)
    {
      Try
      {
	      #Create a new remote ps session and pass in the scrip block to be executed  

         Write-Host "Starting remote session" -NoNewline
         Invoke-Command -ConnectionUri $URIS.ToString() -Credential $Credential -OutVariable $Result -ScriptBlock { 		
		      
            Write-Host -ForegroundColor Green " ...Started"
            Set-ExecutionPolicy Unrestricted -Force

            $drives = gwmi Win32_diskdrive
            $scriptDisk = $Null
            $script = $Null
		
            Write-Host "Formatting data disks..." -NoNewline
		      #Iterate through all drives to find the uninitialized disk
		      foreach ($disk in $drives){
               if ($disk.Partitions -eq "0"){
	               $driveNumber = $disk.DeviceID -replace '[\\\\\.\\physicaldrive]',''     
                  Write-Host " $($driveNumber)" -NoNewline
$script = @"
select disk $driveNumber
online disk noerr
attributes disk clear readonly noerr
create partition primary noerr
format quick
"@
                  }
                  $driveNumber = $Null
                  $scriptDisk += $script + "`n"
                  $script = $Null
               }
               #output diskpart script
               $scriptDisk | Out-File -Encoding ASCII -FilePath "c:\Diskpart.txt" 
               #execute diskpart.exe with the diskpart script as input
               diskpart.exe /s c:\Diskpart.txt >> C:\DiskPartOutput.txt

               #assign letters and labels to initilized physical drives
               $volumes = gwmi Win32_volume | where {$_.BootVolume -ne $True -and $_.SystemVolume -ne $True -and $_.DriveType -eq "3"}
               $letters = 68..89 | ForEach-Object { ([char]$_)+":" }
               $freeletters = $letters | Where-Object { 
	  		        (New-Object System.IO.DriveInfo($_)).DriveType -eq 'NoRootDirectory'
		         }
               foreach ($volume in $volumes){
                  if ($volume.DriveLetter -eq $Null){
	        	        mountvol $freeletters[0] $volume.DeviceID
                  }
                  $freeletters = $letters | Where-Object { 
                     (New-Object System.IO.DriveInfo($_)).DriveType -eq 'NoRootDirectory'
                  }
               }
         }
         break
      }
      Catch [System.Exception]
      {
      Write-Host $_.Exception.Message
         wait -msg "Error - retrying..." -InSeconds 30
	   }
    }
    Write-Host -ForegroundColor Green " ... Formatting complete"
	################## Function execution end #############
}

Function InstallWinRMCertificateForVM
{
   param([string] $serviceName, [string] $vmName)
   
   Write-Host "Installing WinRM Certificate for remote access: <$($serviceName)> <$($vmName)> " -NoNewline
	$WinRMCert = (Get-AzureVM -ServiceName $serviceName -Name $vmName | select -ExpandProperty vm).DefaultWinRMCertificateThumbprint
	$AzureX509cert = Get-AzureCertificate -ServiceName $serviceName -Thumbprint $WinRMCert -ThumbprintAlgorithm sha1

	$certTempFile = [IO.Path]::GetTempFileName()
	$AzureX509cert.Data | Out-File $certTempFile

	# Target The Cert That Needs To Be Imported
	$CertToImport = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certTempFile

	$store = New-Object System.Security.Cryptography.X509Certificates.X509Store "Root", "LocalMachine"
	$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
	$store.Add($CertToImport)
	$store.Close()
	
	Remove-Item $certTempFile
   Write-Host -ForegroundColor Green "... Completed"
}

Function local:Test-RMCertificateForVM
{
   param([string] $serviceName, [string] $vmName, [bool]$InstallIfMissing=$true)
   
   Write-Host "Checking WinRM Certificate for remote access: <$($serviceName)> <$($vmName)> "
	$WinRMCert = (Get-AzureVM -ServiceName $serviceName -Name $vmName | select -ExpandProperty vm).DefaultWinRMCertificateThumbprint
   
   $cert = dir Cert:\CurrentUser\root | ? Thumbprint -eq $WinRMCert
   
   if ([string]::IsNullOrEmpty($cert) -and ($InstallIfMissing)){
      InstallWinRMCertificateForVM -serviceName $serviceName -vmName $vmName
   }
}

Function Create-AzureVmIfNotExists
{
	param([string]$serviceName, [string]$vmName, [string] $size, [string]$imageName, [string]$availabilitySetName, [string[]] $dataDisks,
	[string]$vnetName, [string]$subnetName,[string]$affinityGroup, [string]$adminUsername, [string]$adminPassword,  
   [string] $dcInstallMode="StandAlone", [string]$domainDnsName, [string]$domainNetBiosName, $endPoints)
	    
	 Write-Host "Setting VM Configuration..." -NoNewline ; Write-Host -ForegroundColor Green " <$($vmName)>"
    
#   Create VM if one with the specified name doesn't exist
	$existingVm = Get-AzureVM -ServiceName $serviceName -Name $vmName -WarningAction SilentlyContinue
	if($existingVm -eq $null)
   {
      $vmConfig = New-AzureVMConfig -Name $vmName -InstanceSize $size -ImageName $imageName -AvailabilitySetName $availabilitySetName | `
      Add-AzureProvisioningConfig -Windows -Password $adminPassword -AdminUsername $adminUserName | Set-AzureSubnet -SubnetNames $subnetName 

      ## Localized Disks
      Add-Disks -dataDisks $dataDisks -vmConfig $vmConfig

      ## Localized EndPoints
      Add-EndPoints -Endpoints $Endpoints -vmConfig $vmConfig -ServiceName $serviceName

      if (($dcInstallMode.tolower() -eq "replica") -or ($dcInstallMode.tolower() -eq "domain")) 
      {
      $vmConfig | Add-AzureProvisioningConfig -WindowsDomain -Password $adminPassword -AdminUserName $adminUserName -JoinDomain $domainDnsName -Domain $domainNetBiosName -DomainPassword $adminPassword -DomainUserName $adminUserName | Out-Null
      }
      
      Write-Host "VM Configuration complete"

      Write-Host "`nDeploying VM..." -NoNewline ; Write-Host -ForegroundColor Green " <$($vmName)>" -NoNewline ; Write-Host -ForegroundColor Yellow " $($dcInstallMode) mode"

      if((Get-AzureService -ServiceName $serviceName -ErrorAction SilentlyContinue) -eq $null) 
      { $vmConfig | New-AzureVM -ServiceName $serviceName -AffinityGroup $affinityGroup -VNetName $vnetName -WaitForBoot -Verbose }
      else
      { $vmConfig | New-AzureVM -ServiceName $serviceName -VNetName $vnetName -WaitForBoot -Verbose }

      Write-Host "VM Deployment complete"
      InstallWinRMCertificateForVM $serviceName $vmName
      wait -msg "Pausing for services to start" -InSeconds 300 
	}
	else
	{
	  Write-Host ("VM with Service Name {0} and Name {1} already exists." -f $serviceName, $vmName)
	}
}

#EndRegion

#Region Azure Utility Functions

function local:Set-AffinityGroup 
{
   param([string]$AffinityGroup="", [string]$Region="East US", [string]$AffPreFix="affgrp")

   if ($AffinityGroup -eq "")
   {$AffinityGroup = $AffPreFix + (randomString)}
   
   Write-Host "Checking Affinity Group $($AffinityGroup)" -NoNewline 
   if((Get-AzureAffinityGroup -Name $AffinityGroup -ErrorAction SilentlyContinue) -eq $null)
   {
      Write-Host "...Creating" -NoNewline
      $NullReturn = New-AzureAffinityGroup -Name $AffinityGroup -Location $Region -OutVariable $Result | Out-Null
   }
   else {Write-Host "...Already Exists" -NoNewline }
   Write-host -ForegroundColor Green "... Completed"
   return $affinityGroup
}

function local:Set-Cloud
{
   param([string]$CloudSvc, [string]$AffinityGroup, [string]$Region="East US")
   $continue = $true
   $prefix = "CloudSvc"
   
   if($CloudSvc -eq "") {
      $CloudSvc = $prefix + (randomString) 
   }
   else {
      if((Test-AzureName -Service $CloudSvc) -eq $true)
      {
         if((Get-AzureService -ServiceName $CloudSvc -WarningAction SilentlyContinue -ErrorAction SilentlyContinue) -ne $null)
         { Write-Host "Using exsiting Cloud Service $($CloudSvc)";$continue = $false }
         else {$CloudSvc = $prefix + (randomString)}
      }
   }
   if($continue){
      Write-Host "Creating new Cloud Service $($CloudSvc) in " -NoNewline
      try
      {
         if ($AffinityGroup -ne $null)
         {
            Write-Host "Affinity Group $($AffinityGroup)" -NoNewline
            $NullReturn = New-AzureService -ServiceName $CloudSvc -AffinityGroup $AffinityGroup 
         }
         else 
         {
            Write-Host "location $($Region)" -NoNewline
            $NullReturn = New-AzureService -ServiceName $CloudSvc -Location $Region
         }
         Write-Host -ForegroundColor Yellow "...Waiting for deployment to complete" -NoNewline
         while((Get-AzureService -ServiceName $CloudSvc -WarningAction SilentlyContinue -ErrorAction SilentlyContinue) -eq $null)
         { Write-Host "." -NoNewline;sleep -Seconds 30}
         Write-host -ForegroundColor Green "... Completed"
      }
      catch{}
   }
   
   return $CloudSvc
}

function local:Set-Storage 
{

   param([string]$AffinityGroup, [string]$storageAccountName="", [string]$storageprefix="spstorage", [string]$Region="East US")
   
   $continue = $true
   if($storageAccountName -eq "") {
      $storageAccountName = $storageprefix + (randomString) 
   }
   else {
      if((Test-AzureName -Storage $storageAccountName) -eq $true)
      {
         if ((Get-AzureStorageAccount $storageAccountName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue) -ne $null)
         { Write-Host "Using exsiting storage account $($storageAccountName)";$continue = $false }
         else {Write-Host "Resetting Storage Account"; $storageAccountName = $storageprefix + (randomString)}
      }
   }
   
   while($continue)
   {
      if(((Test-AzureName -Storage $storageAccountName) -eq $true)){
         $storageAccountName = $storageprefix + (randomString)
      }
      else
      {
         Write-Host "Creating new storage account $($storageAccountName) in " -NoNewline
         try
         {
            if ($AffinityGroup -ne $null) 
            {
               Write-Host "Affinity Group $($AffinityGroup)" -NoNewline
               $NullReturn = New-AzureStorageAccount -StorageAccountName $storageAccountName -AffinityGroup $AffinityGroup -OutVariable $Result | Out-Null
            }
            else 
            { 
               Write-Host "location $($Region)" -NoNewline
               $NullReturn = New-AzureStorageAccount -StorageAccountName $storageAccountName -Location $Region -OutVariable $Result | Out-Null
            }
            Write-host -ForegroundColor Green "... Completed"
         }
         catch
         { return $null }
         break
      }
   }
   return $storageAccountName
}

function local:Add-EndPoints
{
   param([string]$ServiceName, $vmConfig, $endPoints,[int]$IndentCt=3)
   $Indent = " " * $IndentCt; $epAdded = $false
   if ($endPoints -ne $null)
   {
      Write-Host "$($Indent)Processing Endpoint(s)"
      foreach($ep in $endPoints) 
      {
         Write-Host "$($Indent)$($Indent)Checking Endpoint $($ep.Name)" -NoNewline
         if ((Get-AzureVM -ServiceName $ServiceName -WarningAction SilentlyContinue | Get-AzureEndpoint | ?{$_.name -eq $ep.Name}))
            {Write-Host " ... already exists skipping"}
         else 
         {
            Write-Host " ... Adding " -NoNewline
            if($ep.LBSetName -ne "") 
            {
               Write-Host "Load Balanced Endpoint <$($ep.PublicPort) - $($ep.LBSetName)>" -NoNewline
               Add-AzureEndpoint -VM $vmConfig -Name $ep.Name -Protocol $ep.Protocol -LocalPort $ep.LocalPort -PublicPort $ep.PublicPort -LBSetName $ep.LBSetName -ProbeProtocol $ep.ProbeProtocol -ProbePath $ep.ProbePath -ProbePort $ep.ProbePort | Out-Null
            }
            else 
            {
               Write-Host "Endpoint <$($ep.PublicPort)>" -NoNewline
               Add-AzureEndpoint -VM $vmConfig -Name $ep.Name -Protocol $ep.Protocol -LocalPort $ep.LocalPort -PublicPort $ep.PublicPort | Out-Null
            }
            Write-Host " ... Complete"
            $epAdded = $true
         }
      }
      Write-Host "$($Indent)Endpoint Processing Completed"
   }
   if (!$epAdded) { Write-Host "$($Indent)No Endpoint(s) added" }
}

Function local:Get-NextLun
{
   param(
      [parameter(Mandatory=$true)]$vmConfig 
   )
##   [string]$storageAccountName = $vmConfig.VM.OSVirtualHardDisk.MediaLink.Host.Split('.')[0]
##   [string]$CloudSvc = $vmConfig.ServiceName
##   [string]$vmName = $vmConfig.InstanceName
##   [int]$NextLun = 0 
##   $DataDisks = Get-AzureVM -ServiceName $CloudSvc -Name $vmName | Get-AzureDataDisk
##   if($DataDisks -ne $null){$NextLun = $dataDisks.Count}
   [int]$NextLun = 0
   $DataDisks = $vmConfig.VM.DataVirtualHardDisks
   if($DataDisks -ne $null){$NextLun = $dataDisks.Count}
   return $NextLun
}

function local:Add-Disks 
{
   param($vmConfig, $dataDisks)
   
   if ($dataDisks -ne $null)
   {
      Write-Host "   Getting next Lun <" -NoNewline
      [int]$Lun = (Get-NextLun -vmConfig $vmConfig)
      Write-Host "$($lun)>"
      Write-Host "   Adding Data disk(s)"
      for($i=0; $i -lt $dataDisks.Count; $i++)
      {
         $fields = $dataDisks[$i].Split(':')
         $dataDiskLabel = [string] $fields[0]
         $dataDiskSize = [string] $fields[1]
         Write-Host ("      {0} size {1} lun {2}" -f $dataDiskLabel, $dataDiskSize, $Lun)	

         #Add Data Disk to the newly created VM
         $vmConfig | Add-AzureDataDisk -CreateNew -DiskSizeInGB $dataDiskSize -DiskLabel $dataDiskSize -LUN $Lun | Out-Null
         $Lun +=1
      }
         Write-Host "   Disk Processing Completed"
   }
   else
   {
      Write-Host "   No Data disk(s) added"
   }
}

function local:Create-VNet 
{
   Param([string]$vnetConfigPath)

   Write-Host "Creating VNet Configuration file"
   Write-Host "   Reading $($vnetConfigPath)" -NoNewline
   $outputVNetConfigPath = "$env:temp\spvnet.xml"
   $inputVNetConfig = [xml] (Get-Content $vnetConfigPath)
   Write-Host -ForegroundColor Green "... Completed"

   Write-Host "   Reading Current Azure VNet configuration" -NoNewline
   #Get current VNet Configuration
   $currentVNetConfig = [xml] (Get-AzureVNetConfig).XMLConfiguration
   Write-Host -ForegroundColor Green "... Completed"
	
   Write-Host "   Merging VNet Configurations" -NoNewline
	#If no configuration found just use the new configuration
   if($currentVNetConfig.NetworkConfiguration -eq $null)
	{
		$combinedVNetConfig = $inputVNetConfig
	}
   else
	{
		# If VNet already exists and identical do nothing
		$inputVNetSite = $inputVNetConfig.SelectSingleNode("/*/*/*[name()='VirtualNetworkSites']/*[name()='VirtualNetworkSite']")
		$existingVNetSite = $currentVNetConfig.SelectSingleNode("/*/*/*[name()='VirtualNetworkSites']/*[name()='VirtualNetworkSite'][@name='" + $inputVNetSite.name + "']")
		if($existingVNetSite -ne $null -and $existingVNetSite.AddressSpace.OuterXml.Equals($inputVNetSite.AddressSpace.OuterXml) `
			-and $existingVNetSite.Subnets.OuterXml.Equals($inputVNetSite.Subnets.OuterXml))
		{
			write-host;Write-Host -ForegroundColor Red ("A VNet with name {0} and identical configuration already exists." -f $inputVNetSite.name)
			return
		}
		
		$combinedVNetConfig = $currentVNetConfig
		
		#Combine DNS Servers
		$dnsNode = $combinedVNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.Dns
		if($dnsNode -ne $null)
		{
			$inputDnsServers = $inputVNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.Dns.DnsServers
			$newDnsServers = MergeXmlChildren $dnsNode.DnsServers $inputDnsServers "name"
			$dnsNode.ReplaceChild($newDnsServers, $dnsNode.DnsServers)
		}
		elseif($currentVNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.Dns -ne $null)
		{
			$combinedVNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.InsertBefore($currentVNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.Dns, $combinedVNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.VirtualNetworkSites)
		}
		
		#Combine VNets
      $virtualNetworkConfigurationNode = $combinedVNetConfig.NetworkConfiguration.VirtualNetworkConfiguration
        
      # If VNET Config exists but there are no currently defined sites
      if($virtualNetworkConfigurationNode.VirtualNetworkSites -ne $null)
      {        
         $inputVirtualNetworkSites = $inputVNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.VirtualNetworkSites    
         $virtualNetworkConfigurationNode.ReplaceChild((MergeXmlChildren $virtualNetworkConfigurationNode.VirtualNetworkSites $inputVirtualNetworkSites "name"), $virtualNetworkConfigurationNode.VirtualNetworkSites)
      }
      else
      {
         $inputVirtualNetworkSites = $inputVNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.VirtualNetworkSites
         $vns = $combinedVNetConfig.CreateElement("VirtualNetworkSites", $combinedVNetConfig.DocumentElement.NamespaceURI)
         $vns.InnerXML = $inputVirtualNetworkSites.InnerXml
         $combinedVNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.AppendChild($vns)
      }
	}
   Write-Host -ForegroundColor Green "... Completed"

   Write-Host "   Saving VNet file to $($outputVNetConfigPath)" -NoNewline
   $combinedVNetConfig.Save($outputVNetConfigPath)
   Write-Host -ForegroundColor Green "... Completed"

   Write-Host "   Setting VNet configuration" -NoNewline
   Set-AzureVNetConfig -ConfigurationPath $outputVNetConfigPath -WarningAction SilentlyContinue | Out-Null
   Write-Host -ForegroundColor Green "... Completed"
   Write-Host "VNet Configuration file creation completed."

}

Function local:Get-VMConnection
{
   param([string]$ServiceName, [string]$vmName)
   Write-Host "Connecting to $($vmName)" -NoNewline
   [System.Uri]$Return_URIS = $null;$Return_URIS = (Get-AzureWinRMUri -ServiceName $ServiceName -Name $vmName)
   if (($Return_URIS -ne $null) -and ($Return_URIS -ne "")) {Write-Host -ForegroundColor Green " ...Connected" }
   else{Write-Host -ForegroundColor Red " ...Unable to connect";$Return_URIS = $null}
   return ($Return_URIS)
}

function local:Add-StorageDisks
{
   param(
      [parameter(Mandatory=$true)][string]$CloudSvc, 
      [parameter(Mandatory=$true)][string]$vmName,
      [parameter(Mandatory=$true)][int]$NumOfDisks,
      [parameter(Mandatory=$true)][int]$SizeGB,
      [parameter(Mandatory=$false)][string]$LabelPrefix="iSCSIDisk"
      )
      
      Write-Host "Updating VM Configuration..." -NoNewline ; Write-Host -ForegroundColor Green " <$($vmName)>"
      $dataDisks = @()
      for($i=0; $i -lt $NumOfDisks; $i++)
      {$dataDisks += @($LabelPrefix + $i.ToString().PadLeft((10).ToString().Length, '0')+ ":" + $SizeGB.ToString().trim())}
      
      $vmConfig = Get-AzureVM -ServiceName $CloudSvc -Name $vmName -WarningAction SilentlyContinue

      Add-Disks -dataDisks $dataDisks -vmConfig $vmConfig 
      Write-Host "   Commiting changes..."
      $vmConfig | Update-AzureVM | Out-Null
      Write-Host "VM Configuration complete"

}

#EndRegion

#Region XML Functions

Function GetPasswordByUserName
{
	param([string]$userName, $serviceAccountList)
	[bool]$found = $false
	foreach($serviceAccount in $serviceAccountList)
	{
		if($serviceAccount.UserName -eq $userName)
		{
			$serviceAccount.Password
			$found = $true
			break
		}
	}
	if(-not $found)
	{
		Write ("User name {0} not found in service account list" -f $userName)
	}
}

#EndRegion

#Region iSCSI Functions

function local:Enable-iSCSIFeatures
{
   param(
   [parameter(Mandatory=$true)][string]$CloudSvc,
   [parameter(Mandatory=$true)][string]$vmName,
   [parameter(Mandatory=$true)]$Credential)

   #Get the hosted service WinRM Uri
   [System.Uri]$uris = (Get-VMConnection -ServiceName $CloudSvc -vmName $vmName)
   if ($uris -eq $null){return}
   
   Write-Host "Starting remote session" -NoNewline
   Invoke-Command -ConnectionUri $URIS.ToString() -Credential $Credential -OutVariable $Result -ErrorVariable $ErrResult -ErrorAction SilentlyContinue -ScriptBlock { 
      Param()
      
      Write-Host -ForegroundColor Green " ...Started"
      Set-ExecutionPolicy Unrestricted -Force
        
      #Hide green status bar
      $ProgressPreference = "SilentlyContinue"

      # Import the ServerManager PowerShell Module
      Import-Module -Name ServerManager
      
      Write-Host "Installing iSCSI Features" -NoNewline
      # Add the Windows Feature iSCSI Target Server
      $Result = Add-WindowsFeature FS-iSCSITarget-Server, iSCSITarget-VSS-VDS -IncludeManagementTools
      Write-Host -ForegroundColor Green " ...Complete"
#      Write-Host $Result
      $Result
      Write-Host "Exiting remote session" -NoNewline
   }
   Write-Host -ForegroundColor Green " ...Complete"
}

function local:Create-ISCSIVirtualDisk
{
   param(
   [parameter(Mandatory=$true)][string]$CloudSvc,
   [parameter(Mandatory=$true)][string]$vmName,
   [parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential,
   [parameter(Mandatory=$true)][string]$iSCSIVirtualDrive,
   [parameter(Mandatory=$true)][string]$iSCSIVirtualDisk,
   [parameter(Mandatory=$true)][long]$iSCSIVirtualDiskSize
   )
   
   #Get the hosted service WinRM Uri
   [System.Uri]$uris = (Get-VMConnection -ServiceName $CloudSvc -vmName $vmName)
   if ($uris -eq $null){return}
   
   Write-Host "Starting remote session" -NoNewline
   Invoke-Command -ConnectionUri $URIS.ToString() -Credential $Credential -OutVariable $Result -ErrorVariable $ErrResult -ErrorAction SilentlyContinue -ScriptBlock {
      Param()

##   -ArgumentList $iSCSIVirtualDrive, $iSCSIVirtualDisk, $iSCSIVirtualDiskSize -ScriptBlock { 
##   Param($iSCSIVirtualDrive, $iSCSIVirtualDisk, $iSCSIVirtualDiskSize)
      
      Write-Host -ForegroundColor Green " ...Started"
      Set-ExecutionPolicy Unrestricted -Force
        
      #Hide green status bar
      $ProgressPreference = "SilentlyContinue"
      
      #Save external variables
      $iSCSIVirtualDrive = $using:iSCSIVirtualDrive
      $iSCSIVirtualDisk = $using:iSCSIVirtualDisk
      $iSCSIVirtualDiskSize = $using:iSCSIVirtualDiskSize

      Write-Host "Creating virtual disk" -NoNewline
      $iSCSIDevicePath = "$($iSCSIVirtualDrive)`:\iSCSIVirtualDisks\$($iSCSIVirtualDisk).vhdx"
      $Result = New-IscsiVirtualDisk –Path $iSCSIDevicePath –Size $iSCSIVirtualDiskSize 
      Write-Host -ForegroundColor Green " ...Complete"
      
      $Result
      Write-Host "Exiting remote session" -NoNewline
   }
   Write-Host -ForegroundColor Green " ...Complete"
   
}

function local:Create-ISCSITargetDNS
{
   param(
   [parameter(Mandatory=$true)][string]$CloudSvc,
   [parameter(Mandatory=$true)][string]$vmName,
   [parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential,
   [parameter(Mandatory=$true)][string]$iSCSIDevicePath,
   [parameter(Mandatory=$true)][string]$iSCSITargetName,
   [parameter(Mandatory=$true)][string]$iSCSIDNSInit
   )
   #Get the hosted service WinRM Uri
   [System.Uri]$uris = (Get-VMConnection -ServiceName $CloudSvc -vmName $vmName)
   if ($uris -eq $null){return}

   Write-Host "Starting remote session" -NoNewline
   Invoke-Command -ConnectionUri $URIS.ToString() -Credential $Credential -OutVariable $Result -ErrorVariable $ErrResult -ErrorAction SilentlyContinue -ScriptBlock {
      Param()

##   -ArgumentList $iSCSIDevicePath, $iSCSITargetName,$iSCSIDNSInit -ScriptBlock { 
##   Param($iSCSIDevicePath, $iSCSITargetName,$iSCSIDNSInit)

      Write-Host -ForegroundColor Green " ...Started"
      Set-ExecutionPolicy Unrestricted -Force
        
      #Hide green status bar
      $ProgressPreference = "SilentlyContinue"
      
      #Save external variables
      $iSCSIDevicePath = $using:iSCSIDevicePath
      $iSCSITargetName = $using:iSCSITargetName
      $iSCSIDNSInit = $using:iSCSIDNSInit

      Write-Host "Creating iSCSI Target" -NoNewline
      $iSCSI = New-IscsiServerTarget -TargetName $iSCSITargetName –InitiatorID $iSCSIDNSInit
      Add-IscsiVirtualDiskTargetMapping –TargetName $iSCSITargetName –DevicePath $iSCSIDevicePath
      Write-Host -ForegroundColor Green " ...Complete"
      $Result
      Write-Host "Exiting remote session" -NoNewline
   }
   Write-Host -ForegroundColor Green " ...Complete"
}

#EndRegion

## Note - To be completed, once method for determining assocatied Volumes to a Virtual Disk can be made
##function local:Remove-StoragePool
##{
##   param(
##   [parameter(Mandatory=$true)][string]$CloudSvc,
##   [parameter(Mandatory=$true)][string]$vmName,
##   [parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential,
##   [parameter(Mandatory=$true)][string]$StoragePoolName
##   )
##   Invoke-Command -ConnectionUri $URIS.ToString() -Credential $Credential -OutVariable $Result -ErrorVariable $ErrResult -ErrorAction SilentlyContinue `
##   -ArgumentList -ScriptBlock { 
##   Param()
##      Set-ExecutionPolicy Unrestricted -Force
##        
##      #Hide green status bar
##      $ProgressPreference = "SilentlyContinue"
##      $Pool = Get-StoragePool -FriendlyName $StoragePoolName
##      
##   }
##}

function local:Create-StoragePool
{
   param(
   [parameter(Mandatory=$true)][string]$CloudSvc,
   [parameter(Mandatory=$true)][string]$vmName,
   [parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential,
   [parameter(Mandatory=$true)][string]$StoragePoolName,
   [parameter(Mandatory=$true)][string]$VirtualDiskName,
   [parameter(Mandatory=$true)][string]$VolumeLabel,
   [parameter(Mandatory=$false)][int]$NumOfDisksInPool=2
)

   #Get the hosted service WinRM Uri
   [System.Uri]$uris = (Get-VMConnection -ServiceName $CloudSvc -vmName $vmName)
   if ($uris -eq $null){return}

   Write-Host "Starting remote session" -NoNewline
   Invoke-Command -ConnectionUri $URIS.ToString() -Credential $Credential -OutVariable $Result -ErrorVariable $ErrResult -ErrorAction SilentlyContinue -ScriptBlock {
   
      Write-Host -ForegroundColor Green " ...Started"
      Set-ExecutionPolicy Unrestricted -Force
        
      #Hide green status bar
      $ProgressPreference = "SilentlyContinue"
      
      #Save external variables
      $StoragePoolName = $using:StoragePoolName
      $VirtualDiskName = $using:VirtualDiskName
      $VolumeLabel = $using:VolumeLabel
      $NumOfDisksInPool = $using:NumOfDisksInPool 

      #Turn off annoying File Explorer POP-ups
      Write-Host "Stopping ShellHWDetection Service" -NoNewline
      Stop-Service -Name ShellHWDetection
      Write-Host -ForegroundColor Green " ...Complete"

      Write-Host "Collecting available disks" -NoNewline
      $availDisks = Get-StorageSubSystem -FriendlyName "Storage Spaces*" | Get-PhysicalDisk -CanPool $True | sort $_.FriendlyName
      $PhysicalDisks = @()
      for($i=0; $i -lt $NumOfDisksInPool; $i++) { $PhysicalDisks += $availDisks[$i] }
      
      Write-Host -ForegroundColor Green " ... Complete <Allocating $($PhysicalDisks.count) of $($availDisks.count) disk(s)>"

      Write-Host "Creating Storage Pool $($StoragePoolName), Virtul Disk $($VirtualDiskName) Volume Label $($VolumeLabel)" -NoNewline
      $Result = New-StoragePool -FriendlyName $StoragePoolName -StorageSubsystemFriendlyName "Storage Spaces*" -PhysicalDisks $PhysicalDisks | `
      New-VirtualDisk -FriendlyName $VirtualDiskName -UseMaximumSize  -ProvisioningType Fixed -ResiliencySettingName Simple | `
      Initialize-Disk -PassThru |New-Partition -AssignDriveLetter -UseMaximumSize | `
      Format-Volume -AllocationUnitSize 65536 -NewFileSystemLabel $VolumeLabel -confirm:$false
      Write-Host -ForegroundColor Green " ...Complete"
      
      #Turn on annoying File Explorer POP-ups
      Write-Host "Starting ShellHWDetection Service" -NoNewline
      start-Service -Name ShellHWDetection
      Write-Host -ForegroundColor Green " ...Complete"
      
      $Result
      Write-Host "Exiting remote session" -NoNewline
   }
   Write-Host -ForegroundColor Green " ...Complete"
}


#Create-StoragePool -CloudSvc "gspcloud01" -vmName "storage01" -Credential $Credential -StoragePoolName "MyStoragePool02" -VirtualDiskName "MyVirtualDisk02" -VolumeLabel "Volume02"

##function local:
##{
##   param(
##   [parameter(Mandatory=$true)][string]$CloudSvc,
##   [parameter(Mandatory=$true)][string]$vmName,
##   [parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential
##   [parameter(Mandatory=$true)][string],
##   [parameter(Mandatory=$true)][string]
##   )
##   #Get the hosted service WinRM Uri
##   [System.Uri]$uris = (Get-VMConnection -ServiceName $CloudSvc -vmName $vmName)
##   if ($uris -eq $null){return}
##
##   Write-Host "Starting remote session" -NoNewline
##   Invoke-Command -ConnectionUri $URIS.ToString() -Credential $Credential -OutVariable $Result -ErrorVariable $ErrResult -ErrorAction SilentlyContinue `
##   -ArgumentList -ScriptBlock { 
##   Param()
##
##      Write-Host -ForegroundColor Green " ...Started"
##      Set-ExecutionPolicy Unrestricted -Force
##        
##      #Hide green status bar
##      $ProgressPreference = "SilentlyContinue"
##
##      #Save external variables
##      = $using:
##
##      $Result
##      Write-Host "Exiting remote session" -NoNewline
##   }
##   Write-Host -ForegroundColor Green " ...Exited"
##}
##