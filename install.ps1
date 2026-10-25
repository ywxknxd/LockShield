#requires -Version 5.1
<#
.SYNOPSIS
    就地创建开始菜单入口。不复制、不搬移任何文件。

.DESCRIPTION
    绿色版用法：程序就留在当前文件夹里，这个脚本只负责在你的开始菜单里
    建三个快捷方式指向它。不会把文件装到 %LOCALAPPDATA%、Program Files
    或任何别的地方，也不会写「应用和功能」的卸载项。

    全部是当前用户级操作，不需要管理员权限。

    四个入口：
        LockShield -> 主菜单（锁屏 / 改密码 / 开关密码保护）
        立即锁屏   -> LockShield.exe -Lock
        设置密码   -> LockShield.exe -SetPassword
        密码开关   -> LockShield.exe -Toggle

.PARAMETER Desktop
    同时在桌面创建「锁屏」快捷方式。

.PARAMETER Uninstall
    只删除本程序创建的开始菜单/桌面快捷方式。
    程序文件与本目录里的所有东西原样保留，要删得自己删文件夹。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Desktop

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
param(
    [switch]$Desktop,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

trap {
    Write-Host ''
    Write-Host "[install] 出错（第 $($_.InvocationInfo.ScriptLineNumber) 行）：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$here     = $PSScriptRoot
$startDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'LockShield'
$deskLnk  = Join-Path ([Environment]::GetFolderPath('Desktop')) 'LockShield.lnk'

# ---------- 找 exe（就在本文件夹里，不复制） ----------
$exe = $null
foreach ($c in @((Join-Path $here 'LockShield.exe'), (Join-Path $here 'dist\LockShield.exe'))) {
    if (Test-Path -LiteralPath $c) { $exe = $c; break }
}
$exeDir = ''
if ($exe) { $exeDir = Split-Path -Parent $exe }

# ============================================================
# 卸载：只删快捷方式
# ============================================================
if ($Uninstall) {
    Write-Host '=== 删除 LockShield 的开始菜单 / 桌面入口 ===' -ForegroundColor Cyan
    Write-Host '只删快捷方式，程序文件不动。' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '将删除：' -ForegroundColor Yellow
    if (Test-Path -LiteralPath $startDir) {
        Get-ChildItem -LiteralPath $startDir -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host ("  " + $_.FullName) }
    } else { Write-Host '  （开始菜单里没有）' -ForegroundColor DarkGray }
    if (Test-Path -LiteralPath $deskLnk) { Write-Host ("  " + $deskLnk) } else { Write-Host '  （桌面没有）' -ForegroundColor DarkGray }

    $ans = Read-Host '确认删除这些快捷方式？输 Y 继续'
    if ($ans -notmatch '^[Yy]') { Write-Host '已取消。' -ForegroundColor Yellow; exit 0 }

    if (Test-Path -LiteralPath $startDir) {
        Remove-Item -LiteralPath $startDir -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $startDir) { Write-Host "  删不掉（可能有文件被占用）: $startDir" -ForegroundColor Red }
        else { Write-Host "  已删: $startDir" -ForegroundColor Green }
    }
    if (Test-Path -LiteralPath $deskLnk) {
        Remove-Item -LiteralPath $deskLnk -Force -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host ("  桌面快捷方式: " + $(if (Test-Path -LiteralPath $deskLnk) { '删不掉' } else { '已删' })) -ForegroundColor Green
    }
    Write-Host ''
    Write-Host "程序文件还在：$here" -ForegroundColor Cyan
    Write-Host '不需要的话，自己把这个文件夹删掉就行。' -ForegroundColor DarkGray
    exit 0
}

# ============================================================
# 安装：只建快捷方式
# ============================================================
if (-not $exe) {
    Write-Host '找不到 LockShield.exe。' -ForegroundColor Red
    Write-Host '找过这两个位置：' -ForegroundColor Yellow
    Write-Host "  $here\dist\LockShield.exe"
    Write-Host "  $here\LockShield.exe"
    Write-Host '先跑一次 build.ps1 编译。' -ForegroundColor Yellow
    exit 1
}

