#requires -Version 5.1
<#
.SYNOPSIS
    全屏遮罩 + 熄屏 + 自定义密码解锁。密码存在本脚本目录的 shield.config.json 里。

.DESCRIPTION
    流程：
      1. 立刻铺一层全屏黑底遮罩（所有显示器都盖住），中间一个密码输入框；
      2. 0.8 秒后关闭显示器，后台程序继续跑；
      3. 你回来动鼠标 -> 屏幕亮 -> 看到的是「已锁定」+ 输入框；
      4. 输入正确密码 -> 遮罩消失。密码错了就清空重输，不限次数。

    按 Esc = 不解锁、直接再熄一次屏（人走开时想重新黑掉很方便）。

    ⚠️ 这不是安全机制，是遮罩。Ctrl+Alt+Del 能叫出任务管理器结束它，
       长按电源键重启也能绕过。挡的是"随手来点两下"的人，不是懂电脑的人。
       真要防人：Win+L 用系统锁屏，或者给 Windows 账户设密码。

    ⚠️ 密码以加盐 SHA-256 存在 shield.config.json（没有明文），
       但这只是"别让旁边的人一眼看到"，不是加密保险箱。

.PARAMETER SetPassword
    设置或修改密码。会让你输两遍确认。

.PARAMETER Hint
    配合 -SetPassword 使用，设置提示语（会显示在输入框下方）。

.PARAMETER ConfigPath
    自定义配置文件路径。默认与本脚本同目录的 shield.config.json。

.PARAMETER Test
    测试模式：只弹出遮罩界面，不熄屏。第一次调样式时用这个，省得黑屏了看不清。

.EXAMPLE
    .\lock-shield.ps1 -SetPassword
    设置密码。

.EXAMPLE
    .\lock-shield.ps1 -SetPassword -Hint "家里那只猫的名字"
    设置密码并写提示语。

.EXAMPLE
    .\lock-shield.ps1
    启动遮罩并熄屏。
#>
[CmdletBinding()]
param(
    [switch]$SetPassword,
    [switch]$Toggle,
    [string]$Hint = '',
    [string]$ConfigPath = '',
    [switch]$Test
)

$ErrorActionPreference = 'Stop'

# 出错时直接报出「第几行 + 那一行源码」，省得来回复述定位
trap {
    $lineNo = $_.InvocationInfo.ScriptLineNumber
    $lineTxt = ''
    if ($_.InvocationInfo.Line) { $lineTxt = $_.InvocationInfo.Line.Trim() }
    Write-Host ''
    Write-Host "=== 脚本出错（第 $lineNo 行）===" -ForegroundColor Red
    if ($lineTxt) { Write-Host "  代码：$lineTxt" -ForegroundColor DarkYellow }
    Write-Host "  原因：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    exit 1
}

# ⚠️ 取「脚本所在目录」要兼容三种情况：
#    1) 直接跑 .ps1  -> $PSScriptRoot 有值
#    2) PS2EXE 编译成 .exe -> 上面两个都为空，只能从进程主模块路径反推
#    3) 兜底 -> 当前工作目录
$here = ''
try { if ($PSScriptRoot) { $here = $PSScriptRoot } } catch { }
if (-not $here) {
    try { if ($MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path } } catch { }
}
if (-not $here) {
    try { $here = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { }
}
if (-not $here) { $here = (Get-Location).Path }
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $here 'shield.config.json'
}

# ============================================================
# 0. 扩展通道：extensions\ 目录里的脚本会被按事件自动调用
# ============================================================
#   on-lock.ps1      遮罩出现时
#   on-screenoff.ps1 每次熄屏时（含无密码模式、按 Esc 重新熄屏）
#   on-unlock.ps1    密码正确、遮罩关闭后
#
# 这些脚本用独立进程异步拉起，隐藏窗口；不存在就跳过；
# 出错也不影响锁屏主流程（锁屏这个功能不能被扩展脚本拖死）。
# 想加功能：往 extensions\ 扔一个同名 .ps1 就行，不用重新打包。
function Invoke-Hook {
    param([string]$Name)
    if (-not $script:hooksEnabled) { return }
    try {
        $dir  = Join-Path $here 'extensions'
        $file = Join-Path $dir ($Name + '.ps1')
        if (-not (Test-Path -LiteralPath $file)) { return }
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $ps)) { $ps = 'powershell.exe' }
        Start-Process -FilePath $ps -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"' + $file + '"')
        ) -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
    }
    catch { }
}

