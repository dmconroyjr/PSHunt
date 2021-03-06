<#
.SYNOPSIS 
	 
	Survey.ps1 is used to collect comprehensive information on the state of running processes, services, drivers along with additional configuration information relevant
	for discovering malware on a live host. 
	
	Project: PSHunt
	Author: Chris Gerritz (Github @singlethreaded) (Twitter @gerritzc)
	Company: Infocyte, Inc.
	License: Apache License 2.0
	Required Dependencies: PSReflect (@Mattifestation)
	Optional Dependencies: None
		
.DESCRIPTION 

	Survey.ps1 is used to collect comprehensive information on the state of running processes, services, drivers along with additional configuration information relevant
	for discovering malware on a live host.  
	
	Survey.ps1 should be ran with full local administrator privileges with SeDebug right.

	
.EXAMPLE  
 
    Usage: powershell -ExecutionPolicy bypass .\Survey.ps1
	
	Tip: The results (HostObject.xml) output can be imported manually into powershell via the following command:
		$var = Import-cliXML .\SurveyResults.xml
		Import it and manipulate it in dot notation.  Example: $myVariableName.ProcessList | format-table -auto	
		
#>
[CmdletBinding()]
Param(	
	[parameter(	Mandatory=$False)]
	[string]$SurveyOut="SurveyResults.xml",
	   
	[parameter(	Mandatory=$False,
			HelpMessage='Where to send the Survey results. Default=DropToDisk C:\Windows\temp\$SurveyOut.xml')]
	[ValidateSet('DropToDisk', 'HTTPPostback', 'FTPPostback')]	
	[String]$ReturnType = "DropToDisk",

	[parameter(	Mandatory=$False,
			HelpMessage='Where to send the Survey results.  Web or FTP address (i.e. http://www.myserver.com/upload/')]	
	[ValidateScript({ ($_ -eq $Null) -OR ($_ -match "/^(https?:\/\/)?([\da-z\.-]+)\.([a-z\.]{2,6})([\/\w \.-]*)*\/?$/") -OR ($_ -match "/^(ftps?:\/\/)?([\da-z\.-]+)\.([a-z\.]{2,6})([\/\w \.-]*)*\/?$/") })]	
	[String]$ReturnAddress,
	
	[parameter(	Mandatory=$False)]
	[System.Management.Automation.PSCredential]$WebCredentials
	)

#Requires -Version 2

#region Variables
# ====================================================
	$Version = 0.7
	
	#$ScriptPath = split-path -parent $MyInvocation.MyCommand.Definition
	# Find paths regardless of where/how script was run (sync scopes in Powershell and .NET enviroments)
	if ($MyInvocation.MyCommand.Path) {
	
		# If it is run as a script MyCommand.Path is your friend (won't work if run from a console) (if 3.0+ use $PSScriptRoot)
		$ScriptPath = $MyInvocation.MyCommand.Path
		$ScriptDir  = Split-Path -Parent $ScriptPath
		
		# Set .net current working directory to Powershell's working directory(scripts ran as SYSTEM will default to C:\Windows\System32\)
		[Environment]::CurrentDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
	} else {
		# Just drop it in the temp folder
		$ScriptDir  = (Resolve-Path $env:windir\temp).Path
		[Environment]::CurrentDirectory = $ScriptDir
	}
	$OutPath = "$ScriptDir\$SurveyOut"
#endregion Variables

#region Initialization	
# ====================================================
	
	# Supress errors unless debugging
	if ((!$PSBoundParameters['verbose']) -AND (!$PSBoundParameters['debug'])) { 
		$ErrorActionPreference  = "SilentlyContinue"
		$DebugPreference = "SilentlyContinue"
		$ErrorView = "CategoryView"
	} 
	elseif ($PSBoundParameters['debug']) { 
		$ErrorActionPreference  = "Inquire"
		$DebugPreference = "Inquire"
		$ErrorView = "NormalView"
		Set-StrictMode -Version 2.0
	} 
	elseif ($PSBoundParameters['verbose']) { 
		$ErrorActionPreference  = "Continue"
		$DebugPreference = "ContinueSilently"
		$ErrorView = "CategoryView"
	}

	# Test Powershell and .NET versions
	function Local:Test-PSCompatibility {
		# Windows PowerShell 2.0 needs to be installed on Windows Server 2008 and Windows Vista. It is already installed on Windows Server 2008 R2 and Windows 7.
		# In Windows Vista SP2 and Windows Server 2008 SP2 the integrated version of the .NET Framework is version 3.0;   
		# in Windows 7 and Windows Server 2008 R2, the integrated version of the .NET Framework is version 3.5 SP1
		
		# These checks won't work in PS 1.0 but will in 2.0+, so just catch failures to find incompatibility.
		try {
			$VersionCheck = New-Object PSObject -Property @{
				PSVersion 		= $psversiontable.PSVersion.ToString()
				DotNetVersion 	= gci 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP' | sort pschildname -Descending | select -First 1 -ExpandProperty pschildname
			}
			
			Write-Verbose "Powershell version: $VersionCheck.PSVersion"
			Write-Verbose "DotNet Version: $VersionCheck.DotNetVersion"
			return $VersionCheck
		} catch {
			Write-Warning "Must have Powershell 2.0 or higher"
			"ERROR: Script not compatible with Powershell 1.0" >> SurveyLog.txt
			del $ScriptPath
			#have to do this or it freezes:
			[System.Diagnostics.Process]::GetCurrentProcess().Kill()
		}									
	}

	$Null = Test-PSCompatibility
	
	# Initialize Crypto
	try { $MD5CryptoProvider = new-object -TypeName system.security.cryptography.MD5CryptoServiceProvider } catch { $MD5CryptoProvider = $null }
	try { $SHA1CryptoProvider = new-object -TypeName system.security.cryptography.SHA1CryptoServiceProvider } catch { $SHA1CryptoProvider = $null }
	try { $SHA256CryptoProvider = new-object -TypeName system.security.cryptography.SHA256CryptoServiceProvider } catch { $SHA256CryptoProvider = $null }
	
	$Global:CryptoProvider = New-Object PSObject -Property @{
		MD5CryptoProvider = $MD5CryptoProvider
		SHA1CryptoProvider = $SHA1CryptoProvider
		SHA256CryptoProvider = $SHA256CryptoProvider
	}

#endregion Initialization

#region Collector Functions 
# ====================================================


function Get-Processes {
	Write-Verbose "Getting ProcessList"
	
	# Get Processes 
	$processes = Get-WmiObject -Class Win32_Process
	
	$processList = @()	
	foreach ($process in $processes) {
        # WMI has CommandLine and ParentID, but no module references or product info - so will need both
		$Modules = get-process -Id ($process.ProcessId) -Module
		
		try {
			$Owner = $process.GetOwner().Domain.ToString() + "\"+ $process.GetOwner().User.ToString()
            $OwnerSID = $process.GetOwnerSid().Sid
		} catch {
			Write-Warning "Owner could not be determined for $($process.Caption) (PID $($process.ProcessId))" 
		}
		
        $thisProcess = New-Object PSObject -Property @{
			ProcessId			= [int]$process.ProcessId
			ParentProcessId		= [int]$process.ParentProcessId
			ParentProcessName 	= ($processes | where { $_.ProcessID -eq $process.ParentProcessId}).Caption
			SessionId			= [int]$process.SessionId
			Name				= $process.Caption
			Owner 				= $Owner
            OwnerSID            = $OwnerSID 
			PathName			= $process.ExecutablePath
			CommandLine			= $process.CommandLine
			CreationDate 		= $process.ConvertToDateTime($process.CreationDate)
			ModuleList 			= @()
		}
		
		if ($process.ExecutablePath) {
			# Get hashes and verify Signatures with Sigcheck
			$Signature = Invoke-Sigcheck $process.ExecutablePath -GetHashes | Select -ExcludeProperty Path
			$Signature.PSObject.Properties | Foreach-Object {
				$thisProcess | Add-Member -type NoteProperty -Name $_.Name -Value $_.Value -ea 0
			}
		}
		
		# Add Modules		
		foreach($module in $Modules) {
			if ($module.ModuleName -notlike "*.exe") { 
				$thisProcess.ModuleList += $module.ModuleName
			}
		}
		
		$processList += $thisProcess 
	}
	return $processList
}

# You are being soooo slow.  TODO: Change to only query WorkingSet (sure I'll miss paged stuff but if there is an active cnx, that prob won't happen... I think)
function Get-MemoryInjects {
<#
.SYNOPSIS

Grab memory regions indicative of Injected DLLs (Reflective DLL Injection, Process Overwrite, etc.)
Check for MZ headers and print all printable strings.

Author: Chris Gerritz(@singlethreaded)
Pulled Liberally from: Matthew Graeber (@mattifestation)
License: BSD 3-Clause
Required Dependencies: PSReflect module
                       Get-ProcessMemoryInfo
Optional Dependencies: 

.DESCRIPTION

Get-MemoryInjects reads every committed executable memory allocation and
checks for MZ headers, returns all printable strings. 

.PARAMETER ProcessID

Specifies the process ID.

.EXAMPLE

Get-Process | Get-MemoryInjects

.EXAMPLE

Get-Process cmd | Get-MemoryInjects
#>

    [CmdletBinding()] Param (
        [Parameter(Position = 0, Mandatory = $True, ValueFromPipelineByPropertyName = $True)]
        [Alias('Id')]
        [ValidateScript({Get-Process -Id $_})]
        [Int32]
        $ProcessID
    )

    BEGIN {
        $Mod = New-InMemoryModule -ModuleName MemoryInjects

        $FunctionDefinitions = @(
		    (func kernel32 GetLastError ([Int32]) @()),
            (func kernel32 GetModuleHandle ([Intptr]) @([String]) -SetLastError),
            (func kernel32 OpenProcess ([IntPtr]) @([UInt32], [Bool], [UInt32]) -SetLastError),
            (func kernel32 ReadProcessMemory ([Bool]) @([IntPtr], [IntPtr], [Byte[]], [Int], [Int].MakeByRefType()) -SetLastError),
            (func kernel32 CloseHandle ([Bool]) @([IntPtr]) -SetLastError),
            (func kernel32 K32GetModuleFileNameEx ([Int]) @([Int], [IntPtr], [Text.StringBuilder], [Int]) -SetLastError),
			(func psapi GetModuleFileNameEx ([Int]) @([Int], [IntPtr], [Text.StringBuilder], [Int]) -SetLastError)
        )

        $Types = $FunctionDefinitions | Add-Win32Type -Module $Mod -Namespace 'Win32MemoryInjects'
        $Kernel32 = $Types['kernel32']
		$Psapi = $Types['psapi']
		$Memory = @()
		
		#$SmallestSize = 4096 # This is taking too long...
		$SmallestSize = 16384 
    }
    
    PROCESS {
		# PROCESS_VM_READ (0x00000010) | PROCESS_QUERY_INFORMATION (0x00000400)
        $hProcess = $Kernel32::OpenProcess(0x410, $False, $ProcessID) # PROCESS_VM_READ (0x00000010)
		$ProcessName = (Get-Process -Id $ProcessId).Name
        $ProcessMemory = Get-ProcessMemoryInfo -ProcessID $ProcessID | where { 
			($_.State -eq 'MEM_COMMIT') -AND 
			($_.Type -eq "MEM_PRIVATE") -AND # When they use VirtualAlloc(Ex), Private memory is allocated. (fragmentation makes heap allocations hard to use for injection so we don't see it)
			($_.RegionSize -gt $SmallestSize) -AND # Lots of false positives are filtered out when we realize any malware with more than one function prob won't fit in 4kb.
			($_.Protect -match "EXECUTE") -AND # Looking only for sections currently marked executable.
			($_.Protect -notmatch "PAGE_GUARD") -AND
			($_.AllocationProtect -notmatch "PAGE_NOACCESS")
			} 
		Write-Verbose "Process: $ProcessID MemObjects: $($ProcessMemory.count)"
        
		$ProcessMemory | % {
            $Allocation = $_

			$Bytes = New-Object Byte[]($Allocation.RegionSize)
			
			$PE = $false
			$BytesRead = 0
			$Result = $Kernel32::ReadProcessMemory($hProcess, $Allocation.BaseAddress, $Bytes, $Allocation.RegionSize, [Ref] $BytesRead)
			Write-Verbose "Read Process Result: $Result"
			
			if ((-not $Result) -or ($BytesRead -ne $Allocation.RegionSize)) {
				Write-Warning "Unable to read 0x$($Allocation.BaseAddress.ToString('X16')) from PID $ProcessID. Size: 0x$($Allocation.RegionSize.ToString('X8'))"
			} else {
				
				# Get ModuleName from handle
				<#
				$FileNameSize = 255
				$StrBuilder = New-Object System.Text.StringBuilder $FileNameSize
				try {
					# Refer to http://msdn.microsoft.com/en-us/library/windows/desktop/ms683198(v=vs.85).aspx+
					# This function may not be exported depending on the OS version.
					$null = $Kernel32::K32GetModuleFileNameEx($hProcess, $Allocation.BaseAddress, $StrBuilder, $FileNameSize)
				} catch {
					Write-Warning "Unable to call K32GetModuleFileNameEx"
					try {
						$null = $Psapi::GetModuleFileNameEx($hProcess, $Allocation.BaseAddress, $StrBuilder, $FileNameSize)
					} catch {
							Write-Warning "Unable to call Psapi::GetModuleFileNameEx"
					}
				}
				$ModuleName = $StrBuilder.ToString()
				#>
				
				# Check for PE Header
				Write-Verbose "Checking for PE Header"
				try {
					$MZHeader = [System.Text.Encoding]::ASCII.GetString($Bytes[0..1])			
				}catch {
					Write-Warning "Could not convert first bytes of allocation to string"
				}
				try {
					$COFFHeader = [System.Text.Encoding]::ASCII.GetString($Bytes[264..265])
				}catch {
					Write-Warning "Could not convert first bytes of allocation to string"
				}				
				try {
					$ArrayPtr = [Runtime.InteropServices.Marshal]::UnsafeAddrOfPinnedArrayElement($Bytes, 0)
					$RawString = [Runtime.InteropServices.Marshal]::PtrToStringAnsi($ArrayPtr, 2)
				}catch {
					Write-Warning "Could not convert first bytes of allocation to string"
				}					
				Write-Verbose "First Bytes: $MZHeader, RawString: $RawString COFF?: $COFFHeader"
				if (( $MZHeader -eq 'MZ' ) -OR ($COFFHeader -eq 'PE') -OR ($RawString  -eq 'MZ')) {
					Write-Verbose "Found an INJECTED MODULE in Process: $ProcessID"
					$PE = $true
				}
				# Get Strings of section
				Write-Verbose "Getting Strings"
				$Strings = ''
				$RawStrings = [System.Text.Encoding]::ASCII.GetString($ByteArray[0..$BytesRead])
				$Regex = [Regex] "[\x20-\x7E]{1,}"
				$Regex.Matches($RawString) | % { 
					$Strings += $_.Value
				}

				$Allocation | Add-Member -type NoteProperty -Name ProcessId -Value $ProcessID
				$Allocation | Add-Member -type NoteProperty -Name ProcessName -Value $ProcessName
				#$Allocation | Add-Member -type NoteProperty -Name ModuleName -Value $ModuleName
				$Allocation | Add-Member -type NoteProperty -Name PE -Value $PE
				$Allocation | Add-Member -type NoteProperty -Name Strings -Value $Strings
				Write-Verbose "$Allocation"
				$Memory += $Allocation
			}

			$Bytes = $null
        }
        
        $null = $Kernel32::CloseHandle($hProcess)
    }

    END {
		return $Memory
	}
}

