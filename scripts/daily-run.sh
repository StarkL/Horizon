#!/usr/bin/env bash
# Horizon daily run + deploy to GitHub Pages + Blog
# Usage: ./scripts/daily-run.sh
# Cron:  0 6:30 * * * /path/to/horizon/scripts/daily-run.sh >> /path/to/horizon/logs/cron.log 2>&1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

cd "$PROJECT_DIR"

echo "$LOG_PREFIX Starting Horizon daily run..."

# 1. Pull latest code
git pull --quiet origin main

# 2. Install/update dependencies
uv sync --quiet

# 3. Run Horizon
uv run horizon --hours 24

# 4. Copy Chinese summary to blog and deploy
echo "$LOG_PREFIX Deploying summary to blog..."

TODAY=$(date '+%Y-%m-%d')
SUMMARY_SRC="data/summaries/horizon-${TODAY}-zh.md"
BLOG_TARGET_DIR="$(dirname "$SCRIPT_DIR")/../blog/src/data/blog/horizon"
BLOG_FILE="${BLOG_TARGET_DIR}/${TODAY}.md"

if [ -f "$SUMMARY_SRC" ]; then
    mkdir -p "$BLOG_TARGET_DIR"

    # Extract item counts from the summary
    TOTAL_FETCHED=$(grep -oP '从 \K\d+' "$SUMMARY_SRC" | head -1)
    IMPORTANT_COUNT=$(grep -oP '精选 \K\d+' "$SUMMARY_SRC" | head -1)

    # Prepend AstroPaper front matter
    cat > "$BLOG_FILE" <<EEOF
---
author: Horizon
pubDatetime: ${TODAY}T00:00:00Z
title: 每日科技要闻 | ${TODAY}
slug: horizon-${TODAY}
featured: false
draft: false
tags:
  - 每日要闻
  - 科技资讯
description: 从 ${TOTAL_FETCHED:-0} 条资讯中精选 ${IMPORTANT_COUNT:-0} 条内容
timezone: Asia/Shanghai
---

EEOF

    # Append the summary content (skip the leading H1 header to avoid duplication)
    tail -n +3 "$SUMMARY_SRC" >> "$BLOG_FILE"

    echo "$LOG_PREFIX Copied summary to blog: $BLOG_FILE"

    # 5. Deploy blog
    DEPLOY_SCRIPT="$(dirname "$SCRIPT_DIR")/../blog/deploy.sh"
    if [ -f "$DEPLOY_SCRIPT" ]; then
        echo "$LOG_PREFIX Running deploy.sh..."
        bash "$DEPLOY_SCRIPT"
    else
        echo "$LOG_PREFIX deploy.sh not found, running manual build+deploy..."
        BLOG_DIR="$(dirname "$SCRIPT_DIR")/../blog"
        cd "$BLOG_DIR"
        pnpm run build
        tar cf - -C dist . | ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i ~/.ssh/blog_deploy_key root@182.92.95.136 "cd /usr/share/nginx/html/blog && rm -rf * && tar xf -"
        echo "$LOG_PREFIX Blog deployed manually."
    fi
else
    echo "$LOG_PREFIX No Chinese summary found for today ($SUMMARY_SRC), skipping blog deploy."
fi

# 6. Also copy to archive directory (original behavior)
ARCHIVE_DIR="D:/每日信息搜索任务"
if command -v cmd.exe &>/dev/null || [[ "$OS" == *"Windows"* ]]; then
    # Windows: use PowerShell for path handling
    POWERSHELL -Command "& {
        \$archiveDir = 'D:\\每日信息搜索任务'
        if (-not (Test-Path \$archiveDir)) { New-Item -Path \$archiveDir -ItemType Directory -Force | Out-Null }
        \$summariesDir = Join-Path '$PROJECT_DIR' 'data\summaries'
        \$latestZh = Get-ChildItem -Path \$summariesDir -Filter 'horizon-*-zh.md' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (\$latestZh) {
            Copy-Item -Path \$latestZh.FullName -Destination \$archiveDir -Force
            Write-Output '[$LOG_PREFIX Archive] Copied ' \$latestZh.Name '-> ' \$archiveDir
        }
    }" 2>/dev/null || echo "$LOG_PREFIX Archive copy failed (expected on non-Windows)."
fi

echo "$LOG_PREFIX Done."
