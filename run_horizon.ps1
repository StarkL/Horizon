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

# ============================================================
# Sync to blog, build, and deploy
# ============================================================
$horizonDir = $PSScriptRoot
$blogDir = "D:\projects\信息聚合\blog"

if (Test-Path $blogDir) {
    # Find the latest ZH summary for the blog
    $latestForBlog = Get-ChildItem -Path $summariesDir -Filter "horizon-*-zh.md" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestForBlog) {
        $date = ($latestForBlog.Name -replace 'horizon-([0-9-]+)-zh\.md', '$1')
        $blogTarget = Join-Path $blogDir "src\data\blog\horizon\$date.md"

        # Check if this date's post already exists and is recent
        if (Test-Path $blogTarget) {
            $blogFileAge = (Get-Item $blogTarget).LastWriteTime
            $summaryAge = $latestForBlog.LastWriteTime
            if ($blogFileAge -ge $summaryAge) {
                Write-Output "[Blog] Post for $date already up-to-date, skipping."
            } else {
                Write-Output "[Blog] Existing post for $date is stale, regenerating."
            }
        }

        # Read summary and transform to blog post format
        $summaryContent = Get-Content $latestForBlog.FullName -Raw -Encoding UTF8

        # Extract date from first line: "# Horizon 每日速递 - YYYY-MM-DD"
        $dateLine = ($summaryContent -split "`n")[0].Trim()
        $postDate = $dateLine -replace '.*?(\d{4}-\d{2}-\d{2}).*', '$1'

        # Extract description from second line: "> 从 X 条资讯中精选 Y 条内容"
        $descLine = ($summaryContent -split "`n")[2].Trim()
        $description = $descLine -replace '> ?', ''

        # Strip the H1 heading from content
        $contentBody = ($summaryContent -split "`n" | Select-Object -Skip 1) -join "`n"

        # Build frontmatter
        $frontmatter = @"
---
author: Horizon
pubDatetime: ${postDate}T00:00:00Z
title: 每日科技要闻 | $postDate
slug: horizon-$postDate
featured: false
draft: false
tags:
  - 每日要闻
  - 科技资讯
description: $description
timezone: Asia/Shanghai
---

"@

        # Write blog post
        $blogDir_target = Join-Path $blogDir "src\data\blog\horizon"
        if (-not (Test-Path $blogDir_target)) {
            New-Item -Path $blogDir_target -ItemType Directory -Force | Out-Null
        }

        $postPath = Join-Path $blogDir_target "$postDate.md"
        $frontmatter + $contentBody | Set-Content -Path $postPath -Encoding UTF8 -NoNewline
        # Ensure file ends with newline
        Add-Content -Path $postPath -Value "`n" -Encoding UTF8
        Write-Output "[Blog] Wrote blog post: $postPath"

        # Build and deploy
        Write-Output "[Blog] Building blog..."
        Push-Location $blogDir
        try {
            pnpm run build
            Write-Output "[Blog] Deploying to VPS..."
            & bash deploy.sh
            Write-Output "[Blog] Deployment complete!"
        } catch {
            Write-Output "[Blog] Build or deploy failed: $_"
        } finally {
            Pop-Location
        }
    } else {
        Write-Output "[Blog] No summary files found, skipping blog sync."
    }
} else {
    Write-Output "[Blog] Blog directory not found at $blogDir, skipping."
}
