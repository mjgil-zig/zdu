param(
  [string]$Version = $env:VERSION,
  [string]$Dir = $env:ZDU_INSTALL_DIR,
  [switch]$NoModifyPath,
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

$App = 'zdu'
$Repo = 'mjgil-zig/zdu'

function Show-Usage {
  @"
Install zdu for Windows.

Usage:
  irm https://mjgil.com/zdu/install.ps1 | iex
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Version 0.1.0
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Dir `$env:USERPROFILE\bin
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -NoModifyPath

Options:
  -Version <version>     Install a specific version, e.g. 0.1.0 or v0.1.0
  -Dir <directory>       Install directory. Default: %LOCALAPPDATA%\Programs\zdu\bin
  -NoModifyPath          Do not update the user PATH
  -Help                  Show this help

Environment:
  VERSION=<version>             Same as -Version
  ZDU_INSTALL_DIR=<directory>   Same as -Dir
"@
}

if ($Help) {
  Show-Usage
  exit 0
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = 'latest'
}

if ([string]::IsNullOrWhiteSpace($Dir)) {
  if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'LOCALAPPDATA is not set; pass -Dir or set ZDU_INSTALL_DIR.'
  }
  $Dir = Join-Path $env:LOCALAPPDATA 'Programs\zdu\bin'
}

$arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
  'X64' { 'x86_64'; break }
  'Arm64' { 'aarch64'; break }
  default { throw "unsupported architecture: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" }
}

$asset = "$App-$arch-windows.zip"
if ($Version -eq 'latest') {
  $url = "https://github.com/$Repo/releases/latest/download/$asset"
} else {
  $versionNoV = $Version.TrimStart('v')
  $url = "https://github.com/$Repo/releases/download/v$versionNoV/$asset"
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("zdu-install-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
  $archivePath = Join-Path $tmp $asset
  $checksumPath = "$archivePath.sha256"

  Write-Host "Installing $App $Version for windows/$arch"
  Write-Host "Downloading $asset"
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archivePath

  $checksumDownloaded = $false
  try {
    Invoke-WebRequest -UseBasicParsing -Uri "$url.sha256" -OutFile $checksumPath
    $checksumDownloaded = $true
  } catch {
    Write-Warning 'No checksum asset found; continuing without checksum verification.'
  }

  if ($checksumDownloaded) {
    Write-Host 'Verifying checksum'
    $expected = ((Get-Content -Raw $checksumPath).Trim() -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 $archivePath).Hash.ToLowerInvariant()
    if ($expected -ne $actual) {
      throw "checksum mismatch: expected $expected, got $actual"
    }
  }

  Expand-Archive -Force -Path $archivePath -DestinationPath $tmp

  $exeSource = Join-Path $tmp "$App.exe"
  if (-not (Test-Path -LiteralPath $exeSource)) {
    throw "archive did not contain $App.exe"
  }

  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  $exeDest = Join-Path $Dir "$App.exe"
  Copy-Item -Force -LiteralPath $exeSource -Destination $exeDest

  if (-not $NoModifyPath) {
    $currentUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathParts = @()
    if (-not [string]::IsNullOrWhiteSpace($currentUserPath)) {
      $pathParts = $currentUserPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    $alreadyInPath = $pathParts | Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') }
    if (-not $alreadyInPath) {
      $newUserPath = if ([string]::IsNullOrWhiteSpace($currentUserPath)) { $Dir } else { "$currentUserPath;$Dir" }
      [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
      Write-Host "Added $Dir to the user PATH. Open a new terminal for it to take effect."
    }

    if ((($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') }).Count -eq 0) {
      $env:Path = "$env:Path;$Dir"
    }
  }

  if ($env:GITHUB_ACTIONS -eq 'true' -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_PATH)) {
    Add-Content -Path $env:GITHUB_PATH -Value $Dir
  }

  Write-Host ''
  Write-Host "zdu installed to: $exeDest"
  Write-Host ''
  Write-Host 'Run it now with:'
  Write-Host "  & '$exeDest'"
  Write-Host ''
  Write-Host 'After opening a new terminal, you should be able to run:'
  Write-Host '  zdu'
} finally {
  Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
