param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [long]$RunId,

    [ValidateSet("Verify", "Publish")]
    [string]$Mode = "Verify",

    [string]$ConfirmTag = ""
)

$ErrorActionPreference = "Stop"

$project = "D:\MAKE\MyCATLLES"
$repo = "tillshift/MyCATLLES-Releases"
$tag = "v$Version"

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Invalid version format."
}

if ($RunId -le 0) {
    throw "Run ID must be positive."
}

$dist = Join-Path $project "automation-test\package-$RunId\dist"

$installer = Join-Path $dist "MyCATTLES-Setup-$Version-win-x64.exe"
$checksum = Join-Path $dist "SHA256SUMS.txt"
$certificate = "D:\MAKE\MyCATLLES-Signing\TILLSHIFT-Phase1.cer"

$expected = @(
    $installer,
    $checksum,
    $certificate
)

function Invoke-GhJson {
    param([string[]]$Arguments)

    $result = & gh @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI failed: gh $($Arguments -join ' ')"
    }

    return ($result | ConvertFrom-Json)
}

Write-Host "=== Verifying local package ==="

& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $project "scripts\verify-release.ps1") `
    -Version $Version `
    -RunId $RunId

if ($LASTEXITCODE -ne 0) {
    throw "Local package verification failed."
}

foreach ($file in $expected) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Missing local file: $file"
    }
}

Write-Host "=== Checking source version ==="

$sourceRepo = "tillshift/MyCATLLES"

$runInfo = Invoke-GhJson @(
    "api",
    "repos/$sourceRepo/actions/runs/$RunId"
)

$sha = $runInfo.head_sha

$pubspec = Invoke-GhJson @(
    "api",
    "repos/$sourceRepo/contents/pubspec.yaml?ref=$sha"
)

$base64 = $pubspec.content -replace '\s', ''

$pubspecText = [System.Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($base64)
)

$match = [regex]::Match(
    $pubspecText,
    '(?m)^\s*version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$'
)

if (-not $match.Success -or $match.Groups[1].Value -ne $Version) {
    throw "Source version mismatch."
}

Write-Host "PASS: Source version verified."

Write-Host "=== Checking GitHub release ==="

$release = Invoke-GhJson @(
    "release", "view", $tag,
    "--repo", $repo,
    "--json", "tagName,isDraft,isPrerelease,assets,url"
)

if ($release.tagName -cne $tag) {
    throw "Release tag mismatch."
}

# 公開済みReleaseを対象にしない
if (-not $release.isDraft) {
    Write-Host "BLOCKED: Release is already published." -ForegroundColor Yellow
    Write-Host "URL: $($release.url)"
    exit 0
}

Write-Host "PASS: Draft release confirmed."

Write-Host "=== Checking asset list ==="

$expectedNames = @(
    $expected | ForEach-Object {
        Split-Path $_ -Leaf
    }
)

$assets = @($release.assets)

if ($assets.Count -ne $expectedNames.Count) {
    throw "Unexpected number of release assets."
}

foreach ($name in $expectedNames) {
    $matches = @($assets | Where-Object { $_.name -ceq $name })

    if ($matches.Count -ne 1) {
        throw "Missing or duplicated asset: $name"
    }
}

Write-Host "PASS: Asset names verified."

Write-Host "=== Downloading GitHub assets for verification ==="

$tempDir = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ("MyCATTLES-verify-" + [guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Path $tempDir -ErrorAction Stop |
    Out-Null

try {
    & gh release download $tag `
        --repo $repo `
        --dir $tempDir

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to download release assets."
    }

    Write-Host "=== Comparing SHA256 hashes ==="

    foreach ($localFile in $expected) {
        $name = Split-Path $localFile -Leaf
        $remoteFile = Join-Path $tempDir $name

        if (-not (Test-Path -LiteralPath $remoteFile -PathType Leaf)) {
            throw "Downloaded asset missing: $name"
        }

        $localHash = (Get-FileHash `
            -LiteralPath $localFile `
            -Algorithm SHA256).Hash

        $remoteHash = (Get-FileHash `
            -LiteralPath $remoteFile `
            -Algorithm SHA256).Hash

        if ($localHash -cne $remoteHash) {
            throw "SHA256 mismatch: $name"
        }

        Write-Host "PASS: $name"
    }
}
finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}

Write-Host ""
Write-Host "PASS: All GitHub assets match local files." -ForegroundColor Green

if ($Mode -eq "Verify") {
    Write-Host "VERIFY COMPLETE: Release remains a draft."
    exit 0
}

if ($ConfirmTag -cne $tag) {
    throw "Publishing requires -ConfirmTag `"$tag`"."
}

Write-Host ""
Write-Host "=== Publishing release ==="
Write-Host "Repository: $repo"
Write-Host "Tag: $tag"
Write-Host "Commit: $sha"

# 公開直前にドラフト状態を再確認
$latest = Invoke-GhJson @(
    "release", "view", $tag,
    "--repo", $repo,
    "--json", "tagName,isDraft"
)

if ($latest.tagName -cne $tag -or -not $latest.isDraft) {
    throw "Release state changed before publishing."
}

& gh release edit $tag `
    --repo $repo `
    --draft=false

if ($LASTEXITCODE -ne 0) {
    throw "Release publication failed."
}

Write-Host "=== Confirming publication ==="

$published = Invoke-GhJson @(
    "release", "view", $tag,
    "--repo", $repo,
    "--json", "tagName,isDraft,url"
)

if ($published.tagName -cne $tag -or $published.isDraft) {
    throw "Publication state could not be confirmed."
}

Write-Host ""
Write-Host "PASS: Release published successfully." -ForegroundColor Green
Write-Host "URL: $($published.url)"