Write-Host '=== 创建开始菜单入口（不复制文件） ===' -ForegroundColor Cyan
Write-Host ("程序位置: " + $exe) -ForegroundColor DarkGray
Write-Host ''

if (-not (Test-Path -LiteralPath $startDir)) {
    New-Item -ItemType Directory -Path $startDir -Force | Out-Null
}

$ws = New-Object -ComObject WScript.Shell

function New-Sc {
    param([string]$Path, [string]$Target, [string]$ArgList = '', [string]$WorkDir = '', [string]$Desc = '')

    # 已存在同名快捷方式时：先试删，删不掉就改名挪开（某些情况下旧 lnk 无法直接覆盖）
    if (Test-Path -LiteralPath $Path) {
        $ok = $false
        try { [System.IO.File]::Delete($Path); $ok = -not (Test-Path -LiteralPath $Path) } catch { }
        if (-not $ok) {
            $bak = $Path + '.old'
            try { [System.IO.File]::Move($Path, $bak) } catch { }
            try { [System.IO.File]::Delete($bak) } catch { }
            Write-Host ("  旧文件改名后重建: " + (Split-Path -Leaf $Path)) -ForegroundColor DarkGray
        }
    }

    $lnk = $ws.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    if ($ArgList) { $lnk.Arguments        = $ArgList }
    if ($WorkDir) { $lnk.WorkingDirectory = $WorkDir }
    if ($Desc)    { $lnk.Description      = $Desc }
    $lnk.IconLocation = "$Target,0"
    $lnk.WindowStyle  = 1
    $lnk.Save()

    if (Test-Path -LiteralPath $Path) {
        Write-Host ("  OK  " + (Split-Path -Leaf $Path)) -ForegroundColor Green
    } else {
        Write-Host ("  失败  " + (Split-Path -Leaf $Path)) -ForegroundColor Red
    }
}

# 清掉上一版的旧入口名（"锁屏"已改名为"立即锁屏"并带上 -Lock）
foreach ($legacy in @('锁屏.lnk')) {
    $lp = Join-Path $startDir $legacy
    if (Test-Path -LiteralPath $lp) {
        try { [System.IO.File]::Delete($lp) } catch { }
        if (Test-Path -LiteralPath $lp) {
            $bak = $lp + '.old'
            try { [System.IO.File]::Move($lp, $bak); [System.IO.File]::Delete($bak) } catch { }
        }
        Write-Host ("  已清理旧入口: " + $legacy) -ForegroundColor DarkGray
    }
}

New-Sc -Path (Join-Path $startDir 'LockShield.lnk') -Target $exe -WorkDir $exeDir -Desc '主菜单：锁屏 / 改密码 / 开关密码保护'
New-Sc -Path (Join-Path $startDir '立即锁屏.lnk')   -Target $exe -ArgList '-Lock'        -WorkDir $exeDir -Desc '跳过菜单，立刻锁屏并熄屏'
New-Sc -Path (Join-Path $startDir '设置密码.lnk')   -Target $exe -ArgList '-SetPassword' -WorkDir $exeDir -Desc '设置或修改遮罩密码'
New-Sc -Path (Join-Path $startDir '密码开关.lnk')   -Target $exe -ArgList '-Toggle'      -WorkDir $exeDir -Desc '切换：要不要输密码 / 只熄屏'

if ($Desktop) {
    New-Sc -Path $deskLnk -Target $exe -WorkDir $exeDir -Desc '立刻锁屏并熄屏'
}

Write-Host ''
Write-Host '完成。' -ForegroundColor Green
Write-Host ("开始菜单: " + $startDir) -ForegroundColor Cyan
Write-Host '按 Win 键，搜「LockShield」或「锁屏」就能看到四个入口。' -ForegroundColor Cyan
Write-Host ''
Write-Host '程序没有任何文件被复制，全部还是本文件夹里那一份。' -ForegroundColor DarkGray
exit 0
