param(
    [Parameter(Mandatory = $true)]
    [long]$RunId
)

$ErrorActionPreference = "Stop"

if ($RunId -le 0) {
    throw "Run ID must be positive."
}

$project = "D:\MAKE\MyCATLLES"
$thumbprint = "C4F0AA19EDB310C69024636C28C07071E9D0E2DD"

$artifactDir = Join-Path $project "automation-test\run-$RunId\MyCATTLES-Windows-x64"
$releaseDir = Join-Path $project "automation-test\package-$RunId\Release"

foreach ($dir in @($artifactDir, $releaseDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        throw "Directory not found: $dir"
    }
}

function Get-FileMap {
    param([string]$Root)

    $map = @{}

    $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse)

    foreach ($file in $files) {
        $relative = $file.FullName.Substring(
            $Root.TrimEnd('\').Length + 1
        )

        $map[$relative] = (
            Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }

    return $map
}

Write-Host "=== Comparing file structure ==="

$artifactMap = Get-FileMap -Root $artifactDir
$releaseMap = Get-FileMap -Root $releaseDir

if ($artifactMap.Count -eq 0) {
    throw "Artifact directory is empty."
}

if ($artifactMap.Count -ne $releaseMap.Count) {
    throw "File count mismatch. Artifact=$($artifactMap.Count) Release=$($releaseMap.Count)"
}

foreach ($relative in $artifactMap.Keys) {
    if (-not $releaseMap.ContainsKey($relative)) {
        throw "File missing from signed release: $relative"
    }
}

Write-Host "PASS: File structure verified."

Write-Host "=== Comparing unsigned resources ==="

$excluded = "mycattles.exe"
$verifiedCount = 0

foreach ($relative in $artifactMap.Keys) {
    if ($relative -ieq $excluded) {
        continue
    }

    if ($artifactMap[$relative] -cne $releaseMap[$relative]) {
        throw "Unexpected file modification: $relative"
    }

    $verifiedCount++
}

Write-Host "PASS: $verifiedCount non-executable files match."

Write-Host "=== Verifying signed executable ==="

$appExe = Join-Path $releaseDir "mycattles.exe"

if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) {
    throw "Signed executable not found."
}

$signature = Get-AuthenticodeSignature -LiteralPath $appExe

if ($signature.Status -ne "Valid") {
    throw "Invalid executable signature: $($signature.Status)"
}

if ($signature.SignerCertificate.Thumbprint -ne $thumbprint) {
    throw "Unexpected signing certificate."
}

Write-Host "PASS: Executable signature verified."

Write-Host ""
Write-Host "PASS: Package input verification completed." -ForegroundColor Green
Write-Host "Run ID: $RunId"
Write-Host "Artifact files: $($artifactMap.Count)"
Write-Host "Verified unchanged files: $verifiedCount"
Write-Host "Signed executable: $appExe"