# ============================================================
# 0.5 工具函数
# ============================================================
function New-Salt {
    $b = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-Code {
    # 直接返回十六进制串，不依赖外部函数，事件里也能用
    param([string]$text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function ConvertFrom-Secure([System.Security.SecureString]$ss) {
    if ($null -eq $ss) { return '' }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# ============================================================
# 1. 设置密码（-SetPassword 主动调用，或首次双击时自动进入）
# ============================================================
function Invoke-SetupPassword {
    Write-Host ''
    Write-Host '=== 设置遮罩密码 ===' -ForegroundColor Cyan
    Write-Host '（这是你自己定的密码，不是 Windows 账户密码）' -ForegroundColor DarkGray
    Write-Host "密码存到：$ConfigPath" -ForegroundColor DarkGray
    Write-Host ''

    $p1 = Read-Host '输入新密码（至少 4 位，输入时不显示）' -AsSecureString
    $s1 = ConvertFrom-Secure $p1
    if ($s1.Length -lt 4) {
        Write-Host '密码太短（至少要 4 位），没保存。' -ForegroundColor Red
        return $false
    }

    $p2 = Read-Host '再输一次确认（这次明文显示，方便核对）'
    # 故意不加 -AsSecureString：第二次用明文，方便核对是不是输错
    $s2 = [string]$p2
    if ($s1 -cne $s2) {
        Write-Host '两次输入不一致，没保存。' -ForegroundColor Red
        return $false
    }

    $salt = New-Salt
    $obj = [ordered]@{
        salt      = $salt
        hash      = (Get-Code ($salt + $s1))
        hint      = $Hint
        createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $json = ($obj | ConvertTo-Json)
    [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($true)))

    Write-Host ''
    Write-Host "已保存：$ConfigPath" -ForegroundColor Green
    if ($Hint) { Write-Host "提示语：$Hint" -ForegroundColor Green }
    return $true
}

# 显式要求改密码
if ($SetPassword) {
    if (Invoke-SetupPassword) { exit 0 } else { exit 1 }
}

# ============================================================
# 1.5 切换密码开关（-Toggle）：关 = 锁定时只熄屏，不要密码
# ============================================================
if ($Toggle) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Host ''
        Write-Host '还没设置过密码（没有 shield.config.json），没什么可关的。' -ForegroundColor Red
        Write-Host '先用 设置密码.bat 设一个；不想要密码的话直接用 monitor-off.bat 熄屏也行。' -ForegroundColor DarkGray
        Write-Host ''
        exit 1
    }
    try {
        $cfgT = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Host "配置文件读不了（JSON 坏了？）：$($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    $cur = $true
    if ($cfgT.PSObject.Properties['enabled']) { $cur = [bool]$cfgT.enabled }
    $new = -not $cur
    $cfgT | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $new -Force
    $json = $cfgT | ConvertTo-Json
    [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($true)))

    Write-Host ''
    Write-Host '=== 遮罩密码开关 ===' -ForegroundColor Cyan
    if ($new) {
        Write-Host '密码已【开启】：双击 lock-shield.bat 会锁定屏幕，回来要输密码。' -ForegroundColor Green
    }
    else {
        Write-Host '密码已【关闭】：双击 lock-shield.bat 现在只熄屏，' -ForegroundColor Yellow
        Write-Host '回来动一下鼠标就直接进桌面，不用输密码。' -ForegroundColor Yellow
        Write-Host '（密码配置原样保留，再双击一次 密码开关.bat 就能切回来。）' -ForegroundColor DarkGray
    }
    Write-Host ''
    exit 0
}

# ============================================================
# 2. 读配置（没有就地引导设置，别让人空跑一趟）
# ============================================================
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host ''
    Write-Host '第一次用，先设一个遮罩密码。' -ForegroundColor Yellow
    if (-not (Invoke-SetupPassword)) {
        Write-Host ''
        Write-Host '没设成。再双击一次 lock-shield.bat 重试。' -ForegroundColor Red
        exit 1
    }
    Write-Host ''
    Write-Host '搞定。' -ForegroundColor Green
    $tryNow = Read-Host '现在试一下锁定效果吗？输 Y 立刻锁屏，直接回车先不锁'
    if ($tryNow -notmatch '^[Yy]') {
        Write-Host '好，下次双击 lock-shield.bat 就直接锁定。' -ForegroundColor Green
        Start-Sleep -Seconds 2
        exit 0
    }
}

try {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Write-Host "配置文件读不了（JSON 坏了？）：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$script:salt     = [string]$cfg.salt
$script:hash     = [string]$cfg.hash
$script:hint     = [string]$cfg.hint
$script:unlocked = $false
$script:wrong    = 0

if (-not $script:salt -or -not $script:hash) {
    Write-Host '配置文件缺 salt / hash。重新设一次密码： lock-shield.bat -SetPassword' -ForegroundColor Red
    exit 1
}

# 密码开关：enabled = false 时锁定 = 只熄屏（配置在，但不用密码）
$script:pwEnabled = $true
if ($cfg.PSObject.Properties['enabled']) { $script:pwEnabled = [bool]$cfg.enabled }

# 扩展通道总开关（缺字段默认开）
$script:hooksEnabled = $true
if ($cfg.PSObject.Properties['hooksEnabled']) { $script:hooksEnabled = [bool]$cfg.hooksEnabled }

# ============================================================
# 3. 载入依赖 + 关屏用的 P/Invoke
# ============================================================
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}
catch {
    Write-Host "载入 WinForms 失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '（本机 PowerShell 可能不是 Windows 自带的 5.1）' -ForegroundColor Red
    exit 1
}

$typeReady = $false
try { [void][Win32.MonitorControl]; $typeReady = $true } catch { }
if (-not $typeReady) {
    Add-Type -Namespace Win32 -Name MonitorControl -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);
'@
}

