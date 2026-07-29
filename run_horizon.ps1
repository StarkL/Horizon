# Horizon 每日全流程运行脚本（本机适配版）
# 由 Windows 任务计划程序每天 6:30 调用
# 流程: 聚合(venv) -> 归档 -> 发布博客+微信(委托已验证的 publish-to-vps.ps1)
# 本机适配要点:
#   - Python 使用项目 .venv（直接跑源码模块，确保用最新代码，不依赖 PATH）
#   - 发布逻辑统一委托 publish-to-vps.ps1（VitePress 博客 + admin+sudo SSH + 微信草稿箱）

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
$env:GITHUB_TOKEN = ($envLines | Where-Object { $_ -match "^GITHUB_TOKEN=" } | ForEach-Object { ($_ -split "=", 2)[1].Trim() })

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
# Step 1: 聚合（核心流程）
# ============================================================
Write-Log "[Horizon] 开始聚合: python -m src.main --hours 24 ..."
try {
    $horizonOutput = & $pythonExe -m src.main --hours 24 2>&1
    $horizonOutput | Add-Content -Path $logFile -Encoding UTF8
} catch {
    Write-Log "[Horizon] 聚合进程异常: $_"
}
Write-Log "[Horizon] 聚合完成 (exit code: $LASTEXITCODE)"

# ============================================================
# Step 2: 归档中文摘要（仅当 D:\ 可用；失败不影响后续）
# ============================================================
$archiveDir = "D:\每日信息搜索任务"
$summariesDir = Join-Path $PSScriptRoot "data\summaries"
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
# Step 3: 发布博客 + 微信草稿箱（委托已验证的 publish-to-vps.ps1）
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
