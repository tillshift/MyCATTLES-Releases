param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [long]$RunId,

    [ValidateSet("Preview", "Draft")]
    [string]$Mode = "Preview",

    [string]$ConfirmTag = ""
)

$ErrorActionPreference = "Stop"

$project = "D:\MAKE\MyCATLLES"
$sourceRepo = "tillshift/MyCATLLES"
$releaseRepo = "tillshift/MyCATLLES-Releases"
$tag = "v$Version"

$dist = Join-Path $project "automation-test\package-$RunId\dist"
$installer = Join-Path $dist "MyCATTLES-Setup-$Version-win-x64.exe"
$checksum = Join-Path $dist "SHA256SUMS.txt"
$certificate = "D:\MAKE\MyCATLLES-Signing\TILLSHIFT-Phase1.cer"

function Invoke-GhJson {
    param([string[]]$Arguments)

    $output = & gh @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI failed: gh $($Arguments -join ' ')"
    }

    return ($output | ConvertFrom-Json)
}

function Get-ApiStatus {
    param([Parameter(Mandatory = $true)][string]$Endpoint)

    # Windows PowerShell 5.1 can turn native stderr into a terminating
    # NativeCommandError when ErrorActionPreference is Stop.
    # Redirect both streams at the process boundary instead.
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()

    try {
        $ghPath = (Get-Command gh.exe -ErrorAction Stop).Source
        $process = Start-Process -FilePath $ghPath `
            -ArgumentList @('api', '--include', $Endpoint) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath

        $stdout = [System.IO.File]::ReadAllText($stdoutPath)
        $stderr = [System.IO.File]::ReadAllText($stderrPath)
        $match = [regex]::Match($stdout, '(?m)^HTTP/\S+\s+(\d{3})')

        if (-not $match.Success) {
            throw "GitHub API HTTP status missing: $Endpoint (exit=$($process.ExitCode); stderr=$stderr)"
        }

        $status = [int]$match.Groups[1].Value
        if ($status -eq 404) {
            return 404
        }
        if ($process.ExitCode -ne 0 -or $status -lt 200 -or $status -ge 300) {
            throw "GitHub API error: HTTP $status (exit=$($process.ExitCode); endpoint=$Endpoint; stderr=$stderr)"
        }
        return $status
    }
    finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Invalid version format."
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLIが見つかりません。"
}

Write-Host "=== Verifying release package ==="

& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $project "scripts\verify-release.ps1") `
    -Version $Version `
    -RunId $RunId

if ($LASTEXITCODE -ne 0) {
    throw "公開前検証に失敗しました。"
}

foreach ($file in @($installer, $checksum, $certificate)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "公開対象ファイルがありません: $file"
    }
}

Write-Host "=== Checking source version ==="

$runInfo = Invoke-GhJson @(
    "api", "repos/$sourceRepo/actions/runs/$RunId"
)

$sha = $runInfo.head_sha

$pubspec = Invoke-GhJson @(
    "api", "repos/$sourceRepo/contents/pubspec.yaml?ref=$sha"
)

$base64 = $pubspec.content -replace '\s', ''
$pubspecText = [System.Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($base64)
)

$versionMatch = [regex]::Match(
    $pubspecText,
    '(?m)^\s*version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$'
)

if (-not $versionMatch.Success) {
    throw "ビルド元のバージョンを取得できません。"
}

$sourceVersion = $versionMatch.Groups[1].Value

if ($sourceVersion -ne $Version) {
    throw "バージョン不一致: source=$sourceVersion requested=$Version"
}

Write-Host "PASS: Source version verified."
Write-Host "Commit: $sha"

Write-Host "=== Checking destination repository ==="

$repoInfo = Invoke-GhJson @(
    "repo", "view", $releaseRepo,
    "--json", "name,visibility"
)

if ($repoInfo.visibility -ne "PUBLIC") {
    throw "公開先リポジトリがPUBLICではありません。"
}

Write-Host "=== Checking existing tag and release ==="

$releaseStatus = Get-ApiStatus `
    "repos/$releaseRepo/releases/tags/$tag"

$tagStatus = Get-ApiStatus `
    "repos/$releaseRepo/git/ref/tags/$tag"

$alreadyExists = (
    $releaseStatus -ne 404 -or
    $tagStatus -ne 404
)

Write-Host ""
Write-Host "=== Publication preview ==="
Write-Host "Mode: $Mode"
Write-Host "Repository: $releaseRepo"
Write-Host "Tag: $tag"
Write-Host "Run ID: $RunId"
Write-Host "Commit: $sha"
Write-Host "Source version: $sourceVersion"
Write-Host "Already exists: $alreadyExists"

Get-Item -LiteralPath $installer,$checksum,$certificate |
    Select-Object Name,Length |
    Format-Table -AutoSize

if ($alreadyExists) {
    Write-Host "BLOCKED: Tag or release already exists." -ForegroundColor Yellow

    if ($Mode -eq "Draft") {
        throw "既存タグまたはReleaseへの重複公開は禁止されています。"
    }

    Write-Host "PREVIEW COMPLETE: No changes made."
    exit 0
}

if ($Mode -eq "Preview") {
    Write-Host "PREVIEW COMPLETE: No changes made." -ForegroundColor Green
    exit 0
}

# Draftモードは明示的なタグ確認を必須にする
if ($ConfirmTag -cne $tag) {
    throw "ドラフト作成には -ConfirmTag `"$tag`" が必要です。"
}

Write-Host "=== Creating draft release ==="

$notes = @"
MyCATTLES $tag

Windows x64 release.

Build commit: $sha
GitHub Actions run: $RunId

The installer is signed with a TILLSHIFT self-signed
code-signing certificate. Windows may display a
publisher trust or SmartScreen warning.

Verify the installer using SHA256SUMS.txt.
"@

$notesFile = Join-Path $dist "release-notes-$tag.txt"

$notes | Set-Content -LiteralPath $notesFile -Encoding UTF8

# --draft を必ず指定し、公開状態にしない。
& gh release create $tag `
    --repo $releaseRepo `
    --target main `
    --title "MyCATTLES $tag" `
    --notes-file $notesFile `
    --draft `
    --prerelease `
    $installer `
    $checksum `
    $certificate

if ($LASTEXITCODE -ne 0) {
    throw "ドラフト作成またはAssetアップロードに失敗しました。"
}

Write-Host "=== Verifying draft assets ==="

$created = Invoke-GhJson @(
    "release", "view", $tag,
    "--repo", $releaseRepo,
    "--json", "tagName,isDraft,isPrerelease,assets,url"
)

if (-not $created.isDraft) {
    throw "作成されたReleaseがドラフトではありません。"
}

$expectedFiles = @($installer, $checksum, $certificate)

foreach ($file in $expectedFiles) {
    $name = Split-Path $file -Leaf
    $expectedSize = (Get-Item -LiteralPath $file).Length

    $asset = @(
        $created.assets |
        Where-Object { $_.name -eq $name }
    )

    if ($asset.Count -ne 1) {
        throw "アップロード済みAssetが見つかりません: $name"
    }

    if ([long]$asset[0].size -ne $expectedSize) {
        throw "Assetサイズが一致しません: $name"
    }
}

Write-Host ""
Write-Host "PASS: Draft release created and assets checked." -ForegroundColor Green
Write-Host "Tag: $tag"
Write-Host "URL: $($created.url)"
Write-Host "Status: DRAFT (not published)"
