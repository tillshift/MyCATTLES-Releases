# Execute on Windows with Python 3.13 and PyInstaller installed.
param([switch]$SkipInstallDependencies)
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $dir
try {
  if (-not $SkipInstallDependencies) {
    py -3.13 -m pip install --upgrade pyinstaller
    if ($LASTEXITCODE -ne 0) { throw 'PyInstaller installation failed.' }
  }
  py -3.13 -m PyInstaller --noconfirm --clean --onefile --console --name mycattles_host mycattles_host.py
  if ($LASTEXITCODE -ne 0) { throw 'Host build failed.' }
  Copy-Item -LiteralPath (Join-Path $dir 'dist\mycattles_host.exe') -Destination (Join-Path $dir 'mycattles_host.exe') -Force
  Write-Host 'Built host\mycattles_host.exe'
} finally { Pop-Location }
