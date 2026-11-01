# Remove only the current user's Chrome registration; keep user data untouched.
$ErrorActionPreference = 'Stop'
$key='HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.mycattles.bridge'
Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'MyCATTLES Native Messaging Host registration removed.'
