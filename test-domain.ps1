
   
   
Function local:Get-Domain
{
	Param([System.Uri]$uris, [System.Management.Automation.PSCredential]$credential)
   
   Write-Host "Starting remote session" -NoNewline
   $result = Invoke-Command -ConnectionUri $uris.ToString() -Credential $credential -ArgumentList $ouName, $Accounts -Scriptblock {
      Param([string]$ouName,$Accounts)

      Write-Host -ForegroundColor Green "... Started"
      Set-ExecutionPolicy Unrestricted -Force
      
      #Hide green status bar
      $ProgressPreference = "SilentlyContinue"

      Write-Host "Loading Active Directory module..." -NoNewline
      Import-Module activedirectory -OutVariable $Result -WarningAction SilentlyContinue -ErrorAction Stop
      Write-Host -ForegroundColor Green "... Complete"
      
      $result = (get-adDomain).dnsRoot
      $result
      Write-Host "Exiting remote session" -NoNewline
   }
   
   Write-Host -ForegroundColor Green "... Complete"
   Write-Host "<$($Result)>";sleep 3
   return $Result
}

Import-Module .\DeploymentFunctions.psm1 -AsCustomObject -Force -DisableNameChecking -Verbose:$false

$dcServiceName = "gspcloud001"
$dcVmName = "dc1"
$domainInstallerUsername = "vaperware\netadmin"
$domainInstallerPassword = "SSimple0"

Test-RMCertificateForVM -serviceName $dcServiceName -vmName $dcVmName

[System.Uri]$uris = (Get-VMConnection -ServiceName $dcServiceName -vmName $dcVmName)
if ($uris -eq $null){return}

$domainCredential = (Set-Credential -Username $domainInstallerUsername -Password $domainInstallerPassword)

Write-Host (get-domain -uris $uris -credential $domainCredential)