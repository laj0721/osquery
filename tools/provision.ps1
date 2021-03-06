#  Copyright (c) 2014-present, Facebook, Inc.
#  All rights reserved.
#
#  This source code is licensed under the BSD-style license found in the
#  LICENSE file in the root directory of this source tree. An additional grant
#  of patent rights can be found in the PATENTS file in the same directory.

# We make heavy use of Write-Host, because colors are awesome. #dealwithit.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", '', Scope="Function", Target="*")]
param()

# URL of where our pre-compiled third-party dependenices are archived
$THIRD_PARTY_ARCHIVE_URL = 'https://osquery-packages.s3.amazonaws.com/choco'

# Adapted from http://www.jonathanmedd.net/2014/01/testing-for-admin-privileges-in-powershell.html
function Test-IsAdmin {
  return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] "Administrator"
  )
}

function Test-RebootPending {
  $compBasedServ = Get-ChildItem "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" -ErrorAction Ignore
  $winUpdate = Get-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" -ErrorAction Ignore
  $ccm = $false
  try {
    $util = [wmiclass]"\\.\root\ccm\clientsdk:CCM_ClientUtilities"
    $status = $util.DetermineIfRebootPending()
    if(($null -ne $status) -and $status.RebootPending){
      $ccm = $true
    }
  } catch {
    $ccm = $false
  }
  return $compBasedServ -or $winUpdate -or $ccm
}

# Checks if a package is already installed through chocolatey
# Returns true if:
#  * The package is installed and the user supplies no version
#  * The package is installed and the version matches the user supplied version
function Test-ChocoPackageInstalled {
param(
  [string] $packageName = '',
  [string] $packageVersion = ''
)
  $out = choco list -lr

  # Parse through the locally installed chocolatey packages and look
  # to see if the supplied package already exists
  ForEach ($pkg in $out) {
    $name, $version = $pkg -split '\|'
    if ($name -eq $packageName) {
      if ($packageVersion -ne "" -and $packageVersion -ne $version) {
        return $false;
      }
      return $true;
    }
  }
  return $false
}

# Installs the Powershell Analzyer: https://github.com/PowerShell/PSScriptAnalyzer
function Install-PowershellLinter {
  [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact="Medium")]
  param()
  if (-not $PSCmdlet.ShouldProcess('PSScriptAnalyzer')) {
    Exit -1
  }

  $nugetProviderInstalled = $false
  Write-Host " => Determining whether NuGet package provider is already installed." -foregroundcolor DarkYellow
  foreach ($provider in Get-PackageProvider) {
    if ($provider.Name -eq "NuGet" -and $provider.Version -ge 2.8.5.206) {
      $nugetProviderInstalled = $true
      break
    }
  }
  if (-not $nugetProviderInstalled) {
    Write-Host " => NuGet provider either not installed or out of date. Installing..." -foregroundcolor Cyan
    Install-PackageProvider -Name NuGet -Force
    Write-Host "[+] NuGet package provider installed!" -foregroundcolor Green
  } else {
    Write-Host "[*] NuGet provider already installed." -foregroundcolor Green
  }

  $psScriptAnalyzerInstalled = $false
  Write-Host " => Determining whether PSScriptAnalyzer is already installed." -foregroundcolor DarkYellow
  foreach ($module in Get-Module -ListAvailable) {
    if ($module.Name -eq "PSScriptAnalyzer" -and $module.Version -ge 1.7.0) {
      $psScriptAnalyzerInstalled = $true
      break
    }
  }
  if (-not $psScriptAnalyzerInstalled) {
    Write-Host " => PSScriptAnalyzer either not installed or out of date. Installing..." -foregroundcolor Cyan
    Install-Module -Name PSScriptAnalyzer -Force
    Write-Host "[+] PSScriptAnalyzer installed!" -foregroundcolor Green
  } else {
    Write-Host "[*] PSScriptAnalyzer already installed." -foregroundcolor Green
  }
}

# Attempts to install chocolatey if not already
function Install-Chocolatey {
  [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact="Medium")]
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingInvokeExpression", "")]
  param()
  if (-not $PSCmdlet.ShouldProcess('Chocolatey')) {
    Exit -1
  }
  Write-Host " => Attemping to detect presence of chocolatey..." -foregroundcolor DarkYellow
  if ($null -eq (Get-Command 'choco.exe' -ErrorAction SilentlyContinue)) {
    if (Test-Path $env:ALLUSERSPROFILE\chocolatey\bin) {
      Write-Host "[-] WARN: Chocolatey appears to be installed, but was not in path!" -foregroundcolor Yellow
    } else {
      Write-Host " => Did not find. Installing chocolatey..." -foregroundcolor Cyan
      Invoke-Expression ((new-object net.webclient).DownloadString('https://chocolatey.org/install.ps1'))
    }
    Write-Host " => Adding chocolatey to path."
    $env:Path = "$env:Path;$env:ALLUSERSPROFILE\chocolatey\bin"
  } else {
    Write-Host "[*] Chocolatey is already installed." -foregroundcolor Green
  }
}

