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

.PARAMETER Lock
    直接锁屏并熄屏，不经过菜单。快捷方式用这个。

.PARAMETER SetPassword
    设置或修改密码。会让你输两遍确认。

.PARAMETER Toggle
    直接切换「要不要密码」，不经过菜单。

.PARAMETER Hint
    配合 -SetPassword 使用，设置提示语（会显示在输入框下方）。

.PARAMETER ConfigPath
    自定义配置文件路径。默认与本脚本同目录的 shield.config.json。

.PARAMETER Test
    测试模式：只弹出遮罩界面，不熄屏。第一次调样式时用这个，省得黑屏了看不清。

.EXAMPLE
    .\lock-shield.ps1
    弹出功能菜单（锁屏 / 改密码 / 开关密码保护）。

.EXAMPLE
    .\lock-shield.ps1 -Lock
    直接锁屏，不进菜单。

.EXAMPLE
    .\lock-shield.ps1 -SetPassword
    设置密码。

.EXAMPLE
    .\lock-shield.ps1 -SetPassword -Hint "家里那只猫的名字"
    设置密码并写提示语。
#>
[CmdletBinding()]
param(
    [switch]$Lock,
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
    $msg = "脚本出错（第 $lineNo 行）`n`n原因：$($_.Exception.Message)"
    if ($lineTxt) { $msg += "`n`n代码：$lineTxt" }
    # Show-Ui 可能还没定义（错误发生在文件最前面时），所以兜一层
    try { Show-Ui $msg 'LockShield' 'Error' } catch { Write-Host $msg -ForegroundColor Red }
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
# 0.5 界面通道 + 工具函数
# ============================================================
# 编译成无控制台的 GUI 版 exe 后，Write-Host 和 Read-Host 都是废的
# （前者没地方显示，后者直接报错）。所以统一走这里：
#   有控制台 -> 文字输出 / Read-Host
#   没控制台 -> MessageBox 弹窗
$script:hasConsole = $false
try {
    if (-not ('Win32.ConsoleProbe' -as [type])) {
        Add-Type -Namespace Win32 -Name ConsoleProbe -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
'@
    }
    $script:hasConsole = ([Win32.ConsoleProbe]::GetConsoleWindow() -ne [IntPtr]::Zero)
}
catch { $script:hasConsole = $false }

$script:uiReady = $false
function Initialize-Ui {
    if ($script:uiReady) { return }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $script:uiReady = $true
}

function Show-Ui {
    param(
        [string]$Text,
        [string]$Title = 'LockShield',
        [ValidateSet('Info', 'Warn', 'Error')][string]$Kind = 'Info'
    )
    if ($script:hasConsole) {
        $color = 'Green'
        if ($Kind -eq 'Warn')  { $color = 'Yellow' }
        if ($Kind -eq 'Error') { $color = 'Red' }
        Write-Host $Text -ForegroundColor $color
        return
    }
    Initialize-Ui
    $icon = [System.Windows.Forms.MessageBoxIcon]::Information
    if ($Kind -eq 'Warn')  { $icon = [System.Windows.Forms.MessageBoxIcon]::Warning }
    if ($Kind -eq 'Error') { $icon = [System.Windows.Forms.MessageBoxIcon]::Error }
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $icon)
}

