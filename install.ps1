#
# slskd install script for Windows
#
# Usage:
#   irm https://slskd.org/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://slskd.org/install.ps1))) -Version 0.26.1
#   & ([scriptblock]::Create((irm https://slskd.org/install.ps1))) -Channel canary
#
# Run with -Help for all options.

<#
.SYNOPSIS
    Installs slskd for the current user.
.DESCRIPTION
    Downloads slskd from GitHub and installs it into a per-user directory, then adds that
    directory to the user's PATH.
.PARAMETER Channel
    Channel to install from: 'release' (default) or 'canary'. canary installs the latest
    successful build of the master branch from GitHub Actions.
.PARAMETER Version
    Release version to install, e.g. 0.26.1 (default: latest). Must be a tag from
    https://github.com/slskd/slskd/releases. Not valid with -Channel canary.
.PARAMETER InstallDir
    Directory to install slskd into. Default: %LOCALAPPDATA%\Programs\slskd (or $env:SLSKD_INSTALL_DIR)
.PARAMETER Architecture
    Override architecture detection: x64 or arm64.
.PARAMETER NoPath
    Do not add the install directory to the user's PATH.
.PARAMETER DryRun
    Show what would be downloaded and installed, then exit.
.PARAMETER Help
    Show this help.
.NOTES
    Set $env:GITHUB_TOKEN or $env:GH_TOKEN to use a GitHub token for API calls and canary downloads.
    Without one, canary builds are downloaded via nightly.link and API calls are subject to rate limits.
.EXAMPLE
    irm https://slskd.org/install.ps1 | iex