# ---- 密码关闭模式：不弹遮罩，直接熄屏退出（效果等同 monitor-off）----
if (-not $script:pwEnabled -and -not $Test) {
    try {
        [void][Win32.MonitorControl]::SendMessage([IntPtr]0xFFFF, 0x0112, [IntPtr]0xF170, [IntPtr]2)
    } catch { }
    Invoke-Hook 'on-screenoff'
    exit 0
}

# ============================================================
# 4. 构建遮罩窗体
# ============================================================
$screens = [System.Windows.Forms.Screen]::AllScreens
$primary = [System.Windows.Forms.Screen]::PrimaryScreen

$bgMain = [System.Drawing.Color]::FromArgb(6, 6, 8)
$bgCard = [System.Drawing.Color]::FromArgb(20, 20, 24)
$fgMain = [System.Drawing.Color]::FromArgb(232, 232, 238)
$fgDim  = [System.Drawing.Color]::FromArgb(120, 120, 130)
$fgErr  = [System.Drawing.Color]::FromArgb(235, 90, 90)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Locked'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Bounds = $primary.Bounds
$form.TopMost = $true
$form.BackColor = $bgMain
$form.ShowInTaskbar = $false
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.ControlBox = $false
$form.KeyPreview = $true

$w = [int]$primary.Bounds.Width
$h = [int]$primary.Bounds.Height

# ---- 卡片 ----
# ⚠️ 所有 New-Object Type(...) 的参数一律先用变量算好再传。
#    坑：PowerShell 里逗号的优先级高于二元减号，写 Size($cardW - 40, 26)
#    会被解析成 $cardW - @(40,26)，报「[System.Object[]] 不包含 op_Subtraction」。
$cardW = 520
$cardH = 260
$innerW = $cardW - 40
$cardX = [int](($w - $cardW) / 2)
$cardY = [int](($h - $cardH) / 2)

$card = New-Object System.Windows.Forms.Panel
$card.Size = New-Object System.Drawing.Size($cardW, $cardH)
$card.Location = New-Object System.Drawing.Point($cardX, $cardY)
$card.BackColor = $bgCard
$form.Controls.Add($card)

# ---- 标题 ----
$title = New-Object System.Windows.Forms.Label
$title.Text = '已 锁 定'
$title.AutoSize = $false
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 26, [System.Drawing.FontStyle]::Regular)
$title.ForeColor = $fgMain
$title.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$title.Size = New-Object System.Drawing.Size($cardW, 60)
$title.Location = New-Object System.Drawing.Point(0, 30)
$card.Controls.Add($title)

# ---- 密码框 ----
$tb = New-Object System.Windows.Forms.TextBox
$tb.UseSystemPasswordChar = $true
$tb.Font = New-Object System.Drawing.Font('Consolas', 20, [System.Drawing.FontStyle]::Regular)
$tb.Size = New-Object System.Drawing.Size(420, 48)
$tb.Location = New-Object System.Drawing.Point(50, 105)
$tb.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 38)
$tb.ForeColor = [System.Drawing.Color]::White
$tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$tb.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
$card.Controls.Add($tb)