function Show-Ask {
    param([string]$Text, [string]$Title = 'LockShield')
    if ($script:hasConsole) {
        $a = Read-Host $Text
        return ([string]$a -match '^[Yy]')
    }
    Initialize-Ui
    $r = [System.Windows.Forms.MessageBox]::Show($Text, $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

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
function Show-PasswordDialog {
    # 图形化设置密码：不管有没有控制台都用这个，行为一致
    param([string]$InitialHint = '')
    Initialize-Ui

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '设置遮罩密码'
    $form.ClientSize = New-Object System.Drawing.Size(440, 300)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $lbInfo = New-Object System.Windows.Forms.Label
    $lbInfo.Text = '这是你自己定的遮罩密码，不是 Windows 账户密码。至少 4 位。'
    $lbInfo.Location = New-Object System.Drawing.Point(20, 12)
    $lbInfo.Size = New-Object System.Drawing.Size(400, 34)
    $form.Controls.Add($lbInfo)

    $lb1 = New-Object System.Windows.Forms.Label
    $lb1.Text = '新密码'
    $lb1.Location = New-Object System.Drawing.Point(20, 58)
    $lb1.Size = New-Object System.Drawing.Size(90, 22)
    $form.Controls.Add($lb1)

    $tb1 = New-Object System.Windows.Forms.TextBox
    $tb1.UseSystemPasswordChar = $true
    $tb1.Location = New-Object System.Drawing.Point(115, 55)
    $tb1.Size = New-Object System.Drawing.Size(300, 26)
    $form.Controls.Add($tb1)

    $lb2 = New-Object System.Windows.Forms.Label
    $lb2.Text = '再输一次'
    $lb2.Location = New-Object System.Drawing.Point(20, 96)
    $lb2.Size = New-Object System.Drawing.Size(90, 22)
    $form.Controls.Add($lb2)

    $tb2 = New-Object System.Windows.Forms.TextBox
    $tb2.UseSystemPasswordChar = $true
    $tb2.Location = New-Object System.Drawing.Point(115, 93)
    $tb2.Size = New-Object System.Drawing.Size(300, 26)
    $form.Controls.Add($tb2)

    $lb3 = New-Object System.Windows.Forms.Label
    $lb3.Text = '提示语（可留空）'
    $lb3.Location = New-Object System.Drawing.Point(20, 134)
    $lb3.Size = New-Object System.Drawing.Size(90, 22)
    $form.Controls.Add($lb3)

    $tb3 = New-Object System.Windows.Forms.TextBox
    $tb3.Location = New-Object System.Drawing.Point(115, 131)
    $tb3.Size = New-Object System.Drawing.Size(300, 26)
    if ($InitialHint) { $tb3.Text = $InitialHint }
    $form.Controls.Add($tb3)

    $lbErr = New-Object System.Windows.Forms.Label
    $lbErr.Text = ''
    $lbErr.ForeColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
    $lbErr.Location = New-Object System.Drawing.Point(20, 172)
    $lbErr.Size = New-Object System.Drawing.Size(400, 22)
    $form.Controls.Add($lbErr)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '保存'
    $btnOk.Location = New-Object System.Drawing.Point(215, 215)
    $btnOk.Size = New-Object System.Drawing.Size(95, 32)
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(320, 215)
    $btnCancel.Size = New-Object System.Drawing.Size(95, 32)
    $form.Controls.Add($btnCancel)

    $script:dialogOk = $false

    $btnOk.Add_Click({
        if ($tb1.Text.Length -lt 4) {
            $lbErr.Text = '密码太短，至少要 4 位。'
            $tb1.Focus()
            return
        }
        if ($tb1.Text -cne $tb2.Text) {
            $lbErr.Text = '两次输入不一致，重新输一次。'
            $tb2.Clear()
            $tb2.Focus()
            return
        }
        $script:dialogOk = $true
        $form.Close()
    })

    $btnCancel.Add_Click({ $form.Close() })

    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    [void]$form.ShowDialog()

    $result = $null
    if ($script:dialogOk) {
        $result = [pscustomobject]@{
            pwd  = $tb1.Text
            hint = ([string]$tb3.Text).Trim()
        }
    }
    foreach ($c in @($tb1, $tb2, $tb3, $lbErr, $btnOk, $btnCancel, $lbInfo, $lb1, $lb2, $lb3, $form)) {
        try { $c.Dispose() } catch { }
    }
    return $result
}

function Invoke-SetupPassword {
    param([string]$InitialHint = '')

    $res = Show-PasswordDialog -InitialHint $InitialHint
    if ($null -eq $res) {
        Show-Ui '已取消，密码没有改动。' 'LockShield' 'Warn'
        return $false
    }

    # 重设密码时保留原有的开关字段，别把它俩重置了
    $old = $null
    if (Test-Path -LiteralPath $ConfigPath) {
        try { $old = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }

    $salt = New-Salt
    $obj = [ordered]@{
        salt      = $salt
        hash      = (Get-Code ($salt + $res.pwd))
        hint      = $res.hint
        createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    if ($old) {
        if ($old.PSObject.Properties['enabled'])      { $obj['enabled']      = [bool]$old.enabled }
        if ($old.PSObject.Properties['hooksEnabled']) { $obj['hooksEnabled'] = [bool]$old.hooksEnabled }
    }

    $json = ($obj | ConvertTo-Json)
    [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($true)))

    $msg = "密码已保存。`n`n$ConfigPath"
    if ($res.hint) { $msg += "`n`n提示语：$($res.hint)" }
    Show-Ui $msg 'LockShield' 'Info'
    return $true
}

# 显式要求改密码
if ($SetPassword) {
    if (Invoke-SetupPassword -InitialHint $Hint) { exit 0 } else { exit 1 }
}

# ============================================================
# 1.7 主菜单：双击 exe（不带任何参数）时显示
# ============================================================
#   返回 'lock'  -> 关掉菜单，继续走下面的锁屏流程
#   返回 'exit'  -> 直接退出
# 设置密码 / 切换开关都在菜单内部完成，不关菜单，只刷新状态。
function Show-MainMenu {
    Initialize-Ui
    $script:menuAction = 'exit'

    $colBg     = [System.Drawing.Color]::FromArgb(30, 32, 37)
    $colText   = [System.Drawing.Color]::FromArgb(236, 238, 242)
    $colSub    = [System.Drawing.Color]::FromArgb(140, 146, 156)
    $colBtn    = [System.Drawing.Color]::FromArgb(54, 58, 66)
    $colBtnHov = [System.Drawing.Color]::FromArgb(72, 78, 88)
    $colAcc    = [System.Drawing.Color]::FromArgb(74, 144, 226)
    $colAccHov = [System.Drawing.Color]::FromArgb(96, 160, 240)
    $colOn     = [System.Drawing.Color]::FromArgb(92, 200, 128)
    $colOff    = [System.Drawing.Color]::FromArgb(214, 160, 90)

    # 事件脚本块里要用到的，全部放脚本作用域，避免闭包丢失
    $script:menuColSub = $colSub
    $script:menuColOn  = $colOn
    $script:menuColOff = $colOff

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'LockShield'
    $form.ClientSize      = New-Object System.Drawing.Size(420, 352)
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.BackColor       = $colBg
    $form.ForeColor       = $colText
    $form.Font            = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $form.KeyPreview      = $true
    $script:menuForm = $form

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text      = 'LockShield'
    $lblTitle.Location  = New-Object System.Drawing.Point(26, 14)
    $lblTitle.Size      = New-Object System.Drawing.Size(180, 34)
    $lblTitle.Font      = New-Object System.Drawing.Font('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = $colText
    $form.Controls.Add($lblTitle)

    $lblVer = New-Object System.Windows.Forms.Label
    $lblVer.Text      = '便携版'
    $lblVer.Location  = New-Object System.Drawing.Point(168, 26)
    $lblVer.Size      = New-Object System.Drawing.Size(60, 20)
    $lblVer.ForeColor = $colAcc
    $form.Controls.Add($lblVer)

    $lblState = New-Object System.Windows.Forms.Label
    $lblState.Location  = New-Object System.Drawing.Point(28, 56)
    $lblState.Size      = New-Object System.Drawing.Size(364, 22)
    $lblState.ForeColor = $colSub
    $lblState.Font      = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblState)
    $script:menuState = $lblState

    # ---- 主按钮：立即锁屏 ----
    $btnLock = New-Object System.Windows.Forms.Button
    $btnLock.Text      = '立即锁屏'
    $btnLock.Location  = New-Object System.Drawing.Point(28, 88)
    $btnLock.Size      = New-Object System.Drawing.Size(364, 48)
    $btnLock.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnLock.FlatAppearance.BorderSize = 0
    $btnLock.BackColor = $colAcc
    $btnLock.ForeColor = [System.Drawing.Color]::White
    $btnLock.Font      = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $btnLock.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($btnLock)

    # ---- 设置 / 修改密码 ----
    $btnPwd = New-Object System.Windows.Forms.Button
    $btnPwd.Text      = '设置 / 修改密码'
    $btnPwd.Location  = New-Object System.Drawing.Point(28, 148)
    $btnPwd.Size      = New-Object System.Drawing.Size(364, 40)
    $btnPwd.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnPwd.FlatAppearance.BorderSize = 0
    $btnPwd.BackColor = $colBtn
    $btnPwd.ForeColor = $colText
    $btnPwd.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($btnPwd)

    # ---- 密码保护开关（文案随状态变） ----
    $btnSw = New-Object System.Windows.Forms.Button
    $btnSw.Location  = New-Object System.Drawing.Point(28, 194)
    $btnSw.Size      = New-Object System.Drawing.Size(364, 40)
    $btnSw.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnSw.FlatAppearance.BorderSize = 0
    $btnSw.BackColor = $colBtn
    $btnSw.ForeColor = $colText
    $btnSw.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($btnSw)
    $script:menuSwitch = $btnSw

    # ---- 退出 ----
    $btnQuit = New-Object System.Windows.Forms.Button
    $btnQuit.Text      = '退出'
    $btnQuit.Location  = New-Object System.Drawing.Point(28, 242)
    $btnQuit.Size      = New-Object System.Drawing.Size(364, 34)
    $btnQuit.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnQuit.FlatAppearance.BorderSize = 0
    $btnQuit.BackColor = $colBg
    $btnQuit.ForeColor = $colSub
    $btnQuit.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($btnQuit)

    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Text      = '配置文件：' + $ConfigPath
    $lblPath.Location  = New-Object System.Drawing.Point(28, 292)
    $lblPath.Size      = New-Object System.Drawing.Size(364, 34)
    $lblPath.ForeColor = $colSub
    $lblPath.Font      = New-Object System.Drawing.Font('Microsoft YaHei UI', 7.5)
    $form.Controls.Add($lblPath)

    $lblTip = New-Object System.Windows.Forms.Label
    $lblTip.Text      = '所有数据都在本文件夹内，整个文件夹拷走即可换机'
    $lblTip.Location  = New-Object System.Drawing.Point(28, 322)
    $lblTip.Size      = New-Object System.Drawing.Size(364, 20)
    $lblTip.ForeColor = $colSub
    $lblTip.Font      = New-Object System.Drawing.Font('Microsoft YaHei UI', 7.5)
    $form.Controls.Add($lblTip)

    # ---- hover 效果 ----
    $btnLock.Add_MouseEnter({ $script:menuLock.BackColor = [System.Drawing.Color]::FromArgb(96, 160, 240) })
    $btnLock.Add_MouseLeave({ $script:menuLock.BackColor = [System.Drawing.Color]::FromArgb(74, 144, 226) })
    $btnPwd.Add_MouseEnter({ $script:menuPwd.BackColor = [System.Drawing.Color]::FromArgb(72, 78, 88) })
    $btnPwd.Add_MouseLeave({ $script:menuPwd.BackColor = [System.Drawing.Color]::FromArgb(54, 58, 66) })
    $btnSw.Add_MouseEnter({ $script:menuSwitch.BackColor = [System.Drawing.Color]::FromArgb(72, 78, 88) })
    $btnSw.Add_MouseLeave({ $script:menuSwitch.BackColor = [System.Drawing.Color]::FromArgb(54, 58, 66) })
    $script:menuLock = $btnLock
    $script:menuPwd  = $btnPwd

    # ---- 状态刷新 ----
    $script:menuRefresh = {
        $has = Test-Path -LiteralPath $ConfigPath
        $on  = $false
        if ($has) {
            try {
                $c = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($c.PSObject.Properties['enabled']) { $on = [bool]$c.enabled }
            }
            catch { }
        }
        if (-not $has) {
            $script:menuState.Text      = '密码保护：尚未设置'
            $script:menuState.ForeColor = $script:menuColSub
            $script:menuSwitch.Text     = '设置密码保护'
        }
        elseif ($on) {
            $script:menuState.Text      = '密码保护：已开启 · 锁屏后要输密码'
            $script:menuState.ForeColor = $script:menuColOn
            $script:menuSwitch.Text     = '关闭密码保护（改为只熄屏）'
        }
        else {
            $script:menuState.Text      = '密码保护：已关闭 · 锁屏只熄屏，不输密码'
            $script:menuState.ForeColor = $script:menuColOff
            $script:menuSwitch.Text     = '开启密码保护（锁屏后要输密码）'
        }
    }
    & $script:menuRefresh

    # ---- 事件 ----
    $btnLock.Add_Click({
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            if (-not (Invoke-SetupPassword)) { & $script:menuRefresh; return }
        }
        $script:menuAction = 'lock'
        $script:menuForm.Close()
    })

    $btnPwd.Add_Click({
        [void](Invoke-SetupPassword)
        & $script:menuRefresh
    })

    $btnSw.Add_Click({
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            [void](Invoke-SetupPassword)
            & $script:menuRefresh
            return
        }
        try {
            $c = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show("配置文件读不了：$($_.Exception.Message)", 'LockShield', 'OK', 'Error')
            return
        }
        $cur = $true
        if ($c.PSObject.Properties['enabled']) { $cur = [bool]$c.enabled }
        $new = -not $cur
        $c | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $new -Force
        try {
            [System.IO.File]::WriteAllText($ConfigPath, ($c | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($true)))
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show("写配置失败：$($_.Exception.Message)", 'LockShield', 'OK', 'Error')
        }
        & $script:menuRefresh
    })

    $btnQuit.Add_Click({
        $script:menuAction = 'exit'
        $script:menuForm.Close()
    })

    $form.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $script:menuAction = 'exit'
            $script:menuForm.Close()
        }
    })

    [void]$form.ShowDialog()
    try { $form.Dispose() } catch { }
    return $script:menuAction
}