.EXAMPLE
    & ([scriptblock]::Create((irm https://slskd.org/install.ps1))) -Channel canary
#>
[CmdletBinding()]
param(
    [ValidateSet('release', 'canary')]
    [string]$Channel = 'release',
    [string]$Version = '',
    [string]$InstallDir = '',
    [ValidateSet('', 'x64', 'arm64')]
    [string]$Architecture = '',
    [switch]$NoPath,
    [switch]$DryRun,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$Repo = 'slskd/slskd'
$GitHubApi = "https://api.github.com/repos/$Repo"
$GitHubDownload = "https://github.com/$Repo/releases/download"
$NightlyLink = "https://nightly.link/$Repo/actions/runs"
$CanaryWorkflow = 'ci.yml'
$CanaryBranch = 'master'
$CanaryMaxRuns = 10

$Token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } elseif ($env:GH_TOKEN) { $env:GH_TOKEN } else { '' }

function Say([string]$Message) {
    Write-Host "slskd-install: $Message"
}

function Say-Verbose([string]$Message) {
    Write-Verbose "slskd-install: $Message"
}

function Say-Warning([string]$Message) {
    Write-Host "slskd-install: warning: $Message" -ForegroundColor Yellow
}

function Say-Success([string]$Message) {
    Write-Host "slskd-install: $Message" -ForegroundColor Green
}

function Fail([string]$Message) {
    throw "slskd-install: error: $Message"
}

function Get-Architecture {
    if ($Architecture) {
        return $Architecture
    }

    $arch = $null

    try {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    } catch {
        # RuntimeInformation isn't available on older .NET Framework versions; fall back to the environment.
        # PROCESSOR_ARCHITEW6432 is set when running in a 32-bit process on a 64-bit OS.
        $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    }

    switch -Regex ($arch) {
        '^(X64|AMD64)$' { return 'x64' }
        '^(Arm64|ARM64)$' { return 'arm64' }
        '^(X86|x86)$' { Fail "32-bit Windows isn't supported" }
        default { Fail "unsupported architecture '$arch'" }
    }
}

function Get-ApiHeaders {
    $headers = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'slskd-install' }

    if ($Token) {
        $headers['Authorization'] = "Bearer $Token"
    }

    return $headers
}

function Invoke-Api([string]$Url) {
    Say-Verbose "GET $Url"
    return Invoke-RestMethod -Uri $Url -Headers (Get-ApiHeaders) -UseBasicParsing
}

function Invoke-Download([string]$Url, [string]$OutFile) {
    Say-Verbose "GET $Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -Headers @{ 'User-Agent' = 'slskd-install' } -UseBasicParsing
}

function Get-LatestRelease {
    try {
        $release = Invoke-Api "$GitHubApi/releases/latest"
    } catch {
        Fail "failed to fetch the latest release from GitHub: $($_.Exception.Message)"
    }

    if (-not $release.tag_name) {
        Fail 'failed to determine the latest release version'
    }

    return $release.tag_name
}

# finds the newest successful canary build that has a non-expired artifact for the given rid
function Find-CanaryArtifact([string]$Rid) {
    try {
        $runs = Invoke-Api "$GitHubApi/actions/workflows/$CanaryWorkflow/runs?branch=$CanaryBranch&event=push&status=success&per_page=$CanaryMaxRuns"
    } catch {
        Fail "failed to fetch canary builds from GitHub. If you're rate limited, set GITHUB_TOKEN and try again. ($($_.Exception.Message))"
    }

    if (-not $runs.workflow_runs) {
        Fail "no successful canary builds found on the $CanaryBranch branch"
    }

    foreach ($run in $runs.workflow_runs) {
        try {
            $artifacts = Invoke-Api "$($run.artifacts_url)?per_page=100"
        } catch {
            continue
        }

        # artifacts look like slskd-0.26.1.65534+6a450e41-win-x64
        $artifact = $artifacts.artifacts |
            Where-Object { $_.name -match "^slskd-.*-$([regex]::Escape($Rid))$" -and -not $_.expired } |
            Select-Object -First 1

        if ($artifact) {
            return [pscustomobject]@{
                RunId = $run.id
                Name = $artifact.name
                ApiUrl = $artifact.archive_download_url
            }
        }

        Say-Verbose "no usable $Rid artifact in run $($run.id)"
    }

    Fail "no canary build with an unexpired $Rid artifact was found in the last $CanaryMaxRuns runs"
}

function Save-CanaryArtifact($Artifact, [string]$OutFile) {
    if ($Token) {
        try {
            # GitHub redirects artifact downloads to blob storage, which rejects the Authorization header,
            # so resolve the redirect with the token and then download without it
            $request = [System.Net.HttpWebRequest]::Create($Artifact.ApiUrl)
            $request.AllowAutoRedirect = $false
            $request.UserAgent = 'slskd-install'
            $request.Headers.Add('Authorization', "Bearer $Token")
            $response = $request.GetResponse()
            $location = $response.Headers['Location']
            $response.Close()

            if ($location) {
                Invoke-Download $location $OutFile
                return
            }
        } catch {
            Say-Verbose "failed to download artifact with token; falling back to nightly.link ($($_.Exception.Message))"
        }
    }

    # GitHub requires authentication to download artifacts, even for public repositories.
    # nightly.link proxies the download for anonymous users.
    Invoke-Download "$NightlyLink/$($Artifact.RunId)/$($Artifact.Name).zip" $OutFile
}

# replaces the contents of InstallDir with the contents of StagingDir
function Install-Files([string]$StagingDir, [string]$Destination) {
    if (-not (Test-Path (Join-Path $StagingDir 'slskd.exe'))) {
        Fail "the downloaded archive doesn't contain slskd.exe"
    }

    if (Test-Path $Destination) {
        if (-not (Test-Path $Destination -PathType Container)) {
            Fail "$Destination exists and isn't a directory"
        }

        # refuse to delete a directory that doesn't look like a previous slskd install
        $existing = Get-ChildItem -Force $Destination
        if ($existing -and -not (Test-Path (Join-Path $Destination 'slskd.exe'))) {
            Fail "$Destination is not empty and doesn't contain a previous slskd install. Choose a different -InstallDir."
        }

        $running = Get-Process -Name slskd -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.StartsWith($Destination, [StringComparison]::OrdinalIgnoreCase) }
        if ($running) {
            Fail "slskd is running from $Destination (pid $($running.Id -join ', ')). Stop it and run the installer again."
        }
    }

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }

    $newDir = "$Destination.new.$PID"
    $oldDir = "$Destination.old.$PID"

    # copy then rename so that an existing install is replaced in one step
    Copy-Item -Path $StagingDir -Destination $newDir -Recurse

    if (Test-Path $Destination) {
        Move-Item -Path $Destination -Destination $oldDir
    }

    try {
        Move-Item -Path $newDir -Destination $Destination
    } catch {
        if (Test-Path $oldDir) {
            Move-Item -Path $oldDir -Destination $Destination
        }
        Fail "failed to move slskd into ${Destination}: $($_.Exception.Message)"
    }

    if (Test-Path $oldDir) {
        Remove-Item -Path $oldDir -Recurse -Force
    }
}

