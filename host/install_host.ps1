param(
  [ValidatePattern('^$|^[a-p]{32}$')][string]$WebStoreExtensionId = '',
  [ValidatePattern('^$|^[a-p]{32}$')][string]$GitHubExtensionId = ''
)
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $dir 'mycattles_host.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Host executable missing: $exe" }
$manifest = Join-Path $dir 'com.mycattles.bridge.json'
$origins = @()
foreach ($id in @($WebStoreExtensionId, $GitHubExtensionId)) {
  if ($id -and ($origins -notcontains "chrome-extension://$id/")) { $origins += "chrome-extension://$id/" }
}
# An empty origin list is permitted for a pre-store install, but no extension can connect until registered.
$payload = [ordered]@{
  name = 'com.mycattles.bridge'
  description = 'MyCATTLES native messaging bridge'
  path = [IO.Path]::GetFullPath($exe)
  type = 'stdio'
  allowed_origins = @($origins)
} | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText($manifest, $payload, (New-Object System.Text.UTF8Encoding($false)))
$key = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.mycattles.bridge'
New-Item -Path $key -Force | Out-Null
Set-Item -Path $key -Value ([IO.Path]::GetFullPath($manifest))
$actual = (Get-Item -LiteralPath $key).GetValue('')
if ($actual -ne [IO.Path]::GetFullPath($manifest)) { throw 'Native Messaging registry verification failed' }
$verify = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
if (@(Compare-Object -ReferenceObject @($origins) -DifferenceObject @($verify.allowed_origins)).Count -gt 0) { throw 'Native Messaging origin verification failed' }
Write-Host "PASS: Native Messaging Host registered; allowed origins: $($origins.Count)"
foreach ($origin in $origins) { Write-Host "PASS: $origin" }
if ($origins.Count -eq 0) { Write-Warning 'No Chrome extension ID registered yet; browser bridge is not usable.' }
