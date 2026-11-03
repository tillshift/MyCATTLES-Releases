param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [ValidateSet("Preview", "Draft", "Publish")]
    [string]$Mode = "Preview",

    [long]$RunId = 0,

    [string]$ConfirmTag = ""
)

$ErrorActionPreference = "Stop"

$project = "D:\MAKE\MyCATLLES"
$scripts = Join-Path $project "scripts"
$stateDir = Join-Path $project "automation-test\release-state"
$tag = "v$Version"
$repo = "tillshift/MyCATLLES-Releases"

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Invalid version format."
}

if ($RunId -lt 0) {
    throw "Invalid Run ID."
}

$statePath = Join-Path $stateDir "$tag.json"

function Invoke-ReleaseScript {
    param(
        [string]$Script,
        [string[]]$Arguments
    )

    $path = Join-Path $scripts $Script

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Script not found: $path"
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File $path @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Script failed: $Script (ExitCode=$LASTEXITCODE)"
    }
}

function Get-Release {
    param([string]$ReleaseTag)

    # Windows PowerShell 5.1 treats native stderr as an error record under
    # $ErrorActionPreference = "Stop". Capture it outside the PowerShell pipeline.
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()

    try {
        $process = Start-Process -FilePath "gh.exe" `
            -ArgumentList @(
                "release", "view", $ReleaseTag,
                "--repo", $repo,
                "--json", "tagName,isDraft,isPrerelease,assets,url"
            ) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath

        $stdout = [System.IO.File]::ReadAllText($stdoutPath)
        $stderr = [System.IO.File]::ReadAllText($stderrPath)

        if ($process.ExitCode -ne 0) {
            if ($stderr -match '(?im)^\s*release not found\s*$') {
                return $null
            }
            throw "Failed to query GitHub Release '$ReleaseTag' (exit $($process.ExitCode)): $stderr"
        }

        if ([string]::IsNullOrWhiteSpace($stdout)) {
            throw "GitHub CLI returned empty release data for '$ReleaseTag'."
        }

        return ($stdout | ConvertFrom-Json)
    }
    finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath `
            -Force -ErrorAction SilentlyContinue
    }
}

function Assert-DraftAssets {
    param([object]$Release)

    if ($Release.tagName -cne $tag -or -not $Release.isDraft) {
        throw "Expected a draft release for $tag."
    }

    $dist = Join-Path $project "automation-test\package-$RunId\dist"
    $files = @(
        (Join-Path $dist "MyCATTLES-Setup-$Version-win-x64.exe"),
        (Join-Path $dist "SHA256SUMS.txt"),
        "D:\MAKE\MyCATLLES-Signing\TILLSHIFT-Phase1.cer"
    )
    $expectedNames = @($files | ForEach-Object { Split-Path $_ -Leaf })
    $assets = @($Release.assets)
    if ($assets.Count -ne $files.Count) {
        throw "Draft asset count mismatch: expected $($files.Count), actual $($assets.Count)."
    }
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Missing local release file: $file"
        }
        $name = Split-Path $file -Leaf
        $matches = @($assets | Where-Object { $_.name -ceq $name })
        if ($matches.Count -ne 1) {
            throw "Draft asset missing or duplicated: $name"
        }
        if ([long]$matches[0].size -ne (Get-Item -LiteralPath $file).Length) {
            throw "Draft asset size mismatch: $name"
        }
    }
    $unexpected = @($assets | Where-Object { $expectedNames -cnotcontains $_.name })
    if ($unexpected.Count -gt 0) {
        throw "Unexpected draft assets: $(($unexpected | ForEach-Object name) -join ', ')"
    }

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("MyCATTLES-draft-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        & gh release download $tag --repo $repo --dir $temp
        if ($LASTEXITCODE -ne 0) { throw "Failed to download draft assets for verification." }
        foreach ($file in $files) {
            $name = Split-Path $file -Leaf
            $remote = Join-Path $temp $name
            if (-not (Test-Path -LiteralPath $remote -PathType Leaf)) {
                throw "Downloaded draft asset missing: $name"
            }
            $localHash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
            $remoteHash = (Get-FileHash -LiteralPath $remote -Algorithm SHA256).Hash
            if ($localHash -cne $remoteHash) { throw "Draft asset SHA256 mismatch: $name" }
            Write-Host "PASS: Draft asset verified: $name"
        }
    }
    finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "PASS: Draft status and all 3 remote assets verified." -ForegroundColor Green
}

