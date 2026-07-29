# Horizon 发布脚本（本机适配版）
# 将最新中文摘要发布到：1) VPS VitePress 博客  2) 微信公众号草稿箱
# 与 run_horizon.ps1 的差异：本机博客是 VitePress(docs/)，SSH 用 admin+id_ed25519+sudo
# 用法: .\publish-to-vps.ps1 [-Stage all|blog|wechat]

param(
    [ValidateSet("all", "blog", "wechat")]
    [string]$Stage = "all"
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

# ---- 路径与常量（本机适配）----
$root         = $PSScriptRoot
$pythonExe    = Join-Path $root ".venv\Scripts\python.exe"
$transform    = Join-Path $root "scripts\transform_summary.py"
$renderTs     = Join-Path $root "scripts\render-wechat.ts"
$summariesDir = Join-Path $root "data\summaries"
$coverSource  = Join-Path $root "scripts\cover.png"
$blogDir      = Join-Path (Split-Path $root -Parent) "blog"
$sshKey       = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
$vps          = "admin@182.92.95.136"
$sshOpts      = @("-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=20", "-i", $sshKey)
$logFile      = Join-Path $root "publish.log"

function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $Message"
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# ---- 选取最新中文摘要 ----
$latest = Get-ChildItem -Path $summariesDir -Filter "horizon-*-zh.md" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $latest) { Write-Log "❌ 未找到中文摘要，退出"; exit 1 }
$postDate = $latest.Name -replace 'horizon-([0-9-]+)-zh\.md', '$1'
$fixedDesc = "AI 驱动的信息聚合，精选全球科技动态"
Write-Log "使用摘要: $($latest.Name) (date=$postDate, Stage=$Stage)"