function Add-ToUserPath([string]$Directory) {
    # read and write the registry directly; [Environment]::SetEnvironmentVariable expands %VARIABLES%
    # in existing entries and changes the value from REG_EXPAND_SZ to REG_SZ
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)

    try {
        $userPath = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $entries = if ($userPath) { $userPath -split ';' | Where-Object { $_ } } else { @() }

        if ($entries | Where-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ieq $Directory.TrimEnd('\') }) {
            Say-Verbose "$Directory is already in the user PATH"
            return $false
        }

        $newPath = (@($entries) + $Directory) -join ';'
        $key.SetValue('Path', $newPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally {
        $key.Close()
    }

    # SetValue doesn't notify other processes the way SetEnvironmentVariable does; setting a dummy
    # variable broadcasts WM_SETTINGCHANGE so new terminals pick up the change
    [Environment]::SetEnvironmentVariable('SLSKD_INSTALL_PATH_UPDATED', '1', 'User')
    [Environment]::SetEnvironmentVariable('SLSKD_INSTALL_PATH_UPDATED', $null, 'User')

    # update the current session too, so slskd can be run right away
    $env:Path = "$env:Path;$Directory"

    return $true
}

function Main {
    if ($Help) {
        if ($PSCommandPath) {
            Get-Help $PSCommandPath -Detailed
        } else {
            Write-Host 'Options: -Channel <release|canary> -Version <version> -InstallDir <dir> -Architecture <x64|arm64> -NoPath -DryRun -Verbose'
            Write-Host 'See https://slskd.org/install.ps1 for details.'
        }
        return
    }

    $onWindows = $env:OS -eq 'Windows_NT'
    if (-not $onWindows) {
        Fail 'install.ps1 only supports Windows. On Linux and macOS, run: curl -fsSL https://slskd.org/install.sh | bash'
    }

    # Windows PowerShell 5.1 doesn't enable TLS 1.2 by default, and its progress bar slows downloads significantly
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $ProgressPreference = 'SilentlyContinue'

    # accept 'v0.26.1' as well as '0.26.1'
    $releaseVersion = $Version -replace '^v', ''

    if ($Channel -eq 'canary' -and $releaseVersion) {
        Fail "-Version can't be used with -Channel canary. Canary always installs the latest $CanaryBranch build."
    }

    $destination = if ($InstallDir) {
        $InstallDir
    } elseif ($env:SLSKD_INSTALL_DIR) {
        $env:SLSKD_INSTALL_DIR
    } else {
        Join-Path $env:LOCALAPPDATA 'Programs\slskd'
    }
    $destination = [IO.Path]::GetFullPath($destination)

    $rid = "win-$(Get-Architecture)"
    Say-Verbose "channel: $Channel, platform: $rid"

    $artifact = $null

    if ($Channel -eq 'canary') {
        $artifact = Find-CanaryArtifact $rid
        $downloadUrl = if ($Token) { $artifact.ApiUrl } else { "$NightlyLink/$($artifact.RunId)/$($artifact.Name).zip" }
        $description = "canary build $($artifact.Name -replace '^slskd-', '') (https://github.com/$Repo/actions/runs/$($artifact.RunId))"
    } else {
        if (-not $releaseVersion) {
            $releaseVersion = Get-LatestRelease
        }

        $downloadUrl = "$GitHubDownload/$($releaseVersion)/slskd-$($releaseVersion)-$rid.zip"
        $description = "slskd $($releaseVersion) ($rid)"
    }

    if ($DryRun) {
        Say 'dry run; nothing will be installed'
        Say "  version:     $description"
        Say "  download:    $downloadUrl"
        Say "  install dir: $destination"
        if (-not $NoPath) {
            Say "  add to PATH: $destination"
        }
        return
    }

    $tempDir = Join-Path ([IO.Path]::GetTempPath()) "slskd-install-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    try {
        $zip = Join-Path $tempDir 'slskd.zip'
        $extracted = Join-Path $tempDir 'extracted'

        Say "downloading $description"

        try {
            if ($artifact) {
                Save-CanaryArtifact $artifact $zip
            } else {
                Invoke-Download $downloadUrl $zip
            }
        } catch {
            if ($Channel -eq 'release') {
                Fail "failed to download $downloadUrl. Make sure version '$($releaseVersion)' exists at https://github.com/$Repo/releases and has a $rid build."
            }
            Fail "failed to download ${downloadUrl}: $($_.Exception.Message)"
        }

        Say 'extracting'
        Expand-Archive -Path $zip -DestinationPath $extracted -Force

        Say "installing to $destination"
        Install-Files $extracted $destination
    } finally {
        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $pathAdded = $false
    if (-not $NoPath) {
        $pathAdded = Add-ToUserPath $destination
    }

    Write-Host ''
    Say-Success 'slskd was installed successfully!'

    if ($pathAdded) {
        Say "added $destination to your PATH. Restart your terminal for the change to take effect in other windows."
    }

    Write-Host @"

  Run 'slskd' to start it, then browse to http://localhost:5030.
  The default username and password are both 'slskd'.

  Configuration and data are stored in %LOCALAPPDATA%\slskd by default.
  See https://github.com/$Repo/blob/master/docs/config.md for configuration options.

"@
}

Main
