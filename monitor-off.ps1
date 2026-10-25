#requires -Version 5.1
<#
.SYNOPSIS
    主动关闭显示器，但不睡眠、不挂起 —— 后台程序继续跑。

.DESCRIPTION
    做的事和「电源选项里等到时间自动关屏」完全一样，只是把触发权从系统手里拿回来：
    双击立刻关屏，或者加 -Delay 让它 N 分钟后自己关。

    关屏后 CPU / 网络 / 磁盘全部照常工作，QQ Agent、下载、渲染、备份都不受影响。
    唯一的限制：动鼠标或按键会亮屏 —— 这是显示器驱动的行为，脚本拦不住。
    （要防止被猫踩亮，加 -Lock 顺带锁屏，亮起来看到的是登录界面。）

.PARAMETER Delay
    延迟多少秒后关屏。默认 0 = 立刻执行。

.PARAMETER Lock
    关屏的同时锁定工作站（等同 Win+L），亮屏时需要输密码。

.EXAMPLE
    .\monitor-off.ps1
    立刻关屏。

.EXAMPLE
    .\monitor-off.ps1 -Delay 300
    5 分钟后关屏。

.EXAMPLE
    .\monitor-off.ps1 -Lock
    立刻关屏并锁屏。
#>
[CmdletBinding()]
param(
    [int]$Delay = 0,
    [switch]$Lock
)

$ErrorActionPreference = 'Stop'

# —— 1. 延迟 ——
if ($Delay -gt 0) {
    Write-Host "将在 $Delay 秒后关闭显示器。按 Ctrl+C 取消。" -ForegroundColor Cyan
    Start-Sleep -Seconds $Delay
}

# —— 2. 关屏 ——
# WM_SYSCOMMAND(0x0112) + SC_MONITORPOWER(0xF170)，lParam = 2 表示关闭显示器
#   lParam  2 -> 关闭（省电态）
#   lParam  1 -> 低功耗档
#   lParam -1 -> 强制点亮
# 用 HWND_BROADCAST(0xFFFF) 广播给所有顶层窗口，效果与电源计划「到时关屏」一致：
# 不进入睡眠、不挂起任何进程、不释放内存，只是熄灭背光。
$typeReady = $false
try { [void][Win32.MonitorControl]; $typeReady = $true } catch { }

if (-not $typeReady) {
    try {
        Add-Type -Namespace Win32 -Name MonitorControl -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);
'@
    }
    catch {
        Write-Host "编译系统调用失败：$($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

try {
    [void][Win32.MonitorControl]::SendMessage([IntPtr]0xFFFF, 0x0112, [IntPtr]0xF170, [IntPtr]2)
}
catch {
    Write-Host "关屏失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# —— 3. 可选：顺带锁屏 ——
if ($Lock) {
    Start-Sleep -Milliseconds 300
    rundll32.exe user32.dll,LockWorkStation
}

exit 0
