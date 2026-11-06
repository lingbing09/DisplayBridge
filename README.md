# DisplayBridge

一键把 iPad 变成 Mac 的副屏。基于 macOS 原生随航（Sidecar）与开源串流方案，提供了一个极简的操作面板。

> 只用「原生随航」的话，**不需要安装任何第三方软件**。

## 功能

界面分三列，对应三种连接方式：

| 方式 | 原理 | 依赖 | 适合场景 |
|------|------|------|----------|
| **原生随航** | macOS Sidecar | 无 | 同一 Apple ID、日常扩展桌面 |
| **串流副屏** | BetterDisplay 虚拟屏 + Sunshine | BetterDisplay、Sunshine、iPad 装 Moonlight | 跨网络、低延迟、可自定义分辨率 |
| **OpenDisplay** | OpenDisplay（OpenSidecar） | OpenDisplay、iPad 端客户端 | 低延迟扩展屏（iPad 端 App Store 下载，无需越狱） |

其他能力：

- **休眠自动断开**：合盖 / 息屏 / 系统睡眠超过设定时间（立即 / 10 / 20 / 30 分钟）自动断开，恢复后自动重连
- **后台常驻**：关闭窗口不退出，登录时自动静默启动，休眠监听持续生效
- **多设备**：原生随航可选目标设备；Sunshine 支持 PIN 配对与已配对设备管理
- **OpenDisplay 配置**：画质、扩展/镜像模式、开机自动连接，直接在设置里调
- **零硬编码**：自动查找已安装的 App、虚拟屏名称可配置、Sunshine 凭据保存在本机钥匙串

## 系统要求

- macOS 13 Ventura 或更高
- Apple Silicon 或 Intel Mac（发布包为 arm64，Intel 需自行编译）
- 原生随航需要 Mac 与 iPad 登录同一 Apple ID，并支持 Sidecar

## 依赖

只有「串流副屏」和「OpenDisplay」需要额外软件。打开 App 后到 **设置 → 依赖** 可以查看安装状态和一键跳转下载。

### 串流副屏

