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
$env:GITHUB_TOKENS = ($envLines | Where-Object { $_ -match "^GITHUB_TOKENS=" } | ForEach-Object { ($_ -split "=", 2)[1].Trim() })
$env:GITHUB_TOKEN = ($envLines | Where-Object { $_ -match "^GITHUB_TOKEN=" } | ForEach-Object { ($_ -split "=", 2)[1].Trim() })

Set-Location "$PSScriptRoot"

$logFile = Join-Path $PSScriptRoot "run.log"

# Logging helper - writes to both console and log file
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# Don't let non-terminating errors stop the script
$ErrorActionPreference = "Continue"

$horizonExe = "C:\Python312\Scripts\horizon.exe"

# Run Horizon core process
Write-Log "[Horizon] Starting horizon.exe --hours 24..."
try {
    $horizonOutput = & $horizonExe --hours 24 2>&1
    $horizonOutput | Add-Content -Path $logFile -Encoding UTF8
} catch {
    Write-Log "[Horizon] horizon.exe threw an exception: $_"
}
Write-Log "[Horizon] Core process completed (exit code: $LASTEXITCODE), continuing with blog/WeChat steps..."

# Copy the full Chinese summary (before DingTalk truncation) to archive
$archiveDir = "D:\每日信息搜索任务"
if (-not (Test-Path $archiveDir)) {
    New-Item -Path $archiveDir -ItemType Directory -Force | Out-Null
}

$summariesDir = Join-Path "$PSScriptRoot" "data\summaries"
$latestZh = Get-ChildItem -Path $summariesDir -Filter "horizon-*-zh.md" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestZh) {
    Copy-Item -Path $latestZh.FullName -Destination $archiveDir -Force
    Write-Log "[Archive] Copied $($latestZh.Name) -> $archiveDir\"
} else {
    Write-Log "[Archive] No Chinese summary found in $summariesDir"
}

