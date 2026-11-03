param(
    [Parameter(Mandatory = $true)]
    [long]$RunId
)

$ErrorActionPreference = "Stop"

if ($RunId -le 0) {
    throw "Run ID must be positive."
}

$project = "D:\MAKE\MyCATLLES"
$repo = "tillshift/MyCATLLES"
$artifactName = "MyCATTLES-Windows-x64"

$localDir = Join-Path $project "automation-test\run-$RunId\$artifactName"

if (-not (Test-Path -LiteralPath $localDir -PathType Container)) {
    throw "Local artifact directory not found: $localDir"
}

function Invoke-GhJson {
    param([string[]]$Arguments)

    $output = & gh @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI failed: gh $($Arguments -join ' ')"
    }

    return ($output | ConvertFrom-Json)
}

Write-Host "=== Checking GitHub Actions run ==="

$run = Invoke-GhJson @(
    "api",
    "repos/$repo/actions/runs/$RunId"
)

if ($run.name -ne "Windows Build" -or
    $run.head_branch -ne "main" -or
    $run.status -ne "completed" -or
    $run.conclusion -ne "success") {
    throw "Invalid GitHub Actions run."
}

Write-Host "PASS: Run verified."
Write-Host "Commit: $($run.head_sha)"

Write-Host "=== Checking GitHub artifact ==="

$artifactResponse = Invoke-GhJson @(
    "api",
    "repos/$repo/actions/runs/$RunId/artifacts"
)

$matches = @(
    $artifactResponse.artifacts |
    Where-Object {
        $_.name -eq $artifactName -and
        -not $_.expired
    }
)

if ($matches.Count -ne 1) {
    throw "Expected artifact not found or ambiguous."
}

$artifact = $matches[0]

Write-Host "PASS: Artifact found."
Write-Host "Artifact ID: $($artifact.id)"

$tempRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ("MyCATTLES-artifact-" + [guid]::NewGuid().ToString("N"))

# --name 指定時は、指定したディレクトリに
# Artifactの内容が直接展開される。
$tempDir = Join-Path $tempRoot "download"

New-Item -ItemType Directory -Path $tempDir -Force |
    Out-Null

try {
    Write-Host "=== Downloading original artifact ==="

    & gh run download $RunId `
        --repo $repo `
        --name $artifactName `
        --dir $tempDir

    if ($LASTEXITCODE -ne 0) {
        throw "Artifact download failed."
    }

    function Get-FileMap {
        param([string]$Root)

        $map = @{}

        $files = Get-ChildItem -LiteralPath $Root -File -Recurse

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

    Write-Host "=== Comparing artifact files ==="

    $remoteMap = Get-FileMap -Root $tempDir
    $localMap = Get-FileMap -Root $localDir

    if ($remoteMap.Count -eq 0) {
        throw "Downloaded artifact is empty."
    }

    if ($remoteMap.Count -ne $localMap.Count) {
        throw "Artifact file count mismatch. Remote=$($remoteMap.Count) Local=$($localMap.Count)"
    }

    foreach ($relative in $remoteMap.Keys) {
        if (-not $localMap.ContainsKey($relative)) {
            throw "Local file missing: $relative"
        }

        if ($remoteMap[$relative] -cne $localMap[$relative]) {
            throw "SHA256 mismatch: $relative"
        }
    }

    Write-Host "PASS: All artifact files match."

    Write-Host ""
    Write-Host "PASS: Artifact provenance comparison completed." -ForegroundColor Green
    Write-Host "Run ID: $RunId"
    Write-Host "Commit: $($run.head_sha)"
    Write-Host "Artifact ID: $($artifact.id)"
    Write-Host "Files: $($remoteMap.Count)"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
