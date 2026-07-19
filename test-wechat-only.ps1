# Test WeChat generation only
$ErrorActionPreference = "Continue"
$logFile = "$PSScriptRoot\run.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [WeChat-Test] $Message"
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

$pythonExe = "C:\Python312\python.exe"
$transformScript = "$PSScriptRoot\scripts\transform_summary.py"
$summariesDir = "$PSScriptRoot\data\summaries"

# Find latest ZH summary
$latestForBlog = Get-ChildItem -Path $summariesDir -Filter "horizon-*-zh.md" | Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $latestForBlog) {
    Write-Log "[WeChat-Test] No summary file found, exiting."
    exit 1
}

Write-Log "[WeChat-Test] Using summary: $($latestForBlog.Name)"

# Extract date and description
$summaryContent = Get-Content $latestForBlog.FullName -Raw -Encoding UTF8
$dateLine = ($summaryContent -split "`n")[0].Trim()
$postDate = $dateLine -replace '.*?(\d{4}-\d{2}-\d{2}).*', '$1'
$descLine = ($summaryContent -split "`n")[2].Trim()
$description = $descLine -replace '> ?', ''

Write-Log "[WeChat-Test] Date: $postDate, Description: $description"

# Transform to WeChat format
$tempWxFile = [System.IO.Path]::GetTempFileName() + ".md"
Write-Log "[WeChat-Test] Transforming summary to WeChat format..."
try {
    $wxTransformOutput = & $pythonExe $transformScript $latestForBlog.FullName $tempWxFile --format wechat 2>&1
    $wxTransformOutput | Add-Content -Path $logFile -Encoding UTF8
    Write-Log "[WeChat-Test] Transform output written to $tempWxFile"
} catch {
    Write-Log "[WeChat-Test] Failed to transform summary: $_"
    exit 1
}

if (-not (Test-Path $tempWxFile)) {
    Write-Log "[WeChat-Test] Transform file not created!"
    exit 1
}

Write-Log "[WeChat-Test] Transform file size: $((Get-Item $tempWxFile).Length) bytes"

# Add frontmatter
$wxFrontmatter = "---`n" +
    "author: AI自动化`n" +
    "title: 每日科技要闻 | $postDate`n" +
    "description: $description`n" +
    "---`n`n"

Write-Log "[WeChat-Test] Adding frontmatter..."
$wxFrontmatter + (Get-Content $tempWxFile -Raw -Encoding UTF8) |
    ForEach-Object {
        $_ -replace 'https://mp\.weixin\.qq\.com/[^)]+', '[微信公众号文章]'
    } |
    Set-Content -Path $tempWxFile -Encoding UTF8

Write-Log "[WeChat-Test] Frontmatter added, file size: $((Get-Item $tempWxFile).Length) bytes"

# Check cover image
$coverPath = "D:\projects\信息聚合\blog\src\data\blog\horizon\imgs\cover-wx-small.png"
if (Test-Path $coverPath) {
    Write-Log "[WeChat-Test] Cover image exists: $coverPath"
} else {
    Write-Log "[WeChat-Test] Cover image NOT found!"
    exit 1
}

# Content security check
$securityCheckScript = "$PSScriptRoot\scripts\check_wechat_content.py"
$baoyuEnv = "$env:USERPROFILE\.baoyu-skills\.env"
if (Test-Path $securityCheckScript) {
    Write-Log "[WeChat-Test] Running content security check..."
    $checkOutput = & $pythonExe $securityCheckScript $tempWxFile $baoyuEnv 2>&1
    $checkOutput | Add-Content -Path $logFile -Encoding UTF8
    $checkResult = $LASTEXITCODE
    if ($checkResult -ne 0) {
        Write-Log "[WeChat-Test] Content security check FAILED! Skipping publish."
        Remove-Item $tempWxFile -Force -ErrorAction SilentlyContinue
        exit 1
    } else {
        Write-Log "[WeChat-Test] Content security check passed."
    }
} else {
    Write-Log "[WeChat-Test] Security check script not found, skipping check."
}

# Publish to WeChat
Write-Log "[WeChat-Test] Publishing to WeChat Official Account..."
$wechatScript = "C:\Users\Administrator\.claude\skills\baoyu-post-to-wechat\scripts\wechat-api.ts"
if (Test-Path $wechatScript) {
    $wxArgs = @(
        $tempWxFile,
        "--theme", "grace",
        "--color", "blue",
        "--title", "每日科技要闻 | $postDate",
        "--summary", $description,
        "--author", "AI自动化",
        "--cover", $coverPath,
        "--no-cite"
    )
    $publishOutput = & npx -y bun $wechatScript @wxArgs 2>&1
    $publishOutput | Add-Content -Path $logFile -Encoding UTF8
    $publishExitCode = $LASTEXITCODE
    if ($publishExitCode -eq 0) {
        Write-Log "[WeChat-Test] Published successfully!"
    } else {
        Write-Log "[WeChat-Test] Publish failed with exit code: $publishExitCode"
    }
} else {
    Write-Log "[WeChat-Test] WeChat script not found at $wechatScript"
}

Remove-Item $tempWxFile -Force -ErrorAction SilentlyContinue
Write-Log "[WeChat-Test] Test complete."
