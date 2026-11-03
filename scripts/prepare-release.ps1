param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [long]$RunId = 0,
    [ValidatePattern('^[a-p]{32}$')][string]$GitHubExtensionId = 'heaonkgdmhjpmmiflpogbebmolfcgeck',
    [ValidatePattern('^$|^[a-p]{32}$')][string]$WebStoreExtensionId = ''
)

$ErrorActionPreference = "Stop"

$project = "D:\MAKE\MyCATLLES"
$repo = "tillshift/MyCATLLES"

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "バージョンは 0.1.0 の形式で指定してください。"
}

if ($RunId -eq 0) {
    $runsJson = gh run list `
        --repo $repo `
        --workflow "windows-build.yml" `
        --branch main `
        --limit 30 `
        --json databaseId,status,conclusion

    if ($LASTEXITCODE -ne 0) {
        throw "Windows Build履歴の取得に失敗しました。"
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

Write-Host "=== Checking source version ==="

$runInfoJson = gh api "repos/$repo/actions/runs/$RunId"

if ($LASTEXITCODE -ne 0) {
    throw "Run情報の取得に失敗しました。"
}

$runInfo = $runInfoJson | ConvertFrom-Json
$sha = $runInfo.head_sha

$pubspecJson = gh api `
    "repos/$repo/contents/pubspec.yaml?ref=$sha"

if ($LASTEXITCODE -ne 0) {
    throw "ビルド元のpubspec.yaml取得に失敗しました。"
}

$pubspec = $pubspecJson | ConvertFrom-Json
$base64 = $pubspec.content -replace '\s', ''
$text = [System.Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($base64)
)

$versionLine = $text -split "`n" |
    Where-Object { $_ -match '^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+)' } |
    Select-Object -First 1

if (-not $versionLine) {
    throw "pubspec.yamlからバージョンを取得できません。"
}

$sourceVersion = [regex]::Match(
    $versionLine,
    'version:\s*([0-9]+\.[0-9]+\.[0-9]+)'
).Groups[1].Value

Write-Host "Requested version: $Version"
Write-Host "Source version: $sourceVersion"
Write-Host "Commit: $sha"

if ($sourceVersion -ne $Version) {
    throw "指定バージョンとビルド元のバージョンが一致しません。"
}

Write-Host "=== Downloading or checking artifact ==="

& (Join-Path $project "scripts\download-build.ps1") -RunId $RunId

if (-not $?) {
    throw "Artifact取得処理に失敗しました。"
}

$work = Join-Path $project "automation-test\package-$RunId"
$installer = Join-Path $work "dist\MyCATTLES-Setup-$Version-win-x64.exe"

if (Test-Path -LiteralPath $work) {
    Write-Host "=== Checking existing package ==="
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw "Incomplete package directory: $work. Inspect it and remove it before retrying."
    }
    & (Join-Path $project "scripts\verify-release.ps1") -Version $Version -RunId $RunId
    if (-not $?) { throw "Existing package verification failed." }
    $integration = Get-Content -LiteralPath (Join-Path $work "integration-manifest.json") -Raw | ConvertFrom-Json
    if ($integration.githubExtensionId -cne $GitHubExtensionId -or $integration.webStoreExtensionId -cne $WebStoreExtensionId) { throw "Existing package extension IDs differ; rebuild in a fresh package directory." }
    Write-Host "PASS: Existing package verified." -ForegroundColor Green
}
else {
    Write-Host "=== Creating signed package ==="
    & (Join-Path $project "scripts\package-signed.ps1") -Version $Version -RunId $RunId -GitHubExtensionId $GitHubExtensionId -WebStoreExtensionId $WebStoreExtensionId
    if (-not $?) { throw "Signing/packaging failed." }
    & (Join-Path $project "scripts\verify-release.ps1") -Version $Version -RunId $RunId
    if (-not $?) { throw "New package verification failed." }
}

Write-Host ""
Write-Host "PASS: Release preparation completed." -ForegroundColor Green
Write-Host "Run ID: $RunId"
Write-Host "Installer: $installer"
