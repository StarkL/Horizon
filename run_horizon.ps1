# Horizon Daily Runner Script
# Run by Windows Task Scheduler at 6:30 AM daily

# Force UTF-8 output encoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

# Read secrets from .env
$envLines = Get-Content "$PSScriptRoot\.env" -Encoding UTF8
$env:ANTHROPIC_API_KEY = ($envLines | Where-Object { $_ -match "^ANTHROPIC_API_KEY=" } | ForEach-Object { ($_ -split "=", 2)[1].Trim() })
$env:HORIZON_WEBHOOK_URL = ($envLines | Where-Object { $_ -match "^HORIZON_WEBHOOK_URL=" } | ForEach-Object { ($_ -split "=", 2)[1].Trim() })

Set-Location "$PSScriptRoot"

$logFile = Join-Path $PSScriptRoot "run.log"
$horizonExe = "C:\Python312\Scripts\horizon.exe"

& $horizonExe --hours 24 2>&1 | Add-Content -Path $logFile -Encoding UTF8

# Copy the full Chinese summary (before DingTalk truncation) to archive
$archiveDir = "D:\每日信息搜索任务"
if (-not (Test-Path $archiveDir)) {
    New-Item -Path $archiveDir -ItemType Directory -Force | Out-Null
}

$summariesDir = Join-Path "$PSScriptRoot" "data\summaries"
$latestZh = Get-ChildItem -Path $summariesDir -Filter "horizon-*-zh.md" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestZh) {
    Copy-Item -Path $latestZh.FullName -Destination $archiveDir -Force
    Write-Output "[Archive] Copied $($latestZh.Name) -> $archiveDir\"
} else {
    Write-Output "[Archive] No Chinese summary found in $summariesDir"
}
