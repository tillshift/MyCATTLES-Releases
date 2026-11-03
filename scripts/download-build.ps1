param(
    [long]$RunId = 0
)

$ErrorActionPreference = "Stop"

$project = "D:\MAKE\MyCATLLES"
$repo = "tillshift/MyCATLLES"
$artifactName = "MyCATTLES-Windows-x64"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) が見つかりません。"
}

if ($RunId -eq 0) {
    Write-Host "=== Finding latest successful Windows Build ==="

    $runsJson = gh run list `
        --repo $repo `
        --workflow "windows-build.yml" `
        --branch main `
        --limit 30 `
        --json databaseId,status,conclusion

    if ($LASTEXITCODE -ne 0) {
        throw "GitHub Actions履歴の取得に失敗しました。"
    }

    $run = $runsJson |
        ConvertFrom-Json |
        Where-Object {
            $_.status -eq "completed" -and
            $_.conclusion -eq "success"
        } |
        Select-Object -First 1

    if (-not $run) {
        throw "成功済みWindows Buildが見つかりません。"
    }

    $RunId = [long]$run.databaseId
}

Write-Host "Selected Run ID: $RunId"

$runInfoJson = gh api "repos/$repo/actions/runs/$RunId"

if ($LASTEXITCODE -ne 0) {
    throw "Run情報の取得に失敗しました。"
}

$runInfo = $runInfoJson | ConvertFrom-Json

if ($runInfo.name -ne "Windows Build" -or
    $runInfo.head_branch -ne "main" -or
    $runInfo.conclusion -ne "success" -or
    $runInfo.status -ne "completed") {
    throw "指定Runは成功済みWindows Buildではありません。"
}

$artifactsJson = gh api "repos/$repo/actions/runs/$RunId/artifacts"

if ($LASTEXITCODE -ne 0) {
    throw "Artifact情報の取得に失敗しました。"
}

$artifacts = @(
    ($artifactsJson | ConvertFrom-Json).artifacts |
    Where-Object { $_.name -eq $artifactName }
)

if ($artifacts.Count -ne 1 -or $artifacts[0].expired) {
    throw "有効なArtifactが見つかりません。"
}

$downloadDir = Join-Path $project "automation-test\run-$RunId"
$releaseDir = Join-Path $downloadDir $artifactName
$manifestPath = Join-Path $downloadDir "artifact-manifest.json"

$required = @(
    "mycattles.exe",
    "flutter_windows.dll",
    "data\app.so",
    "data\icudtl.dat",
    "data\flutter_assets\AssetManifest.bin"
)

# A cached artifact is trusted only when it has a complete manifest.
# Incomplete previous downloads are discarded and downloaded again.
$cacheValid = (Test-Path -LiteralPath $manifestPath -PathType Leaf)
if ($cacheValid) {
    try {
        $cached = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($cached.runId -ne $RunId -or
            $cached.commit -ne $runInfo.head_sha -or
            $cached.artifactId -ne $artifacts[0].id -or
            @($cached.files).Count -eq 0) { $cacheValid = $false }
        foreach ($entry in @($cached.files)) {
            if ([IO.Path]::IsPathRooted([string]$entry.path) -or
                [string]$entry.path -match '(^|[\\/])\.\.([\\/]|$)') { $cacheValid = $false; break }
            $path = Join-Path $releaseDir $entry.path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256) {
                $cacheValid = $false; break
            }
        }
    } catch { $cacheValid = $false }
}
if ($cacheValid) {
    Write-Host "=== Existing artifact found ==="

    foreach ($file in $required) {
        $path = Join-Path $releaseDir $file
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "既存Artifactの必要ファイルが不足しています: $path"
        }
    }

    Write-Host "PASS: Existing artifact verified." -ForegroundColor Green
}
else {
    if (Test-Path -LiteralPath $downloadDir) {
        Write-Host "Removing incomplete artifact cache: $downloadDir"
        Remove-Item -LiteralPath $downloadDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null

    Write-Host "=== Downloading artifact ==="

    gh run download $RunId `
        --repo $repo `
        --name $artifactName `
        --dir $releaseDir

    if ($LASTEXITCODE -ne 0) {
        throw "Artifactダウンロードに失敗しました。"
    }

    foreach ($file in $required) {
        $path = Join-Path $releaseDir $file
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "ダウンロードしたArtifactに必要ファイルがありません: $path"
        }
    }

    $entries = @(
        Get-ChildItem -LiteralPath $releaseDir -Recurse -File |
        ForEach-Object {
            [PSCustomObject]@{
                path = $_.FullName.Substring($releaseDir.Length + 1)
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        }
    )

    [PSCustomObject]@{
        runId = $RunId
        commit = $runInfo.head_sha
        artifactId = $artifacts[0].id
        files = $entries
    } |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8

    Write-Host "PASS: Artifact downloaded and manifest created." -ForegroundColor Green
}

Write-Host "Run ID: $RunId"
Write-Host "Commit: $($runInfo.head_sha)"
Write-Host "Artifact: $releaseDir"
