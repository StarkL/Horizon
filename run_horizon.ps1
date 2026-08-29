# Horizon 每日全流程运行脚本（本机适配版）
# 由 Windows 任务计划程序每天 6:30 调用
# 流程: 聚合(venv) -> 归档 -> 发布博客+微信(委托已验证的 publish-to-vps.ps1)
# 本机适配要点:
#   - Python 使用项目 .venv（直接跑源码模块，确保用最新代码，不依赖 PATH）
#   - 发布逻辑统一委托 publish-to-vps.ps1（VitePress 博客 + admin+sudo SSH + 微信草稿箱）

param(
    [int]$Hours = 24   # 聚合时间窗口（小时），默认 24，补跑可传 48 等
)

# ============================================================
# AI 模型配置（更新 key 来源或端点改这里）
# ============================================================
$AI_KEY_ENV_NAME = "CODING_PLAN__API_KEY"                # 从哪个系统环境变量读 API key
$AI_BASE_URL = "https://coding.dashscope.aliyuncs.com/apps/anthropic"
$AI_CUSTOM_HEADERS = "X-DashScope-Wait-Timeout: 30"      # DashScope 必须的自定义头，否则 401

# 强制 UTF-8 输出
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

# 从 .env 读取密钥注入环境变量（聚合进程自身也会 load_dotenv，此处为兼容子进程）
$envLines = Get-Content "$PSScriptRoot\.env" -Encoding UTF8
$env:ANTHROPIC_API_KEY = ($envLines | Where-Object { $_ -match "^ANTHROPIC_API_KEY=" } | ForEach-Object { ($_ -split "=", 2)[1].Trim() })
$env:HORIZON_WEBHOOK_URL = ($envLines | Where-Object { $_ -match "^HORIZON_WEBHOOK_URL=" } | ForEach-Object { ($_ -split "=", 2)[1].Trim() })
$env:GITHUB_TOKENS = ($envLines | Where-Object { $_ -match "^GITHUB_TOKENS=" } | ForEach-Object { ($_ -split "=", 2)[1].Trim() })
# GITHUB_TOKEN 改由系统环境变量提供（多项目统一），不再从 .env 读取

Set-Location "$PSScriptRoot"

$logFile = Join-Path $PSScriptRoot "run.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

$ErrorActionPreference = "Continue"

# 本机 Python：直接用 venv 解释器跑源码模块（永远是最新代码，无需 horizon.exe/PATH）
$pythonExe = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"

# ============================================================
# Step 1: 同步 AI 配置到 config.json（确保 Python 读到最新值）
# ============================================================
$configPath = Join-Path $PSScriptRoot "data\config.json"
$configContent = Get-Content $configPath -Raw -Encoding UTF8
$configContent = $configContent -replace '"api_key_env"\s*:\s*"[^"]*"', "`"api_key_env`": `"$AI_KEY_ENV_NAME`""
$configContent = $configContent -replace '"base_url"\s*:\s*"[^"]*"', "`"base_url`": `"$AI_BASE_URL`""
Set-Content $configPath -Value $configContent -Encoding UTF8
# 自定义头通过环境变量传给 Python（与 ccswitch 配置对齐，DashScope 没这个头就 401）
$env:ANTHROPIC_CUSTOM_HEADERS = $AI_CUSTOM_HEADERS
Write-Log "[Config] AI 配置已同步: api_key_env=$AI_KEY_ENV_NAME, base_url=$AI_BASE_URL, headers=$AI_CUSTOM_HEADERS"

# ============================================================
# Step 2: 聚合（核心流程）
# ============================================================
Write-Log "[Horizon] 开始聚合: python -m src.main --hours $Hours ..."
try {
    $horizonOutput = & $pythonExe -m src.main --hours $Hours 2>&1
    $horizonOutput | Add-Content -Path $logFile -Encoding UTF8
} catch {
    Write-Log "[Horizon] 聚合进程异常: $_"
}
Write-Log "[Horizon] 聚合完成 (exit code: $LASTEXITCODE)"

# ============================================================
# Step 2.5: 给摘要文件加时间戳（防止同一天多次运行互相覆盖）
# ============================================================
$summariesDir = Join-Path $PSScriptRoot "data\summaries"
$timestamp = Get-Date -Format "HHmm"
$today = Get-Date -Format "yyyy-MM-dd"

# 查找今天生成的摘要文件（兼容有无时间戳的格式）
$todayFiles = @(
    Get-ChildItem -Path $summariesDir -Filter "horizon-${today}-*.md" | Where-Object { $_.Name -notmatch "-\d{4}-" },  # 无时间戳的
    Get-ChildItem -Path $summariesDir -Filter "horizon-${today}-????.md" | Where-Object { $_.Name -match "-\d{4}-" }   # 有时间戳的
) | Sort-Object LastWriteTime -Descending | Select-Object -First 1

if ($todayFiles) {
    $oldFile = $todayFiles
    $newName = $oldFile.Name -replace "horizon-${today}-(zh|en)\.md$", "horizon-${today}-${timestamp}-`$1.md"

    if ($oldFile.Name -ne $newName) {
        # 如果新文件名已存在，先备份
        $newPath = Join-Path $summariesDir $newName
        if (Test-Path $newPath) {
            $backupName = $newName + ".bak-${timestamp}"
            $backupPath = Join-Path $summariesDir $backupName
            Rename-Item -Path $newPath -NewName $backupName -Force
            Write-Log "[Rename] 已备份旧文件: $backupName"
        }

        Rename-Item -Path $oldFile.FullName -NewName $newName
        Write-Log "[Rename] 已添加时间戳: $($oldFile.Name) -> $newName"
    }
}

# ============================================================
# Step 3: 归档中文摘要（仅当 D:\ 可用；失败不影响后续）
# ============================================================
$archiveDir = "D:\每日信息搜索任务"
if (Test-Path "D:\") {
    try {
        if (-not (Test-Path $archiveDir)) { New-Item -Path $archiveDir -ItemType Directory -Force | Out-Null }
        $latestZh = Get-ChildItem -Path $summariesDir -Filter "horizon-*-zh.md" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestZh) {
            Copy-Item -Path $latestZh.FullName -Destination $archiveDir -Force
            Write-Log "[Archive] 已归档 $($latestZh.Name) -> $archiveDir\"
        } else {
            Write-Log "[Archive] 未找到中文摘要，跳过归档"
        }
    } catch {
        Write-Log "[Archive] 归档失败(忽略): $_"
    }
} else {
    Write-Log "[Archive] D:\ 不可用，跳过归档"
}

# ============================================================
# Step 4: 发布博客 + 微信草稿箱（委托已验证的 publish-to-vps.ps1）
# ============================================================
$publishScript = Join-Path $PSScriptRoot "publish-to-vps.ps1"
if (Test-Path $publishScript) {
    Write-Log "[Horizon] 调用 publish-to-vps.ps1 发布博客 + 微信草稿箱..."
    try {
        $publishOutput = & $publishScript -Stage all 2>&1
        $publishOutput | Add-Content -Path $logFile -Encoding UTF8
    } catch {
        Write-Log "[Horizon] 发布进程异常: $_"
    }
    Write-Log "[Horizon] 发布流程结束 (exit code: $LASTEXITCODE)"
} else {
    Write-Log "[Horizon] ❌ 未找到 publish-to-vps.ps1，跳过发布"
}

Write-Log "[Horizon] ===== 全流程结束 ====="
