# Horizon Daily Automation
# Runs every day at 6:00 AM
# Pipeline: fetch -> convert -> blog build/deploy -> cover -> wechat publish

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"
$env:DASHSCOPE_API_KEY = "sk-55421dc6eaf24e39909f26c419bd8250"

$logDir = "F:\document\pf\IT\projects\Horizon\logs"
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$logFile = Join-Path $logDir "horizon-$(Get-Date -Format 'yyyyMMdd').log"

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

Log "========== Horizon Daily Run Started =========="

# === Step 1: Run Horizon ===
Log "[1/5] Running Horizon fetch + AI analysis..."
try {
    Set-Location "F:\document\pf\IT\projects\Horizon"
    $output = & "C:\Users\29093\anaconda3\python.exe" -m uv run horizon --hours 24 2>&1
    $output | Add-Content -Path $logFile -Encoding UTF8
    Log "[1/5] Horizon completed (exit code: $LASTEXITCODE)"
} catch {
    Log "[1/5] Horizon FAILED: $_"
}

# === Step 2: Convert to VitePress article ===
Log "[2/5] Converting to VitePress article..."
try {
    $today = Get-Date -Format "yyyy-MM-dd"
    $summaryFile = "F:\document\pf\IT\projects\Horizon\data\summaries\horizon-${today}-zh.md"
    if (Test-Path $summaryFile) {
        $articleFile = "F:\document\pf\IT\projects\blog\docs\posts\horizon\${today}.md"
        $content = Get-Content $summaryFile -Raw -Encoding UTF8
        $lines = $content -split "`n"
        $result = @()
        $skipIndex = $false
        foreach ($line in $lines) {
            if ($line -match '^# ') { continue }
            if ($line -match '今日要闻') { $skipIndex = $true; continue }
            if ($skipIndex) { if ($line.Trim() -eq '---') { $skipIndex = $false }; continue }
            if ($line.Trim() -match '<a id="item-\d+"></a>') { continue }
            if ($line.Trim() -in @('<details open>', '</details>', '<details>', '</details>')) { continue }
            if ($line -match '^- \[' -and $line -match '#item-') { continue }
            if ($line -match '\s*<summary>(.+?)</summary>') {
                $txt = $Matches[1]
                if ($txt -match '\[([^\]]+)\]\(([^)]+)\)') {
                    $title = $Matches[1]; $url = $Matches[2]
                    $score = ''; if ($txt -match '([\d.]+/10)') { $score = $Matches[1] }
                    $result += "## [$title]($url) $score".Trim()
                } else {
                    $title = $txt -replace '\s*[\d.]+/10$', '' -replace '^\d+\.', ''
                    $score = ''; if ($txt -match '([\d.]+/10)') { $score = $Matches[1] }
                    $result += "## $title $score".Trim()
                }
                continue
            }
            if ($line -match '^### ') { continue }
            $result += $line
        }
        $text = ($result -join "`n") -replace '\n{4,}', "`n`n`n"
        $fm = "---`ntitle: `"`u6BCF日科技要闻`"`ndate: $today`ndescription: `"AI 驱动的信息聚合，精选全球科技动态`"`n---`n`n"
        Set-Content -Path $articleFile -Value ($fm + $text) -Encoding UTF8
        Log "[2/5] Article created: $articleFile"
    } else {
        Log "[2/5] No summary found for today, skipping"
    }
} catch {
    Log "[2/5] Article conversion FAILED: $_"
}

# === Step 3: Build blog + deploy to VPS ===
Log "[3/5] Building blog and deploying..."
try {
    Set-Location "F:\document\pf\IT\projects\blog"
    $buildOutput = & pnpm run build 2>&1
    $buildOutput | Add-Content -Path $logFile -Encoding UTF8
    Log "[3/5] Build completed (exit code: $LASTEXITCODE)"

    if ($LASTEXITCODE -eq 0) {
        $sshKey = "$env:USERPROFILE\.ssh\id_ed25519"
        $ssh = "C:\Program Files\Git\usr\bin\ssh.exe"
        $scp = "C:\Program Files\Git\usr\bin\scp.exe"

        & $ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i $sshKey admin@182.92.95.136 "rm -rf /tmp/blog_dist" 2>$null
        & $scp -o BatchMode=yes -o StrictHostKeyChecking=no -i $sshKey -r "F:\document\pf\IT\projects\blog\docs\.vitepress\dist" admin@182.92.95.136:/tmp/blog_dist 2>$null
        $deployResult = & $ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i $sshKey admin@182.92.95.136 "sudo rm -rf /usr/share/nginx/html/blog ; sudo mv /tmp/blog_dist /usr/share/nginx/html/blog ; sudo chown -R root:root /usr/share/nginx/html/blog ; echo OK" 2>&1
        Log "[3/5] Blog deployed: $deployResult"
    }
} catch {
    Log "[3/5] Blog deploy FAILED: $_"
}

