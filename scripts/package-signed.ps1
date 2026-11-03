param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [long]$RunId,
    [ValidatePattern('^[a-p]{32}$')][string]$GitHubExtensionId = 'heaonkgdmhjpmmiflpogbebmolfcgeck',
    [ValidatePattern('^$|^[a-p]{32}$')][string]$WebStoreExtensionId = ''
)

$ErrorActionPreference = "Stop"

$project = "D:\MAKE\MyCATLLES"
$artifactName = "MyCATTLES-Windows-x64"

$source = Join-Path $project "automation-test\run-$RunId\$artifactName"
$work = Join-Path $project "automation-test\package-$RunId"
$releaseDir = Join-Path $work "Release"
$outputDir = Join-Path $work "dist"

$compiler = "C:\Program Files\Inno Setup 7\ISCC.exe"
$signtool = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe"
$thumbprint = "C4F0AA19EDB310C69024636C28C07071E9D0E2DD"

function Assert-LastExitCode {
    param([string]$Step)

    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed. Exit code: $LASTEXITCODE"
    }
}

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must be in the format 0.1.0"
}

if (-not (Test-Path -LiteralPath $source)) {
    throw "Artifact directory not found: $source"
}

foreach ($path in @($compiler, $signtool)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required tool not found: $path"
    }
}

$cert = Get-Item "Cert:\CurrentUser\My\$thumbprint" -ErrorAction Stop

if (-not $cert.HasPrivateKey) {
    throw "Signing certificate has no private key."
}

Write-Host "=== Verifying original artifact ==="
& (Join-Path $project "scripts\verify-artifact.ps1") -RunId $RunId
if (-not $?) { throw "Artifact provenance verification failed." }

if (Test-Path -LiteralPath $work) {
    throw "Work directory already exists: $work"
}

New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

Copy-Item -Path (Join-Path $source "*") `
    -Destination $releaseDir `
    -Recurse -Force

$appExe = Join-Path $releaseDir "mycattles.exe"

if (-not (Test-Path -LiteralPath $appExe)) {
    throw "mycattles.exe not found."
}

if (-not (Test-Path -LiteralPath (Join-Path $releaseDir "flutter_windows.dll"))) {
    throw "flutter_windows.dll not found."
}

if (-not (Test-Path -LiteralPath (Join-Path $releaseDir "data"))) {
    throw "data directory not found."
}

Write-Host "=== Signing application ==="

& $signtool sign /sha1 $thumbprint /fd SHA256 `
    /d "MyCATTLES Windows Application" $appExe

Assert-LastExitCode "Application signing"

& $signtool verify /pa $appExe

Assert-LastExitCode "Application signature verification"

Write-Host "=== Preparing and signing Native Messaging Host ==="
$hostSource = Join-Path $project "host\mycattles_host.exe"
$hostDir = Join-Path $work "Host"
$hostExe = Join-Path $hostDir "mycattles_host.exe"
if (-not (Test-Path -LiteralPath $hostSource -PathType Leaf)) { throw "Host not built: $hostSource" }
New-Item -ItemType Directory -Path $hostDir -Force | Out-Null
Copy-Item -LiteralPath $hostSource -Destination $hostExe -Force
& $signtool sign /sha1 $thumbprint /fd SHA256 /d "MyCATTLES Native Messaging Host" $hostExe
Assert-LastExitCode "Native Host signing"
& $signtool verify /pa $hostExe
Assert-LastExitCode "Native Host signature verification"
$hostSig = Get-AuthenticodeSignature -LiteralPath $hostExe
if ($hostSig.Status -ne 'Valid' -or $hostSig.SignerCertificate.Thumbprint -ne $thumbprint) { throw 'Native Host signature invalid.' }
Write-Host "PASS: Native Host signed and verified."

Write-Host "=== Building installer ==="

$iss = Join-Path $project "installer\MyCATTLES.iss"

& $compiler `
    "/DReleaseDir=$releaseDir" `
    "/DMyAppVersion=$Version" `
    "/DHostExe=$hostExe" `
    "/DGitHubExtensionId=$GitHubExtensionId" `
    "/DChromeExtensionId=$WebStoreExtensionId" `
    "/O$outputDir" `
    $iss

Assert-LastExitCode "Installer compilation"

$unsigned = Join-Path $outputDir "MyCATTLES-Setup-$Version-win-x64-unsigned.exe"
$signed = Join-Path $outputDir "MyCATTLES-Setup-$Version-win-x64.exe"

if (-not (Test-Path -LiteralPath $unsigned)) {
    throw "Generated installer not found: $unsigned"
}

Write-Host "=== Signing installer ==="

& $signtool sign /sha1 $thumbprint /fd SHA256 `
    /d "MyCATTLES Windows Installer" $unsigned

Assert-LastExitCode "Installer signing"

& $signtool verify /pa $unsigned

Assert-LastExitCode "Installer signature verification"

Rename-Item -LiteralPath $unsigned `
    -NewName (Split-Path $signed -Leaf)

Write-Host "=== Generating SHA256 ==="

$hash = (Get-FileHash -LiteralPath $signed -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumPath = Join-Path $outputDir "SHA256SUMS.txt"

"$hash  $(Split-Path $signed -Leaf)" |
    Set-Content -LiteralPath $checksumPath -Encoding ascii

$line = @(Get-Content -LiteralPath $checksumPath)

if ($line.Count -ne 1 -or $line[0] -cnotmatch '^([0-9a-f]{64})  (.+)$') {
    throw "Invalid SHA256SUMS format."
}

$expectedHash = $Matches[1]
$expectedName = $Matches[2]

if ($expectedHash -cne $hash -or
    $expectedName -cne (Split-Path $signed -Leaf)) {
    throw "SHA256 verification failed."
}

Write-Host ""
Write-Host "PASS: Signed installer package created." -ForegroundColor Green
Write-Host "Installer: $signed"
Write-Host "SHA256SUMS: $checksumPath"

# Record exact installer inputs to prevent stale package reuse.
$inputFiles = @(
    'installer\MyCATTLES.iss', 'host\install_host.ps1',
    'host\uninstall_host.ps1', 'host\register_github_extension.ps1'
)
$inputHashes = [ordered]@{}
foreach ($relative in $inputFiles) {
    $inputHashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $project $relative) -Algorithm SHA256).Hash.ToLowerInvariant()
}
$metadata = [ordered]@{
    schema = 1; version = $Version; runId = $RunId
    githubExtensionId = $GitHubExtensionId; webStoreExtensionId = $WebStoreExtensionId
    hostSha256 = (Get-FileHash -LiteralPath $hostExe -Algorithm SHA256).Hash.ToLowerInvariant()
    inputHashes = $inputHashes
}
$metadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $work 'integration-manifest.json') -Encoding UTF8
Write-Host 'PASS: Integration manifest written.'