# Attempts to install a chocolatey package of a specific version if
# not already there.
function Install-ChocoPackage {
  [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact="Medium")]
  param(
    [string] $packageName = '',
    [string] $packageVersion = '',
    [array] $packageOptions = @()
  )
  if (-not $PSCmdlet.ShouldProcess($packageName)) {
    Exit -1
  }
  Write-Host " => Determining whether $packageName is already installed..." -foregroundcolor DarkYellow
  $isInstalled = Test-ChocoPackageInstalled $packageName $packageVersion
  if (-not $isInstalled) {
    Write-Host " => Did not find. Installing $packageName $packageVersion" -foregroundcolor Cyan
    $args = @("install", "-y", "-r", "${packageName}")
    if ($packageVersion -ne '') {
      $args += @("--version", "${packageVersion}")
    }
    if ($packageOptions.count -gt 0) {
      Write-Host "Options: $packageOptions" -foregroundcolor Cyan
      $args += ${packageOptions}
    }
    choco ${args}
    if (@(3010,2147781575,-2147185721,-2147205120) -Contains $LastExitCode){
      $LastExitCode = 0
    }
    if ($LastExitCode -ne 0) {
      Write-Host "[-] ERROR: $packageName $packageVersion failed to install!" -foregroundcolor Red
      Exit -1
    }
    Write-Host "[+] Done." -foregroundcolor Green
  } else {
    Write-Host "[*] $packageName $packageVersion already installed." -foregroundcolor Green
  }
}

function Install-PipPackage {
  [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact="Medium")]
  param()
  if (-not $PSCmdlet.ShouldProcess('Pip required modules')) {
    Exit -1
  }
  Write-Host " => Attempting to install Python packages" -foregroundcolor DarkYellow
  $env:Path = "$env:Path;$env:HOMEDRIVE\tools\python2;$env:HOMEDRIVE\tools\python2\Scripts"
  if ($null -eq (Get-Command 'python.exe' -ErrorAction SilentlyContinue)) {
    Write-Host "[-] ERROR: failed to find python" -foregroundcolor Red
    Exit -1
  }
  if ($null -eq (Get-Command 'pip.exe' -ErrorAction SilentlyContinue)) {
    Write-Host "[-] ERROR: failed to find pip" -foregroundcolor Red
    Exit -1
  }
  $requirements = Resolve-Path ([System.IO.Path]::Combine($PSScriptRoot, '..', 'requirements.txt'))
  Write-Host " => Upgrading pip..." -foregroundcolor DarkYellow
  python -m pip -q install --upgrade pip
  if ($LastExitCode -ne 0) {
    Write-Host "[-] ERROR: pip upgrade failed." -foregroundcolor Red
    Exit -1
  }
  Write-Host " => Installing from requirements.txt" -foregroundcolor DarkYellow
  pip -q install -r $requirements.path
  if ($LastExitCode -ne 0) {
    Write-Host "[-] ERROR: Install packages from requirements failed." -foregroundcolor Red
    Exit -1
  }
}

