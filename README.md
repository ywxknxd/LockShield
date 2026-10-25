# LockShield —— Windows 极简锁屏遮罩

双击锁屏，回来输密码；不想输密码时，纯熄屏也行。单文件 44 KB，不装任何运行时。

> **这不是安全机制。** 它挡的是"随手来点两下"的人，不是懂电脑的人。真要防人，用 Win+L 加系统账户密码。

---

## 它能干什么

- **全屏遮罩**：黑底盖住所有显示器，中间一个密码框
- **自动熄屏**：遮罩出现 0.8 秒后关显示器背光，后台程序继续跑
- **密码保护**：加盐 SHA-256 存在本地 JSON 里，不存明文
- **一键切换**：要密码 / 只要熄屏，双击一个 bat 就切
- **扩展通道**：往 `extensions\` 扔脚本，不用重新编译就能加功能

---

## 文件说明

| 文件 | 作用 |
|---|---|
| `dist\LockShield.exe` | 编译好的主程序（推荐用这个） |
| `lock-shield.ps1` | 源码，免编译直接跑 |
| `monitor-off.ps1` | 纯熄屏，不遮罩 |
| `build.ps1` | 从源码重新编译 exe |
| `设置密码.bat` | 设置 / 修改遮罩密码 |
| `密码开关.bat` | 切换「要不要密码」 |
| `lock-shield.bat` | 启动锁屏（命令行版入口） |
| `monitor-off.bat` | 启动纯熄屏 |
| `shield.config.json` | 密码哈希与开关状态（**不入库**） |
| `extensions\` | 扩展通道，见下文 |

---

## 怎么用

1. 第一次用，双击 `设置密码.bat`，输入两遍密码（至少 4 位）
2. 之后双击 `dist\LockShield.exe` 或 `lock-shield.bat` 锁屏
3. 回来时动一下鼠标屏幕就亮，输入密码回车解锁
4. 在锁屏界面按 `Esc` = 不解锁，直接再熄一次屏

### 只熄屏、不要密码

双击 `密码开关.bat`，看到「密码已【关闭】」即可。之后锁屏就是纯熄屏，动鼠标直接回桌面。
再双击一次切回要密码。密码配置一直保留，不会丢。

### 命令行参数

```powershell
# 从源码运行
.\lock-shield.ps1                  # 锁屏（熄屏 + 遮罩）
.\lock-shield.ps1 -Test            # 只显示遮罩不熄屏，调样式用
.\lock-shield.ps1 -SetPassword     # 设置密码
.\lock-shield.ps1 -Toggle          # 切换密码开关
.\lock-shield.ps1 -SetPassword -Hint "提示语"

# 用编译好的 exe，参数完全一样
.\dist\LockShield.exe -Test
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

- 只认 `.ps1`，目录里自带的是 `.sample` 示例，改名去掉后缀才生效
- 用**独立隐藏进程**拉起，主程序不等它跑完（不会拖慢锁屏）
- 出错静默忽略，不影响锁屏本身
- 钩子里路径一律写绝对路径（工作目录不保证）
- 总开关：`shield.config.json` 里的 `"hooksEnabled": false` 可整体关闭

示例：锁屏自动静音、解锁恢复音量、记锁屏日志 —— 见 `extensions\*.sample`。

---

## 从源码构建 exe

需要 PS2EXE 模块（本仓库 `.ps2exe\` 已附带，离线也能构建）：

```powershell
# 如果不用附带的模块
Save-Module -Name PS2EXE -Path .\.ps2exe

# 构建
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
# 产物：dist\LockShield.exe
```

编译参数用了 `-x64 -STA -SupportOS`。`-STA` 是必须的：WinForms 需要单线程单元，缺了会出各种怪问题。

---

## 已知限制

- **锁屏瞬间会闪一下控制台窗口**。因为首次设密码走的是 `Read-Host`，做成无控制台会把设置功能弄坏。介意的话可以自己把设置界面改成 WinForms。
- 只支持 Windows + PowerShell 5.1（系统自带，不用额外装）
- PS2EXE 打包的 exe 可能被杀软误报，属于这类工具的常见现象

---

## 免责声明

本项目仅供个人使用与学习。使用本工具造成的任何数据丢失或安全问题，作者不承担责任。
