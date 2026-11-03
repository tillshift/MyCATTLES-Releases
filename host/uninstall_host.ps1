$ErrorActionPreference='Stop'
$key='HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.mycattles.bridge'
$dir=Split-Path -Parent $MyInvocation.MyCommand.Path
$ownManifest=[IO.Path]::GetFullPath((Join-Path $dir 'com.mycattles.bridge.json'))
if (Test-Path -LiteralPath $key) {
  $registered=(Get-Item -LiteralPath $key).GetValue('')
  if ([string]::Equals($registered,$ownManifest,[StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $key -Recurse -Force
    Write-Host 'PASS: Native Messaging registration removed.'
  } else {
    Write-Host 'PASS: Registration belongs to another installation; left unchanged.'
  }
} else { Write-Host 'PASS: Native Messaging registration already absent.' }
