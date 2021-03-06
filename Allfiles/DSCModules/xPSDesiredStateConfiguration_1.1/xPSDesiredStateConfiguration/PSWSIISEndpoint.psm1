# This module file contains a utility to perform PSWS IIS Endpoint setup
# Module exports New-PSWSEndpoint function to perform the endpoint setup
#
#	Copyright (c) Microsoft Corporation, 2013
#
# Author: Raghu Shantha [RaghuS@Microsoft.com]
# ChangeLog: 7/11/2013 - Providing Dispatch/Port is now optional; Removed taking backup of existing endpoints since this was unnecessary and not performant; Logging only if something fails
#

# Validate supplied configuration to setup the PSWS Endpoint
# Function checks for the existence of PSWS Schema files, IIS config
# Also validate presence of IIS on the target machine
#
function Initialize-Endpoint
{
    param (
        $site,
        $path,
        $cfgfile,
        $port,
        $app,
        $applicationPoolIdentityType,
        $svc,
        $mof,
        $dispatch,        
        $asax,
        $dependentBinaries,
        $language,
        $dependentMUIFiles,
        $psFiles,
        $removeSiteFiles = $false,
        $certificateThumbPrint)
    
    if (!(Test-Path $cfgfile))
    {        
        throw "ERROR: $cfgfile does not exist"    
    }            
    
    if (!(Test-Path $svc))
    {        
        throw "ERROR: $svc does not exist"    
    }            
    
    if (!(Test-Path $mof))
    {        
        throw "ERROR: $mof does not exist"  
    }   	
    
    if (!(Test-Path $asax))
    {        
        throw "ERROR: $asax does not exist"  
    }  

    if ($certificateThumbPrint -ne "AllowUnencryptedTraffic")
    {    
        Write-Verbose "Verify that the certificate with the provided thumbprint exists in CERT:\LocalMachine\MY\"
        $certificate = Get-childItem CERT:\LocalMachine\MY\ | Where {$_.Thumbprint -eq $certificateThumbPrint}
        if (!$Certificate) 
        { 
             throw "ERROR: Certificate with thumbprint $certificateThumbPrint does not exist in CERT:\LocalMachine\MY\"
        }  
    }     
    
    Test-IISInstall
    
    $appPool = "PSWS"
    
    Write-Verbose "Delete the App Pool if it exists"
    Remove-AppPool -apppool $appPool
    
    Write-Verbose "Remove the site if it already exists"
    Update-Site -siteName $site -siteAction Remove
    
    if ($removeSiteFiles)
    {
        if(Test-Path $path)
        {
            Remove-Item -Path $path -Recurse -Force
        }
    }
    
    Copy-Files -path $path -cfgfile $cfgfile -svc $svc -mof $mof -dispatch $dispatch -asax $asax -dependentBinaries $dependentBinaries -language $language -dependentMUIFiles $dependentMUIFiles -psFiles $psFiles
    
    Update-AllSites Stop
    Update-DefaultAppPool Stop
    Update-DefaultAppPool Start
    
    New-IISWebSite -site $site -path $path -port $port -app $app -apppool $appPool -applicationPoolIdentityType $applicationPoolIdentityType -certificateThumbPrint $certificateThumbPrint
}

# Validate if IIS and all required dependencies are installed on the target machine
#
function Test-IISInstall
{
        Write-Verbose "Checking IIS requirements"
        $iisVersion = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\InetStp -ErrorAction silentlycontinue).MajorVersion + (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\InetStp -ErrorAction silentlycontinue).MinorVersion
        
        if ($iisVersion -lt 7.0) 
        {
            throw "ERROR: IIS Version detected is $iisVersion , must be running higher than 7.0"            
        }        
        
        $wsRegKey = (Get-ItemProperty hklm:\SYSTEM\CurrentControlSet\Services\W3SVC -ErrorAction silentlycontinue).ImagePath
        if ($wsRegKey -eq $null)
        {
            throw "ERROR: Cannot retrive W3SVC key. IIS Web Services may not be installed"            
        }        
        
        if ((Get-Service w3svc).Status -ne "running")
        {
            throw "ERROR: service W3SVC is not running"
        }
}

# Verify if a given IIS Site exists
#
function Test-IISSiteExists
{
    param ($siteName)

    if (Get-Website -Name $siteName)
    {
        return $true
    }
    
    return $false
}