1. **[BetterDisplay](https://betterdisplay.pro)** — 免费版即可。用来创建虚拟显示器。
2. **[Sunshine](https://app.lizardbyte.dev/Sunshine/)** — 开源的串流主机端。
3. **iPad 端 [Moonlight](https://apps.apple.com/app/moonlight-game-streaming/id1000551566)** — App Store 免费。

### OpenDisplay

1. **[OpenDisplay（OpenSidecar）](https://github.com/peetzweg/OpenSidecar)** — Mac 端。
2. iPad 端在 **App Store 搜索 OpenDisplay** 下载客户端（无需越狱，适配 iOS/iPadOS 15 及以上）。

## 安装

1. 从 [Releases](../../releases) 下载最新的 `DisplayBridge-<版本>-macOS.zip`，解压。
2. 把 `DisplayBridge.app` 拖进「应用程序」。
3. 首次打开：**右键 → 打开**（应用为 ad-hoc 签名，未经过 Apple 公证）。
   如果仍被 Gatekeeper 拦住，在终端执行：
   ```bash
   xattr -cr /Applications/DisplayBridge.app
   ```
4. 打开后到 **设置 → 依赖** 检查依赖是否齐全。

## 首次配置：串流副屏

这是唯一需要手动配置一次的方式，配置好之后日常只需点一个按钮。

### 1. BetterDisplay 创建虚拟屏

打开 BetterDisplay → 新建虚拟显示器，**名称保持默认的 `display`**。

> 如果你用了别的名称，到 DisplayBridge **设置 → 依赖 → 虚拟屏名称** 改成一致的名字，点「检测」确认能找到。

### 2. Sunshine 初始化

手动打开一次 Sunshine，它会让你设置 **Web UI 用户名和密码**。

> 记住这组账号密码，稍后要填到 DisplayBridge 里。Sunshine 的 Web UI 地址是 `https://localhost:47990`。

### 3. 填写凭据

DisplayBridge **设置 → Web UI**，填入刚才的用户名和密码，点「保存密码」（保存在本机钥匙串）。

### 4. 连接

主界面点「连接副屏」。首次会依次启动 BetterDisplay → 虚拟屏 → Sunshine，视机器冷启动情况约 3~20 秒。

### 5. iPad 配对

1. iPad 打开 Moonlight，等待自动发现，或手动添加 Mac 的局域网 IP。
2. 点连接后 iPad 上会显示一个 **4 位 PIN**。
3. 在 DisplayBridge **设置 → 串流 → 设备配对** 输入 PIN，点「发送」。

配对只需一次，之后 iPad 直接连。

## 权限说明

- **辅助功能**：仅当「随航连接方式」选择「系统设置界面（离线可用）」时需要。
  路径：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 DisplayBridge。
- **自动化**：连接随航时如果弹出「想控制 System Events」，点允许。
- **不需要** root 权限，不安装系统级服务。

## 常见问题

**Q：点「连接副屏」提示缺少 BetterDisplay / Sunshine？**
说明没装，或装在 LaunchServices 还没索引到的位置。到 **设置 → 依赖** 点「重新检测」；仍不行就重新安装一次。

**Q：提示「未检测到虚拟屏 display」？**
BetterDisplay 里没有创建虚拟屏，或名称不一致。创建后到 **设置 → 依赖** 点「检测」验证。

**Q：Sunshine 显示 HTTP 401？**
Web UI 账号密码不对。到 **设置 → Web UI** 重新填写并保存。

**Q：合盖后 iPad 画面还在？**
OpenDisplay 的虚拟屏是外接显示器，合盖时 Mac 走 clamshell 模式不会睡眠。到 **设置 → OpenDisplay** 打开「合盖 / 息屏时自动退出」，延迟选「立即」或你需要的分钟数。

**Q：窗口关掉了，软件还在跑吗？**
在跑。关闭窗口只是隐藏，休眠断开、登录自启等功能持续生效。点 Dock 图标可以重新打开。

**Q：怎么彻底退出？**
主界面底部「退出」按钮，或 `⌘Q`。

**Q：自动启动怎么关？**
**设置 → 随航 → 后台常驻 → 登录时自动启动** 关掉。

**Q：Intel Mac 能用吗？**
可以，但发布包是 arm64。自行编译时把 `-target` 改成 `x86_64-apple-macosx13.0`。

## 从源码构建

```bash
git clone https://github.com/<your-name>/DisplayBridge.git
cd DisplayBridge

# 只编译不打包
swiftc -O -target arm64-apple-macosx13.0 \
  -framework SwiftUI -framework AppKit -framework CoreGraphics -framework IOKit \
  -o DisplayBridge DisplayBridge.swift

# 编译 + 组装 .app + 签名 + 打 zip（产物在 dist/）
bash build_dist.sh
```

`build_dist.sh` 会自动编译 `get_virtual_display` 工具、把脚本内置到 `Contents/Resources/scripts`，并生成可分发的 zip。

## 项目结构

```
DisplayBridge.swift              主程序（SwiftUI + AppKit）
Info.plist                       App 元信息
get_virtual_display.swift        虚拟屏检测工具（构建时编译为二进制）
ipad_sidecar_start_silent.sh     启动：虚拟屏 → Sunshine 配置同步 → 启动 Sunshine
ipad_sidecar_stop_silent.sh      关闭：停止 Sunshine → 关闭虚拟屏 → 按需退出 BetterDisplay
sidecar_ui_connect.applescript   随航「系统设置界面」方式的 UI 自动化
sidecar_toggle(.scpt/.swift)     随航连接辅助
build_dist.sh                    构建与分发打包
```

## 设计说明

- **零外部依赖的运行方式**：脚本优先从 App 的 `Contents/Resources/scripts` 读取，不需要把文件复制到 `~` 下。
- **App 路径自适应**：通过 LaunchServices 查找 `BetterDisplay.app` / `Sunshine.app`，装在 `/Applications` 或 `~/Applications` 都能识别。
- **凭据不落明文**：Sunshine 密码存 macOS 钥匙串（`Keychain`），用户名存 UserDefaults。
- **僵尸态处理**：串流类副屏用「进程 + 虚拟屏」双条件判定，避免自动断开后 UI 误报「已连接」。

## 已知限制

- 发布包未做 Apple 公证，首次打开需右键 → 打开。
- Sunshine 的分辨率 / 刷新率以虚拟屏和 Sunshine 配置为准，App 里的下拉选项是给后续版本预留的。
- OpenDisplay 的 iPad 端客户端在 App Store 下载，适配 iOS/iPadOS 15 及以上系统。

## 许可

[MIT](LICENSE)

第三方组件遵循各自许可：BetterDisplay（商业软件，有免费版）、Sunshine（GPL-3.0）、OpenDisplay（见其仓库）、Moonlight（GPL-3.0）。