# ---- 提示 / 报错行 ----
$hintLbl = New-Object System.Windows.Forms.Label
$hintLbl.AutoSize = $false
if ($script:hint) {
    $hintLbl.Text = $script:hint
    $hintLbl.ForeColor = $fgDim
} else {
    $hintLbl.Text = '输入密码后按回车'
    $hintLbl.ForeColor = $fgDim
}
$hintLbl.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Regular)
$hintLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$hintLbl.Size = New-Object System.Drawing.Size($innerW, 26)
$hintLbl.Location = New-Object System.Drawing.Point(20, 165)
$card.Controls.Add($hintLbl)

# ---- 底部小字 ----
$foot = New-Object System.Windows.Forms.Label
$foot.AutoSize = $false
$foot.Text = 'Esc 重新熄屏'
$foot.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Regular)
$foot.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 78)
$foot.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$foot.Size = New-Object System.Drawing.Size($innerW, 22)
$foot.Location = New-Object System.Drawing.Point(20, 215)
$card.Controls.Add($foot)

# ---- 回车 / Esc ----
$tb.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($script:salt + $tb.Text)
        $hex = (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
        $sha.Dispose()

        if ($hex -eq $script:hash) {
            $script:unlocked = $true
            Invoke-Hook 'on-unlock'
            $form.Close()
        }
        else {
            $script:wrong++
            $hintLbl.ForeColor = $fgErr
            $hintLbl.Text = "密码不对，再试一次（第 $($script:wrong) 次输错）"
            $tb.Clear()
        }
        $_.SuppressKeyPress = $true
    }
    elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
        # 不解锁，直接再熄一次屏
        [void][Win32.MonitorControl]::SendMessage([IntPtr]0xFFFF, 0x0112, [IntPtr]0xF170, [IntPtr]2)
        Invoke-Hook 'on-screenoff'
        $_.SuppressKeyPress = $true
    }
})

# ---- 拦 Alt+F4 / 关窗按钮 ----
$form.Add_FormClosing({
    param($sender, $e)
    if (-not $script:unlocked) { $e.Cancel = $true }
})

# ---- 抢焦点（防止 Win 键 / Alt+Tab 切走留个空桌面）----
# ⚠️ 用 ContainsFocus 而不是 Focused：焦点在密码框里时 Form.Focused 恒为 false，
#    会导致每 700ms 无意义地 Activate 一次，输入中文时被 IME 打断。
$script:focusTimer = New-Object System.Windows.Forms.Timer
$script:focusTimer.Interval = 700
$script:focusTimer.Add_Tick({
    if (-not $script:unlocked) {
        $form.TopMost = $true
        if (-not $form.ContainsFocus) { $form.Activate() }
        if (-not $tb.Focused -and $form.ContainsFocus) { $tb.Focus() }
    }
})

# ---- 副屏纯黑窗体 ----
$script:extras = @()
foreach ($sc in $screens) {
    if ($sc.DeviceName -eq $primary.DeviceName) { continue }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Locked'
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.Bounds = $sc.Bounds
    $f.TopMost = $true
    $f.BackColor = $bgMain
    $f.ShowInTaskbar = $false
    $f.ControlBox = $false
    $script:extras += $f
}

# ---- 窗体出现后：铺副屏 + 0.8 秒后熄屏 ----
$form.Add_Shown({
    foreach ($f in $script:extras) {
        try { $f.Show(); $f.TopMost = $true } catch { }
    }
    $tb.Focus()
    Invoke-Hook 'on-lock'

    if ($Test) {
        # 测试模式：只显示界面，不熄屏，方便先看清长什么样
        $hintLbl.Text = '测试模式：不会熄屏。输入密码回车可以退出'
        $script:focusTimer.Start()
        return
    }

    $script:offTimer = New-Object System.Windows.Forms.Timer
    $script:offTimer.Interval = 800
    $script:offTimer.Add_Tick({
        $script:offTimer.Stop()
        try { [void][Win32.MonitorControl]::SendMessage([IntPtr]0xFFFF, 0x0112, [IntPtr]0xF170, [IntPtr]2) } catch { }
        Invoke-Hook 'on-screenoff'
    })
    $script:offTimer.Start()

    $script:focusTimer.Start()
})

# ============================================================
# 5. 跑
# ============================================================
[void]$form.ShowDialog()

# 收尾：停掉定时器，关掉副屏窗体，别留幽灵进程
foreach ($t in @($script:focusTimer, $script:offTimer)) {
    if ($null -ne $t) {
        try { $t.Stop(); $t.Dispose() } catch { }
    }
}
foreach ($f in $script:extras) {
    try { $f.Close(); $f.Dispose() } catch { }
}

exit 0
