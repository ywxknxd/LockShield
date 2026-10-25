#requires -Version 5.1
<#
.SYNOPSIS
    把 LockShield 安装到当前用户目录，并在开始菜单里建好入口。

.DESCRIPTION
    用户级安装，不需要管理员权限：
      - 程序装到 %LOCALAPPDATA%\Programs\LockShield
      - 开始菜单建一个 LockShield 文件夹，里面三个入口：
            锁屏 / 设置密码 / 密码开关
      - 已有的密码配置和扩展钩子会一起搬过去
      - 可选在桌面也放一个

.PARAMETER Desktop
    同时在桌面创建「锁屏」快捷方式。

.PARAMETER Uninstall
    卸载：列出要删的东西 -> 删除快捷方式和程序目录。
    密码配置 shield.config.json 会保留（不删），除非再加 -PurgeConfig。

.PARAMETER PurgeConfig
    配合 -Uninstall，连密码配置一起删。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Desktop
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#>
param(
    [switch]$Desktop,
    [switch]$Uninstall,
    [switch]$PurgeConfig
)

$ErrorActionPreference = 'Stop'

trap {
    Write-Host ''
    Write-Host "[install] 出错（第 $($_.InvocationInfo.ScriptLineNumber) 行）：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$here       = $PSScriptRoot
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\LockShield'
$exeName    = 'LockShield.exe'
$installExe = Join-Path $installDir $exeName

$startRoot  = [Environment]::GetFolderPath('Programs')
$startDir   = Join-Path $startRoot 'LockShield'

# ============================================================
# 卸载
# ============================================================
if ($Uninstall) {
    Write-Host '=== 准备卸载 LockShield ===' -ForegroundColor Cyan
    Write-Host '将删除以下内容：' -ForegroundColor Yellow
    if (Test-Path -LiteralPath $startDir) {
        Get-ChildItem -LiteralPath $startDir -Recurse -File | ForEach-Object { Write-Host ("  快捷方式: " + $_.FullName) }
    }
    if (Test-Path -LiteralPath $installDir) {
        Write-Host ("  程序目录: " + $installDir + "（整个删除，但 shield.config.json 默认保留）")
        if ($PurgeConfig) { Write-Host '  !! 密码配置也会一起删（-PurgeConfig）' -ForegroundColor Red }
    }
    if (-not $Desktop) {
        Write-Host '  桌面快捷方式（如果之前建过）'
    }

    $ans = Read-Host '确认执行？输 Y 继续，其他键取消'
    if ($ans -notmatch '^[Yy]') {
        Write-Host '已取消。' -ForegroundColor Yellow
        exit 0
    }

    # 快捷方式
    $desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'LockShield.lnk'
    foreach ($lnk in @($desktopLnk)) {
        if (Test-Path -LiteralPath $lnk) {
            Remove-Item -LiteralPath $lnk -Force -Confirm:$false
            Write-Host ("  已删: " + $lnk) -ForegroundColor Green
        }
    }
    if (Test-Path -LiteralPath $startDir) {
        Remove-Item -LiteralPath $startDir -Recurse -Force -Confirm:$false
        Write-Host ("  已删: " + $startDir) -ForegroundColor Green
    }

    # 程序目录（保留配置）
    if (Test-Path -LiteralPath $installDir) {
        if ($PurgeConfig) {
            Remove-Item -LiteralPath $installDir -Recurse -Force -Confirm:$false
            Write-Host ("  已删: " + $installDir) -ForegroundColor Green
        }
        else {
            $cfgPath = Join-Path $installDir 'shield.config.json'
            $backup = $null
            if (Test-Path -LiteralPath $cfgPath) {
                $backup = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
            }
            Remove-Item -LiteralPath $installDir -Recurse -Force -Confirm:$false
            if ($backup) {
                $keepDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'LockShield-配置备份'
                New-Item -ItemType Directory -Path $keepDir -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $keepDir 'shield.config.json'), $backup, (New-Object System.Text.UTF8Encoding($true)))
                Write-Host ("  密码配置已备份到: " + (Join-Path $keepDir 'shield.config.json')) -ForegroundColor Yellow
            }
            Write-Host ("  已删: " + $installDir) -ForegroundColor Green
        }
    }

    Write-Host ''
    Write-Host '卸载完成。' -ForegroundColor Green
    exit 0
}

# ============================================================
# 安装
# ============================================================
Write-Host '=== 安装 LockShield ===' -ForegroundColor Cyan