function Get-InjectedModule {
	<#		
		Info on parsing PE Headers in memory (tl;dr it's a zoo)
		https://media.blackhat.com/bh-us-11/Vuksan/BH_US_11_VuksanPericin_PECOFF_Slides.pdf
		
		PE headers
		By default the PE header has read and execute attributes set. If DEP has been turned on the header has read only attributes.
		
		FileAlignment:
		Hardcoded to 0x200 of the PECOFF
		The alignment factor (in bytes) that is used to align the raw data of sections in the image file. 
		The value should be a power of 2 between 512 and 64 K, inclusive. The default is 512.
		PE file validations
			• Headers
				• Disallow files which have headers outside the NtSizeOfHeaders
				• Disallow files which have too big NtSizeOfOptionalHeaders field value
				• Disallow files which have entry point outside the file
			• Sections
				• Disallow files with zero sections
			• Imports
				• String validation
				• Disallow table reuse and overlap
			• Exports
				• Disallow multiple entries with the same name
				• Disallow entries which have invalid function addresses
			• Relocations
				• Block files which utilize multiple relocations per address
			• TLS
				• Disallow files whose TLS callbacks are outside the image
	#>
}

function Get-Modules {
	Write-Verbose "Getting loaded Modules"

	$modules = Get-Process -ea 0 -Module | where { $_.FileName -notmatch "\.exe$" } | sort-object FileName -unique

	$ModuleList = @()
	foreach ($module in $modules) {
		
		$newModule = New-Object PSObject -Property @{	
			ModuleName	= $module.ModuleName
			PathName	= $module.FileName
			Company		= $module.Company
			Product		= $module.Product
			ProductVersion = $module.ProductVersion
			FileVersion = $module.FileVersion
			Description = $module.Description
			InternalName = $module.FileVersionInfo.InternalName
			OriginalFilename = $module.FileVersionInfo.OriginalFilename
			Language    = $module.FileVersionInfo.Language
		}
		
		if ($module.FileName) {
			# Get hashes and verify Signatures with Sigcheck
			$Signature = Invoke-Sigcheck $module.FileName -GetHashes | Select -ExcludeProperty Path
			$Signature.PSObject.Properties | Foreach-Object {
				$newModule | Add-Member -type NoteProperty -Name $_.Name -Value $_.Value
			}
		}
		
		$ModuleList += $newModule
	}	
	return $ModuleList
} 

function Get-Drivers {
	Write-Verbose "Getting Drivers"
	# Get driver Information
	$drivers = Get-WmiObject Win32_SystemDriver #| Select Name, DisplayName, Description, PathName, State, Started, StartMode, ServiceType
	
	$driverList = @()
	foreach ($driver in $drivers) { 
	#	Write-Host "in FIRST foreach: " $proc.ProcessId | ft #debug
		$path = Get-ParsedSystemPath $driver.PathName
		#$hashes = $null
		#$hashes = Get-Hashes $path
        #$VersionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path)

		$newDriver = New-Object PSObject -Property @{
			Name			= $driver.Name
			DisplayName		= $driver.DisplayName
			Description		= $driver.Description
			PathName		= $path
			State			= $driver.State
			Started			= $driver.Started
			StartMode		= $driver.StartMode
			ServiceType		= $driver.ServiceType
		}	
		
		if ($path) {
			# Get hashes and verify Signatures with Sigcheck
			$Signature = Invoke-Sigcheck $path -GetHashes | Select -ExcludeProperty Path
			$Signature.PSObject.Properties | Foreach-Object {
				$newDriver | Add-Member -type NoteProperty -Name $_.Name -Value $_.Value -ea 0
			}
		}

		$driverList += $newDriver;
	}

	return $driverList;
}

function Get-Netstat {
	Write-Verbose "Getting Netstat"
	$netstat = @()
	
	# Run netstat for tcp and udp
	$netstat_tcp = &{netstat -ano -p tcp}  | select -skip 4
	$netstat_udp = &{netstat -ano -p udp} | select -skip 4
	
	# Process output into objects
	foreach ($line in $netstat_tcp) { 	
		$val = -Split $line
		$l = $val[1] -Split ":" 
		$r = $val[2] -Split ":" 		
		$netstat += new-Object PSObject -Property @{
			Protocol		= $val[0] 
			Src_Address		= $l[0]
			Src_Port 		= [int]$l[1]
			Dst_Address 	= $r[0] 
			Dst_Port 		= [int]$r[1] 
			State 			= $val[3] 
			ProcessId 		= [int]$val[4]
			ProcessName 	= [String](Get-Process -Id ([int]$val[4])).Name
		}			
	}
	foreach ($line in $netstat_udp) { 	
		$val = -Split $line
		$l = $val[1] -Split ":" 
		$netstat += new-Object PSObject -Property @{
			Protocol		= $val[0] 
			Src_Address		= $l[0]
			Src_Port 		= [int]$l[1]
			Dst_Address 	= $null
			Dst_Port 		= [int]$null 
			State 			= $null
			ProcessId 		= [int]$val[3]
			ProcessName 	= [String](Get-Process -Id ([int]$val[3])).Name
		}
	}
	return $netstat
}

function Get-OldestLogs {
    # Get oldest log.  A limited look back could be indicative of a log wipe (it's infinitely easier to delete all logs than manipulate individual ones - expect it)
	$Oldest = @()
	$Oldest +=  Get-WinEvent -Oldest -MaxEvents 1 -FilterHashTable @{LogName='Application'} | Select LogName,TimeCreated
	$Oldest +=  Get-WinEvent -Oldest -MaxEvents 1 -FilterHashTable @{LogName='Security'} | Select LogName,TimeCreated
	$Oldest +=  Get-WinEvent -Oldest -MaxEvents 1 -FilterHashTable @{LogName='System'} | Select LogName,TimeCreated
	return $Oldest
}
	
function Invoke-Autorunsc {
param(
	[String]$autorunscPath="C:\Windows\temp\autorunsc.exe"
)
	
	# Hardcode Hash (TODO: impliment more better authentication mechanism, maybe a signature check for MS)
	if ((Get-WmiObject -class win32_operatingsystem -Property OSArchitecture).OSArchitecture -match "64") {	
		$autorunsURL = "http://live.sysinternals.com/autorunsc64.exe"
	} else {
		$autorunsURL = "http://live.sysinternals.com/autorunsc.exe"
	}
	
	# Download Autoruns if not in the target directory & verify it's actually right sigcheck
	# $(get-AuthenticodeSignature myfile.exe).SignerCertificate.Subject <-- PS 3.0+
	if ( -NOT (Test-Path $autorunscPath) ) {
		$wc = New-Object System.Net.WebClient
		
		# Check if there is a proxy.  Explicitly Authenticated proxies are not yet supported.
		$proxyAddr = (get-itemproperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyServer
		if ($proxyAddr) {
			$proxy = new-object System.Net.WebProxy
			$proxy.Address = $proxyAddr
			$proxy.useDefaultCredentials = $true
			$wc.proxy = $proxy
		}
		try {
			$wc.DownloadFile($autorunsURL,$autorunscPath)
		} 
		catch {
			Write-Warning "ERROR[Invoke-Autoruns]: Could not download autoruns from Microsoft"
			return $null
		} 
		finally {
			$wc.Dispose()
		}
	}

	Write-Verbose 'Getting Autoruns via Autorunsc.exe -accepteula -a * -c -h -s *'
	$ar = (&"$autorunscPath" -accepteula -nobanner -a * -c *) | ConvertFrom-CSV | where { $_."Image Path" -ne "" } | Select Category,  
		@{Name="Name";Expression={$_.Entry}}, 
		@{Name="Key";Expression={$_."Entry Location"}}, 
		@{Name="PathName";Expression={$_."Image Path"}}, 
		@{Name="CommandLine";Expression={$_."Launch String"}},
		Description,
		Company,
		Version,
		Time,
		Enabled
	
	Foreach ($autorun in $ar) {		
		# Verify Signatures with Sigcheck (Yes, I know autoruns can get this but i'm normalizing formats and sigcheck gets more signature info)
		$Signature = Invoke-Sigcheck $autorun.PathName -GetHashes | Select -ExcludeProperty Path,Company,Version,Description,PESHA1,PESHA256,IMP
		$Signature.PSObject.Properties | Foreach-Object {
			$autorun | Add-Member -type NoteProperty -Name $_.Name -Value $_.Value
		}
	}	
	return $ar
}

$GetAutorunsSB = {
	
    $autorunscPath = "C:\Windows\temp\autorunsc.exe"
    
    # Hardcode Hash check (TODO: impliment more better authentication mechanism, maybe a signature check for MS sigs)
	if ((Get-WmiObject -class win32_operatingsystem -Property OSArchitecture).OSArchitecture -match "64") {	
		$autorunsURL = "http://live.sysinternals.com/autorunsc64.exe"
	} else {
		$autorunsURL = "http://live.sysinternals.com/autorunsc.exe"
	}
	
	# Download Autoruns if not in the target directory & verify it's actually right sigcheck
	# $(get-AuthenticodeSignature myfile.exe).SignerCertificate.Subject <-- PS 3.0+
	if ( -NOT (Test-Path $autorunscPath) ) {
		$wc = New-Object System.Net.WebClient
		
		# Check if there is a proxy.  Explicitly Authenticated proxies are not yet supported.
		$proxyAddr = (get-itemproperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyServer
		if ($proxyAddr) {
			$proxy = new-object System.Net.WebProxy
			$proxy.Address = $proxyAddr
			$proxy.useDefaultCredentials = $true
			$wc.proxy = $proxy
		}
		try {
			$wc.DownloadFile($autorunsURL,$autorunscPath)
		} 
		catch {
			return $null
		} 
		finally {
			$wc.Dispose()
		}
	}
	
	$ar = (&"$autorunscPath" -accepteula -nobanner -a * -c -h -s *) | ConvertFrom-CSV | where { $_."Image Path" -ne "" } | Select Category, 
		Description, 
		@{Name="Name";Expression={$_.Entry}}, 
		@{Name="Key";Expression={$_."Entry Location"}}, 
		@{Name="PathName";Expression={$_."Image Path"}}, 
		@{Name="CommandLine";Expression={$_."Launch String"}},
		@{Name="MD5";Expression={$_.MD5.ToUpper()}},
		@{Name="SHA1";Expression={$_.'SHA-1'.ToUpper()}},
		@{Name="SHA256";Expression={$_.'SHA-256'.ToUpper()}},
		Company,
		Version,
		Publisher,
		Time,
		Signer,
		Enabled
	
	return $ar
}

# Native function (doesn't use sysinternals autoruns) - hasn't reached parity though (Work in progress)
function Get-Autostarts {
	Write-Verbose "Getting Autostarts"
	<# 
	$autorunkeys = @(
		"HKCU:\Control Panel\Desktop"
		"HKCU:\Control Panel\Desktop\Scrnsave.exe"
		"HKCU:\Software\Classes\*\ShellEx\ContextMenuHandlers"
		"HKCU:\Software\Classes\AllFileSystemObjects\ShellEx\ContextMenuHandlers"
		"HKCU:\Software\Classes\Directory\Background\ShellEx\ContextMenuHandlers"
		"HKCU:\Software\Classes\Directory\ShellEx\ContextMenuHandlers"
		"HKCU:\Software\Classes\Folder\Shellex\ColumnHandlers"
		"HKCU:\Software\Classes\Folder\ShellEx\ContextMenuHandlers"
		"HKCU:\SOFTWARE\Microsoft\Active Setup\Installed Components"
		"HKCU:\Software\Microsoft\Command Processor\Autorun"
		"HKCU:\Software\Microsoft\Ctf\LangBarAddin"
		"HKCU:\SOFTWARE\Microsoft\Internet Explorer\Desktop\Components"
		"HKCU:\Software\Microsoft\Internet Explorer\Explorer Bars"
		"HKCU:\Software\Microsoft\Internet Explorer\Extensions"
		"HKCU:\Software\Microsoft\Internet Explorer\UrlSearchHooks"
		"HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\Install\Software\Microsoft\Windows\CurrentVersion\Run"
		"HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\Install\Software\Microsoft\Windows\CurrentVersion\Runonce"
		"HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\Install\Software\Microsoft\Windows\CurrentVersion\RunonceEx"
		"HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows\Load"
		"HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows\Run"
		"HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
		"HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\Shell"
		"HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers"
		"HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run"
		"HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run"
		"HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System\Shell"
		"HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
		"HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
		"HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved"
		"HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ShellServiceObjectDelayLoad"
		"HKCU:\Software\Policies\Microsoft\Windows\System\Scripts\Logon"
		"HKCU:\Software\Wow6432Node\Microsoft\Internet Explorer\Explorer Bars"
		"HKCU:\Software\Wow6432Node\Microsoft\Internet Explorer\Extensions"
		"HKLM:\Software\Classes\*\ShellEx\ContextMenuHandlers"
		"HKLM:\Software\Classes\AllFileSystemObjects\ShellEx\ContextMenuHandlers"
		"HKLM:\Software\Classes\Directory\Background\ShellEx\ContextMenuHandlers"
		"HKLM:\Software\Classes\Directory\ShellEx\ContextMenuHandlers"
		"HKLM:\Software\Classes\Directory\Shellex\CopyHookHandlers"
		"HKLM:\Software\Classes\Directory\Shellex\DragDropHandlers"
		"HKLM:\Software\Classes\Directory\Shellex\PropertySheetHandlers"
		"HKLM:\SOFTWARE\Classes\Exefile\Shell\Open\Command\(Default)"
		"HKLM:\Software\Classes\Folder\Shellex\ColumnHandlers"
		"HKLM:\Software\Classes\Folder\ShellEx\ContextMenuHandlers"
		"HKLM:\SOFTWARE\Classes\Protocols\Filter"
		"HKLM:\SOFTWARE\Classes\Protocols\Handler"
		"HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components"
		"HKLM:\Software\Microsoft\Command Processor\Autorun"
		"HKLM:\Software\Microsoft\Ctf\LangBarAddin"
		"HKLM:\Software\Microsoft\Internet Explorer\Explorer Bars"
		"HKLM:\Software\Microsoft\Internet Explorer\Extensions"
		"HKLM:\Software\Microsoft\Internet Explorer\Toolbar"
		"HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
		"HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\Install\Software\Microsoft\Windows\CurrentVersion\Run"
		"HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\Install\Software\Microsoft\Windows\CurrentVersion\Runonce"
		"HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\Install\Software\Microsoft\Windows\CurrentVersion\RunonceEx"
		"HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"
		"HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows\Appinit_Dlls"
		"HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
		"HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\AppSetup"
		"HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GinaDLL"
		"HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\Notify"
		"HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\Shell"
		"HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\System"
		"HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\Taskman"
		"HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\UIHost"
		"HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\Userinit"
		"HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Provider Filters"
		"HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers"
		"HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\PLAP Providers"
		"HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\Browser Helper Objects"
		"HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SharedTaskScheduler"
		"HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\ShellExecuteHooks"
		"HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers"
		"HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run"
		"HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\Shell"
		"HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
		"HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
		"HKLM:\software\microsoft\windows\currentversion\runonceex"
		"HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnceEx"
		"HKLM:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved"
		"HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ShellServiceObjectDelayLoad"
		"HKLM:\Software\Policies\Microsoft\Windows\System\Scripts\Logon"
		"HKLM:\Software\Policies\Microsoft\Windows\System\Scripts\Startup"
		"HKLM:\Software\Wow6432Node\Classes\*\ShellEx\PropertySheetHandlers"
		"HKLM:\Software\Wow6432Node\Classes\AllFileSystemObjects\ShellEx\ContextMenuHandlers"
		"HKLM:\Software\Wow6432Node\Classes\Directory\Background\ShellEx\ContextMenuHandlers"
		"HKLM:\Software\Wow6432Node\Classes\Directory\ShellEx\ContextMenuHandlers"
		"HKLM:\Software\Wow6432Node\Classes\Directory\Shellex\CopyHookHandlers"
		"HKLM:\Software\Wow6432Node\Classes\Folder\Shellex\ColumnHandlers"
		"HKLM:\Software\Wow6432Node\Classes\Folder\ShellEx\ContextMenuHandlers"
		"HKLM:\Software\Wow6432Node\Classes\Folder\ShellEx\DragDropHandlers"
		"HKLM:\Software\Wow6432Node\Classes\Folder\ShellEx\PropertySheetHandlers"
		"HKLM:\SOFTWARE\Wow6432Node\Microsoft\Active Setup\Installed Components"
		"HKLM:\Software\Wow6432Node\Microsoft\Command Processor\Autorun"
		"HKLM:\Software\Wow6432Node\Microsoft\Internet Explorer\Explorer Bars"
		"HKLM:\Software\Wow6432Node\Microsoft\Internet Explorer\Extensions"
		"HKLM:\Software\Wow6432Node\Microsoft\Internet Explorer\Toolbar"
		"HKLM:\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
		"HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows NT\CurrentVersion\Windows\Appinit_Dlls"
		"HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\Browser Helper Objects"
		"HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\SharedTaskScheduler"
		"HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\ShellExecuteHooks"
		"HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers"
		"HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Run"
		"HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Run\AutorunsDisabled"
		"HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\RunOnce"
		"HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\RunOnceEx"
		"HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved"
		"HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\ShellServiceObjectDelayLoad"
		"HKLM:\System\CurrentControlSet\Control\BootVerificationProgram\ImagePath"
		"HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
		"HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Authentication Packages"
		"HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Notification Packages"
		"HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Security Packages"
		"HKLM:\SYSTEM\CurrentControlSet\Control\NetworkProvider\Order"
		"HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors"
		"HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot"
		"HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders"
		"HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SecurityProviders"
		"HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
		"HKLM:\System\CurrentControlSet\Control\Session Manager\BootExecute"
		"HKLM:\System\CurrentControlSet\Control\Session Manager\Execute"
		"HKLM:\System\CurrentControlSet\Control\Session Manager\KnownDlls"
		"HKLM:\System\CurrentControlSet\Control\Session Manager\SetupExecute"
		"HKLM:\System\CurrentControlSet\Control\Terminal Server\Wds\rdpwd\StartupPrograms"
		"HKLM:\System\currentcontrolset\services\Tcpip\Parameters\Winsock"
		"HKLM:\System\CurrentControlSet\Services\WinSock2\Parameters\NameSpace_Catalog5\Catalog_Entries"
		"HKLM:\System\CurrentControlSet\Services\WinSock2\Parameters\NameSpace_Catalog5\Catalog_Entries64"
		"HKLM:\System\CurrentControlSet\Services\WinSock2\Parameters\Protocol_Catalog9\Catalog_Entries"
		"HKLM:\System\CurrentControlSet\Services\WinSock2\Parameters\Protocol_Catalog9\Catalog_Entries64"
		"HKLM\Software\Classes\*\ShellEx\ContextMenuHandlers"
		"HKLM\Software\Wow6432Node\Classes\*\ShellEx\ContextMenuHandlers"
		)
	#>
	
			
	# Get Startups from wmi - queries the below run keys and startup locations
	<# 
		HKLM\Software\Microsoft\Windows\CurrentVersion\Run
		HKLM\Software\Microsoft\Windows\CurrentVersion\RunOnce
		HKCU\Software\Microsoft\Windows\CurrentVersion\Run
		HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce
		HKU\ProgID\Software\Microsoft\Windows\CurrentVersion\Run
		systemdrive\Documents and Settings\All Users\Start Menu\Programs\Startup
		systemdrive\Documents and Settings\<username>\Start Menu\Programs\Startup 
	#>
	$StartupWMI = gwmi Win32_StartupCommand | Select Caption,User,UserSID,
		@{Name="Key";Expression={ $_.Location }},
		@{Name="CommandLine";Expression={ $_.Command }},
		@{Name="PathName";Expression={ (Get-ParsedSystemPath $_.Command) }}
	
	$StartupWMI | foreach {
		$hashes = Get-Hashes $_.PathName
		$_ | Add-Member -type NoteProperty -Name MD5 -Value $hashes.MD5
		$_ | Add-Member -type NoteProperty -Name SHA1 -Value $hashes.SHA1
		$_ | Add-Member -type NoteProperty -Name SHA256 -Value $hashes.SHA256
	}

	# Get scheduled tasks on system
	# Note: `at` jobs show up as task name At#, with comment of created by "NetScheduleJobAdd" function
	
	# Get Scheduled Tasks via schtasks
	$Schtasks = ConvertFrom-CSV (schtasks /query /v /fo csv) | 
		where { ($_.TaskName -ne "TaskName") -AND ($_.TaskName -notlike "\Microsoft\Windows*")} | 
		Select "TaskName","Next Run Time","Status","Last Run Time","Author","Task To Run","Comment",`
		"Scheduled Task State","Run As User","Schedule Type","Start Time","Start Date",`
		"End Date","Days","Months","Repeat: Every","Repeat: Until: Time","Repeat: Until: Duration"
	
	# Get hash for any paths found
	$Schtasks | foreach {
		$_ | Add-Member -type NoteProperty -name PathName -Value $null
		$_ | Add-Member -type NoteProperty -name MD5 -Value $null
		$_ | Add-Member -type NoteProperty -name SHA1 -Value $null
		$_ | Add-Member -type NoteProperty -name SHA256 -Value $null
		if ($_."Task To Run" -match "\\") {
			$path = Get-ParsedSystemPath $_."Task To Run"
		    $Hashes = Get-Hashes $path

			$_.PathName = $path
			$_.MD5		= $hashes.MD5
			$_.SHA1	    = $hashes.SHA1
			$_.SHA256	= $hashes.SHA256
		}
	} 
	
	# Get items in the Start up and task folders
	$StartupFolders = @()
	# Getting Startup Programs (All_Users)
	$StartupFolders += gci -Force -Recurse "$env:ALLUSERSPROFILE\Start Menu\Programs\Startup\" -ae 0 | where {$_.FullName -notlike "*.ini"} | Select FullName, Length, CreationTime
	# Getting All Users Start up (Vista Plus)
	$StartupFolders += gci -Force -Recurse "$env:ALLUSERSPROFILE\Microsoft\Windows\Start Menu\Programs\Startup\" -ea 0 | where {$_.FullName -notlike "*.ini"}  | Select FullName, Length, CreationTime
	# Surveying Startup Programs (Userprofile)
	$StartupFolders += gci -Force -Recurse "C:\Users\*\Start Menu\Programs\Startup\" -ea 0 | where {$_.FullName -notlike "*.ini"} | Select FullName, Length, CreationTime
	# Surveying C:\Windows\Tasks
	$StartupFolders += gci -Force -Recurse "$env:windir\Tasks" -ea 0 | where {$_.FullName -notlike "*.ini"} | Select FullName, Length, CreationTime
	
	
	$Startups = new-Object PSObject -Property @{
		StartupFolders		= $startupfolder
		WMIStartup			= $StartupWMI
		Schtasks			= $Schtasks
		}
		
	return $startups
}

function Get-DiskInfo {
	Write-Verbose "Getting Disk info"
	# Get Disks Installed
	# return gwmi -Class Win32_LogicalDisk | Select DeviceID, DriveType, FreeSpace, Size, VolumeName, FileSystem
	
	$disks = gwmi -Class win32_logicaldisk | 
		Select Name,
		@{Name="Freespace";Expression={"{0:N1} GB" -f ($_.Freespace / 1000000000)}},
		@{Name="Size";Expression={"{0:N1} GB" -f ($_.Size / 1000000000)}},
		FileSystem,
		VolumeSerialNumber,
		DriveType
									
	Switch ($disks.DriveType) {
		0 { $disks.DriveType = "Unknown (0)"; break}
		1 { $disks.DriveType = "No Root Directory (1)"; break}
		2 { $disks.DriveType = "Removable Disk (2)"; break}
		3 { $disks.DriveType = "Local Disk (3)"; break}
		4 { $disks.DriveType = "Network Drive (4)"; break}
		5 { $disks.DriveType = "Compact Disc (5)"; break}		
		6 { $disks.DriveType = "RAM Disk (6)"; break}	
	}

	return $disks
}

function Get-Pipes {
	Write-Verbose "Getting NamedPipes"
	# Get all Named pipes
	try {
		$NamedPipes = [System.IO.Directory]::GetFiles("\\.\pipe\")
	} catch {
		# Will fail if pipe has an illegal name for path objects
	}
	
	# Get null session pipes and shares (these are generally bad - used by legacy Win2k era applications and malware that do lateral C2 via NamedPipes)
	$NullSessionPipes = (Get-ItemProperty -ea 0 HKLM:\SYSTEM\CurrentControlSet\Services\lanmanserver\parameters).nullsessionpipes
	$NullSessionShares = (Get-ItemProperty -ea 0 HKLM:\System\CurrentControlSet\Services\LanmanServer\Parameters).NullSessionShares
	
	$Pipes = new-Object PSObject -Property @{
		NamedPipes			= $NamedPipes
		NullSessionPipes	= $nullSessionPipes
		NullSessionShares	= $NullSessionShares
	}
	return $Pipes
}

function Get-HostInfo {
	# Gather System and Operating System Information from WMI or Cim (Cim = Powershell 3.0+ unfortunately)
	# If you are 3.0+, please use Cim.  WMI is being depreciated.
	# Difference: WMI sits on top of DCOM, Cim sits on top of WinRM
	# Example: 
	# Get-WmiObject Win32_ComputerSystem
	# Get-CimInstance -Class Win32_ComputerSystem
	
	$SystemInfo = Get-WmiObject Win32_ComputerSystem | Select Name,DNSHostName,Domain,Workgroup,SystemType,@{Name = 'CurrentTimeZone'; Expression = {$_.CurrentTimeZone/60}},Manufacturer,Model,DomainRole
	Switch ($Systeminfo.DomainRole) {
		0 { $Systeminfo.DomainRole = "Standalone Workstation (0)"; break}
		1 { $Systeminfo.DomainRole = "Member Workstation (1)"; break}
		2 { $Systeminfo.DomainRole = "Standalone Server (2)"; break}
		3 { $Systeminfo.DomainRole = "Member Server (3)"; break}
		4 { $Systeminfo.DomainRole = "Backup Domain Controller (4)"; break}
		5 { $Systeminfo.DomainRole = "Primary Domain Controller (5)"; break}		
	}
	
	$OS = Get-wmiobject Win32_OperatingSystem | 
		Select @{Name = 'OS'; Expression = {$_.Caption}},
		Version,
		CSDVersion,
		OSArchitecture,
		@{Name = 'InstallDate'; Expression = {$_.ConvertToDateTime($_.InstallDate).ToString()}},
		@{Name = 'LastBootUpTime'; Expression = {$_.ConvertToDateTime($_.LastBootUpTime).ToString()}},
		@{Name = 'LocalDateTime'; Expression = {$_.ConvertToDateTime($_.LocalDateTime).ToString()}}
		
	$OS.PSObject.Properties | Foreach-Object {
		$SystemInfo | Add-Member -type NoteProperty -Name $_.Name -Value $_.Value
	}
	
	# Grab the path variable (might be useful?)
	$SystemInfo | Add-Member -type NoteProperty -Name EnvPath -Value $env:Path
	
	Return $SystemInfo 
}

function Get-InterestingStuff {
	# Pending File Rename Operations (Can delete stuff on reboot. Set when people want to delete something that's locked by OS -- like your log files)
	$PendingFileRename = (get-itemproperty "HKLM:\System\CurrentControlSet\Control\Session Manager").PendingFileRenameOperations
	
	$InterestingStuff = new-Object PSObject -Property @{
		PendingFileRename	= $PendingFileRename
	}
	return $InterestingStuff
}

function Get-AccountInfo {
	Write-Verbose "Getting Account Info"
	# Net User can be a heavy load on domain controllers because all domain accounts are local to a domain controller

	# LastLogon = yyyymmddhhmmss.mmmmmm

    # User to SID - This will give you a Domain User's SID
    # $objUser = New-Object System.Security.Principal.NTAccount("DOMAIN_NAME", "USER_NAME") 
    # $strSID = $objUser.Translate([System.Security.Principal.SecurityIdentifier]).Value 
    
    # SID to Domain User - This will allow you to enter a SID and find the Domain User

    # $SID = "S-1-5-21-1031827263-1101308967-1021258693-501"
    # $objSID = New-Object System.Security.Principal.SecurityIdentifier($SID) 
    # $objUser = $objSID.Translate( [System.Security.Principal.NTAccount]).Value 


    $LocalAccounts = gwmi win32_useraccount -Filter "LocalAccount='True'" | Select Caption,
        Description,
        AccountType,
        Disabled,
        Domain,
        FullName,
        @{Name = 'InstallDate'; Expression = {$_.ConvertToDateTime($_.InstallDate).ToString()}},
        LocalAccount,
        SID,
        SIDType,
        Lockout,
		Comment

	# Login history (Note: NumberOfLogons is maintained seperately on each DC - so it's usually smaller than it should be)
	$logins = gwmi -Class Win32_NetworkLoginProfile -Filter "Privileges='2'"| Select Name,Comment,BadPasswordCount,AccountExpires,Description,FullName, 
        @{Name = 'LastLogon'; Expression = {$_.ConvertToDateTime($_.LastLogon).ToString()}},
        @{Name = 'LastLogoff'; Expression = { if ( $_.LastLogoff -notmatch "\*\*\*") { $_.ConvertToDateTime($_.LastLogoff).ToString()}  }},
        NumberOfLogons,UserType,UserId,UserComment,
		@{Name = 'Privileges'; Expression = { 
				Switch ($_.Privileges) { 
					0 { "Guest (0)" }
					1 { "User (1)" }
					2 { "Administrator (2)" }
				} 
			}
		}

	$logins | Foreach-Object {
		# Add SIDs
		$Domain = ($_.Name).Split("\\")[0]
		$Username = ($_.Name).Split("\\")[1]
		try { 
			$UserObj = New-Object System.Security.Principal.NTAccount($Domain, $Username) 
			$UserSID = $UserObj.Translate([System.Security.Principal.SecurityIdentifier]).Value
		} catch { 
			Write-Warning "Could not get SID for $Domain\$Username"
		}
		$_ | Add-Member -type NoteProperty -Name UserSID -Value $UserSID
	}
	
	# Get Local Admins
	$LocalAdministratorMembers = Gwmi win32_groupuser | ? { $_.groupcomponent -like '*"Administrators"'} | % { 
		$_.partcomponent -match ".+Domain\=(.+)\,Name\=(.+)$" > $null
		$matches[1].trim('"') + "\" + $matches[2].trim('"') 
	} 
        
	$RDPHistory = gci -ea 0 "HKCU:\Software\Microsoft\Terminal Server Client" | ForEach-Object {Get-ItemProperty -ea 0 $_.pspath} 
	
	#	Retrieves the date/time that users logged on and logged off on the system.
	# Version 3.0+ - I borrowed this from Jacob Soo (@jacobsoo) 
	$WinLogonEvents = Get-EventLog System -Source Microsoft-Windows-Winlogon | Select @{n="Time";e={$_.TimeGenerated}},
		@{n="User";e={(New-Object System.Security.Principal.SecurityIdentifier $_.ReplacementStrings[1]).Translate([System.Security.Principal.NTAccount])}}, 
		@{n="Action";e={if($_.EventID -eq 7001) {"Logon"} else {"Logoff"}}}
		
	
	$accountinfo = new-Object PSObject -Property @{
		LocalAccounts				= $LocalAccounts
		LoginHistory				= $logins
		LocalAdministratorMembers 	= $LocalAdministratorMembers
		RDPHistory					= $RDPHistory
		WinLogonEvents				= $WinLogonEvents
		}
		
	return $accountinfo
}

function Get-InstalledApps {
<#
.SYNOPSIS
Get the list of installed applications on a system.
Author: Jacob Soo (@jacobsoo)
License: BSD 3-Clause
Required Dependencies: None
Optional Dependencies: None
.DESCRIPTION
Get the list of installed applications on a system.
.EXAMPLE
PS C:\>Get-Installed-Apps
Description
-----------
Get the list of installed applications on a system.
#>

	$InstalledAppsList = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* -ea 0 | where { 
		$_.DisplayName -ne $null } | Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, InstallLocation, DisplayIcon
		
	$InstalledAppsList += Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ea 0 | where { 
		$_.DisplayName -ne $null } | Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, InstallLocation, DisplayIcon 
		
	return $InstalledAppsList
}

function Get-FirewallRules {
	#http://blogs.technet.com/b/heyscriptingguy/archive/2010/07/03/hey-scripting-guy-weekend-scripter-how-to-retrieve-enabled-windows-firewall-rules.aspx
	#Create the firewall com object to enumerate 
	$fw = New-Object -ComObject HNetCfg.FwPolicy2 
	#Retrieve all firewall rules 
	$FirewallRules = $fw.rules 
	#create a hashtable to define all values
	$fwprofiletypes = @{1GB="All";1="Domain"; 2="Private" ; 4="Public"}
	$fwaction = @{1="Allow";0="Block"}
	$FwProtocols = @{1="ICMPv4";2="IGMP";6="TCP";17="UDP";41="IPV6";43="IPv6Route"; 44="IPv6Frag";
			  47="GRE"; 58="ICMPv6";59="IPv6NoNxt";60="IPv60pts";112="VRRP"; 113="PGM";115="L2TP"}
	$fwdirection = @{1="Inbound"; 2="Outbound"} 

	#Retrieve the profile type in use and the current rules

	$fwprofiletype = $fwprofiletypes.Get_Item($fw.CurrentProfileTypes)
	$fwrules = $fw.rules

	"Current Firewall Profile Type in use: $fwprofiletype"
	$AllFWRules = @()
	#enumerate the firewall rules
	$fwrules | ForEach-Object{
		#Create custom object to hold properties for each firewall rule 
		$FirewallRule = New-Object PSObject -Property @{
			ApplicationName = $_.Name
			Protocol = $fwProtocols.Get_Item($_.Protocol)
			Direction = $fwdirection.Get_Item($_.Direction)
			Action = $fwaction.Get_Item($_.Action)
			LocalIP = $_.LocalAddresses
			LocalPort = $_.LocalPorts
			RemoteIP = $_.RemoteAddresses
			RemotePort = $_.RemotePorts
		}

		$AllFWRules += $FirewallRule

		
	} 
	return $AllFWRules
}

function Get-NetworkConfig {
	Write-Verbose "Getting Network Configuration"
	# ============ Surveying Network Configuration ===========================
	# OnlyConnectedNetworkAdapters
	# $ipconfig = gwmi -Class Win32_NetworkAdapterConfiguration | Where { $_.IPEnabled -eq $true } `
		# | Format-List @{ Label="Computer Name"; Expression= { $_.__SERVER }}, IPEnabled, Description, MACAddress, IPAddress, `
		# IPSubnet, DefaultIPGateway, DHCPEnabled, DHCPServer, @{ Label="DHCP Lease Expires"; Expression= { [dateTime]$_.DHCPLeaseExpires }}, `
		# @{ Label="DHCP Lease Obtained"; Expression= { [dateTime]$_.DHCPLeaseObtained }}

	$hosts 	= (Get-Content c:\windows\system32\drivers\etc\hosts | select-string -notmatch "^#").ToString().Trim()
		
	$routes = @()
	$temp = netstat -nr | Out-String 
	$routes += "IPv4 " + $temp.Substring( $temp.IndexOf("Persistent"), ($temp.IndexOf("IPv6")-$temp.IndexOf("Persistent")) )
	$routes += "IPv6 " + $temp.Substring( $temp.LastIndexOf("Persistent") )

#		routes 		= gwmi -Class Win32_IP4RouteTable | Select Description, Name, InterfaceIndex, NextHop, Status, Type, InstallDate, Age

	$ipconfig = gwmi -Class Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True" | Select DHCPEnabled, 
		IPAddress, DefaultIPGateway, DNSDomain, ServiceName, Description, Index, 
		@{Name = 'DHCPLeaseObtained'; Expression = {$_.ConvertToDateTime($_.DHCPLeaseObtained).ToString()}},
		@{Name = 'DHCPLeaseExpires'; Expression = {$_.ConvertToDateTime($_.DHCPLeaseExpires).ToString()}}
	
	$Shares = gwmi -Class Win32_Share | Select Description, Name, Path, Status, 
		InstallDate, 
		@{Name = 'Type'; Expression = {
				switch ($_.Type) {
					0 { "Disk Drive (0)" }
					1 { "Print Queue (1)" }
					2 { "Device (2)" }
					3 { "IPC (3)" }
					2147483648 { "Disk Drive Admin (2147483648)" }
					2147483649 { "Print Queue Admin (2147483649)" }
					2147483650 { "Device Admin (2147483650)" }
					2147483651 { "IPC Admin (2147483651)" }
				}
			}
		}
	
	$Connections = gwmi -Class Win32_NetworkConnection | Select Name, 
		Status, ConnectionState, Persistent, LocalName, RemoteName, 
		RemotePath, InstallDate, ProviderName,DisplayType,UserName
	
	$netconfig = new-Object PSObject -Property @{
		Ipconfig	= $ipconfig
		Hosts 		= $hosts
		Routes 		= $routes
		Shares		= $Shares
		Arp 		= arp -a #TODO: objectify this... 
		Connections	= $Connections
		NetSessions	= net session #TODO: objectify this... 
		}
		
	return $netconfig
}

# Useless in PS 2.0 but awesome for those rare PS 5.0 boxes
Function Find-PSScriptsInPSAppLog {
<#
.SYNOPSIS
Go through the PowerShell operational log to find scripts that run (by looking for ExecutionPipeline logs eventID 4100 in PowerShell app log).
You can then backdoor these scripts or do other malicious things.
Function: Find-AppLockerLogs
Author: Joe Bialek, Twitter: @JosephBialek
Required Dependencies: None
Optional Dependencies: None
.DESCRIPTION
Go through the PowerShell operational log to find scripts that run (by looking for ExecutionPipeline logs eventID 4100 in PowerShell app log).
You can then backdoor these scripts or do other malicious things.
.EXAMPLE
Find-PSScriptsInPSAppLog
Find unique PowerShell scripts being executed from the PowerShell operational log.
.NOTES
.LINK
Blog: http://clymb3r.wordpress.com/
Github repo: https://github.com/clymb3r/PowerShell
#>
    $ReturnInfo = @{}
    $Logs = Get-WinEvent -LogName "Microsoft-Windows-PowerShell/Operational" -ErrorAction SilentlyContinue | Where {$_.Id -eq 4100}

    foreach ($Log in $Logs)
    {
        $ContainsScriptName = $false
        $LogDetails = $Log.Message -split "`r`n"

        $FoundScriptName = $false
        foreach($Line in $LogDetails)
        {
            if ($Line -imatch "^\s*Script\sName\s=\s(.+)")
            {
                $ScriptName = $Matches[1]
                $FoundScriptName = $true
            }
            elseif ($Line -imatch "^\s*User\s=\s(.*)")
            {
                $User = $Matches[1]
            }
        }

        if ($FoundScriptName)
        {
            $Key = $ScriptName + "::::" + $User

            if (!$ReturnInfo.ContainsKey($Key))
            {
                $Properties = @{
                    ScriptName = $ScriptName
                    UserName = $User
                    Count = 1
                    Times = @($Log.TimeCreated)
                }

                $Item = New-Object PSObject -Property $Properties
                $ReturnInfo.Add($Key, $Item)
            }
            else
            {
                $ReturnInfo[$Key].Count++
                $ReturnInfo[$Key].Times += ,$Log.TimeCreated
            }
        }
    }

    return $ReturnInfo
}

# Broken until Mark fixes CSV output on the -t option.  Use of comma delimited fields mangles CSV output (-t -c)
function Get-RootCertificateStore {
	Param(
		[string] $SigcheckPath="C:\Windows\temp\sigcheck.exe"
	)
	
	# Hardcode Hash (TODO: impliment better authentication mechanism, maybe a signature check for MS)
	if ((Get-WmiObject -class win32_operatingsystem -Property OSArchitecture).OSArchitecture -match "64") {	
		$SigcheckURL = "http://live.sysinternals.com/sigcheck64.exe"
		$SigcheckHash = "860CECD4BF4AFEAC0F6CCCA4BECFEBD0ABF06913197FC98AB2AE715F382F45BF"
	} else {
		$SigcheckURL = "http://live.sysinternals.com/sigcheck.exe"
		$SigcheckHash = "92A9500E9AF8F2FBE77FB63CAF67BD6CC4CC110FA475ADFD88AED789FB515E6A"
	}
	
	# Download Autoruns if not in the target directory and it's the right file
	# $(get-AuthenticodeSignature myfile.exe).SignerCertificate.Subject <-- PS 3.0+
	if ( Test-Path $SigcheckPath ) {
	
	} else {
		$wc = New-Object System.Net.WebClient
		
		# Check if there is a proxy.  Explicitly Authenticated proxies are not yet supported.
		if (Get-Item "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\proxyserver" -ea 0) {
			$proxyAddr = (get-itemproperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyServer
			$proxy = new-object System.Net.WebProxy
			$proxy.Address = $proxyAddr
			$proxy.useDefaultCredentials = $true
			$wc.proxy = $proxy
		}
		try {
			$wc.DownloadFile($SigcheckURL,$SigcheckPath)
		} 
		catch {
			Write-Warning "Could not download sigcheck from Microsoft"
			return $null
		} 
		finally {
			$wc.Dispose()
		}
	}
	
	<#

	#>
	Write-Verbose 'Verifying Digital Signatures via sigcheck.exe -accepteula -a * -c -h -s *'
	$TrustStores = (&"$SigcheckPath" -accepteula -t -c) | Select -skip 5 | ConvertFrom-CSV
	
	# Note - this utility won't parse as there is a bug in the csv output of -t which uses an arbitrary number of comma seperated fields within
	# the "Valid Usage" field.  So CSV parsing is out.
	<#
	GeoTrust Primary Certification Authority - G3
     Cert Status:    Valid
     Valid Usage:    Server Auth, Client Auth, Email Protection, Code Signing, Timestamp Signing
     Cert Issuer:    GeoTrust Primary Certification Authority - G3
     Serial Number:  15 AC 6E 94 19 B2 79 4B 41 F6 27 A9 C3 18 0F 1F
     Thumbprint:     039EEDB80BE7A03C6953893B20D2D9323A4C2AFD
     Algorithm:      sha256RSA
     Valid from:     7:00 PM 4/1/2008
     Valid to:       6:59 PM 12/1/2037
	#>
	
	return $TrustStores
}

# TODO: Impliment the following:
<# 
	Enumerate hidden processes via "HPD using Direct NT System Call Implemenation"
			http://securityxploded.com/hidden-process-detection.php#HPD_DirectNT_Call
	Enumerate hidden processes via "CRSS process and thread handles" 

	Enumerate User-Mode IDT Hooks
	Analyze User-Mode IDT Hooks via identifying Hooking DLLs
	
	Enumerate User-Mode Inline Hooks
	Analyze User-Mode Inline Hooks via following JMP instructions to identify Hook DLLs
	
#>

#endregion Collector Functions 

#region Helper Functions:
function Invoke-Sigcheck {
	Param(
		[Parameter(Position=0, Mandatory=$True)]
		[ValidateNotNullOrEmpty()]
		[string] $FilePath,
		
		[string] $SigcheckPath="C:\Windows\temp\sigcheck.exe",
		
		[switch] $GetHashes
	)
	
	# Hardcode Hash (TODO: impliment more better authentication mechanism, maybe a signature check for MS)
	if ((Get-WmiObject -class win32_operatingsystem -Property OSArchitecture).OSArchitecture -match "64") {	
		$SigcheckURL = "http://live.sysinternals.com/sigcheck64.exe"
	} else {
		$SigcheckURL = "http://live.sysinternals.com/sigcheck.exe"
	}
	
	# Download SigCheck if not in the target directory (might want to verify it's the right SigCheck before running this)
	if ( -NOT (Test-Path $SigcheckPath) ) {
		if (Invoke-DownloadFile $SigcheckURL $SigcheckPath) { } else { 
			Write-Warning "ERROR[Invoke-Sigcheck]: Could not download SigCheck from Microsoft"
			return $null
		}	
	}
	
<#
	Path            : c:\windows\temp\autorunsc.exe
	Verified        : Signed
	Date            : 12:43 PM 7/6/2016
	Publisher       : Microsoft Corporation
	Company         : Sysinternals - www.sysinternals.com
	Description     : Autostart program viewer
	Product         : Sysinternals autoruns
	Product Version : 13.61
	File Version    : 13.61
	Machine Type    : 64-bit
	Binary Version  : 13.61.0.0
	Original Name   : autoruns.exe
	Internal Name   : Sysinternals Autoruns
	Copyright       : Copyright (C) 2002-2016 Mark Russinovich
	Comments        : n/a
	Entropy         : 5.966
	MD5             : 3DB29814EA5A2091425200B58E25BA15
	SHA1            : E33A2A83324731F8F808B2B1E1F5D4A90A9B9C33
	PESHA1          : B4DC9B4C6C053ED5D41ADB85DCDC8C8651D478FC
	PESHA256        : 6C7E61FE0FBE73E959AA78A40810ACD1DB3B308D9466AA6A4ACD9B0356B55B5B
	SHA256          : D86C508440EB2938639006D0D021ADE7554ABB2D1CFAA88C1EE1EE324BF65EC7
	IMP             : FA51BDCED359B24C8FCE5C35F417A9AF
#>
	
	if ($GetHashes) {
		Write-Verbose "Verifying Digital Signatures via sigcheck.exe -accepteula -nobanner -c -h -a $FilePath"
		$Signature = (&"$SigcheckPath" -accepteula -nobanner -c -a -h $FilePath) | ConvertFrom-CSV | Select -ExcludeProperty PESHA1,PESHA256,IMP | where { 
			$_.Path -ne "No matching files were found." } 
		
	} else {
		Write-Verbose "Verifying Digital Signatures via sigcheck.exe -accepteula -nobanner -c -a $FilePath"
		$Signature = (&"$SigcheckPath" -accepteula -nobanner -c -a $FilePath) | ConvertFrom-CSV | where {
			$_.Path -ne "No matching files were found." }
		
	}

	return $Signature
}

function Get-Hashes {
# Perform Cryptographic hash on a file
#
# @param path		File to hash
# @param Type	    Type of hashing to conduct
#
# Returns:			[Object] Path, MD5, SHA1, SHA256.  All uppercase hex without byte group delimiters
	Param(
	    [Parameter(
			Position=0,
			ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true
			)]
		[Alias("FullName")]
		[String]$Path,

		[Parameter(Position=1)]
        [ValidateSet('MD5','SHA1','SHA256','All')]
		[string[]]$Type = @('ALL')
	) 

	BEGIN {
		# Initialize Cryptoproviders

		if (-NOT $Global:CryptoProvider) {
			try { $MD5CryptoProvider = new-object -TypeName system.security.cryptography.MD5CryptoServiceProvider } catch { $MD5CryptoProvider = $null }
			try { $SHA1CryptoProvider = new-object -TypeName system.security.cryptography.SHA1CryptoServiceProvider } catch { $SHA1CryptoProvider = $null }
			try { $SHA256CryptoProvider = new-object -TypeName system.security.cryptography.SHA256CryptoServiceProvider } catch { $SHA256CryptoProvider = $null }
			
			$Global:CryptoProvider = New-Object PSObject -Property @{
				MD5CryptoProvider = $MD5CryptoProvider
				SHA1CryptoProvider = $SHA1CryptoProvider
				SHA256CryptoProvider = $SHA256CryptoProvider
			}	
		}
		Write-Debug "Before $Global:CryptoProvider"
	}
	
	PROCESS {
		
		try {
			$inputBytes = [System.IO.File]::ReadAllBytes($Path);
		} catch {
			Write-Warning "Hash Error: Could not read file $Path"
			return $null
		}
		
		$Results = New-Object PSObject -Property @{
			Path = $Path
			MD5 = $null
			SHA1 = $null
			SHA256 = $null
		}
		
		Switch ($Type) {
			All {
				try {
					$Hash = [System.BitConverter]::ToString($Global:CryptoProvider.MD5CryptoProvider.ComputeHash($inputBytes))
					$result = $Hash.Replace('-','').ToUpper()
				} catch {
					Write-Warning "Hash Error: Could not compute Hash $Path with MD5CryptoProvider"
					$result = $null
				}
				$Results.MD5 = $result
				
				try {
					$Hash = [System.BitConverter]::ToString($Global:CryptoProvider.SHA1CryptoProvider.ComputeHash($inputBytes))
					$result = $Hash.Replace('-','').ToUpper()
				} catch {
					Write-Warning "Hash Error: Could not compute Hash $Path with SHA1CryptoProvider"
					$result = $null
				}
				$Results.SHA1 = $result
				
				try {
					$Hash = [System.BitConverter]::ToString($Global:CryptoProvider.SHA256CryptoProvider.ComputeHash($inputBytes))
					$result = $Hash.Replace('-','').ToUpper()
				} catch {
					Write-Warning "Hash Error: Could not compute Hash $Path with SHA256CryptoProvider"
					$result = $null
				}
				$Results.SHA256 = $result
				break;
			}
			MD5 { 
				try {
					$Hash = [System.BitConverter]::ToString($Global:CryptoProvider.MD5CryptoProvider.ComputeHash($inputBytes))
					$result = $Hash.Replace('-','').ToUpper()
				} catch {
					Write-Warning "Hash Error: Could not compute Hash $Path with MD5CryptoProvider"
					$result = $null
				}
				$Results.MD5 = $result			
			}
			SHA1 {
				Write-Verbose "Type: SHA1"
				try {
					$Hash = [System.BitConverter]::ToString($Global:CryptoProvider.SHA1CryptoProvider.ComputeHash($inputBytes))
					$result = $Hash.Replace('-','').ToUpper()
				} catch {
					Write-Warning "Hash Error: Could not compute Hash $Path with SHA1CryptoProvider"
					$result = $null
				}
				$Results.SHA1 = $result
			}
			SHA256 {
				try {
					$Hash = [System.BitConverter]::ToString($Global:CryptoProvider.SHA256CryptoProvider.ComputeHash($inputBytes))
					$result = $Hash.Replace('-','').ToUpper()
				} catch {
					Write-Warning "Hash Error: Could not compute Hash $Path with SHA256CryptoProvider"
					$result = $null
				}
				$Results.SHA256 = $result
			}
		}

		Write-Output $Results
	}
	
	END {}
}

function Invoke-DownloadFile {
# Need this in Powershell V2, otherwise us Invoke-WebRequest (aka wget)
# Return true if file downloaded, otherwise false/null
	Param(
		[Parameter(Position=0, Mandatory=$True)]
		[String]$Url,
		[Parameter(Position=1, Mandatory=$True)]
		[String]$Path
	)
	$wc = New-Object System.Net.WebClient
	
	# GetSystemWebProxy method reads the current user's Internet Explorer (IE) proxy settings. 
	$proxy = [System.Net.WebRequest]::GetSystemWebProxy()
	# Check if there is a proxy.  Explicitly Authenticated proxies are not yet supported.
	
	$wc.Proxy = $proxy
	$wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
	# $proxyAddr = (get-itemproperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyServer
	# $wc.proxy.Address = $proxyAddr
	
	try {
		$wc.DownloadFile($Url,$Path)
		return $true
	} 
	catch {
		Write-Warning "Could not download file from $Url -> $Path"
		return $false
	} 
	finally {
		$wc.Dispose()
	}
}

function Get-ParsedSystemPath {
	Param(
		[Parameter(Position=0, Mandatory=$True)]
		[ValidateNotNullOrEmpty()]	
		[string]$inputStr
	)

	# PathName extractor
	#[regex]$pathpattern = '(\b[a-z]:\\(?# Drive)(?:[^\\/:*?"<>|\r\n]+\\)*)(?# Folder)([^\\/:*?"<>|\r\n,\s]*)(?# File)'
	#[regex]$pathpattern = "((?:(?:%\w+%\\)|(?:[a-z]:\\)){1}(?:[^\\/:*?""<>|\r\n]+\\)*[^\\/:*?""<>|\r\n]*\.(?:exe|dll|sys))"
	# [System.Environment]::ExpandEnvironmentVariables("%SystemRoot%\System32\Winevt\Logs\DebugChannel.etl")
	
    $str = $inputStr.ToLower()

	#Check for paths with no drive letter:
	if ($str.StartsWith('"')) {
		#$str = $str.Replace('"', '')
        #$str -replace 
	}	
	if ($str.StartsWith('\??\')) {
		$str = $str.Replace('\??\', '')
	}
	if ($str -match '%systemroot%') {
		$str = $str.Replace("%systemroot%", "$env:SystemRoot")
	}
	if ($str -match "%programfiles%") {
		$str = $str.Replace("%programfiles%", "$env:programfiles")
	}
	if ($str -match "%windir%") {
		$str = $str.Replace("%windir%", "$env:windir")
	}	
	if ($str -match "\\systemroot") {
		$str = $str.Replace('\systemroot', "$env:SystemRoot")
	}
	if ($str.StartsWith("system32")) {
		$str = $env:windir + "\" + $str
	}
	if ($str.StartsWith("syswow64")) {
		$str = $env:windir + "\" + $str
	}

	# Match Regex of File Path
	$regex = '(\b[a-z]:\\(?# Drive)(?:[^\\/:*?"<>|\r\n]+\\)*)(?# Folder)([^\\/:*?"<>|\r\n,\s]*)(?# File)'
	$matches = $str | select-string -Pattern $regex -AllMatches | % { $_.Matches } | % { $_.Value }
	
	if ($matches.count -gt 1) {
		Write-Verbose "Multiple paths found $matches"
		$matches | % { Write-Warning "==Match Found! $_" }
		return $matches[0].ToLower()			
	} else {
		return $matches.ToLower()
	}
	# Write-Verbose "Matches: $str --> $matches"
	
	#if ($str -match "@\w+\.dll,") {
	#	$str = $env:windir + "\system32\" + $str.Split(",")[0].Substring(1)
	#}	
}

function Convert-BinaryToString {
    [CmdletBinding()]
    param (
        [string] $FilePath
    )

	# $Content = Get-Content -Path $FilePath -Encoding Byte
	# $Base64 = [System.Convert]::ToBase64String($Content)
	# $Base64 | Out-File $FilePath.txt
	# http://trevorsullivan.net/2012/07/24/powershell-embed-binary-data-in-your-script/
	
    try {
        $ByteArray = [System.IO.File]::ReadAllBytes($FilePath);
    }
    catch {
        throw "Failed to read file. Please ensure that you have permission to the file, and that the file path is correct.";
    }

    if ($ByteArray) {
        $Base64String = [System.Convert]::ToBase64String($ByteArray);
    }
    else {
        throw '$ByteArray is $null.';
    }

    Write-Output -InputObject $Base64String;
}

function Convert-StringToBinary {
    [CmdletBinding()]
    param (
          [string] $InputString
        , [string] $FilePath = ('{0}\{1}' -f $env:TEMP, [System.Guid]::NewGuid().ToString())
    )
	# $TargetFile = Convert-StringToBinary -InputString $NewExe -FilePath C:\temp\new.exe;
	# Start-Process -FilePath $TargetFile.FullName;
	# http://trevorsullivan.net/2012/07/24/powershell-embed-binary-data-in-your-script/
	
	if (Test-Path $FilePath) { Remove-Item $FilePath -force }
	
    try {
        if ($InputString.Length -ge 1) {
            $ByteArray = [System.Convert]::FromBase64String($InputString);
            [System.IO.File]::WriteAllBytes($FilePath, $ByteArray);
        }
    }
    catch {
        throw ('Failed to create file from Base64 string: {0}' -f $FilePath);
    }

    Write-Output -InputObject (Get-Item -Path $FilePath);
}

function Get-Entropy {
<#
.SYNOPSIS

Calculates the entropy of a file or byte array.

Author: Matthew Graeber (@mattifestation)
License: BSD 3-Clause
Required Dependencies: None
Optional Dependencies: None

.PARAMETER ByteArray

Specifies the byte array containing the data from which entropy will be calculated.

.PARAMETER FilePath

Specifies the path to the input file from which entropy will be calculated.

.EXAMPLE

Get-Entropy -FilePath C:\Windows\System32\kernel32.dll

.EXAMPLE

ls C:\Windows\System32\*.dll | % { Get-Entropy -FilePath $_ }

.EXAMPLE

C:\PS>$RandArray = New-Object Byte[](10000)
C:\PS>foreach ($Offset in 0..9999) { $RandArray[$Offset] = [Byte] (Get-Random -Min 0 -Max 256) }
C:\PS>$RandArray | Get-Entropy

Description
-----------
Calculates the entropy of a large array containing random bytes.

.EXAMPLE

0..255 | Get-Entropy

Description
-----------
Calculates the entropy of 0-255. This should equal exactly 8.

.OUTPUTS

System.Double

Get-Entropy outputs a double representing the entropy of the byte array.
#>

    [CmdletBinding()] Param (
        [Parameter(Mandatory = $True, Position = 0, ValueFromPipeline = $True, ParameterSetName = 'Bytes')]
        [ValidateNotNullOrEmpty()]
        [Byte[]]
        $ByteArray,

        [Parameter(Mandatory = $True, Position = 0, ParameterSetName = 'File')]
        [ValidateNotNullOrEmpty()]
        [IO.FileInfo]
        $FilePath
    )

    BEGIN
    {
        $FrequencyTable = @{}
        $ByteArrayLength = 0
    }

    PROCESS
    {
        if ($PsCmdlet.ParameterSetName -eq 'File')
        {
            $ByteArray = [IO.File]::ReadAllBytes($FilePath.FullName)
        }

        foreach ($Byte in $ByteArray)
        {
            $FrequencyTable[$Byte]++
            $ByteArrayLength++
        }
    }

    END
    {
        $Entropy = 0.0

        foreach ($Byte in 0..255)
        {
            $ByteProbability = ([Double] $FrequencyTable[[Byte]$Byte]) / $ByteArrayLength
            if ($ByteProbability -gt 0)
            {
                $Entropy += -$ByteProbability * [Math]::Log($ByteProbability, 2)
            }
        }

        Write-Output $Entropy
    }
}

function Get-SystemInfo {
<#
.SYNOPSIS

A wrapper for kernel32!GetSystemInfo

Author: Matthew Graeber (@mattifestation)
License: BSD 3-Clause
Required Dependencies: PSReflect module
Optional Dependencies: None
#>

    $Mod = New-InMemoryModule -ModuleName SysInfo

    $ProcessorType = psenum $Mod SYSINFO.PROCESSOR_ARCH UInt16 @{
        PROCESSOR_ARCHITECTURE_INTEL =   0
        PROCESSOR_ARCHITECTURE_MIPS =    1
        PROCESSOR_ARCHITECTURE_ALPHA =   2
        PROCESSOR_ARCHITECTURE_PPC =     3
        PROCESSOR_ARCHITECTURE_SHX =     4
        PROCESSOR_ARCHITECTURE_ARM =     5
        PROCESSOR_ARCHITECTURE_IA64 =    6
        PROCESSOR_ARCHITECTURE_ALPHA64 = 7
        PROCESSOR_ARCHITECTURE_AMD64 =   9
        PROCESSOR_ARCHITECTURE_UNKNOWN = 0xFFFF
    }

    $SYSTEM_INFO = struct $Mod SYSINFO.SYSTEM_INFO @{
        ProcessorArchitecture = field 0 $ProcessorType
        Reserved = field 1 Int16
        PageSize = field 2 Int32
        MinimumApplicationAddress = field 3 IntPtr
        MaximumApplicationAddress = field 4 IntPtr
        ActiveProcessorMask = field 5 IntPtr
        NumberOfProcessors = field 6 Int32
        ProcessorType = field 7 Int32
        AllocationGranularity = field 8 Int32
        ProcessorLevel = field 9 Int16
        ProcessorRevision = field 10 Int16
    }

    $FunctionDefinitions = @(
        (func kernel32 GetSystemInfo ([Void]) @($SYSTEM_INFO.MakeByRefType()))
    )

    $Types = $FunctionDefinitions | Add-Win32Type -Module $Mod -Namespace 'Win32SysInfo'
    $Kernel32 = $Types['kernel32']

    $SysInfo = [Activator]::CreateInstance($SYSTEM_INFO)
    $Kernel32::GetSystemInfo([Ref] $SysInfo)

    $SysInfo
}

function Get-VirtualMemoryInfo {
<#
.SYNOPSIS

A wrapper for kernel32!VirtualQueryEx

Author: Matthew Graeber (@mattifestation)
License: BSD 3-Clause
Required Dependencies: PSReflect module
Optional Dependencies: None

.PARAMETER ProcessID

Specifies the process ID.

.PARAMETER ModuleBaseAddress

Specifies the address of the memory to be queried.

.PARAMETER PageSize

Specifies the system page size. Defaults to 0x1000 if one is not
specified.

.EXAMPLE

Get-VirtualMemoryInfo -ProcessID $PID -ModuleBaseAddress 0
#>

    Param (
        [Parameter(Position = 0, Mandatory = $True)]
        [ValidateScript({Get-Process -Id $_})]
        [Int]
        $ProcessID,

        [Parameter(Position = 1, Mandatory = $True)]
        [IntPtr]
        $ModuleBaseAddress,

        [Int]
        $PageSize = 0x1000
    )

    $Mod = New-InMemoryModule -ModuleName MemUtils

    $MemProtection = psenum $Mod MEMUTIL.MEM_PROTECT Int32 @{
        PAGE_EXECUTE =           0x00000010
        PAGE_EXECUTE_READ =      0x00000020
        PAGE_EXECUTE_READWRITE = 0x00000040
        PAGE_EXECUTE_WRITECOPY = 0x00000080
        PAGE_NOACCESS =          0x00000001
        PAGE_READONLY =          0x00000002
        PAGE_READWRITE =         0x00000004
        PAGE_WRITECOPY =         0x00000008
        PAGE_GUARD =             0x00000100
        PAGE_NOCACHE =           0x00000200
        PAGE_WRITECOMBINE =      0x00000400
    } -Bitfield

    $MemState = psenum $Mod MEMUTIL.MEM_STATE Int32 @{
        MEM_COMMIT =  0x00001000
        MEM_FREE =    0x00010000
        MEM_RESERVE = 0x00002000
    } -Bitfield

    $MemType = psenum $Mod MEMUTIL.MEM_TYPE Int32 @{
        MEM_IMAGE =   0x01000000
        MEM_MAPPED =  0x00040000
        MEM_PRIVATE = 0x00020000
    } -Bitfield

    if ([IntPtr]::Size -eq 4) {
        $MEMORY_BASIC_INFORMATION = struct $Mod MEMUTIL.MEMORY_BASIC_INFORMATION @{
            BaseAddress = field 0 Int32
            AllocationBase = field 1 Int32
            AllocationProtect = field 2 $MemProtection
            RegionSize = field 3 Int32
            State = field 4 $MemState
            Protect = field 5 $MemProtection
            Type = field 6 $MemType
        }
    } else {
        $MEMORY_BASIC_INFORMATION = struct $Mod MEMUTIL.MEMORY_BASIC_INFORMATION @{
            BaseAddress = field 0 Int64
            AllocationBase = field 1 Int64
            AllocationProtect = field 2 $MemProtection
            Alignment1 = field 3 Int32
            RegionSize = field 4 Int64
            State = field 5 $MemState
            Protect = field 6 $MemProtection
            Type = field 7 $MemType
            Alignment2 = field 8 Int32
        }
    }

    $FunctionDefinitions = @(
        (func kernel32 VirtualQueryEx ([Int32]) @([IntPtr], [IntPtr], $MEMORY_BASIC_INFORMATION.MakeByRefType(), [Int]) -SetLastError),
        (func kernel32 OpenProcess ([IntPtr]) @([UInt32], [Bool], [UInt32]) -SetLastError),
        (func kernel32 CloseHandle ([Bool]) @([IntPtr]) -SetLastError)
    )

    $Types = $FunctionDefinitions | Add-Win32Type -Module $Mod -Namespace 'Win32MemUtils'
    $Kernel32 = $Types['kernel32']

    # Get handle to the process
    $hProcess = $Kernel32::OpenProcess(0x400, $False, $ProcessID) # PROCESS_QUERY_INFORMATION (0x00000400)

    if (-not $hProcess) {
        throw "Unable to get a process handle for process ID: $ProcessID"
    }

    $MemoryInfo = New-Object $MEMORY_BASIC_INFORMATION
    $BytesRead = $Kernel32::VirtualQueryEx($hProcess, $ModuleBaseAddress, [Ref] $MemoryInfo, $PageSize)

    $null = $Kernel32::CloseHandle($hProcess)

    $Fields = @{
        BaseAddress = $MemoryInfo.BaseAddress
        AllocationBase = $MemoryInfo.AllocationBase
        AllocationProtect = $MemoryInfo.AllocationProtect
        RegionSize = $MemoryInfo.RegionSize
        State = $MemoryInfo.State
        Protect = $MemoryInfo.Protect
        Type = $MemoryInfo.Type
    }

    $Result = New-Object PSObject -Property $Fields
    $Result.PSObject.TypeNames.Insert(0, 'MEM.INFO')

    $Result
}

filter Get-ProcessMemoryInfo {
<#
.SYNOPSIS

Retrieve virtual memory information for every unique set of pages in
user memory. This function is similar to the !vadump WinDbg command.

Author: Matthew Graeber (@mattifestation)
License: BSD 3-Clause
Required Dependencies: PSReflect module
                       Get-SystemInfo
                       Get-VirtualMemoryInfo
Optional Dependencies: None

.PARAMETER ProcessID

Specifies the process ID.

.EXAMPLE

Get-ProcessMemoryInfo -ProcessID $PID
#>

    Param (
        [Parameter(ParameterSetName = 'InMemory', Position = 0, Mandatory = $True, ValueFromPipelineByPropertyName = $True)]
        [Alias('Id')]
        [ValidateScript({Get-Process -Id $_})]
        [Int]
        $ProcessID
    )

    $SysInfo = Get-SystemInfo

    $MemoryInfo = Get-VirtualMemoryInfo -ProcessID $ProcessID -ModuleBaseAddress ([IntPtr]::Zero) -PageSize $SysInfo.PageSize

    $MemoryInfo

    while (($MemoryInfo.BaseAddress + $MemoryInfo.RegionSize) -lt $SysInfo.MaximumApplicationAddress) {
        $BaseAllocation = [IntPtr] ($MemoryInfo.BaseAddress + $MemoryInfo.RegionSize)
        $MemoryInfo = Get-VirtualMemoryInfo -ProcessID $ProcessID -ModuleBaseAddress $BaseAllocation -PageSize $SysInfo.PageSize
        
        if ($MemoryInfo.State -eq 0) { break }
        $MemoryInfo
    }
}

# -------- PSReflect -------------
# http://www.powershellmagazine.com/2014/09/25/easily-defining-enums-structs-and-win32-functions-in-memory/

function New-InMemoryModule
{
<#
.SYNOPSIS

Creates an in-memory assembly and module

Author: Matthew Graeber (@mattifestation)
License: BSD 3-Clause
Required Dependencies: None
Optional Dependencies: None
 
.DESCRIPTION

When defining custom enums, structs, and unmanaged functions, it is
necessary to associate to an assembly module. This helper function
creates an in-memory module that can be passed to the 'enum',
'struct', and Add-Win32Type functions.

.PARAMETER ModuleName

Specifies the desired name for the in-memory assembly and module. If
ModuleName is not provided, it will default to a GUID.

.EXAMPLE

$Module = New-InMemoryModule -ModuleName Win32
#>

    Param
    (
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [String]
        $ModuleName = [Guid]::NewGuid().ToString()
    )

    $LoadedAssemblies = [AppDomain]::CurrentDomain.GetAssemblies()

    foreach ($Assembly in $LoadedAssemblies) {
        if ($Assembly.FullName -and ($Assembly.FullName.Split(',')[0] -eq $ModuleName)) {
            return $Assembly
        }
    }

    $DynAssembly = New-Object Reflection.AssemblyName($ModuleName)
    $Domain = [AppDomain]::CurrentDomain
    $AssemblyBuilder = $Domain.DefineDynamicAssembly($DynAssembly, 'Run')
    $ModuleBuilder = $AssemblyBuilder.DefineDynamicModule($ModuleName, $False)

    return $ModuleBuilder
}

function func
{
    Param
    (
        [Parameter(Position = 0, Mandatory = $True)]
        [String]
        $DllName,

        [Parameter(Position = 1, Mandatory = $True)]
        [string]
        $FunctionName,

        [Parameter(Position = 2, Mandatory = $True)]
        [Type]
        $ReturnType,

        [Parameter(Position = 3)]
        [Type[]]
        $ParameterTypes,

        [Parameter(Position = 4)]
        [Runtime.InteropServices.CallingConvention]
        $NativeCallingConvention,

        [Parameter(Position = 5)]
        [Runtime.InteropServices.CharSet]
        $Charset,

        [Switch]
        $SetLastError
    )

    $Properties = @{
        DllName = $DllName
        FunctionName = $FunctionName
        ReturnType = $ReturnType
    }

    if ($ParameterTypes) { $Properties['ParameterTypes'] = $ParameterTypes }
    if ($NativeCallingConvention) { $Properties['NativeCallingConvention'] = $NativeCallingConvention }
    if ($Charset) { $Properties['Charset'] = $Charset }
    if ($SetLastError) { $Properties['SetLastError'] = $SetLastError }

    New-Object PSObject -Property $Properties
}

function Add-Win32Type
{
<#
.SYNOPSIS

Creates a .NET type for an unmanaged Win32 function.

Author: Matthew Graeber (@mattifestation)
License: BSD 3-Clause
Required Dependencies: None
Optional Dependencies: func
 
.DESCRIPTION

Add-Win32Type enables you to easily interact with unmanaged (i.e.
Win32 unmanaged) functions in PowerShell. After providing
Add-Win32Type with a function signature, a .NET type is created
using reflection (i.e. csc.exe is never called like with Add-Type).

The 'func' helper function can be used to reduce typing when defining
multiple function definitions.

.PARAMETER DllName

The name of the DLL.

.PARAMETER FunctionName

The name of the target function.

.PARAMETER ReturnType

The return type of the function.

.PARAMETER ParameterTypes

The function parameters.

.PARAMETER NativeCallingConvention

Specifies the native calling convention of the function. Defaults to
stdcall.

.PARAMETER Charset

If you need to explicitly call an 'A' or 'W' Win32 function, you can
specify the character set.

.PARAMETER SetLastError

Indicates whether the callee calls the SetLastError Win32 API
function before returning from the attributed method.

.PARAMETER Module

The in-memory module that will host the functions. Use
New-InMemoryModule to define an in-memory module.

.PARAMETER Namespace

An optional namespace to prepend to the type. Add-Win32Type defaults
to a namespace consisting only of the name of the DLL.

.EXAMPLE

$Mod = New-InMemoryModule -ModuleName Win32

$FunctionDefinitions = @(
  (func kernel32 GetProcAddress ([IntPtr]) @([IntPtr], [String]) -Charset Ansi -SetLastError),
  (func kernel32 GetModuleHandle ([Intptr]) @([String]) -SetLastError),
  (func ntdll RtlGetCurrentPeb ([IntPtr]) @())
)

$Types = $FunctionDefinitions | Add-Win32Type -Module $Mod -Namespace 'Win32'
$Kernel32 = $Types['kernel32']
$Ntdll = $Types['ntdll']
$Ntdll::RtlGetCurrentPeb()
$ntdllbase = $Kernel32::GetModuleHandle('ntdll')
$Kernel32::GetProcAddress($ntdllbase, 'RtlGetCurrentPeb')

.NOTES

Inspired by Lee Holmes' Invoke-WindowsApi http://poshcode.org/2189

When defining multiple function prototypes, it is ideal to provide
Add-Win32Type with an array of function signatures. That way, they
are all incorporated into the same in-memory module.
#>

    [OutputType([Hashtable])]
    Param(
        [Parameter(Mandatory = $True, ValueFromPipelineByPropertyName = $True)]
        [String]
        $DllName,

        [Parameter(Mandatory = $True, ValueFromPipelineByPropertyName = $True)]
        [String]
        $FunctionName,

        [Parameter(Mandatory = $True, ValueFromPipelineByPropertyName = $True)]
        [Type]
        $ReturnType,

        [Parameter(ValueFromPipelineByPropertyName = $True)]
        [Type[]]
        $ParameterTypes,

        [Parameter(ValueFromPipelineByPropertyName = $True)]
        [Runtime.InteropServices.CallingConvention]
        $NativeCallingConvention = [Runtime.InteropServices.CallingConvention]::StdCall,

        [Parameter(ValueFromPipelineByPropertyName = $True)]
        [Runtime.InteropServices.CharSet]
        $Charset = [Runtime.InteropServices.CharSet]::Auto,

        [Parameter(ValueFromPipelineByPropertyName = $True)]
        [Switch]
        $SetLastError,

        [Parameter(Mandatory = $True)]
        [ValidateScript({($_ -is [Reflection.Emit.ModuleBuilder]) -or ($_ -is [Reflection.Assembly])})]
        $Module,

        [ValidateNotNull()]
        [String]
        $Namespace = ''
    )

    BEGIN
    {
        $TypeHash = @{}
    }

    PROCESS
    {
        if ($Module -is [Reflection.Assembly])
        {
            if ($Namespace)
            {
                $TypeHash[$DllName] = $Module.GetType("$Namespace.$DllName")
            }
            else
            {
                $TypeHash[$DllName] = $Module.GetType($DllName)
            }
        }
        else
        {
            # Define one type for each DLL
            if (!$TypeHash.ContainsKey($DllName))
            {
                if ($Namespace)
                {
                    $TypeHash[$DllName] = $Module.DefineType("$Namespace.$DllName", 'Public,BeforeFieldInit')
                }
                else
                {
                    $TypeHash[$DllName] = $Module.DefineType($DllName, 'Public,BeforeFieldInit')
                }
            }

            $Method = $TypeHash[$DllName].DefineMethod(
                $FunctionName,
                'Public,Static,PinvokeImpl',
                $ReturnType,
                $ParameterTypes)

            # Make each ByRef parameter an Out parameter
            $i = 1
            foreach($Parameter in $ParameterTypes)
            {
                if ($Parameter.IsByRef)
                {
                    [void] $Method.DefineParameter($i, 'Out', $null)
                }

                $i++
            }

            $DllImport = [Runtime.InteropServices.DllImportAttribute]
            $SetLastErrorField = $DllImport.GetField('SetLastError')
            $CallingConventionField = $DllImport.GetField('CallingConvention')
            $CharsetField = $DllImport.GetField('CharSet')
            if ($SetLastError) { $SLEValue = $True } else { $SLEValue = $False }

            # Equivalent to C# version of [DllImport(DllName)]
            $Constructor = [Runtime.InteropServices.DllImportAttribute].GetConstructor([String])
            $DllImportAttribute = New-Object Reflection.Emit.CustomAttributeBuilder($Constructor,
                $DllName, [Reflection.PropertyInfo[]] @(), [Object[]] @(),
                [Reflection.FieldInfo[]] @($SetLastErrorField, $CallingConventionField, $CharsetField),
                [Object[]] @($SLEValue, ([Runtime.InteropServices.CallingConvention] $NativeCallingConvention), ([Runtime.InteropServices.CharSet] $Charset)))

            $Method.SetCustomAttribute($DllImportAttribute)
        }
    }

    END
    {
        if ($Module -is [Reflection.Assembly])
        {
            return $TypeHash
        }

        $ReturnTypes = @{}

        foreach ($Key in $TypeHash.Keys)
        {
            $Type = $TypeHash[$Key].CreateType()
            
            $ReturnTypes[$Key] = $Type
        }

        return $ReturnTypes
    }
}

function psenum
{
<#
.SYNOPSIS

Creates an in-memory enumeration for use in your PowerShell session.

Author: Matthew Graeber (@mattifestation)
License: BSD 3-Clause
Required Dependencies: None
Optional Dependencies: None
 
.DESCRIPTION

The 'psenum' function facilitates the creation of enums entirely in
memory using as close to a "C style" as PowerShell will allow.

.PARAMETER Module

The in-memory module that will host the enum. Use
New-InMemoryModule to define an in-memory module.

.PARAMETER FullName

The fully-qualified name of the enum.

.PARAMETER Type

The type of each enum element.

.PARAMETER EnumElements

A hashtable of enum elements.

.PARAMETER Bitfield

Specifies that the enum should be treated as a bitfield.

.EXAMPLE

$Mod = New-InMemoryModule -ModuleName Win32

$ImageSubsystem = psenum $Mod PE.IMAGE_SUBSYSTEM UInt16 @{
    UNKNOWN =                  0
    NATIVE =                   1 # Image doesn't require a subsystem.
    WINDOWS_GUI =              2 # Image runs in the Windows GUI subsystem.
    WINDOWS_CUI =              3 # Image runs in the Windows character subsystem.
    OS2_CUI =                  5 # Image runs in the OS/2 character subsystem.
    POSIX_CUI =                7 # Image runs in the Posix character subsystem.
    NATIVE_WINDOWS =           8 # Image is a native Win9x driver.
    WINDOWS_CE_GUI =           9 # Image runs in the Windows CE subsystem.
    EFI_APPLICATION =          10
    EFI_BOOT_SERVICE_DRIVER =  11
    EFI_RUNTIME_DRIVER =       12
    EFI_ROM =                  13
    XBOX =                     14
    WINDOWS_BOOT_APPLICATION = 16
}

.NOTES

PowerShell purists may disagree with the naming of this function but
again, this was developed in such a way so as to emulate a "C style"
definition as closely as possible. Sorry, I'm not going to name it
New-Enum. :P
#>

    [OutputType([Type])]
    Param
    (
        [Parameter(Position = 0, Mandatory = $True)]
        [ValidateScript({($_ -is [Reflection.Emit.ModuleBuilder]) -or ($_ -is [Reflection.Assembly])})]
        $Module,

        [Parameter(Position = 1, Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [String]
        $FullName,

        [Parameter(Position = 2, Mandatory = $True)]
        [Type]
        $Type,

        [Parameter(Position = 3, Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [Hashtable]
        $EnumElements,

        [Switch]
        $Bitfield
    )

    if ($Module -is [Reflection.Assembly])
    {
        return ($Module.GetType($FullName))
    }

    $EnumType = $Type -as [Type]

    $EnumBuilder = $Module.DefineEnum($FullName, 'Public', $EnumType)

    if ($Bitfield)
    {
        $FlagsConstructor = [FlagsAttribute].GetConstructor(@())
        $FlagsCustomAttribute = New-Object Reflection.Emit.CustomAttributeBuilder($FlagsConstructor, @())
        $EnumBuilder.SetCustomAttribute($FlagsCustomAttribute)
    }

    foreach ($Key in $EnumElements.Keys)
    {
        # Apply the specified enum type to each element
        $null = $EnumBuilder.DefineLiteral($Key, $EnumElements[$Key] -as $EnumType)
    }

    $EnumBuilder.CreateType()
}

function field
{
    Param
    (
        [Parameter(Position = 0, Mandatory = $True)]
        [UInt16]
        $Position,
        
        [Parameter(Position = 1, Mandatory = $True)]
        [Type]
        $Type,
        
        [Parameter(Position = 2)]
        [UInt16]
        $Offset,
        
        [Object[]]
        $MarshalAs
    )

    @{
        Position = $Position
        Type = $Type -as [Type]
        Offset = $Offset
        MarshalAs = $MarshalAs
    }
}

function struct
{
<#
.SYNOPSIS

Creates an in-memory struct for use in your PowerShell session.

Author: Matthew Graeber (@mattifestation)
License: BSD 3-Clause
Required Dependencies: None
Optional Dependencies: field
 
.DESCRIPTION

The 'struct' function facilitates the creation of structs entirely in
memory using as close to a "C style" as PowerShell will allow. Struct
fields are specified using a hashtable where each field of the struct
is comprosed of the order in which it should be defined, its .NET
type, and optionally, its offset and special marshaling attributes.

One of the features of 'struct' is that after your struct is defined,
it will come with a built-in GetSize method as well as an explicit
converter so that you can easily cast an IntPtr to the struct without
relying upon calling SizeOf and/or PtrToStructure in the Marshal
class.

.PARAMETER Module

The in-memory module that will host the struct. Use
New-InMemoryModule to define an in-memory module.

.PARAMETER FullName

The fully-qualified name of the struct.

.PARAMETER StructFields

A hashtable of fields. Use the 'field' helper function to ease
defining each field.

.PARAMETER PackingSize

Specifies the memory alignment of fields.

.PARAMETER ExplicitLayout

Indicates that an explicit offset for each field will be specified.

.EXAMPLE

$Mod = New-InMemoryModule -ModuleName Win32

$ImageDosSignature = psenum $Mod PE.IMAGE_DOS_SIGNATURE UInt16 @{
    DOS_SIGNATURE =    0x5A4D
    OS2_SIGNATURE =    0x454E
    OS2_SIGNATURE_LE = 0x454C
    VXD_SIGNATURE =    0x454C
}

$ImageDosHeader = struct $Mod PE.IMAGE_DOS_HEADER @{
    e_magic =    field 0 $ImageDosSignature
    e_cblp =     field 1 UInt16
    e_cp =       field 2 UInt16
    e_crlc =     field 3 UInt16
    e_cparhdr =  field 4 UInt16
    e_minalloc = field 5 UInt16
    e_maxalloc = field 6 UInt16
    e_ss =       field 7 UInt16
    e_sp =       field 8 UInt16
    e_csum =     field 9 UInt16
    e_ip =       field 10 UInt16
    e_cs =       field 11 UInt16
    e_lfarlc =   field 12 UInt16
    e_ovno =     field 13 UInt16
    e_res =      field 14 UInt16[] -MarshalAs @('ByValArray', 4)
    e_oemid =    field 15 UInt16
    e_oeminfo =  field 16 UInt16
    e_res2 =     field 17 UInt16[] -MarshalAs @('ByValArray', 10)
    e_lfanew =   field 18 Int32
}

# Example of using an explicit layout in order to create a union.
$TestUnion = struct $Mod TestUnion @{
    field1 = field 0 UInt32 0
    field2 = field 1 IntPtr 0
} -ExplicitLayout

.NOTES

PowerShell purists may disagree with the naming of this function but
again, this was developed in such a way so as to emulate a "C style"
definition as closely as possible. Sorry, I'm not going to name it
New-Struct. :P
#>

    [OutputType([Type])]
    Param
    (
        [Parameter(Position = 1, Mandatory = $True)]
        [ValidateScript({($_ -is [Reflection.Emit.ModuleBuilder]) -or ($_ -is [Reflection.Assembly])})]
        $Module,

        [Parameter(Position = 2, Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [String]
        $FullName,

        [Parameter(Position = 3, Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [Hashtable]
        $StructFields,

        [Reflection.Emit.PackingSize]
        $PackingSize = [Reflection.Emit.PackingSize]::Unspecified,

        [Switch]
        $ExplicitLayout
    )

    if ($Module -is [Reflection.Assembly])
    {
        return ($Module.GetType($FullName))
    }

    [Reflection.TypeAttributes] $StructAttributes = 'AnsiClass,
        Class,
        Public,
        Sealed,
        BeforeFieldInit'

    if ($ExplicitLayout)
    {
        $StructAttributes = $StructAttributes -bor [Reflection.TypeAttributes]::ExplicitLayout
    }
    else
    {
        $StructAttributes = $StructAttributes -bor [Reflection.TypeAttributes]::SequentialLayout
    }

    $StructBuilder = $Module.DefineType($FullName, $StructAttributes, [ValueType], $PackingSize)
    $ConstructorInfo = [Runtime.InteropServices.MarshalAsAttribute].GetConstructors()[0]
    $SizeConst = @([Runtime.InteropServices.MarshalAsAttribute].GetField('SizeConst'))

    $Fields = New-Object Hashtable[]($StructFields.Count)

    # Sort each field according to the orders specified
    # Unfortunately, PSv2 doesn't have the luxury of the
    # hashtable [Ordered] accelerator.
    foreach ($Field in $StructFields.Keys)
    {
        $Index = $StructFields[$Field]['Position']
        $Fields[$Index] = @{FieldName = $Field; Properties = $StructFields[$Field]}
    }

    foreach ($Field in $Fields)
    {
        $FieldName = $Field['FieldName']
        $FieldProp = $Field['Properties']

        $Offset = $FieldProp['Offset']
        $Type = $FieldProp['Type']
        $MarshalAs = $FieldProp['MarshalAs']

        $NewField = $StructBuilder.DefineField($FieldName, $Type, 'Public')

        if ($MarshalAs)
        {
            $UnmanagedType = $MarshalAs[0] -as ([Runtime.InteropServices.UnmanagedType])
            if ($MarshalAs[1])
            {
                $Size = $MarshalAs[1]
                $AttribBuilder = New-Object Reflection.Emit.CustomAttributeBuilder($ConstructorInfo,
                    $UnmanagedType, $SizeConst, @($Size))
            }
            else
            {
                $AttribBuilder = New-Object Reflection.Emit.CustomAttributeBuilder($ConstructorInfo, [Object[]] @($UnmanagedType))
            }
            
            $NewField.SetCustomAttribute($AttribBuilder)
        }

        if ($ExplicitLayout) { $NewField.SetOffset($Offset) }
    }

    # Make the struct aware of its own size.
    # No more having to call [Runtime.InteropServices.Marshal]::SizeOf!
    $SizeMethod = $StructBuilder.DefineMethod('GetSize',
        'Public, Static',
        [Int],
        [Type[]] @())
    $ILGenerator = $SizeMethod.GetILGenerator()
    # Thanks for the help, Jason Shirk!
    $ILGenerator.Emit([Reflection.Emit.OpCodes]::Ldtoken, $StructBuilder)
    $ILGenerator.Emit([Reflection.Emit.OpCodes]::Call,
        [Type].GetMethod('GetTypeFromHandle'))
    $ILGenerator.Emit([Reflection.Emit.OpCodes]::Call,
        [Runtime.InteropServices.Marshal].GetMethod('SizeOf', [Type[]] @([Type])))
    $ILGenerator.Emit([Reflection.Emit.OpCodes]::Ret)

    # Allow for explicit casting from an IntPtr
    # No more having to call [Runtime.InteropServices.Marshal]::PtrToStructure!
    $ImplicitConverter = $StructBuilder.DefineMethod('op_Implicit',
        'PrivateScope, Public, Static, HideBySig, SpecialName',
        $StructBuilder,
        [Type[]] @([IntPtr]))
    $ILGenerator2 = $ImplicitConverter.GetILGenerator()
    $ILGenerator2.Emit([Reflection.Emit.OpCodes]::Nop)
    $ILGenerator2.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $ILGenerator2.Emit([Reflection.Emit.OpCodes]::Ldtoken, $StructBuilder)
    $ILGenerator2.Emit([Reflection.Emit.OpCodes]::Call,
        [Type].GetMethod('GetTypeFromHandle'))
    $ILGenerator2.Emit([Reflection.Emit.OpCodes]::Call,
        [Runtime.InteropServices.Marshal].GetMethod('PtrToStructure', [Type[]] @([IntPtr], [Type])))
    $ILGenerator2.Emit([Reflection.Emit.OpCodes]::Unbox_Any, $StructBuilder)
    $ILGenerator2.Emit([Reflection.Emit.OpCodes]::Ret)

    $StructBuilder.CreateType()
}

#endregion Helper Functions


##################     MAIN     ##################

Write-Verbose "Starting Scan"

# Scan Start Time:
$Scan_start = Get-date

# Grab Dependencies:
$autorunscPath="C:\Windows\temp\autorunsc.exe"
$SigcheckPath="C:\Windows\temp\sigcheck.exe"
	
# Hardcode Hash (TODO: impliment more better authentication mechanism, maybe a signature check for MS)
if ([IntPtr]::Size -eq "8") {	
	$autorunsURL = "http://live.sysinternals.com/autorunsc64.exe"
	$autorunsHash = "8A92A525B0BB752E0C2A4ED79555FBB6FA28202DEB17CA45D66DF96FA1063A95"
} else {
	$autorunsURL = "http://live.sysinternals.com/autorunsc.exe"
	$autorunsHash = "B7FBB91BEDC171B07457DC24DF46A00CDB786CFC2C2C80137A37935F0D737894"
}

# Download Autoruns if not in the target directory & verify it's actually right sigcheck
# $(get-AuthenticodeSignature myfile.exe).SignerCertificate.Subject <-- PS 3.0+
#if ( (Test-Path $autorunscPath) -AND ((Get-Hashes $autorunscPath).SHA256 -eq $autorunsHash) ) {
if (Test-Path $autorunscPath) {
} else {
	if (Invoke-DownloadFile $autorunsURL $autorunscPath) { } else { 
		Write-Error "Could not download Autorunsc from Microsoft Live"
		return $null
	}
}

# Hardcode Hash (TODO: impliment more better authentication mechanism, maybe a signature check for MS)
if ([IntPtr]::Size -eq "8") {	
	$SigcheckURL = "http://live.sysinternals.com/sigcheck64.exe"
	$SigcheckHash = "860CECD4BF4AFEAC0F6CCCA4BECFEBD0ABF06913197FC98AB2AE715F382F45BF"
} else {
	$SigcheckURL = "http://live.sysinternals.com/sigcheck.exe"
	$SigcheckHash = "92A9500E9AF8F2FBE77FB63CAF67BD6CC4CC110FA475ADFD88AED789FB515E6A"
}

# Download Autoruns if not in the target directory & verify it's actually right sigcheck
# $(get-AuthenticodeSignature myfile.exe).SignerCertificate.Subject <-- PS 3.0+
#if ( (Test-Path $SigcheckPath) -AND ((Get-Hashes $SigcheckPath).SHA256 -eq $SigcheckHash) ) {
if (Test-Path $SigcheckPath) {
} else {
	if (Invoke-DownloadFile $SigcheckURL $SigcheckPath) { } else { 
		Write-Error "Could not download Sigcheck from Microsoft Live"
		return $null
	}
}

# RUN TESTS AND BUILD HOST OBJECT 

# Get Host Info
$HostInfo = Get-HostInfo
try { $IPs = ([System.Net.Dns]::GetHostAddresses($HostInfo.DNSHostname)).IPAddressToString } catch { $IPs = $null }

# Build HostObject Metadata
Write-Verbose "Building HostObject"
$HostObjProperties = @{
	ObjectName			= $HostInfo.Name + "_HostObject"
	ObjGUID				= [Guid]::NewGuid().ToString()
	Version				= $Version
	ObjectType			= "psHunt_HostObject"
	Processed			= $False
	DateProcessed		= $Null
	SurveyStart			= $Scan_start
	IPAddresses			= $IPs
	Hostname			= $HostInfo.DNSHostname
}

$HostObject = New-Object PSObject -Property $HostObjProperties
$HostObject.PSObject.TypeNames.Insert(0, 'PSHunt_HostObject')

# Running Tests and adding to HostObject 
Write-Verbose "Running Tests and adding to HostObject"
$TestTimes = New-Object PSObject -Property @{
	SurveyStart = $Scan_start
}

#Do Autoruns as a background job (it takes too long normally)
#Write-Verbose "Running autoruns as a background job"
#$null = Start-Job -name ar -ScriptBlock $GetAutorunsSB

$HostObject | Add-Member -type NoteProperty -Name HostInfo 			-Value $HostInfo

$testtime = Get-Date
#$HostObject | Add-Member -type NoteProperty -Name InjectedModules 	-Value (Get-Process | Get-MemoryInjects)
$TestTimes  | Add-Member -type NoteProperty -Name InjectedModules 	-Value ((Get-Date)-$testtime).TotalSeconds

$testtime = Get-Date
$HostObject | Add-Member -type NoteProperty -Name ProcessList 		-Value (Get-Processes)
$TestTimes  | Add-Member -type NoteProperty -Name ProcessList 		-Value ((Get-Date)-$testtime).TotalSeconds

$testtime = Get-Date
$HostObject | Add-Member -type NoteProperty -Name Netstat 			-Value (Get-Netstat)
$TestTimes  | Add-Member -type NoteProperty -Name Netstat 			-Value ((Get-Date)-$testtime).TotalSeconds

$testtime = Get-Date
$HostObject | Add-Member -type NoteProperty -Name ModuleList		-Value (Get-Modules)
$TestTimes  | Add-Member -type NoteProperty -Name ModuleList 		-Value ((Get-Date)-$testtime).TotalSeconds

$testtime = Get-Date 
$HostObject | Add-Member -type NoteProperty -Name Autoruns 			-Value (Invoke-Autorunsc)
$TestTimes  | Add-Member -type NoteProperty -Name Autoruns 			-Value ((Get-Date)-$testtime).TotalSeconds

$testtime = Get-Date
$HostObject | Add-Member -type NoteProperty -Name DriverList 		-Value (Get-Drivers)
$TestTimes  | Add-Member -type NoteProperty -Name DriverList 		-Value ((Get-Date)-$testtime).TotalSeconds

$testtime = Get-Date
$HostObject | Add-Member -type NoteProperty -Name Accounts 			-Value (Get-AccountInfo)
$TestTimes  | Add-Member -type NoteProperty -Name Accounts 			-Value ((Get-Date)-$testtime).TotalSeconds

#$HostObject | Add-Member -type NoteProperty -Name Autostarts 		-Value (Get_Autostarts)
#$TestTimes  | Add-Member -type NoteProperty -Name Autostarts		-Value ((Get-Date)-$testtime).TotalSeconds

$testtime = Get-Date
$HostObject | Add-Member -type NoteProperty -Name Disks 			-Value (Get-DiskInfo)
$HostObject | Add-Member -type NoteProperty -Name NetworkConfig		-Value (Get-NetworkConfig)
$HostObject | Add-Member -type NoteProperty -Name Pipes 			-Value (Get-Pipes)
$HostObject | Add-Member -type NoteProperty -Name OldestEventlog	-Value (Get_OldestLog)
$HostObject | Add-Member -type NoteProperty -Name FirewallRules		-Value (Get-FirewallRules)
$HostObject | Add-Member -type NoteProperty -Name Misc				-Value (Get-InterestingStuff)
$HostObject | Add-Member -type NoteProperty -Name InstalledApps		-Value (Get-InstalledApps)
$TestTimes  | Add-Member -type NoteProperty -Name Misc	 			-Value ((Get-Date)-$testtime).TotalSeconds

#Get Autoruns output
#Write-Verbose "Getting Job results"
#Get-Job -name ar | Wait-Job | out-null
#$HostObject | Add-Member -type NoteProperty -Name Autoruns 	-Value (Receive-Job -name ar)
#Remove-Job -name ar

$Scan_complete = Get-date

# Add scan metadata
$HostObject  | Add-Member -type NoteProperty -Name SurveyStop -Value $Scan_complete
$TestTimes  | Add-Member -type NoteProperty -Name SurveyStop -Value $Scan_complete
$TestTimes  | Add-Member -type NoteProperty -Name SurveyRunTime  -Value ($Scan_complete - $Scan_start).totalseconds
$HostObject | Add-Member -type NoteProperty -Name TestTimes -Value $TestTimes

# Return Results:

Switch ($ReturnType) {
	"NoDrop" { return $HostObject }
	"DropToDisk" {
		# Drop to Disk
		# Export Object to XML
		Write-Verbose "Exporting HostObject!"
		$HostObject | Export-CliXML $OutPath -encoding 'UTF8' -force
	}
	"HTTPPostback" {
		# Post to Web Server
		Write-Verbose "Posting results to web server"
		# $ReturnAddress = "http://www.YourDomainName.com/ClientFiles/"
		$destinationFilePath = $ReturnAddress + $SurveyOut
		$wc = New-Object System.Net.WebClient
		if ($WebCredentials) { 
			$wc.Credentials = $WebCredentials.GetNetworkCredentials() 
		} else {
			$wc.UseDefaultCredentials = $true
		}
		try { 
			$wc.UploadFile($destinationFilePath, "PUT", $OutPath)
		} 
		catch {
			Write-Warning "Error posting to web server, dropping to disk"
			# Export Object to XML
			Write-Verbose "Exporting HostObject!"
			$HostObject | Export-CliXML $OutPath -encoding 'UTF8' -force
		} 
		finally {
			$wc.Dispose()
		}	
	}
	"FTPPostback" {
		# Post to FTP Server
		Write-Verbose "Posting results to ftp server"
		# $ReturnAddress = "ftp://www.YourDomainName.com/ClientFiles/"
		$destinationFilePath = $ReturnAddress + $SurveyOut
		$uri = New-Object System.Uri($ftpAddress+$SurveyOut) 
		$wc = New-Object System.Net.WebClient
		if ($WebCredentials) { 
			$wc.Credentials = $WebCredentials.GetNetworkCredentials() 
		} else {
			$wc.UseDefaultCredentials = $true
		}
		try { 
			$wc.UploadFile($uri, $OutPath) 
		} 
		catch {
			Write-Warning "Error posting to FTP server, dropping to disk"
			# Export Object to XML
			Write-Verbose "Exporting HostObject!"
			$HostObject | Export-CliXML $OutPath -encoding 'UTF8' -force
		} 
		finally {
			$wc.Dispose()
		}
	}
} 

Write-Verbose "Scan Complete!"

# Cleanup temp files and delete the survey script (if not running interactively)
if (($ScriptPath) -AND ($ScriptDir -match "^C:\\Windows*")) { 
	Remove-Item $ScriptPath
	#have to do this or it sometimes freezes
	[System.Diagnostics.Process]::GetCurrentProcess().Kill()
}
