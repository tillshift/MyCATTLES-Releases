param(
    [switch]$StopOnly
)

$ErrorActionPreference = 'Stop'

$key = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.mycattles.bridge'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

$ownManifest = [IO.Path]::GetFullPath(
    (Join-Path $dir 'com.mycattles.bridge.json')
)

$ownHost = [IO.Path]::GetFullPath(
    (Join-Path $dir 'mycattles_host.exe')
)

if (-not $StopOnly) {
    # 1. Native Messaging登録解除
    if (Test-Path -LiteralPath $key) {
        $registered = (Get-Item -LiteralPath $key).GetValue('')

        if ([string]::Equals(
            $registered,
            $ownManifest,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            Remove-Item -LiteralPath $key -Recurse -Force
            Write-Host 'PASS: Native Messaging registration removed.'
        }
        else {
            Write-Host 'PASS: Registration belongs to another installation; left unchanged.'
        }
    }
    else {
        Write-Host 'PASS: Native Messaging registration already absent.'
    }

}

# 2. このインストール先のNative Hostのみ終了
$hosts = @(
    Get-CimInstance Win32_Process -Filter "Name = 'mycattles_host.exe'" |
        Where-Object {
            $_.ExecutablePath -and
            [string]::Equals(
                [IO.Path]::GetFullPath($_.ExecutablePath),
                $ownHost,
                [StringComparison]::OrdinalIgnoreCase
            )
        }
)

foreach ($hostProcess in $hosts) {
    Write-Host "Stopping Native Host PID=$($hostProcess.ProcessId)"

    Stop-Process -Id $hostProcess.ProcessId -Force -ErrorAction Stop
}

# 3. プロセス終了待ち
foreach ($hostProcess in $hosts) {
    try {
        Wait-Process -Id $hostProcess.ProcessId -Timeout 10 -ErrorAction Stop
    }
    catch {
        if (Get-Process -Id $hostProcess.ProcessId -ErrorAction SilentlyContinue) {
            throw "Native Host process did not exit: PID=$($hostProcess.ProcessId)"
        }
    }
}

Write-Host 'PASS: Native Host shutdown completed.'