# Perform an action (such as stop, start, delete) for a given IIS Site
#
function Update-Site
{
    param (
        [Parameter(ParameterSetName = 'SiteName', Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [String]$siteName,

        [Parameter(ParameterSetName = 'Site', Mandatory, Position = 0)]        
        $site,

        [Parameter(ParameterSetName = 'SiteName', Mandatory, Position = 1)]
        [Parameter(ParameterSetName = 'Site', Mandatory, Position = 1)]
        [String]$siteAction)
    
    [String]$name = $null
    if ($PSCmdlet.ParameterSetName -eq 'SiteName')
    {
        $name = $siteName
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Site')
    {   
        $name = $site.Name
    }
    
    if (Test-IISSiteExists $name)
    {        
        switch ($siteAction) 
        { 
            "Start"  {Start-Website -Name $name} 
            "Stop"   {Stop-Website -Name $name -ErrorAction SilentlyContinue} 
            "Remove" {Remove-Website -Name $name}
        }
    }
}

# Delete the given IIS Application Pool
# This is required to cleanup any existing conflicting apppools before setting up the endpoint
#
function Remove-AppPool
{
    param ($appPool)    
    
    Remove-WebAppPool -Name $appPool -ErrorAction SilentlyContinue
}

# Perform given action(start, stop, delete) on all IIS Sites
#
function Update-AllSites
{
    param ($action)    
    
    foreach ($site in Get-Website)
    {
        Update-Site $site $action
    }
}

# Perform given action(start, stop) on the default app pool
#
function Update-DefaultAppPool
{
    param ($action) 
    
    switch ($action) 
    { 
        "Start"  {Start-WebAppPool -Name "DefaultAppPool"} 
        "Stop"   {Stop-WebAppPool -Name "DefaultAppPool"} 
        "Remove" {Remove-WebAppPool -Name "DefaultAppPool"}
    }
}

# Generate an IIS Site Id while setting up the endpoint
# The Site Id will be the max available in IIS config + 1
#
function New-SiteID
{
    return ((Get-Website | % { $_.Id } | Measure-Object -Maximum).Maximum + 1)
}

# Validate the PSWS config files supplied and copy to the IIS endpoint in inetpub
#
function Copy-Files
{
    param (
        $path,
        $cfgfile,
        $svc,
        $mof,    
        $dispatch,
        $asax,
        $dependentBinaries,
        $language,
        $dependentMUIFiles,
        $psFiles)    
    
    if (!(Test-Path $cfgfile))
    {
        throw "ERROR: $cfgfile does not exist"    
    }
    
    if (!(Test-Path $svc))
    {
        throw "ERROR: $svc does not exist"    
    }
    
    if (!(Test-Path $mof))
    {
        throw "ERROR: $mof does not exist"    
    }

    if (!(Test-Path $asax))
    {
        throw "ERROR: $asax does not exist"    
    }
    
    if (!(Test-Path $path))
    {
        $null = New-Item -ItemType container -Path $path        
    }
    
    foreach ($dependentBinary in $dependentBinaries)
    {
        if (!(Test-Path $dependentBinary))
        {					
            throw "ERROR: $dependentBinary does not exist"  
        } 	
    }

    foreach ($dependentMUIFile in $dependentMUIFiles)
    {
        if (!(Test-Path $dependentMUIFile))
        {					
            throw "ERROR: $dependentMUIFile does not exist"  
        } 	
    }
    
    Write-Verbose "Create the bin folder for deploying custom dependent binaries required by the endpoint"
    $binFolderPath = Join-Path $path "bin"
    $null = New-Item -path $binFolderPath  -itemType "directory" -Force
    Copy-Item $dependentBinaries $binFolderPath -Force
    
    if ($language)
    {
        $muiPath = Join-Path $binFolderPath $language

        if (!(Test-Path $muiPath))
        {
            $null = New-Item -ItemType container $muiPath        
        }
        Copy-Item $dependentMUIFiles $muiPath -Force
    }
    
    foreach ($psFile in $psFiles)
    {
        if (!(Test-Path $psFile))
        {					
            throw "ERROR: $psFile does not exist"  
        } 	
        
        Copy-Item $psFile $path -Force
    }		
    
    Copy-Item $cfgfile (Join-Path $path "web.config") -Force
    Copy-Item $svc $path -Force
    Copy-Item $mof $path -Force
    
    if ($dispatch)
    {
        Copy-Item $dispatch $path -Force
    }  
    
    if ($asax)
    {
        Copy-Item $asax $path -Force
    }
}

# Setup IIS Apppool, Site and Application
#
function New-IISWebSite
{
    param (
        $site,
        $path,    
        $port,
        $app,
        $appPool,        
        $applicationPoolIdentityType,
        $certificateThumbPrint)    
    
    $siteID = New-SiteID
    
    Write-Verbose "Adding App Pool"
    $null = New-WebAppPool -Name $appPool

    Write-Verbose "Set App Pool Properties"
    $appPoolIdentity = 4
    if ($applicationPoolIdentityType)
    {   
        # LocalSystem = 0, LocalService = 1, NetworkService = 2, SpecificUser = 3, ApplicationPoolIdentity = 4        
        if ($applicationPoolIdentityType -eq "LocalSystem")
        {
            $appPoolIdentity = 0
        }
        elseif ($applicationPoolIdentityType -eq "LocalService")
        {
            $appPoolIdentity = 1
        }      
        elseif ($applicationPoolIdentityType -eq "NetworkService")
        {
            $appPoolIdentity = 2
        }        
    } 

    $appPoolItem = Get-Item IIS:\AppPools\$appPool
    $appPoolItem.managedRuntimeVersion = "v4.0"
    $appPoolItem.enable32BitAppOnWin64 = $true
    $appPoolItem.processModel.identityType = $appPoolIdentity
    $appPoolItem | Set-Item
    
    Write-Verbose "Add and Set Site Properties"
    if ($certificateThumbPrint -eq "AllowUnencryptedTraffic")
    {
        $webSite = New-WebSite -Name $site -Id $siteID -Port $port -IPAddress "*" -PhysicalPath $path -ApplicationPool $appPool
    }
    else
    {
        $webSite = New-WebSite -Name $site -Id $siteID -Port $port -IPAddress "*" -PhysicalPath $path -ApplicationPool $appPool -Ssl

        # Remove existing binding for $port
        Remove-Item IIS:\SSLBindings\0.0.0.0!$port -ErrorAction Ignore

        # Create a new binding using the supplied certificate
        $null = Get-Item CERT:\LocalMachine\MY\$certificateThumbPrint | New-Item IIS:\SSLBindings\0.0.0.0!$port
    }
        
    Write-Verbose "Delete application"
    Remove-WebApplication -Name $app -Site $site -ErrorAction SilentlyContinue
    
    Write-Verbose "Add and Set Application Properties"
    $null = New-WebApplication -Name $app -Site $site -PhysicalPath $path -ApplicationPool $appPool
    
    Update-Site -siteName $site -siteAction Start    
}

# Allow Clients outsite the machine to access the setup endpoint on a User Port
#
function New-FirewallRule
{
    param ($firewallPort)
    
    Write-Verbose "Disable Inbound Firewall Notification"
    Set-NetFirewallProfile -Profile Domain,Public,Private –NotifyOnListen False
    
    Write-Verbose "Add Firewall Rule for port $firewallPort"    
    $null = New-NetFirewallRule -DisplayName "Allow Port $firewallPort for PSWS" -Direction Inbound -LocalPort $firewallPort -Protocol TCP -Action Allow
}

# Enable & Clear PSWS Operational/Analytic/Debug ETW Channels
#
function Enable-PSWSETW
{    
    # Disable Analytic Log
    & $script:wevtutil sl Microsoft-Windows-ManagementOdataService/Analytic /e:false /q | Out-Null    

    # Disable Debug Log
    & $script:wevtutil sl Microsoft-Windows-ManagementOdataService/Debug /e:false /q | Out-Null    

    # Clear Operational Log
    & $script:wevtutil cl Microsoft-Windows-ManagementOdataService/Operational | Out-Null    

    # Enable/Clear Analytic Log
    & $script:wevtutil sl Microsoft-Windows-ManagementOdataService/Analytic /e:true /q | Out-Null    

    # Enable/Clear Debug Log
    & $script:wevtutil sl Microsoft-Windows-ManagementOdataService/Debug /e:true /q | Out-Null    
}

<#
.Synopsis
   Create PowerShell WebServices IIS Endpoint
.DESCRIPTION
   Creates a PSWS IIS Endpoint by consuming PSWS Schema and related dependent files
.EXAMPLE
   New a PSWS Endpoint [@ http://Server:39689/PSWS_Win32Process] by consuming PSWS Schema Files and any dependent scripts/binaries
   New-PSWSEndpoint -site Win32Process -path $env:HOMEDRIVE\inetpub\wwwroot\PSWS_Win32Process -cfgfile Win32Process.config -port 39689 -app Win32Process -svc PSWS.svc -mof Win32Process.mof -dispatch Win32Process.xml -dependentBinaries ConfigureProcess.ps1, Rbac.dll -psFiles Win32Process.psm1
#>
function New-PSWSEndpoint
{
[CmdletBinding()]
    param (
        
        # Unique Name of the IIS Site        
        [String] $site = "PSWS",
        
        # Physical path for the IIS Endpoint on the machine (under inetpub/wwwroot)        
        [String] $path = "$env:HOMEDRIVE\inetpub\wwwroot\PSWS",
        
        # Web.config file        
        [String] $cfgfile = "web.config",
        
        # Port # for the IIS Endpoint        
        [Int] $port = 8080,
        
        # IIS Application Name for the Site        
        [String] $app = "PSWS",
        
        # IIS App Pool Identity Type - must be one of LocalService, LocalSystem, NetworkService, ApplicationPoolIdentity		
        [ValidateSet('LocalService', 'LocalSystem', 'NetworkService', 'ApplicationPoolIdentity')]		
        [String] $applicationPoolIdentityType,
        
        # WCF Service SVC file        
        [String] $svc = "PSWS.svc",
        
        # PSWS Specific MOF Schema File
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $mof,
        
        # PSWS Specific Dispatch Mapping File [Optional]
        [ValidateNotNullOrEmpty()]		
        [String] $dispatch,    
        
        # Global.asax file [Optional]
        [ValidateNotNullOrEmpty()]
        [String] $asax,
        
        # Any dependent binaries that need to be deployed to the IIS endpoint, in the bin folder
        [ValidateNotNullOrEmpty()]
        [String[]] $dependentBinaries,

         # MUI Language [Optional]
        [ValidateNotNullOrEmpty()]
        [String] $language,

        # Any dependent binaries that need to be deployed to the IIS endpoint, in the bin\mui folder [Optional]
        [ValidateNotNullOrEmpty()]
        [String[]] $dependentMUIFiles,
        
        # Any dependent PowerShell Scipts/Modules that need to be deployed to the IIS endpoint application root
        [ValidateNotNullOrEmpty()]
        [String[]] $psFiles,
        
        # True to remove all files for the site at first, false otherwise
        [Boolean]$removeSiteFiles = $false,

        # Enable Firewall Exception for the supplied port        
        [Boolean] $EnableFirewallException,

        # Enable and Clear PSWS ETW        
        [switch] $EnablePSWSETW,
        
        # Thumbprint of the Certificate in CERT:\LocalMachine\MY\ for Pull Server
        [String] $certificateThumbPrint = "AllowUnencryptedTraffic")
    
    $script:wevtutil = "$env:windir\system32\Wevtutil.exe"
       
    $svcName = Split-Path $svc -Leaf
    $protocol = "https:"
    if ($certificateThumbPrint -eq "AllowUnencryptedTraffic")
    {
        $protocol = "http:"
    }

    # Get Machine Name and Domain
    $cimInstance = Get-CimInstance -ClassName Win32_ComputerSystem
    
    Write-Verbose ("SETTING UP ENDPOINT at - $protocol//" + $cimInstance.Name + "." + $cimInstance.Domain + ":" + $port + "/" + $site + "/" + $svcName)
    Initialize-Endpoint -site $site -path $path -cfgfile $cfgfile -port $port -app $app `
                        -applicationPoolIdentityType $applicationPoolIdentityType -svc $svc -mof $mof `
                        -dispatch $dispatch -asax $asax -dependentBinaries $dependentBinaries `
                        -language $language -dependentMUIFiles $dependentMUIFiles -psFiles $psFiles `
                        -removeSiteFiles $removeSiteFiles -certificateThumbPrint $certificateThumbPrint
    
    if ($EnableFirewallException -eq $true)
    {
        Write-Verbose "Enabling firewall exception for port $port"
        $null = New-FirewallRule $port
    }

    if ($EnablePSWSETW)
    {
        Enable-PSWSETW
    }
    
    Update-AllSites start
    
}

<#
.Synopsis
   Set the option into the web.config for an endpoint
.DESCRIPTION
   Set the options into the web.config for an endpoint allowing customization.
.EXAMPLE
#>
function Set-AppSettingsInWebconfig
{
    param (
                
        # Physical path for the IIS Endpoint on the machine (possibly under inetpub/wwwroot)
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $path,
        
        # Key to add/update
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $key,

        # Value 
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $value

        )
                
    $webconfig = Join-Path $path "web.config"
    [bool] $Found = $false

    if (Test-Path $webconfig)
    {
        $xml = [xml](get-content $webconfig)
        $root = $xml.get_DocumentElement() 

        foreach( $item in $root.appSettings.add) 
        { 
            if( $item.key -eq $key ) 
            { 
                $item.value = $value; 
                $Found = $true;
            } 
        }

        if( -not $Found)
        {
            $newElement = $xml.CreateElement("add")                               
            $nameAtt1 = $xml.CreateAttribute("key")                    
            $nameAtt1.psbase.value = $key;                                
            $null = $newElement.SetAttributeNode($nameAtt1)
                                   
            $nameAtt2 = $xml.CreateAttribute("value")                      
            $nameAtt2.psbase.value = $value;                       
            $null = $newElement.SetAttributeNode($nameAtt2)       
                                   
            $null = $xml.configuration["appSettings"].AppendChild($newElement)   
        }
    }

    $xml.Save($webconfig) 
}

Export-ModuleMember -function New-PSWSEndpoint, Set-AppSettingsInWebconfig















# SIG # Begin signature block
# MIIavQYJKoZIhvcNAQcCoIIarjCCGqoCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUAwIpjq6twoWeoF0hGhfdsgo5
# OoOgghWCMIIEwzCCA6ugAwIBAgITMwAAAEyh6E3MtHR7OwAAAAAATDANBgkqhkiG
# 9w0BAQUFADB3MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSEw
# HwYDVQQDExhNaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EwHhcNMTMxMTExMjIxMTMx
# WhcNMTUwMjExMjIxMTMxWjCBszELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjENMAsGA1UECxMETU9QUjEnMCUGA1UECxMebkNpcGhlciBEU0UgRVNO
# OkMwRjQtMzA4Ni1ERUY4MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBT
# ZXJ2aWNlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsdj6GwYrd6jk
# lF18D+Z6ppLuilQdpPmEdYWXzMtcltDXdS3ZCPtb0u4tJcY3PvWrfhpT5Ve+a+i/
# ypYK3EbxWh4+AtKy4CaOAGR7vjyT+FgyeYfSGl0jvJxRxA8Q+gRYtRZ2buy8xuW+
# /K2swUHbqs559RyymUGneiUr/6t4DVg6sV5Q3mRM4MoVKt+m6f6kZi9bEAkJJiHU
# Pw0vbdL4d5ADbN4UEqWM5zYf9IelsEEXb+NNdGbC/aJxRjVRzGsXUWP6FZSSml9L
# KLrmFkVJ6Sy1/ouHr/ylbUPcpjD6KSjvmw0sXIPeEo1qtNtx71wUWiojKP+BcFfx
# jAeaE9gqUwIDAQABo4IBCTCCAQUwHQYDVR0OBBYEFLkNrbNN9NqfGrInJlUNIETY
# mOL0MB8GA1UdIwQYMBaAFCM0+NlSRnAK7UD7dvuzK7DDNbMPMFQGA1UdHwRNMEsw
# SaBHoEWGQ2h0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3Rz
# L01pY3Jvc29mdFRpbWVTdGFtcFBDQS5jcmwwWAYIKwYBBQUHAQEETDBKMEgGCCsG
# AQUFBzAChjxodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY3Jv
# c29mdFRpbWVTdGFtcFBDQS5jcnQwEwYDVR0lBAwwCgYIKwYBBQUHAwgwDQYJKoZI
# hvcNAQEFBQADggEBAAmKTgav6O2Czx0HftcqpyQLLa+aWyR/lHEMVYgkGlIVY+KQ
# TQVKmEqc++GnbWhVgrkp6mmpstXjDNrR1nolN3hnHAz72ylaGpc4KjlWRvs1gbnk
# PUZajuT8dTdYWUmLTts8FZ1zUkvreww6wi3Bs5tSLeA1xbnBV7PoPaE8RPIjFh4K
# qlk3J9CVUl6ofz9U8IHh3Jq9ZdV49vdMObvd4NY3DpGah4xz53FkUvc+A9jGzXK4
# NDSYW4zT9Qim63jGUaANDm/0azxAGmAWLKkGUp0cE5DObwIe6nucs/b4l2DyZdHR
# H4c6wXXwQo167Yxysnv7LIq0kUdU4i5pzBZUGlkwggTsMIID1KADAgECAhMzAAAA
# ymzVMhI1xOFVAAEAAADKMA0GCSqGSIb3DQEBBQUAMHkxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xIzAhBgNVBAMTGk1pY3Jvc29mdCBDb2RlIFNp
# Z25pbmcgUENBMB4XDTE0MDQyMjE3MzkwMFoXDTE1MDcyMjE3MzkwMFowgYMxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xDTALBgNVBAsTBE1PUFIx
# HjAcBgNVBAMTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjCCASIwDQYJKoZIhvcNAQEB
# BQADggEPADCCAQoCggEBAJZxXe0GRvqEy51bt0bHsOG0ETkDrbEVc2Cc66e2bho8
# P/9l4zTxpqUhXlaZbFjkkqEKXMLT3FIvDGWaIGFAUzGcbI8hfbr5/hNQUmCVOlu5
# WKV0YUGplOCtJk5MoZdwSSdefGfKTx5xhEa8HUu24g/FxifJB+Z6CqUXABlMcEU4
# LYG0UKrFZ9H6ebzFzKFym/QlNJj4VN8SOTgSL6RrpZp+x2LR3M/tPTT4ud81MLrs
# eTKp4amsVU1Mf0xWwxMLdvEH+cxHrPuI1VKlHij6PS3Pz4SYhnFlEc+FyQlEhuFv
# 57H8rEBEpamLIz+CSZ3VlllQE1kYc/9DDK0r1H8wQGcCAwEAAaOCAWAwggFcMBMG
# A1UdJQQMMAoGCCsGAQUFBwMDMB0GA1UdDgQWBBQfXuJdUI1Whr5KPM8E6KeHtcu/
# gzBRBgNVHREESjBIpEYwRDENMAsGA1UECxMETU9QUjEzMDEGA1UEBRMqMzE1OTUr
# YjQyMThmMTMtNmZjYS00OTBmLTljNDctM2ZjNTU3ZGZjNDQwMB8GA1UdIwQYMBaA
# FMsR6MrStBZYAck3LjMWFrlMmgofMFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9j
# cmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY0NvZFNpZ1BDQV8w
# OC0zMS0yMDEwLmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljQ29kU2lnUENBXzA4LTMx
# LTIwMTAuY3J0MA0GCSqGSIb3DQEBBQUAA4IBAQB3XOvXkT3NvXuD2YWpsEOdc3wX
# yQ/tNtvHtSwbXvtUBTqDcUCBCaK3cSZe1n22bDvJql9dAxgqHSd+B+nFZR+1zw23
# VMcoOFqI53vBGbZWMrrizMuT269uD11E9dSw7xvVTsGvDu8gm/Lh/idd6MX/YfYZ
# 0igKIp3fzXCCnhhy2CPMeixD7v/qwODmHaqelzMAUm8HuNOIbN6kBjWnwlOGZRF3
# CY81WbnYhqgA/vgxfSz0jAWdwMHVd3Js6U1ZJoPxwrKIV5M1AHxQK7xZ/P4cKTiC
# 095Sl0UpGE6WW526Xxuj8SdQ6geV6G00DThX3DcoNZU6OJzU7WqFXQ4iEV57MIIF
# vDCCA6SgAwIBAgIKYTMmGgAAAAAAMTANBgkqhkiG9w0BAQUFADBfMRMwEQYKCZIm
# iZPyLGQBGRYDY29tMRkwFwYKCZImiZPyLGQBGRYJbWljcm9zb2Z0MS0wKwYDVQQD
# EyRNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkwHhcNMTAwODMx
# MjIxOTMyWhcNMjAwODMxMjIyOTMyWjB5MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSMwIQYDVQQDExpNaWNyb3NvZnQgQ29kZSBTaWduaW5nIFBD
# QTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALJyWVwZMGS/HZpgICBC
# mXZTbD4b1m/My/Hqa/6XFhDg3zp0gxq3L6Ay7P/ewkJOI9VyANs1VwqJyq4gSfTw
# aKxNS42lvXlLcZtHB9r9Jd+ddYjPqnNEf9eB2/O98jakyVxF3K+tPeAoaJcap6Vy
# c1bxF5Tk/TWUcqDWdl8ed0WDhTgW0HNbBbpnUo2lsmkv2hkL/pJ0KeJ2L1TdFDBZ
# +NKNYv3LyV9GMVC5JxPkQDDPcikQKCLHN049oDI9kM2hOAaFXE5WgigqBTK3S9dP
# Y+fSLWLxRT3nrAgA9kahntFbjCZT6HqqSvJGzzc8OJ60d1ylF56NyxGPVjzBrAlf
# A9MCAwEAAaOCAV4wggFaMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFMsR6MrS
# tBZYAck3LjMWFrlMmgofMAsGA1UdDwQEAwIBhjASBgkrBgEEAYI3FQEEBQIDAQAB
# MCMGCSsGAQQBgjcVAgQWBBT90TFO0yaKleGYYDuoMW+mPLzYLTAZBgkrBgEEAYI3
# FAIEDB4KAFMAdQBiAEMAQTAfBgNVHSMEGDAWgBQOrIJgQFYnl+UlE/wq4QpTlVnk
# pDBQBgNVHR8ESTBHMEWgQ6BBhj9odHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtp
# L2NybC9wcm9kdWN0cy9taWNyb3NvZnRyb290Y2VydC5jcmwwVAYIKwYBBQUHAQEE
# SDBGMEQGCCsGAQUFBzAChjhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2Nl
# cnRzL01pY3Jvc29mdFJvb3RDZXJ0LmNydDANBgkqhkiG9w0BAQUFAAOCAgEAWTk+
# fyZGr+tvQLEytWrrDi9uqEn361917Uw7LddDrQv+y+ktMaMjzHxQmIAhXaw9L0y6
# oqhWnONwu7i0+Hm1SXL3PupBf8rhDBdpy6WcIC36C1DEVs0t40rSvHDnqA2iA6VW
# 4LiKS1fylUKc8fPv7uOGHzQ8uFaa8FMjhSqkghyT4pQHHfLiTviMocroE6WRTsgb
# 0o9ylSpxbZsa+BzwU9ZnzCL/XB3Nooy9J7J5Y1ZEolHN+emjWFbdmwJFRC9f9Nqu
# 1IIybvyklRPk62nnqaIsvsgrEA5ljpnb9aL6EiYJZTiU8XofSrvR4Vbo0HiWGFzJ
# NRZf3ZMdSY4tvq00RBzuEBUaAF3dNVshzpjHCe6FDoxPbQ4TTj18KUicctHzbMrB
# 7HCjV5JXfZSNoBtIA1r3z6NnCnSlNu0tLxfI5nI3EvRvsTxngvlSso0zFmUeDord
# EN5k9G/ORtTTF+l5xAS00/ss3x+KnqwK+xMnQK3k+eGpf0a7B2BHZWBATrBC7E7t
# s3Z52Ao0CW0cgDEf4g5U3eWh++VHEK1kmP9QFi58vwUheuKVQSdpw5OPlcmN2Jsh
# rg1cnPCiroZogwxqLbt2awAdlq3yFnv2FoMkuYjPaqhHMS+a3ONxPdcAfmJH0c6I
# ybgY+g5yjcGjPa8CQGr/aZuW4hCoELQ3UAjWwz0wggYHMIID76ADAgECAgphFmg0
# AAAAAAAcMA0GCSqGSIb3DQEBBQUAMF8xEzARBgoJkiaJk/IsZAEZFgNjb20xGTAX
# BgoJkiaJk/IsZAEZFgltaWNyb3NvZnQxLTArBgNVBAMTJE1pY3Jvc29mdCBSb290
# IENlcnRpZmljYXRlIEF1dGhvcml0eTAeFw0wNzA0MDMxMjUzMDlaFw0yMTA0MDMx
# MzAzMDlaMHcxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xITAf
# BgNVBAMTGE1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQTCCASIwDQYJKoZIhvcNAQEB
# BQADggEPADCCAQoCggEBAJ+hbLHf20iSKnxrLhnhveLjxZlRI1Ctzt0YTiQP7tGn
# 0UytdDAgEesH1VSVFUmUG0KSrphcMCbaAGvoe73siQcP9w4EmPCJzB/LMySHnfL0
# Zxws/HvniB3q506jocEjU8qN+kXPCdBer9CwQgSi+aZsk2fXKNxGU7CG0OUoRi4n
# rIZPVVIM5AMs+2qQkDBuh/NZMJ36ftaXs+ghl3740hPzCLdTbVK0RZCfSABKR2YR
# JylmqJfk0waBSqL5hKcRRxQJgp+E7VV4/gGaHVAIhQAQMEbtt94jRrvELVSfrx54
# QTF3zJvfO4OToWECtR0Nsfz3m7IBziJLVP/5BcPCIAsCAwEAAaOCAaswggGnMA8G
# A1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFCM0+NlSRnAK7UD7dvuzK7DDNbMPMAsG
# A1UdDwQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADCBmAYDVR0jBIGQMIGNgBQOrIJg
# QFYnl+UlE/wq4QpTlVnkpKFjpGEwXzETMBEGCgmSJomT8ixkARkWA2NvbTEZMBcG
# CgmSJomT8ixkARkWCW1pY3Jvc29mdDEtMCsGA1UEAxMkTWljcm9zb2Z0IFJvb3Qg
# Q2VydGlmaWNhdGUgQXV0aG9yaXR5ghB5rRahSqClrUxzWPQHEy5lMFAGA1UdHwRJ
# MEcwRaBDoEGGP2h0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1
# Y3RzL21pY3Jvc29mdHJvb3RjZXJ0LmNybDBUBggrBgEFBQcBAQRIMEYwRAYIKwYB
# BQUHMAKGOGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljcm9z
# b2Z0Um9vdENlcnQuY3J0MBMGA1UdJQQMMAoGCCsGAQUFBwMIMA0GCSqGSIb3DQEB
# BQUAA4ICAQAQl4rDXANENt3ptK132855UU0BsS50cVttDBOrzr57j7gu1BKijG1i
# uFcCy04gE1CZ3XpA4le7r1iaHOEdAYasu3jyi9DsOwHu4r6PCgXIjUji8FMV3U+r
# kuTnjWrVgMHmlPIGL4UD6ZEqJCJw+/b85HiZLg33B+JwvBhOnY5rCnKVuKE5nGct
# xVEO6mJcPxaYiyA/4gcaMvnMMUp2MT0rcgvI6nA9/4UKE9/CCmGO8Ne4F+tOi3/F
# NSteo7/rvH0LQnvUU3Ih7jDKu3hlXFsBFwoUDtLaFJj1PLlmWLMtL+f5hYbMUVbo
# nXCUbKw5TNT2eb+qGHpiKe+imyk0BncaYsk9Hm0fgvALxyy7z0Oz5fnsfbXjpKh0
# NbhOxXEjEiZ2CzxSjHFaRkMUvLOzsE1nyJ9C/4B5IYCeFTBm6EISXhrIniIh0EPp
# K+m79EjMLNTYMoBMJipIJF9a6lbvpt6Znco6b72BJ3QGEe52Ib+bgsEnVLaxaj2J
# oXZhtG6hE6a/qkfwEm/9ijJssv7fUciMI8lmvZ0dhxJkAj0tr1mPuOQh5bWwymO0
# eFQF1EEuUKyUsKV4q7OglnUa2ZKHE3UiLzKoCG6gW4wlv6DvhMoh1useT8ma7kng
# 9wFlb4kLfchpyOZu6qeXzjEp/w7FW1zYTRuh2Povnj8uVRZryROj/TGCBKUwggSh
# AgEBMIGQMHkxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xIzAh
# BgNVBAMTGk1pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBAhMzAAAAymzVMhI1xOFV
# AAEAAADKMAkGBSsOAwIaBQCggb4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQw
# HAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFJNc
# pnA7yYSHNnj4OFqf3hsWy4vIMF4GCisGAQQBgjcCAQwxUDBOoCaAJABNAGkAYwBy
# AG8AcwBvAGYAdAAgAEwAZQBhAHIAbgBpAG4AZ6EkgCJodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vbGVhcm5pbmcgMA0GCSqGSIb3DQEBAQUABIIBACAWm1L2ysNYpuw/
# nbOm5lm5PKLjDzghrklY4WB/OrtcgrrOQ05q9R+YWcfZWda4u2dte8C5iwUy2yXj
# N2wPkjmJKXn6Xr+oFoyd90QCqd2Txg+pZpmrJ8RGy16o0mluftnvwp0vvCwumJEh
# UCy2/eM4NSO/rnN4hnco085A7As76mKpGf7VwZspvLPYbI0QByRNWcq4tV8bY2Vq
# 2HROpg8V2kU3ZxhhMyOZhKxcJGBMpqUW93qhb8AKK+oyygeOUku78RTBkZAaG5NV
# YsgkcISEpnbYwUm1qSVpi6QOzZLw7XxMZGLnFpVe46KZIJndzsN28r6Irz6MiBcU
# iUdbGGihggIoMIICJAYJKoZIhvcNAQkGMYICFTCCAhECAQEwgY4wdzELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEhMB8GA1UEAxMYTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgUENBAhMzAAAATKHoTcy0dHs7AAAAAABMMAkGBSsOAwIaBQCg
# XTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0xNDA3
# MjgwODAyMTZaMCMGCSqGSIb3DQEJBDEWBBSfscews0myocvobb1GnFpVhOrnbzAN
# BgkqhkiG9w0BAQUFAASCAQCsl/uRuE57srgvRJU4i0gWlU8/8Wo9uy2fWARCCQKW
# qkAOAy6Rl0wftq/dlUY/bb5ENOefM6ex2quHL3ZPBsXsgXJZxmC4kqVwRgLsmJbI
# Q4ELE5CsVIZ9DnldrFRMne2WqQlDrc09GKrJsyw8bQ9mwkm1Ke+XoP7h62v6FyDg
# xH62INL1ZDL6bnVyXUjF+E9E7Gyq4tKzLyjid8kMApdsTN2xWw8sKBDz79cx9Ny4
# TW7TARu5Et/1+83G63UwsudT8RmcWephBcgev+4ovd4ynxuVW986keHpBzGVFNpP
# NJv/ukdg6AbTMuw4zqmhf9+WGAzDGEF3/8cG5duKJXks
# SIG # End signature block