function Install-ThirdParty {
  [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact="Medium")]
  param()
  if (-not $PSCmdlet.ShouldProcess('Thirdparty Chocolatey Libraries')) {
    Exit -1
  }
  Write-Host " => Retrieving third-party dependencies" -foregroundcolor DarkYellow

  # XXX: The code below exists because our chocolatey packages are not currently in the chocolatey
  #      repository. For now, we will download our packages locally and install from a local source.
  #      We also include the official source since thrift-dev depends on the chocolatey thrift package.
  #
  #      Once our chocolatey packages are added to the official repository, installing the third-party
  #      dependencies will be as easy as Install-ChocoPackage '<package-name>'.
  $packages = @(
    "boost-msvc14.1.59.0",
    "bzip2.1.0.6",
    "doxygen.1.8.11",
    "gflags-dev.2.1.2",
    "glog.0.3.4",
    "openssl.1.0.2",
    "rocksdb.4.4",
    "snappy-msvc.1.1.1.8",
    "thrift-dev.0.9.3",
    "cpp-netlib.0.12.0-r1",
    "linenoise-ng.1.0.0",
    "clang-format.3.9.0",
    "zlib.1.2.8"
  )
  $tmpDir = Join-Path $env:TEMP 'osquery-packages'
  Remove-Item $tmpDir -Recurse -ErrorAction Ignore
  New-Item -Force -Type directory -Path $tmpDir
  Try {
    foreach ($package in $packages) {
      $chocoForce = ""
      $packageData = $package -split '\.'
      $packageName = $packageData[0]
      $packageVersion = [string]::Join('.', $packageData[1..$packageData.length])

      Write-Host " => Determining whether $packageName is already installed..." -foregroundcolor DarkYellow
      $isInstalled = Test-ChocoPackageInstalled $packageName $packageVersion
      if ($isInstalled) {
        Write-Host "[*] $packageName $packageVersion already installed." -foregroundcolor Green
        continue
      }
      # Chocolatey package is installed, but version is off
      $oldVersionInstalled = Test-ChocoPackageInstalled $packageName
      if ($oldVersionInstalled) {
        Write-Host " => An old version of $packageName is installed. Forcing re-installation" -foregroundcolor Cyan
        $chocoForce = "-f"
      } else {
        Write-Host " => Did not find. Installing $packageName $packageVersion" -foregroundcolor Cyan
      }
      $downloadUrl = "$THIRD_PARTY_ARCHIVE_URL/$package.nupkg"
      $tmpFilePath = Join-Path $tmpDir "$package.nupkg"
      Write-Host " => Downloading $downloadUrl" -foregroundcolor DarkCyan
      Try {
        (New-Object net.webclient).DownloadFile($downloadUrl, $tmpFilePath)
      } catch [Net.WebException] {
        Write-Host "[-] ERROR: Downloading $package failed. Check connection?" -foregroundcolor Red
        Exit -1
      }
      choco install --pre -y -r $chocoForce $packageName --version=$packageVersion --source="$tmpDir;https://chocolatey.org/api/v2"
      if ($LastExitCode -ne 0) {
        Write-Host "[-] ERROR: Install of $package failed." -foregroundcolor Red
        Exit -1
      }
      Write-Host "[+] DONE" -foregroundcolor Green
    }
  } Finally {
    Remove-Item $tmpDir -Recurse
  }
}

function Update-GitSubmodule {
  [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact="Low")]
  param()
  if (-not $PSCmdlet.ShouldProcess('Git Submodules')) {
    Exit -1
  }
  if ($null -eq (Get-Command 'git.exe' -ErrorAction SilentlyContinue)) {
    Write-Host "[-] ERROR: Git was not found on the system. Install git." -foregroundcolor Red
    Exit -1
  }
  $thirdPartyPath = Resolve-Path ([System.IO.Path]::Combine($PSScriptRoot, '..', 'third-party'))
  Write-Host " => Updating git submodules in $thirdPartyPath ..." -foregroundcolor Yellow
  Push-Location $thirdPartyPath
  git submodule --quiet update --init
  Pop-Location
  Write-Host "[+] Submodules updated!" -foregroundcolor Yellow
}

function Main {
  if ($PSVersionTable.PSVersion.Major -lt 3.0 ) {
    Write-Output "This installer currently requires Powershell 3.0 or greater."
    Exit -1
  }

  Write-Host "[+] Provisioning a Win64 build environment for osquery" -foregroundcolor Yellow
  Write-Host " => Verifying script is running with Admin privileges" -foregroundcolor Yellow
  if (-not (Test-IsAdmin)) {
    Write-Host "[-] ERROR: Please run this script with Admin privileges!" -foregroundcolor Red
    Exit -1
  }
  Write-Host "[+] Success!" -foregroundcolor Green
  $out = Install-Chocolatey
  $out = Install-ChocoPackage 'cppcheck'
  $out = Install-ChocoPackage '7zip.commandline'
  $out = Install-ChocoPackage 'cmake.portable' '3.6.1'
  $out = Install-ChocoPackage 'python2' '2.7.11'
  $out = Install-PipPackage
  $out = Update-GitSubmodule
  $deploymentFile = Resolve-Path ([System.IO.Path]::Combine($PSScriptRoot, 'vsdeploy.xml'))
  $chocoParams = @("--execution-timeout", "7200", "-packageParameters", "--AdminFile ${deploymentFile}")
  $out = Install-ChocoPackage 'visualstudio2015community' '' ${chocoParams}
  if(Test-RebootPending -eq $true) {
    Write-Host "*** Windows requires a reboot to complete installing Visual Studio. Please reboot your system and re-run this provisioning script. ***" -foregroundcolor yellow
    Exit 0
  }
  $out = Install-ThirdParty
  if ($PSVersionTable.PSVersion.Major -lt 5.1 ) {
    Write-Host "[*] Powershell version is < 5.1. Skipping Powershell Linter Installation." -foregroundcolor yellow
  } else {
    $out = Install-PowershellLinter
  }
  Write-Host "[+] Done." -foregroundcolor Yellow
}

$null = Main
