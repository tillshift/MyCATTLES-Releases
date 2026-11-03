param(
  [Parameter(Mandatory=$true)]
  [ValidatePattern('^[a-p]{32}$')][string]$ExtensionId
)
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifest = Join-Path $dir 'com.mycattles.bridge.json'
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw "Missing manifest: $manifest" }
$key = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.mycattles.bridge'
if (-not (Test-Path -LiteralPath $key)) { throw 'Native Messaging registry entry is missing; reinstall the Windows application.' }
$registered = (Get-Item -LiteralPath $key).GetValue('')
if (-not [string]::Equals($registered,[IO.Path]::GetFullPath($manifest),[StringComparison]::OrdinalIgnoreCase)) { throw 'Registered host belongs to a different installation.' }
$data = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
$origin = "chrome-extension://$ExtensionId/"
$origins = @($data.allowed_origins | Where-Object { $_ -and $_ -ne $origin }) + @($origin)
$data.allowed_origins = @($origins)
[IO.File]::WriteAllText($manifest, ($data | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
$verify = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
if (@($verify.allowed_origins) -notcontains $origin) { throw 'Origin verification failed' }
Write-Host "PASS: GitHub unpacked Chrome extension ID registered: $ExtensionId"