# 不带参数启动 = 弹菜单；-Lock 才是直接锁屏
if (-not $SetPassword -and -not $Toggle -and -not $Test -and -not $Lock) {
    $menuAct = Show-MainMenu
    if ($menuAct -ne 'lock') { exit 0 }
}

# ============================================================
# 1.5 切换密码开关（-Toggle）：关 = 锁定时只熄屏，不要密码
# ============================================================
if ($Toggle) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Show-Ui "还没设置过密码（没有 shield.config.json），没什么可关的。`n`n先用「设置密码」设一个。" 'LockShield' 'Error'
        exit 1
    }
    try {
        $cfgT = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Show-Ui "配置文件读不了（JSON 坏了？）：$($_.Exception.Message)" 'LockShield' 'Error'
        exit 1
    }
    $cur = $true
    if ($cfgT.PSObject.Properties['enabled']) { $cur = [bool]$cfgT.enabled }
    $new = -not $cur
    $cfgT | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $new -Force
    $json = $cfgT | ConvertTo-Json
    [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($true)))

    if ($new) {
        Show-Ui "密码已【开启】`n`n下次启动会弹出遮罩，回来要输密码。" 'LockShield' 'Info'
    }
    else {
        Show-Ui "密码已【关闭】`n`n下次启动只熄屏，回来动一下鼠标就直接进桌面。`n密码配置原样保留，随时可以切回来。" 'LockShield' 'Warn'
    }
    exit 0
}