# ===================== 博客 =====================
if ($Stage -eq "all" -or $Stage -eq "blog") {
    Write-Log "===== [Blog] 开始 ====="

    # 转换为博客正文（HTML 标题，VitePress 可渲染）
    $tempBlog = [System.IO.Path]::GetTempFileName() + ".md"
    & $pythonExe $transform $latest.FullName $tempBlog --format blog
    $body = Get-Content $tempBlog -Raw -Encoding UTF8
    Remove-Item $tempBlog -Force

    # VitePress frontmatter（对齐现有文章格式）+ 正文
    $front = "---`ntitle: `"每日科技要闻`"`ndate: $postDate`ndescription: `"$fixedDesc`"`n---`n`n"
    $postDir = Join-Path $blogDir "docs\posts\horizon"
    if (-not (Test-Path $postDir)) { New-Item -Path $postDir -ItemType Directory -Force | Out-Null }
    $postPath = Join-Path $postDir "$postDate.md"
    [System.IO.File]::WriteAllText($postPath, ($front + $body + "`n"), (New-Object System.Text.UTF8Encoding $false))
    Write-Log "[Blog] 写入文章: $postPath"

    # 本地构建 VitePress
    Write-Log "[Blog] 构建 VitePress (pnpm run build)..."
    Push-Location $blogDir
    $buildOut = & pnpm run build 2>&1
    $buildCode = $LASTEXITCODE
    $buildOut | Add-Content -Path $logFile -Encoding UTF8
    Pop-Location

    if ($buildCode -ne 0) {
        Write-Log "❌ [Blog] 构建失败 (exit $buildCode)，跳过部署"
    } else {
        Write-Log "[Blog] 构建成功，准备部署..."
        # VitePress 产物在 docs/.vitepress/dist（不是 Astro 的 blog/dist）
        $distDir = Join-Path $blogDir "docs\.vitepress\dist"
        if (-not (Test-Path (Join-Path $distDir "index.html"))) {
            Write-Log "❌ [Blog] 构建产物缺失 ($distDir 无 index.html)，跳过部署以保护线上"
        } else {
            $tarPath = Join-Path $env:TEMP "hz_blog_dist.tar.gz"
            if (Test-Path $tarPath) { Remove-Item $tarPath -Force }
            # 打包 dist 内容（-C 进 dist 目录，归档 . 即全部内容）
            & tar -czf $tarPath -C $distDir . 2>&1 | Add-Content -Path $logFile -Encoding UTF8
            $tarSize = if (Test-Path $tarPath) { (Get-Item $tarPath).Length } else { 0 }
            # 防御：包过小（<50KB）说明产物异常，拒绝部署以免空包覆盖线上
            if ($tarSize -lt 50000) {
                Write-Log "❌ [Blog] 打包异常（仅 $tarSize bytes），拒绝部署以保护线上"
            } else {
                Write-Log "[Blog] 打包完成 ($tarSize bytes)，上传并部署..."
                # 上传 tar 包到 VPS /tmp
                & scp @sshOpts $tarPath "${vps}:/tmp/hz_blog_dist.tar.gz" 2>&1 | Add-Content -Path $logFile -Encoding UTF8
                $scpCode = $LASTEXITCODE
                if ($scpCode -ne 0) {
                    Write-Log "❌ [Blog] SCP 上传失败 (exit $scpCode)"
                } else {
                    # sudo 解压归位到 nginx（归档即内容，无需 strip-components），保持属主
                    $remote = "sudo rm -rf /usr/share/nginx/html/blog && sudo mkdir -p /usr/share/nginx/html/blog && sudo tar -xzf /tmp/hz_blog_dist.tar.gz -C /usr/share/nginx/html/blog && sudo chown -R blog-deploy:blog-deploy /usr/share/nginx/html/blog && rm -f /tmp/hz_blog_dist.tar.gz && echo BLOG_DEPLOY_OK"
                    $dep = & ssh @sshOpts $vps $remote 2>&1
                    $dep | Add-Content -Path $logFile -Encoding UTF8
                    if ($dep -match "BLOG_DEPLOY_OK") {
                        Write-Log "✅ [Blog] VPS 部署完成"
                    } else {
                        Write-Log "❌ [Blog] 部署未确认成功，请查 publish.log"
                    }
                }
            }
            Remove-Item $tarPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# ===================== 微信公众号草稿箱 =====================
if ($Stage -eq "all" -or $Stage -eq "wechat") {
    Write-Log "===== [WeChat] 开始 ====="

    # 转换为微信格式（含敏感词过滤/语气软化）
    $tempWx = [System.IO.Path]::GetTempFileName() + ".md"
    & $pythonExe $transform $latest.FullName $tempWx --format wechat
    $wxContent = Get-Content $tempWx -Raw -Encoding UTF8
    $wxClean = ($wxContent -replace '^---\s*$', '').Trim()

    if ($wxClean.Length -lt 100) {
        Write-Log "⚠️ [WeChat] 净化后内容过短($($wxClean.Length)字符)，可能全被过滤，跳过发布"
        Remove-Item $tempWx -Force -ErrorAction SilentlyContinue
    } else {
        $title = "每日科技要闻 | $postDate"
        $wxFront = "---`nauthor: AI自动化`ntitle: $title`ndescription: $fixedDesc`n---`n`n"
        $combined = ($wxFront + $wxContent) -replace 'https://mp\.weixin\.qq\.com/[^)]+', '[微信公众号文章]'
        [System.IO.File]::WriteAllText($tempWx, $combined, (New-Object System.Text.UTF8Encoding $false))
        Write-Log "[WeChat] 净化转换完成 ($($combined.Length) 字符)"

        # 渲染为微信排版 HTML
        $tempHtml = [System.IO.Path]::GetTempFileName() + ".html"
        if (Test-Path $renderTs) {
            $rendOut = & npx -y bun $renderTs $tempWx $tempHtml $title "grace" "blue" 2>&1
            $rendOut | Add-Content -Path $logFile -Encoding UTF8
        }
        if (-not (Test-Path $tempHtml) -or (Get-Item $tempHtml).Length -lt 100) {
            Write-Log "⚠️ [WeChat] HTML 渲染异常，回退为原始 markdown"
            Copy-Item $tempWx $tempHtml -Force
        }
        Write-Log "[WeChat] HTML 就绪 ($((Get-Item $tempHtml).Length) bytes)"

        # 读取微信凭证
        $envPath = Join-Path $env:USERPROFILE ".baoyu-skills\.env"
        $appId = ""; $appSecret = ""
        if (Test-Path $envPath) {
            $el = Get-Content $envPath -Encoding UTF8
            $appId = ($el | Where-Object { $_ -match "^WECHAT_APP_ID=" } | ForEach-Object { ($_ -split "=", 2)[1].Trim() })
            $appSecret = ($el | Where-Object { $_ -match "^WECHAT_APP_SECRET=" } | ForEach-Object { ($_ -split "=", 2)[1].Trim() })
        }

        if (-not $appId -or -not $appSecret) {
            Write-Log "❌ [WeChat] 缺少 WECHAT_APP_ID/SECRET 凭证，跳过"
        } else {
            # 用 ConvertTo-Json 安全转义（避免密钥特殊字符破坏 JSON）
            $cfg = @{
                app_id     = $appId
                app_secret = $appSecret
                title      = $title
                author     = "AI自动化"
                cover_path = "/tmp/wechat-cover.png"
            }
            $configJson = $cfg | ConvertTo-Json
            $payloadPath = [System.IO.Path]::GetTempFileName() + ".json"
            [System.IO.File]::WriteAllText($payloadPath, $configJson, (New-Object System.Text.UTF8Encoding $false))

            # 上传 HTML / config / 封面 到 VPS /tmp（admin 可写）
            & scp @sshOpts $payloadPath "${vps}:/tmp/wechat-config.json" 2>&1 | Add-Content -Path $logFile -Encoding UTF8
            & scp @sshOpts $tempHtml "${vps}:/tmp/wechat-content.html" 2>&1 | Add-Content -Path $logFile -Encoding UTF8
            & scp @sshOpts $coverSource "${vps}:/tmp/wechat-cover.png" 2>&1 | Add-Content -Path $logFile -Encoding UTF8
            Write-Log "[WeChat] 已上传 HTML/config/cover 到 VPS"

            # 触发 VPS 端发布到草稿箱（sudo 保持与原 root 行为一致）
            $pub = & ssh @sshOpts $vps "sudo bash /opt/scripts/wechat-publish.sh" 2>&1
            $pubCode = $LASTEXITCODE
            $pub | Add-Content -Path $logFile -Encoding UTF8
            Write-Log "[WeChat] 发布脚本退出码: $pubCode"
            Write-Log "[WeChat] 输出: $($pub -join ' | ')"
            if ($pubCode -eq 0) { Write-Log "✅ [WeChat] 草稿箱推送完成" } else { Write-Log "❌ [WeChat] 草稿箱推送失败，请查 publish.log" }

            Remove-Item $payloadPath -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $tempHtml -Force -ErrorAction SilentlyContinue
        Remove-Item $tempWx -Force -ErrorAction SilentlyContinue
    }
}

Write-Log "===== 全部完成 (Stage=$Stage) ====="