# 1. 找 exe
$srcExe = Join-Path $here ('dist\' + $exeName)
if (-not (Test-Path -LiteralPath $srcExe)) {
    Write-Host "找不到 $srcExe" -ForegroundColor Red
    Write-Host '先跑一次 build.ps1 编译。' -ForegroundColor Yellow
    exit 1
}

# 2. 目录
if (-not (Test-Path -LiteralPath $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}
Copy-Item -LiteralPath $srcExe -Destination $installExe -Force
Write-Host ("[1/4] 程序已放到: " + $installExe) -ForegroundColor Green

# 3. 搬配置和扩展（不覆盖已有的）
$srcCfg = Join-Path $here 'shield.config.json'
$dstCfg = Join-Path $installDir 'shield.config.json'
if ((Test-Path -LiteralPath $srcCfg) -and -not (Test-Path -LiteralPath $dstCfg)) {
    Copy-Item -LiteralPath $srcCfg -Destination $dstCfg -Force
    Write-Host '[2/4] 已把现有密码配置一起带过去' -ForegroundColor Green
}
elseif (Test-Path -LiteralPath $dstCfg) {
    Write-Host '[2/4] 目标已有密码配置，保留不动' -ForegroundColor Green
}
else {
    Write-Host '[2/4] 没有现成密码配置，首次启动会让你设置' -ForegroundColor Yellow
}

$srcExt = Join-Path $here 'extensions'
$dstExt = Join-Path $installDir 'extensions'
if (Test-Path -LiteralPath $srcExt) {
    if (-not (Test-Path -LiteralPath $dstExt)) { New-Item -ItemType Directory -Path $dstExt -Force | Out-Null }
    Copy-Item -Path (Join-Path $srcExt '*.ps1') -Destination $dstExt -Force -ErrorAction SilentlyContinue
    Copy-Item -Path (Join-Path $srcExt '*.sample') -Destination $dstExt -Force -ErrorAction SilentlyContinue
}

# 4. 快捷方式
$ws = New-Object -ComObject WScript.Shell

function New-Shortcut {
    param([string]$Path, [string]$Target, [string]$Args = '', [string]$WorkDir = '', [string]$Desc = '')
    $lnk = $ws.CreateShortcut($Path)
    $lnk.TargetPath       = $Target
    if ($Args)    { $lnk.Arguments        = $Args }
    if ($WorkDir) { $lnk.WorkingDirectory = $WorkDir }
    if ($Desc)    { $lnk.Description      = $Desc }
    $lnk.IconLocation = "$Target,0"
    $lnk.WindowStyle  = 1
    $lnk.Save()
}

if (-not (Test-Path -LiteralPath $startDir)) {
    New-Item -ItemType Directory -Path $startDir -Force | Out-Null
}

New-Shortcut -Path (Join-Path $startDir '锁屏.lnk')     -Target $installExe -WorkDir $installDir -Desc '立刻锁屏并熄屏'
New-Shortcut -Path (Join-Path $startDir '设置密码.lnk') -Target $installExe -Args '-SetPassword' -WorkDir $installDir -Desc '设置或修改遮罩密码'
New-Shortcut -Path (Join-Path $startDir '密码开关.lnk') -Target $installExe -Args '-Toggle' -WorkDir $installDir -Desc '切换：要不要输密码 / 只熄屏'
Write-Host ("[3/4] 开始菜单已建好: " + $startDir) -ForegroundColor Green

if ($Desktop) {
    New-Shortcut -Path (Join-Path ([Environment]::GetFolderPath('Desktop')) 'LockShield.lnk') -Target $installExe -WorkDir $installDir -Desc '立刻锁屏并熄屏'
    Write-Host '[3/4] 桌面快捷方式已建' -ForegroundColor Green
}

# 5. 注册卸载入口（写不进去也不算失败）
try {
    $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\LockShield'
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $unins = "$psExe -NoProfile -ExecutionPolicy Bypass -File `"$here\install.ps1`" -Uninstall"
    Set-ItemProperty -Path $regPath -Name 'DisplayName'     -Value 'LockShield 锁屏遮罩'
    Set-ItemProperty -Path $regPath -Name 'DisplayVersion'  -Value '1.1.0'
    Set-ItemProperty -Path $regPath -Name 'Publisher'       -Value 'ywxknxd'
    Set-ItemProperty -Path $regPath -Name 'InstallLocation' -Value $installDir
    Set-ItemProperty -Path $regPath -Name 'DisplayIcon'     -Value "$installExe,0"
    Set-ItemProperty -Path $regPath -Name 'UninstallString' -Value $unins
    Set-ItemProperty -Path $regPath -Name 'NoModify'        -Value 1 -Type DWord
    Set-ItemProperty -Path $regPath -Name 'NoRepair'        -Value 1 -Type DWord
    Write-Host '[4/4] 已注册到「应用和功能」，可以正常卸载' -ForegroundColor Green
}
catch {
    Write-Host ("[4/4] 注册卸载入口失败（不影响使用）：" + $_.Exception.Message) -ForegroundColor Yellow
}

Write-Host ''
Write-Host '装好了。' -ForegroundColor Green
Write-Host '按 Win 键，搜「锁屏」就能看到三个入口。' -ForegroundColor Cyan
Write-Host ''
exit 0