# ============================================================
# Sync to blog, build, and deploy
# ============================================================
$horizonDir = $PSScriptRoot
$blogDir = Join-Path (Split-Path $horizonDir -Parent) "blog"

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
                Write-Log "[Blog] Post for $date already up-to-date, skipping."
            } else {
                Write-Log "[Blog] Existing post for $date is stale, regenerating."
            }
        }

        # Use Python script to transform summary to blog-friendly format
        $pythonExe = "C:\Python312\python.exe"
        $transformScript = Join-Path "$PSScriptRoot" "scripts\transform_summary.py"

        # Read summary content first
        $summaryContent = Get-Content $latestForBlog.FullName -Raw -Encoding UTF8

        # Extract date and description
        $dateLine = ($summaryContent -split "`n")[0].Trim()
        $postDate = $dateLine -replace '.*?(\d{4}-\d{2}-\d{2}).*', '$1'
        $descLine = ($summaryContent -split "`n")[2].Trim()
        $description = $descLine -replace '> ?', ''

        # --- Generate blog post (HTML format) ---
        $tempBlogFile = [System.IO.Path]::GetTempFileName() + ".md"
        & $pythonExe $transformScript $latestForBlog.FullName $tempBlogFile --format blog
        $blogTransformedContent = Get-Content $tempBlogFile -Raw -Encoding UTF8
        Remove-Item $tempBlogFile -Force

        # Use yesterday's date at 23:00 UTC (07:00 next day Beijing) so Astro's postFilter
        # doesn't treat this as a scheduled future post.
        $publishDate = (Get-Date $postDate).AddDays(-1).ToString("yyyy-MM-dd")
        $pubDatetime = "${publishDate}T23:00:00Z"

        # Build frontmatter using explicit UTF-8 byte construction
        $frontmatter = "---`n" +
            "author: Horizon`n" +
            "pubDatetime: ${pubDatetime}`n" +
            "title: 每日科技要闻 | $postDate`n" +
            "slug: horizon-$postDate`n" +
            "featured: false`n" +
            "draft: false`n" +
            "tags:`n" +
            "  - 每日要闻`n" +
            "  - 科技资讯`n" +
            "description: $description`n" +
            "timezone: Asia/Shanghai`n" +
            "---`n`n"

        # Write blog post
        $blogDir_target = Join-Path $blogDir "src\data\blog\horizon"
        if (-not (Test-Path $blogDir_target)) {
            New-Item -Path $blogDir_target -ItemType Directory -Force | Out-Null
        }

        $postPath = Join-Path $blogDir_target "$postDate.md"
        $fullContent = $frontmatter + $blogTransformedContent + "`n"
        # Use .NET API to write UTF-8 without BOM
        [System.IO.File]::WriteAllText($postPath, $fullContent, (New-Object System.Text.UTF8Encoding $false))
        Write-Log "[Blog] Wrote blog post: $postPath"

        # Build and deploy (pure PowerShell, no bash/WSL dependency)
        Write-Log "[Blog] Building blog..."
        Push-Location $blogDir
        $buildOutput = & pnpm run build 2>&1
        $buildExitCode = $LASTEXITCODE
        $buildOutput | Add-Content -Path $logFile -Encoding UTF8

        if ($buildExitCode -eq 0) {
            Write-Log "[Blog] Build succeeded, deploying to VPS..."
            $distDir = Join-Path $blogDir "dist"
            $sshKey = Join-Path $env:USERPROFILE ".ssh\blog_deploy_key"

            # SCP dist/ contents to VPS (copy directory, then flatten on remote)
            $sshResult = & ssh -o BatchMode=yes -o IdentitiesOnly=yes -i $sshKey root@182.92.95.136 `
                "rm -rf /usr/share/nginx/html/blog_new && mkdir -p /usr/share/nginx/html/blog_new" 2>&1
            $sshResult | Add-Content -Path $logFile -Encoding UTF8

            & scp -o BatchMode=yes -o IdentitiesOnly=yes -i $sshKey -r "$distDir" root@182.92.95.136:/usr/share/nginx/html/blog_new/ 2>&1 | Add-Content -Path $logFile -Encoding UTF8

            if ($LASTEXITCODE -eq 0) {
                # Flatten: move dist/* to blog_new/, then swap
                $flattenResult = & ssh -o BatchMode=yes -o IdentitiesOnly=yes -i $sshKey root@182.92.95.136 `
                    "shopt -s dotglob && mv /usr/share/nginx/html/blog_new/dist/* /usr/share/nginx/html/blog_new/ && rmdir /usr/share/nginx/html/blog_new/dist && rm -rf /usr/share/nginx/html/blog && mv /usr/share/nginx/html/blog_new /usr/share/nginx/html/blog" 2>&1
                $flattenResult | Add-Content -Path $logFile -Encoding UTF8
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "[Blog] Deployment complete!"
                } else {
                    Write-Log "[Blog] Flatten/swap FAILED (exit code: $LASTEXITCODE)..."
                }
            } else {
                Write-Log "[Blog] SCP upload FAILED (exit code: $LASTEXITCODE)..."
                & ssh -o BatchMode=yes -o IdentitiesOnly=yes -i $sshKey root@182.92.95.136 "rm -rf /usr/share/nginx/html/blog_new" 2>&1
            }
        } else {
            Write-Log "[Blog] Build FAILED (exit code: $buildExitCode)..."
        }
        Pop-Location

        # --- Generate WeChat version (pure markdown) ---
        Write-Log "[WeChat] Generating WeChat version..."
        $tempWxFile = [System.IO.Path]::GetTempFileName() + ".md"

        try {
            # Call transform_summary.py to generate WeChat format
            $wxTransformOutput = & $pythonExe $transformScript $latestForBlog.FullName $tempWxFile --format wechat 2>&1
            $wxTransformOutput | Add-Content -Path $logFile -Encoding UTF8
            Write-Log "[WeChat] Transform output written to $tempWxFile"
        } catch {
            Write-Log "[WeChat] Failed to transform summary: $_"
        }

        if (-not (Test-Path $tempWxFile)) {
            Write-Log "[WeChat] WeChat transform file not created, skipping WeChat publish."
        } else {
            # Check if sanitized content is too short (all items blocked)
            $wxContent = Get-Content $tempWxFile -Raw -Encoding UTF8
            # Remove separators and whitespace to check actual content length
            $wxClean = ($wxContent -replace '^---\s*$', '').Trim()
            if ($wxClean.Length -lt 100) {
                Write-Log "[WeChat] Sanitized content too short ($($wxClean.Length) chars), likely all items filtered. Skipping publish."
                Remove-Item $tempWxFile -Force -ErrorAction SilentlyContinue
            } else {
                Write-Log "[WeChat] Transform output written to $tempWxFile ($($wxContent.Length) chars)"

                # Add frontmatter for WeChat
                $wxFrontmatter = "---`n" +
                    "author: AI自动化`n" +
                    "title: 每日科技要闻 | $postDate`n" +
                    "description: $description`n" +
                    "---`n`n"
                $wxFrontmatter + (Get-Content $tempWxFile -Raw -Encoding UTF8) |
                    ForEach-Object {
                        $_ -replace 'https://mp\.weixin\.qq\.com/[^)]+', '[微信公众号文章]'
                    } |
                    Set-Content -Path $tempWxFile -Encoding UTF8

                # Generate WeChat cover image (900x383)
                $coverDir = Join-Path $blogDir_target "imgs"
                if (-not (Test-Path $coverDir)) {
                    New-Item -Path $coverDir -ItemType Directory -Force | Out-Null
                }
                $coverPath = Join-Path $coverDir "cover-wx-small.png"
                if (-not (Test-Path $coverPath)) {
                    Write-Log "[WeChat] Generating cover image..."
                    $imagineScript = "C:\Users\Administrator\.claude\skills\baoyu-imagine\scripts\main.ts"
                    if (Test-Path $imagineScript) {
                        & npx -y bun $imagineScript `
                            --prompt "科技资讯博客封面，现代简洁风格，蓝色科技色调，渐变背景，适合微信公众号封面，宽屏横版" `
                            --image $coverPath `
                            --provider dashscope `
                            --model wan2.7-image `
                            --size 1920x817 `
                            --quality 2k
                        Write-Log "[WeChat] Cover generated: $coverPath"
                    }
                }

                # Publish to WeChat Official Account via VPS
                if ((Test-Path $tempWxFile) -and (Test-Path $coverPath)) {
                    # Content security check is now done on VPS side (no local IP dependency)
                    Write-Log "[WeChat] Content security check will run on VPS..."
                    Write-Log "[WeChat] Publishing to WeChat via VPS..."

                    # Step 1: Render HTML locally
                    $renderScript = Join-Path "$PSScriptRoot" "scripts\render-wechat.ts"
                    $tempHtmlFile = [System.IO.Path]::GetTempFileName() + ".html"
                    if (Test-Path $renderScript) {
                        $renderOutput = & npx -y bun $renderScript $tempWxFile $tempHtmlFile "每日科技要闻 | $postDate" "grace" "blue" 2>&1
                        $renderOutput | Add-Content -Path $logFile -Encoding UTF8
                    } else {
                        Copy-Item $tempWxFile $tempHtmlFile -Force
                        Write-Log "[WeChat] Render script not found, using raw markdown."
                    }

                    # Step 2: Read credentials and build small config JSON
                    $envPath = "$env:USERPROFILE\.baoyu-skills\.env"
                    $appId = ""
                    $appSecret = ""
                    if (Test-Path $envPath) {
                        $envLines = Get-Content $envPath -Encoding UTF8
                        $appId = ($envLines | Where-Object { $_ -match "^WECHAT_APP_ID=" } | ForEach-Object { ($_ -split "=", 2)[1].Trim() })
                        $appSecret = ($envLines | Where-Object { $_ -match "^WECHAT_APP_SECRET=" } | ForEach-Object { ($_ -split "=", 2)[1].Trim() })
                    }

                    $payloadPath = [System.IO.Path]::GetTempFileName() + ".json"
                    $configJson = @"
{
  "app_id": "$appId",
  "app_secret": "$appSecret",
  "title": "每日科技要闻 | $postDate",
  "author": "AI自动化",
  "cover_path": "/tmp/wechat-cover.png"
}
"@
                    [System.IO.File]::WriteAllText($payloadPath, $configJson, (New-Object System.Text.UTF8Encoding $false))

                    # Step 3: SCP HTML + config + cover to VPS
                    $sshKey = Join-Path $env:USERPROFILE ".ssh\blog_deploy_key"

                    $scpConfig = & scp -o BatchMode=yes -o IdentitiesOnly=yes -i $sshKey $payloadPath root@182.92.95.136:/tmp/wechat-config.json 2>&1
                    $scpConfig | Add-Content -Path $logFile -Encoding UTF8
                    $configExitCode = $LASTEXITCODE

                    if (Test-Path $tempHtmlFile) {
                        $scpHtml = & scp -o BatchMode=yes -o IdentitiesOnly=yes -i $sshKey $tempHtmlFile root@182.92.95.136:/tmp/wechat-content.html 2>&1
                        $scpHtml | Add-Content -Path $logFile -Encoding UTF8
                    } else {
                        $configExitCode = 1
                        Write-Log "[WeChat] HTML file not found, skipping."
                    }
                    $htmlExitCode = $LASTEXITCODE

                    if (Test-Path $coverPath) {
                        $scpCover = & scp -o BatchMode=yes -o IdentitiesOnly=yes -i $sshKey $coverPath root@182.92.95.136:/tmp/wechat-cover.png 2>&1
                        $scpCover | Add-Content -Path $logFile -Encoding UTF8
                    } else {
                        $configExitCode = 1
                        Write-Log "[WeChat] Cover image not found, skipping."
                    }
                    $coverExitCode = $LASTEXITCODE

                    if ($configExitCode -eq 0 -and $htmlExitCode -eq 0 -and $coverExitCode -eq 0) {
                        Write-Log "[WeChat] Triggering VPS publish..."
                        $sshResult = & ssh -o BatchMode=yes -o IdentitiesOnly=yes -i $sshKey root@182.92.95.136 `
                            "bash /opt/scripts/wechat-publish.sh" 2>&1
                        $sshResult | Add-Content -Path $logFile -Encoding UTF8
                        if ($LASTEXITCODE -eq 0) {
                            Write-Log "[WeChat] Published successfully via VPS!"
                        } else {
                            Write-Log "[WeChat] VPS publish failed (exit code: $LASTEXITCODE)..."
                        }
                    } else {
                        Write-Log "[WeChat] SCP upload FAILED (exit code: $LASTEXITCODE)..."
                    }

                    Remove-Item $tempHtmlFile -Force -ErrorAction SilentlyContinue
                    Remove-Item $payloadPath -Force -ErrorAction SilentlyContinue
                }
                Remove-Item $tempWxFile -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-Log "[Blog] No summary files found, skipping blog sync."
    }
} else {
    Write-Log "[Blog] Blog directory not found at $blogDir, skipping."
}
