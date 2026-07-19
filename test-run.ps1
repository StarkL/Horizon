$ErrorActionPreference = 'Continue'

$logFile = 'D:/projects/信息聚合/Horizon/test-run.log'
if (Test-Path $logFile) { Remove-Item $logFile -Force }

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

Write-Log "Test starting"

Start-Sleep -Seconds 2
$LASTEXITCODE = 0

Write-Log "Core process completed (exit code: $LASTEXITCODE)"
Write-Log "[Blog] Test blog step 1"
Start-Sleep -Seconds 1
Write-Log "[Blog] Test blog step 2"
Start-Sleep -Seconds 1
Write-Log "[Blog] Test blog step 3 - deployment"
Start-Sleep -Seconds 1
Write-Log "[Blog] Test blog step 4 - complete!"
Write-Log "Test completed"
