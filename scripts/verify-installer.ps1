param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [long]$RunId
)

$ErrorActionPreference = "Stop"

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Invalid version."
}

if ($RunId -le 0) {
    throw "Invalid Run ID."
}

$project = "D:\MAKE\MyCATLLES"

$releaseDir = Join-Path $project "automation-test\package-$RunId\Release"
$installer = Join-Path $project "automation-test\package-$RunId\dist\MyCATTLES-Setup-$Version-win-x64.exe"

foreach ($path in @($releaseDir, $installer)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required path missing: $path"
    }
}

# 既存のユーザーデータを守るため、実行前に
# インストーラーの設定内容を確認する。
$iss = Join-Path $project "installer\MyCATTLES.iss"

if (-not (Test-Path -LiteralPath $iss)) {
    throw "Inno Setup script not found."
}

Write-Host "=== Checking installer configuration ==="

$issText = Get-Content -LiteralPath $iss -Raw

# 実行中のアプリや既存インストールへの影響を避けるため、
# ここでは設定確認のみ行う。
$checks = @(
    "AppId",
    "DefaultDirName",
    "[Files]",
    "HostExe",
    "install_host.ps1",
    "uninstall_host.ps1",
    "register_github_extension.ps1",
    "CurStepChanged",
    "CurUninstallStepChanged"
)

foreach ($item in $checks) {
    if ($issText -notmatch [regex]::Escape($item)) {
        throw "Installer configuration missing: $item"
    }
}

Write-Host "PASS: Installer configuration fields found (static source inspection only)."

Write-Host "=== Checking signed installer ==="

$sig = Get-AuthenticodeSignature -LiteralPath $installer

if ($sig.Status -ne "Valid") {
    throw "Installer signature invalid: $($sig.Status)"
}

$thumbprint = "C4F0AA19EDB310C69024636C28C07071E9D0E2DD"

if ($sig.SignerCertificate.Thumbprint -ne $thumbprint) {
    throw "Installer certificate mismatch."
}

Write-Host "PASS: Installer signature verified."

Write-Host ""
Write-Host "=== Installer verification status ==="
Write-Host "Source directory: $releaseDir"
Write-Host "Installer: $installer"
Write-Host ""
Write-Host "PASS: Static installer checks completed." -ForegroundColor Green
Write-Host "NOTE: Installed file comparison has not been performed."
