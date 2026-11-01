# Register a packaged Native Messaging Host for the current Windows user.
# Usage: .\install_host.ps1 -ExtensionId <32-character Chrome extension ID>
param(
  [Parameter(Mandatory=$true)]
  [ValidatePattern('^[a-p]{32}$')][string]$ExtensionId
)
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $dir 'mycattles_host.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
  throw "Host executable is missing: $exe. Build the Windows distribution first."
}
# Store manifest alongside the host so updates can replace the EXE in place.
$manifest = Join-Path $dir 'com.mycattles.bridge.json'
$payload = [ordered]@{
  name='com.mycattles.bridge'
  description='MyCATTLES native messaging bridge'
  path=[System.IO.Path]::GetFullPath($exe)
  type='stdio'
  allowed_origins=@("chrome-extension://$ExtensionId/")
} | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($manifest, $payload, (New-Object System.Text.UTF8Encoding($false)))
$key='HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.mycattles.bridge'
New-Item -Path $key -Force | Out-Null
Set-Item -Path $key -Value ([System.IO.Path]::GetFullPath($manifest))
Write-Host "MyCATTLES Native Messaging Host registered for $ExtensionId"