function Save-DraftState {
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($saved.tag -cne $tag -or $saved.version -cne $Version -or
            [long]$saved.runId -ne $RunId -or $saved.repository -cne $repo) {
            throw "Existing release state conflicts with verified draft: $statePath"
        }
        Write-Host "PASS: Existing release state matches."
        return
    }
    $state = [ordered]@{
        version = $Version
        tag = $tag
        runId = $RunId
        repository = $repo
        createdAt = (Get-Date).ToString('o')
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    Write-Host "PASS: Draft release state saved."
}

function Get-SavedRunId {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "Release state not found: $statePath"
    }

    $state = Get-Content -LiteralPath $statePath -Raw |
        ConvertFrom-Json

    if ($state.tag -cne $tag -or
        $state.version -cne $Version -or
        [long]$state.runId -le 0) {
        throw "Invalid release state."
    }

    return [long]$state.runId
}

function Get-LatestSuccessfulRunId {
    $json = & gh run list `
        --repo "tillshift/MyCATLLES" `
        --workflow "windows-build.yml" `
        --branch main `
        --limit 30 `
        --json databaseId,status,conclusion

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to retrieve GitHub Actions runs."
    }

    $runs = @($json | ConvertFrom-Json)

    $selected = $runs |
        Where-Object {
            $_.status -eq "completed" -and
            $_.conclusion -eq "success"
        } |
        Select-Object -First 1

    if (-not $selected) {
        throw "No successful Windows Build run found."
    }

    return [long]$selected.databaseId
}

# Publishでは最新ビルドを選択しない
if ($Mode -eq "Publish") {
    $savedRunId = Get-SavedRunId

    if ($RunId -ne 0 -and $RunId -ne $savedRunId) {
        throw "Run ID does not match saved release state."
    }

    $RunId = $savedRunId
}
elseif ($RunId -eq 0) {
    $RunId = Get-LatestSuccessfulRunId
}

Write-Host ""
Write-Host "=== MyCATTLES Release ==="
Write-Host "Version: $Version"
Write-Host "Mode: $Mode"
Write-Host "Run ID: $RunId"
Write-Host ""

if ($Mode -eq "Publish") {
    if ($ConfirmTag -cne $tag) {
        throw "Publishing requires -ConfirmTag `"$tag`"."
    }

    $before = Get-Release -ReleaseTag $tag

    if (-not $before) {
        throw "Release not found."
    }

    if (-not $before.isDraft) {
        throw "Release is already published. No changes made."
    }

    Invoke-ReleaseScript "finalize-release.ps1" @(
        "-Version", $Version,
        "-RunId", "$RunId",
        "-Mode", "Publish",
        "-ConfirmTag", $ConfirmTag
    )

    $after = Get-Release -ReleaseTag $tag

    if (-not $after -or $after.isDraft) {
        throw "Release publication was not confirmed."
    }

    Write-Host ""
    Write-Host "PASS: Release published." -ForegroundColor Green
    exit 0
}

Invoke-ReleaseScript "prepare-release.ps1" @(
    "-Version", $Version,
    "-RunId", "$RunId"
)

if ($Mode -eq "Preview") {
    Invoke-ReleaseScript "publish-release.ps1" @(
        "-Version", $Version,
        "-RunId", "$RunId",
        "-Mode", "Preview"
    )

    Write-Host ""
    Write-Host "PASS: Preview command completed." -ForegroundColor Green
    exit 0
}

if ($ConfirmTag -cne $tag) {
    throw "Draft creation requires -ConfirmTag `"$tag`"."
}

# Draft is idempotent: verify existing remote assets instead of recreating.
$existing = Get-Release -ReleaseTag $tag
if ($existing) {
    if (-not $existing.isDraft) {
        throw "Release is already published: $tag (no changes made)."
    }
    Write-Host "=== Existing draft found; verifying remote files ==="
    Assert-DraftAssets -Release $existing
    Save-DraftState
    Write-Host "PASS: Existing draft verified; no changes made." -ForegroundColor Green
    Write-Host "Repository: $repo"
    Write-Host "Tag: $tag"
    Write-Host "Draft: True"
    Write-Host "URL: $($existing.url)"
    Write-Host "State: $statePath"
    exit 0
}

Invoke-ReleaseScript "publish-release.ps1" @(
    "-Version", $Version,
    "-RunId", "$RunId",
    "-Mode", "Draft",
    "-ConfirmTag", $ConfirmTag
)

$created = Get-Release -ReleaseTag $tag
if (-not $created) { throw "Draft creation was not confirmed." }
Assert-DraftAssets -Release $created
Save-DraftState
Write-Host "PASS: Draft created and verified." -ForegroundColor Green
Write-Host "Repository: $repo"
Write-Host "Tag: $tag"
Write-Host "Draft: True"
Write-Host "URL: $($created.url)"
Write-Host "State: $statePath"
