# LockShield —— Windows 极简锁屏遮罩

双击弹菜单，一键锁屏，回来输密码；不想输密码时，纯熄屏也行。单文件 67 KB，无窗口弹出，不装任何运行时。

> **这不是安全机制。** 它挡的是"随手来点两下"的人，不是懂电脑的人。真要防人，用 Win+L 加系统账户密码。

---

## 它能干什么

- **全屏遮罩**：黑底盖住所有显示器，中间一个密码框
- **自动熄屏**：遮罩出现 0.8 秒后关显示器背光，后台程序继续跑
- **密码保护**：加盐 SHA-256 存在本地 JSON 里，不存明文
- **一键切换**：要密码 / 只要熄屏，点一下就能切
- **零黑窗**：GUI 版编译成无控制台程序，放开始菜单不会闪窗
- **扩展通道**：往 `extensions\` 扔脚本，不用重新编译就能加功能

---

## 使用

**绿色免安装**：整个文件夹放哪都行，双击 `LockShield.exe` 会弹出**主菜单**：

- **立即锁屏** —— 遮罩 + 熄屏
- **设置 / 修改密码** —— 图形化弹窗，输两遍确认
- **切换密码保护** —— 要密码 / 只熄屏
- 窗口顶部实时显示当前状态（已开启 / 已关闭 / 尚未设置）

想在开始菜单里放入口，双击 **`安装.bat`**。它只做一件事：
在你的开始菜单建一个 `LockShield` 文件夹，里面四个快捷方式——

- **LockShield** —— 主菜单（同上）
- **立即锁屏** —— 跳过菜单，直接锁屏熄屏
- **设置密码** —— 直达改密码弹窗
- **密码开关** —— 直达开 / 关切换

它**不会复制任何文件**到 `%LOCALAPPDATA%`、`Program Files` 或别的地方，
也不写「应用和功能」的卸载项。程序永远只有你手上这一份。

装完按 `Win` 键，搜「LockShield」就能看到。

> 想换位置就整个文件夹搬走，然后重新双击一次 `安装.bat`（快捷方式会指向新路径）。
> 快捷方式是绝对路径，**搬完一定要重跑一次**，否则会指向旧位置。

---

## 文件说明

| 文件 | 作用 |
|---|---|
| `LockShield.exe` | 主程序（GUI 版，无黑窗） |
| `安装.bat` / `install.ps1` | 就地创建开始菜单入口（不复制文件）/ `-Uninstall` 只删快捷方式 |
| `lock-shield.ps1` | 源码，免编译直接跑 |
| `monitor-off.ps1` | 纯熄屏，不遮罩 |
| `build.ps1` | 重新编译 exe |
| `设置密码.bat` | 设置密码（源码版入口） |
| `密码开关.bat` | 切换密码开关（源码版入口） |
| `lock-shield.bat` | 启动锁屏（源码版入口） |
| `monitor-off.bat` | 启动纯熄屏（源码版入口） |
| `shield.config.json` | 密码哈希与开关状态（**不入库**） |
| `extensions\` | 扩展通道，见下文 |

---

## 怎么用

1. 第一次用，点「设置密码」，浏览器风格的弹窗里输两遍（至少 4 位）
2. 点「锁屏」立刻锁屏
3. 回来时动一下鼠标屏幕就亮，输入密码回车解锁
4. 锁屏界面按 `Esc` = 不解锁，直接再熄一次屏

### 只熄屏、不要密码

点「密码开关」，弹窗告诉你当前状态。关掉后锁屏就是纯熄屏，动鼠标直接回桌面。
再点一次切回来。密码配置一直保留，不会丢。

### 命令行参数

```powershell
.\lock-shield.ps1                  # 锁屏（熄屏 + 遮罩）
.\lock-shield.ps1 -Test            # 只显示遮罩不熄屏，调样式用
.\lock-shield.ps1 -SetPassword     # 图形化设置密码
.\lock-shield.ps1 -Toggle          # 切换密码开关
.\lock-shield.ps1 -SetPassword -Hint "提示语"

# exe 参数完全一样
.\LockShield.exe -Test
.\LockShield.exe -SetPassword
```

---

## 扩展通道

`extensions\` 目录里按事件放脚本，主程序在对应时机**自动调用**，不用改代码、不用重新编译。

| 文件名 | 触发时机 |
|---|---|
| `on-lock.ps1` | 遮罩出现时 |
| `on-screenoff.ps1` | 每次熄屏时（自动熄屏 / 按 Esc / 无密码模式） |
| `on-unlock.ps1` | 密码正确、遮罩关闭后 |

规则：

- 只认 `.ps1`，仓库里自带的是 `.sample` 示例，改名去掉后缀才生效
- 用**独立隐藏进程**拉起，主程序不等它跑完（不会拖慢锁屏）
- 出错静默忽略，不影响锁屏本身
- 钩子里路径一律写绝对路径（工作目录不保证）
- 总开关：`shield.config.json` 里的 `"hooksEnabled": false` 可整体关闭

示例：锁屏自动静音、解锁恢复音量、记锁屏日志 —— 见 `extensions\*.sample`。

---

## 卸载

只想去掉开始菜单入口：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

会先列出要删的快捷方式，确认后才动手。**程序文件一个都不动。**

彻底不用了：先跑上面那条，再把整个文件夹删掉即可（密码配置就在
`shield.config.json` 里，会跟着一起删）。

---

## 从源码构建 exe

仓库自带 PS2EXE 模块（`.ps2exe\`），离线也能构建：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
# 产物：LockShield.exe        （GUI 版，无控制台）

powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Console
# 产物：LockShield-console.exe（控制台版，调试用，会闪黑窗）
```

编译参数：`-x64 -STA -SupportOS`，GUI 版额外加 `-NoConsole`。

- `-STA` 必须有：WinForms 需要单线程单元，缺了会出各种怪问题
- `-NoConsole` 是"放开始菜单不闪窗"的关键；但脚本里所有交互必须先过
  `Show-Ui` / `Show-Ask` / `Show-PasswordDialog` 这层封装，否则无控制台下 `Read-Host` 会直接报错

---

## 已知限制

- 只支持 Windows + PowerShell 5.1（系统自带，不用额外装）
- PS2EXE 打包的 exe 可能被杀软误报，属于这类工具的常见现象
- 遮罩挡不住懂电脑的人（Ctrl+Alt+Del 能结束进程），它就是个门帘

---

## 免责声明

本项目仅供个人使用与学习。使用本工具造成的任何数据丢失或安全问题，作者不承担责任。
