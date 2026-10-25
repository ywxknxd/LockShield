#requires -Version 5.1
<#
.SYNOPSIS
    把 lock-shield.ps1 编译成独立的 LockShield.exe。

.DESCRIPTION
    用 PS2EXE 把脚本和它的依赖一起塞进一个 exe，双击即用，不需要旁边有 .ps1。

    编译产物是 Console 版（会短暂闪一下黑窗），原因是脚本里有 Read-Host 交互：
    首次运行要输入两遍密码、-Toggle 要打印状态。改成无控制台会把这些功能弄坏。

    需要 PS2EXE 模块：
        Save-Module -Name PS2EXE -Path <某目录>
    然后 -ModulePath 指向该目录下的 ps2exe.psd1。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
#>
param(
    [string]$ModulePath = '',
    [string]$OutFile    = '',
    [switch]$Console
)

$ErrorActionPreference = 'Stop'

trap {
    Write-Host "[build] 出错（第 $($_.InvocationInfo.ScriptLineNumber) 行）：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutFile) {
    if ($Console) { $OutFile = Join-Path $here 'LockShield-console.exe' }
    else          { $OutFile = Join-Path $here 'LockShield.exe' }
}

# ---- 找 PS2EXE ----
if (-not $ModulePath) {
    $cand = Get-ChildItem -Path (Join-Path $here '.ps2exe') -Filter 'ps2exe.psd1' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if ($cand) { $ModulePath = $cand.FullName }
}
if (-not $ModulePath -or -not (Test-Path -LiteralPath $ModulePath)) {
    $installed = Get-Module -ListAvailable ps2exe | Select-Object -First 1
    if ($installed) { $ModulePath = $installed.Path }
}
if (-not $ModulePath -or -not (Test-Path -LiteralPath $ModulePath)) {
    Write-Host '[build] 找不到 ps2exe 模块。先跑：' -ForegroundColor Red
    Write-Host '        Save-Module -Name PS2EXE -Path .\.ps2exe' -ForegroundColor Yellow
    exit 1
}

Import-Module -Name $ModulePath -Force

$src = Join-Path $here 'lock-shield.ps1'
if (-not (Test-Path -LiteralPath $src)) { throw "源脚本不存在：$src" }

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

Write-Host "[build] 源文件: $src"
Write-Host "[build] 输出:   $OutFile"
if ($Console) { Write-Host '[build] 模式: 控制台版（会闪黑窗，仅调试用）' }
else          { Write-Host '[build] 模式: GUI 版（无窗口，适合放开始菜单）' }

$ps2exeArgs = @{
    InputFile   = $src
    OutputFile  = $OutFile
    Title       = 'LockShield'
    Description = 'Fullscreen lock mask with password, plus monitor-off mode'
    Product     = 'LockShield'
    Company     = ''
    Version     = '1.1.0.0'
    x64         = $true
    STA         = $true
    SupportOS   = $true
}
# 关键：不加 NoConsole 就会带一个控制台窗口，固定到开始菜单每次点都闪黑窗
if (-not $Console) { $ps2exeArgs['NoConsole'] = $true }

Invoke-PS2EXE @ps2exeArgs -Verbose

if (-not (Test-Path -LiteralPath $OutFile)) { throw '编译结束但没有产物，看上面的报错' }

# 把扩展示例一起放到产物目录，方便直接分发（.sample 不会被自动执行）
$extSrc = Join-Path $here 'extensions'
if ((Test-Path -LiteralPath $extSrc) -and ($outDir -ne $here)) {
    $extDst = Join-Path $outDir 'extensions'
    if (-not (Test-Path -LiteralPath $extDst)) { New-Item -ItemType Directory -Path $extDst -Force | Out-Null }
    Copy-Item -Path (Join-Path $extSrc '*.sample') -Destination $extDst -Force -ErrorAction SilentlyContinue
    Write-Host "[build] 扩展示例已复制到 $extDst"
}

$exe = Get-Item -LiteralPath $OutFile
Write-Host ''
Write-Host ("[build] 完成：{0}  ({1:N0} KB)" -f $exe.FullName, ($exe.Length / 1KB)) -ForegroundColor Green
exit 0