# ============================================================
# 2. 读配置（没有就地引导设置，别让人空跑一趟）
# ============================================================
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Show-Ui '第一次用，先设一个遮罩密码。' 'LockShield' 'Warn'
    if (-not (Invoke-SetupPassword -InitialHint $Hint)) {
        Show-Ui '没设成，再启动一次重试。' 'LockShield' 'Error'
        exit 1
    }
    if (-not (Show-Ask '密码设好了。现在试一下锁定效果吗？' 'LockShield')) {
        Show-Ui '好，下次启动就直接锁定。' 'LockShield' 'Info'
        exit 0
    }
}

try {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Show-Ui "配置文件读不了（JSON 坏了？）：$($_.Exception.Message)" 'LockShield' 'Error'
    exit 1
}

$script:salt     = [string]$cfg.salt
$script:hash     = [string]$cfg.hash
$script:hint     = [string]$cfg.hint
$script:unlocked = $false
$script:wrong    = 0

if (-not $script:salt -or -not $script:hash) {
    Show-Ui '配置文件缺 salt / hash，重新设一次密码。' 'LockShield' 'Error'
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
    $m = "载入 WinForms 失败：$($_.Exception.Message)`n（本机 PowerShell 可能不是 Windows 自带的 5.1）"
    try { Show-Ui $m 'LockShield' 'Error' } catch { Write-Host $m -ForegroundColor Red }
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