# === Step 4: Use fixed cover ===
Log "[4/5] Using fixed cover image..."
try {
    $today = Get-Date -Format "yyyy-MM-dd"
    $coverPath = "$env:TEMP\cover-auto-${today}.png"
    $fixedCover = "F:\document\pf\IT\projects\Horizon\scripts\cover.png"
    if (Test-Path $fixedCover) {
        Copy-Item $fixedCover $coverPath -Force
        Log "[4/5] Cover: $(if(Test-Path $coverPath){(Get-Item $coverPath).Length.ToString() + ' bytes'}else{'FAIL'})"
    } else {
        Log "[4/5] Fixed cover not found: $fixedCover"
    }
} catch {
    Log "[4/5] Cover FAILED: $_"
}

# === Step 5: Publish to WeChat ===
Log "[5/5] Publishing to WeChat..."
try {
    $today = Get-Date -Format "yyyy-MM-dd"
    $summaryFile = "F:\document\pf\IT\projects\Horizon\data\summaries\horizon-${today}-zh.md"
    $coverPath = "$env:TEMP\cover-auto-${today}.png"
    $sshKey = "$env:USERPROFILE\.ssh\id_ed25519"
    $ssh = "C:\Program Files\Git\usr\bin\ssh.exe"
    $scp = "C:\Program Files\Git\usr\bin\scp.exe"

    if (Test-Path $summaryFile -and Test-Path $coverPath) {
        $tempWxFile = [System.IO.Path]::GetTempFileName() + ".md"
        & "C:\Users\29093\anaconda3\python.exe" "F:\document\pf\IT\projects\Horizon\scripts\transform_summary.py" $summaryFile $tempWxFile --format wechat 2>&1 | Add-Content -Path $logFile -Encoding UTF8

        $tempHtmlFile = [System.IO.Path]::GetTempFileName() + ".html"
        & npx -y bun "F:\document\pf\IT\projects\Horizon\scripts\render-wechat.ts" $tempWxFile $tempHtmlFile "每日科技要闻 | $today" "grace" "blue" 2>&1 | Add-Content -Path $logFile -Encoding UTF8

        & $scp -o BatchMode=yes -o StrictHostKeyChecking=no -i $sshKey $tempHtmlFile admin@182.92.95.136:/tmp/wechat-content.html 2>$null
        & $scp -o BatchMode=yes -o StrictHostKeyChecking=no -i $sshKey $coverPath admin@182.92.95.136:/tmp/wechat-cover.png 2>$null

        $configJson = @{
            app_id = "wx1413a97c5ecec720"
            app_secret = "add87948a1d33c170b60ade2c0a0998c"
            title = "每日科技要闻 | $today"
            author = "AI自动化"
            cover_path = "/tmp/wechat-cover.png"
        } | ConvertTo-Json -Compress
        $configPath = [System.IO.Path]::GetTempFileName() + ".json"
        [System.IO.File]::WriteAllText($configPath, $configJson, (New-Object System.Text.UTF8Encoding $false))
        & $scp -o BatchMode=yes -o StrictHostKeyChecking=no -i $sshKey $configPath admin@182.92.95.136:/tmp/wechat-config.json 2>$null

        $publishResult = & $ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i $sshKey admin@182.92.95.136 "bash /opt/scripts/wechat-publish.sh" 2>&1
        $publishResult | Add-Content -Path $logFile -Encoding UTF8
        Log "[5/5] WeChat publish completed"
    } else {
        Log "[5/5] Missing files, skipping WeChat publish"
    }
} catch {
    Log "[5/5] WeChat publish FAILED: $_"
}

Log "========== Horizon Daily Run Completed =========="

