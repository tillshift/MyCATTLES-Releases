param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [long]$RunId
)

$ErrorActionPreference = "Stop"

$project = "D:\MAKE\MyCATLLES"
$thumbprint = "C4F0AA19EDB310C69024636C28C07071E9D0E2DD"

$work = Join-Path $project "automation-test\package-$RunId"
$releaseDir = Join-Path $work "Release"
$dist = Join-Path $work "dist"

$appExe = Join-Path $releaseDir "mycattles.exe"
$installer = Join-Path $dist "MyCATTLES-Setup-$Version-win-x64.exe"
$checksumFile = Join-Path $dist "SHA256SUMS.txt"

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Invalid version format."
}

Write-Host "=== Verifying Native Host integration ==="
$manifestFile = Join-Path $work 'integration-manifest.json'
$hostExe = Join-Path $work 'Host\mycattles_host.exe'
foreach ($file in @($manifestFile,$hostExe)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Integration artifact missing: $file. Existing package is obsolete; do not publish." }
}
$integration = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
if ($integration.schema -ne 1 -or $integration.version -cne $Version -or [long]$integration.runId -ne $RunId) { throw 'Integration manifest does not match this release.' }
if ($integration.githubExtensionId -cnotmatch '^[a-p]{32}$' -or $integration.webStoreExtensionId -cnotmatch '^$|^[a-p]{32}$') { throw 'Invalid extension IDs in integration manifest.' }
foreach ($property in $integration.inputHashes.PSObject.Properties) {
    $sourcePath = Join-Path $project $property.Name
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Source missing: $sourcePath" }
    $hash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $property.Value) { throw "Packaging input changed after build: $($property.Name)" }
}
$hostHash = (Get-FileHash -LiteralPath $hostExe -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hostHash -cne $integration.hostSha256) { throw 'Signed Host hash mismatch.' }
$hostSig = Get-AuthenticodeSignature -LiteralPath $hostExe
if ($hostSig.Status -ne 'Valid' -or $hostSig.SignerCertificate.Thumbprint -ne $thumbprint) { throw 'Native Host signature verification failed.' }
Write-Host 'PASS: Signed Native Host and integration manifest verified.'

Write-Host "=== Checking required files ==="

foreach ($file in @(
    $appExe,
    $installer,
    $checksumFile,
    (Join-Path $releaseDir "flutter_windows.dll"),
    (Join-Path $releaseDir "data\app.so")
)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Required file missing: $file"
    }
}

Write-Host "=== Verifying application signature ==="

$appSignature = Get-AuthenticodeSignature -LiteralPath $appExe

if ($appSignature.Status -ne "Valid") {
    throw "Application signature is invalid: $($appSignature.Status)"
}

if ($appSignature.SignerCertificate.Thumbprint -ne $thumbprint) {
    throw "Application signer certificate mismatch."
}

Write-Host "PASS: Application signature verified."

Write-Host "=== Verifying installer signature ==="

$installerSignature = Get-AuthenticodeSignature -LiteralPath $installer

if ($installerSignature.Status -ne "Valid") {
    throw "Installer signature is invalid: $($installerSignature.Status)"
}

if ($installerSignature.SignerCertificate.Thumbprint -ne $thumbprint) {
    throw "Installer signer certificate mismatch."
}

Write-Host "PASS: Installer signature verified."

Write-Host "=== Verifying SHA256 ==="

$actualHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
$lines = @(Get-Content -LiteralPath $checksumFile)

if ($lines.Count -ne 1) {
    throw "SHA256SUMS.txt must contain exactly one line."
}

$expectedLine = "$actualHash  $(Split-Path $installer -Leaf)"

if ($lines[0] -cne $expectedLine) {
    throw "SHA256SUMS.txt does not match installer."
}

Write-Host "PASS: SHA256 verified."
& (Join-Path $project "scripts\verify-installer.ps1") -Version $Version -RunId $RunId
if (-not $?) { throw "Installer configuration verification failed." }

Write-Host "=== Checking signed package inputs ==="
& (Join-Path $project "scripts\verify-package-input.ps1") -RunId $RunId
if (-not $?) { throw "Signed package input verification failed." }

Write-Host "=== Checking GitHub Actions run ==="

$repo = "tillshift/MyCATLLES"

$runInfoJson = gh api "repos/$repo/actions/runs/$RunId"

if ($LASTEXITCODE -ne 0) {
    throw "Failed to retrieve GitHub Actions run."
}

$runInfo = $runInfoJson | ConvertFrom-Json

if ($runInfo.name -ne "Windows Build" -or
    $runInfo.head_branch -ne "main" -or
    $runInfo.status -ne "completed" -or
    $runInfo.conclusion -ne "success") {
    throw "GitHub Actions run is not a successful Windows Build."
}

Write-Host "PASS: GitHub Actions run verified."
Write-Host "Commit: $($runInfo.head_sha)"

Write-Host ""
Write-Host "PASS: All release verification checks completed." -ForegroundColor Green
Write-Host "Version: $Version"
Write-Host "Run ID: $RunId"
Write-Host "Installer: $installer"
Write-Host "SHA256: $actualHash"
