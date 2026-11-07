// DisplayBridge.swift v5 — 设置面板 + 多设备支持
// Build: swiftc -O -target arm64-apple-macosx13.0 -framework SwiftUI -framework AppKit -o DisplayBridge DisplayBridge.swift

import SwiftUI
import AppKit
import Security
import SystemConfiguration
import ApplicationServices
import IOKit.pwr_mgt

// ══════════════════════════════════════════════════════════════════════
//  AX —— 原生辅助功能 API 薄封装
//
//  为什么不再用 AppleScript：
//    · osascript + System Events 每次 AX 调用要 50~200ms，光是递归找按钮就要 4 秒
//    · 原生 AX 调用只要 0.1~1ms，且能在窗口出现的头几毫秒就把它移出屏幕（真正零闪烁）
//    · 还省掉一个子进程 + AppleScript 编译开销
// ══════════════════════════════════════════════════════════════════════
enum AX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }
    static func str(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }
    static func role(_ el: AXUIElement) -> String { str(el, kAXRoleAttribute as String) ?? "" }
    static func title(_ el: AXUIElement) -> String { str(el, kAXTitleAttribute as String) ?? "" }
    static func desc(_ el: AXUIElement) -> String { str(el, kAXDescriptionAttribute as String) ?? "" }
    static func value(_ el: AXUIElement) -> String {
        guard let v = attr(el, kAXValueAttribute as String) else { return "" }
        return (v as? String) ?? ""
    }
    static func els(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        (attr(el, name) as? [AXUIElement]) ?? []
    }
    static func children(_ el: AXUIElement) -> [AXUIElement] { els(el, kAXChildrenAttribute as String) }
    private static func axValue(_ v: CFTypeRef) -> AXValue? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXValue.self)
    }
    static func pt(_ el: AXUIElement, _ name: String) -> CGPoint? {
        guard let v = attr(el, name), let a = axValue(v) else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(a, .cgPoint, &p) else { return nil }
        return p
    }
    static func sz(_ el: AXUIElement, _ name: String) -> CGSize? {
        guard let v = attr(el, name), let a = axValue(v) else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(a, .cgSize, &s) else { return nil }
        return s
    }
    static func pos(_ el: AXUIElement) -> CGPoint? { pt(el, kAXPositionAttribute as String) }
    static func size(_ el: AXUIElement) -> CGSize? { sz(el, kAXSizeAttribute as String) }
    @discardableResult
    static func setPos(_ el: AXUIElement, _ p: CGPoint) -> Bool {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) == .success
    }
    @discardableResult
    static func press(_ el: AXUIElement) -> Bool {
        AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }
}

/// 检测当前是否有可用网络（无网时 SidecarCore 的设备发现会失败，需改走系统设置界面）
func hasActiveNetwork() -> Bool {
    var zero = sockaddr_in()
    zero.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    zero.sin_family = sa_family_t(AF_INET)
    guard let reach = withUnsafePointer(to: &zero, {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            SCNetworkReachabilityCreateWithAddress(nil, $0)
        }
    }) else { return true }
    var flags = SCNetworkReachabilityFlags()
    guard SCNetworkReachabilityGetFlags(reach, &flags) else { return true }
    return flags.contains(.reachable) && !flags.contains(.connectionRequired)
}

// ── 全局通知广播 ──
extension Notification.Name {
    static let sleepAutoStop = Notification.Name("sleepAutoStop")   // 休眠唤醒后自动断开串流（广播给 UI 刷新状态）
    static let windowDidShow = Notification.Name("dbWindowDidShow") // 主窗口每次显示（含复用唤回）→ 重新检测真实状态
    static let openDisplayAutoStop = Notification.Name("openDisplayAutoStop") // 合盖自动断开 OpenDisplay（广播给 UI 刷新）
    static let openDisplayAutoReconnect = Notification.Name("openDisplayAutoReconnect") // 开盖/亮屏自动重连 OpenDisplay（广播给 UI 刷新）
}

extension Color {
    static let accentBlue = Color(red: 0.0, green: 0.48, blue: 1.0)
    static let accentGreen = Color(red: 0.13, green: 0.77, blue: 0.35)
    static let accentOrange = Color(red: 1.0, green: 0.6, blue: 0.0)
    static let accentRed = Color(red: 0.94, green: 0.27, blue: 0.22)
    static let accentPurple = Color(red: 0.58, green: 0.32, blue: 0.85)
    static let accentTeal = Color(red: 0.0, green: 0.62, blue: 0.62)
    static let switchOff = Color.gray.opacity(0.35)
}

// ── 休眠/合盖监听：电脑「休眠」或「合盖」达阈值后自动断开串流副屏 ──
// 注意：串流副屏的虚拟屏是外接显示器，合盖后 Mac 走 clamshell 模式（不睡眠），
// 系统睡眠通知 willSleep/didWake 根本不会触发 —— 所以必须额外轮询「合盖(lid)」状态。
final class SleepWatcher: NSObject {
    static let shared = SleepWatcher()
    private var lowPowerSince: Date?     // 进入低功耗（合盖 / 待机关屏 / 系统睡眠）的时刻
    private var lidTimer: Timer?
    private var started = false
    private var odLowPowerSince: Date?      // 进入低功耗（合盖 / 主显示器息屏）的时刻，用于「延迟断开」计时
    private var autoStoppedOpenDisplay = false  // 是否因合盖自动退出了 OpenDisplay（只有这种情况开盖才自动重连）

    func start() {
        guard !started else { return }
        started = true
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(willSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        // 轮询：5 秒一次，统一检测「合盖」与「主显示器睡眠」（待机关屏）
        let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in self?.tick() }
        lidTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    // ── 配置读取 ──
    private var enabled: Bool { UserDefaults.standard.bool(forKey: UserDefaults.Key.sleepAutoStop) }
    private var threshold: TimeInterval {
        let m = UserDefaults.standard.integer(forKey: UserDefaults.Key.sleepAutoStopMinutes)
        return m > 0 ? Double(m) * 60 : 30 * 60
    }

    // ── 路径 1：系统睡眠（真睡眠/定时睡眠；进程挂起，靠唤醒通知兜底）──
    @objc private func willSleep(_ n: Notification) {
        guard enabled else { return }
        if lowPowerSince == nil { lowPowerSince = Date() }
    }

    @objc private func didWake(_ n: Notification) {
        guard enabled else { lowPowerSince = nil; return }
        if let s = lowPowerSince, Date().timeIntervalSince(s) >= threshold { Self.performAutoStop() }
        lowPowerSince = nil
    }

    // ── 路径 2：合盖 或 待机（主屏睡眠）—— 进程仍活着，靠轮询到点断开 ──
    private func tick() {
        if enabled {
            let lowPower = Self.isLidClosed() || Self.isMainDisplayAsleep()
            if lowPower {
                if lowPowerSince == nil { lowPowerSince = Date() }
            } else {
                lowPowerSince = nil
            }
            // 持续低功耗 ≥ 阈值 → 立即断开（无需等开盖/唤醒）
            if let s = lowPowerSince, Date().timeIntervalSince(s) >= threshold {
                lowPowerSince = nil
                Self.performAutoStop()
            }
        } else {
            lowPowerSince = nil
        }
        // OpenDisplay 合盖/息屏断开（独立于 Sunshine 阈值；延迟由 openDisplayAutoStopMinutes 决定，0=立即）
        handleOpenDisplayLowPower()
    }

    // ── OpenDisplay：合盖 / 主显示器息屏 断开（可设 0/10/20/30 分钟延迟），恢复后自动重连 ──
    // OpenDisplay 的虚拟屏是外接显示器：合盖时 Mac 走 clamshell 模式（不睡眠），
    // 主显示器息屏（待机关屏）时系统仍在运行 —— 两种情况 OpenDisplay 都不会自己退，
    // 画面一直留在 iPad 上，靠轮询来退出它。
    private var openDisplayThreshold: TimeInterval {
        let m = UserDefaults.standard.integer(forKey: UserDefaults.Key.openDisplayAutoStopMinutes)
        return m > 0 ? Double(m) * 60 : 0   // 0 = 立即断开
    }

    private func handleOpenDisplayLowPower() {
        guard UserDefaults.standard.bool(forKey: UserDefaults.Key.openDisplayAutoStop) else {
            odLowPowerSince = nil
            return
        }
        let lowPower = Self.isLidClosed() || Self.isMainDisplayAsleep()
        if lowPower {
            if odLowPowerSince == nil { odLowPowerSince = Date() }
            // 立即（阈值 0）或持续 ≥ 阈值 → 退出 OpenDisplay，虚拟屏随之消失
            if let s = odLowPowerSince, Date().timeIntervalSince(s) >= openDisplayThreshold,
               Self.isOpenDisplayRunning() {
                Self.stopOpenDisplay()
                autoStoppedOpenDisplay = true
                DispatchQueue.main.async { NotificationCenter.default.post(name: .openDisplayAutoStop, object: nil) }
            }
        } else {
            // 恢复（开盖 / 亮屏 / 唤醒）：若上次是自动退出的 → 自动重连
            if autoStoppedOpenDisplay,
               UserDefaults.standard.bool(forKey: UserDefaults.Key.openDisplayAutoReconnect) {
                Self.startOpenDisplay()
                DispatchQueue.main.async { NotificationCenter.default.post(name: .openDisplayAutoReconnect, object: nil) }
            }
            autoStoppedOpenDisplay = false
            odLowPowerSince = nil
        }
    }

    // ── 工具 ──
    static func isLidClosed() -> Bool {
        let matching = IOServiceMatching("IOPMrootDomain")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        defer { IOObjectRelease(service) }
        if let v = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                   kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
            return v
        }
        return false
    }

    /// 主显示器是否睡眠（待机 = displaysleep 关屏；合盖场景已由 lid 覆盖，这里只管"不合盖的待机"）
    static func isMainDisplayAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    private static func isSunshineRunning() -> Bool {
        let p = Process(); p.launchPath = "/usr/bin/pgrep"
        p.arguments = ["-x", "Sunshine"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// 执行自动断开（后台跑 stop 脚本，与手动断开一致）
    static func performAutoStop() {
        DispatchQueue.global(qos: .utility).async {
            guard Self.isSunshineRunning() else { return }
            let p = Process(); p.launchPath = "/bin/bash"
            p.arguments = [DBPaths.tool("ipad_sidecar_stop_silent.sh")]
            var env = ProcessInfo.processInfo.environment
            let keepWarm = UserDefaults.standard.bool(forKey: UserDefaults.Key.keepBDWarm)
            env["KEEP_BD"] = keepWarm ? "1" : "0"
            env["VD_NAME"] = DBPaths.virtualDisplayName
            p.environment = env
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            DispatchQueue.main.async { NotificationCenter.default.post(name: .sleepAutoStop, object: nil) }
        }
    }

    // ── OpenDisplay 进程操作（合盖断开 / 开盖重连 用）──
    static func isOpenDisplayRunning() -> Bool {
        let p = Process(); p.launchPath = "/usr/bin/pgrep"
        p.arguments = ["-x", "OpenDisplay"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func stopOpenDisplay() {
        let p = Process(); p.launchPath = "/usr/bin/pkill"
        p.arguments = ["-x", "OpenDisplay"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }

    static func startOpenDisplay() {
        let p = Process(); p.launchPath = "/usr/bin/open"
        p.arguments = ["-a", "OpenDisplay"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
}

// ── 登录自动启动（LaunchAgent）：登录后静默后台启动，保证热键 + 休眠断开常驻有效 ──
enum LoginAgent {
    static let label = "com.displaybridge"

    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/com.displaybridge.plist"
    }

    static var executablePath: String {
        Bundle.main.executablePath ?? "/Applications/DisplayBridge.app/Contents/MacOS/DisplayBridge"
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// 写入 LaunchAgent plist（RunAtLoad=true，登录时以 --login 静默启动）。
    /// 只写文件、不 bootstrap，避免与当前已运行的实例冲突；下次登录自动生效。
    static func enable() {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath, "--login"],
            "RunAtLoad": true,
            "ProcessType": "Interactive"
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            let dir = (plistPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        } catch {}
    }

    /// 卸载并删除 LaunchAgent（下次登录不再自启）
    static func disable() {
        let p = Process(); p.launchPath = "/bin/launchctl"
        p.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        try? FileManager.default.removeItem(atPath: plistPath)
    }
}

// ── 钥匙串：存 Sunshine Web UI 密码等敏感凭据（不落 UserDefaults 明文）──
enum Keychain {
    static let service = "DisplayBridge"

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

// ── 工具/脚本路径解析：优先 App 内置（Contents/Resources/scripts，打包分发用），回退本机传统目录 ──
enum DBPaths {
    static var legacyDir: String { NSHomeDirectory() + "/Applications/iPad副屏" }

    static func tool(_ fileName: String) -> String {
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        if let bundled = Bundle.main.path(forResource: name, ofType: ext, inDirectory: "scripts"),
           FileManager.default.fileExists(atPath: bundled) { return bundled }
        return legacyDir + "/" + fileName
    }

    /// 查找已安装的 App：先用 LaunchServices（能找到任意位置已注册的 app），再退回常见目录。
    /// 这样别人把 App 装在 ~/Applications 或自定义位置也能正常工作。
    static func appURL(bundleID: String, appName: String) -> URL? {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return u }
        for base in ["/Applications", NSHomeDirectory() + "/Applications", "/Applications/Utilities"] {
            let p = base + "/" + appName + ".app"
            if FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    /// BetterDisplay 虚拟屏名称（BetterDisplay 默认叫 display，用户改过名可在这里配置）
    static var virtualDisplayName: String {
        let n = UserDefaults.standard.string(forKey: UserDefaults.Key.virtualDisplayName)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? "display" : n
    }
}

// ── 外部依赖：检测安装状态 + 官方下载入口（开源分发用，不绑定任何本机路径）──
enum Dependency: String, CaseIterable, Identifiable {
    case betterDisplay, sunshine, openDisplay
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .betterDisplay: return "BetterDisplay"
        case .sunshine: return "Sunshine"
        case .openDisplay: return "OpenDisplay"
        }
    }
    var bundleID: String {
        switch self {
        case .betterDisplay: return "pro.betterdisplay.BetterDisplay"
        case .sunshine: return "dev.lizardbyte.app.Sunshine"
        case .openDisplay: return "com.peetzweg.opensidecar.mac"
        }
    }
    /// 串流副屏链路所需（OpenDisplay 是独立链路）
    var requiredForBridge: Bool { self == .betterDisplay || self == .sunshine }
    var downloadURL: String {
        switch self {
        case .betterDisplay: return "https://betterdisplay.pro"
        case .sunshine: return "https://app.lizardbyte.dev/Sunshine/"
        case .openDisplay: return "https://github.com/peetzweg/OpenSidecar"
        }
    }
    var installHint: String {
        switch self {
        case .betterDisplay: return "免费版即可。安装后需创建名为「display」的虚拟屏（或到「串流」页改名称）"
        case .sunshine: return "安装后先手动打开一次完成初始化（设置网页账号密码），再回到这里"
        case .openDisplay: return "开源 Sidecar 替代品；iPad 端在 App Store 搜索下载（适配 iOS 15+，无需越狱）"
        }
    }
    var isInstalled: Bool { DBPaths.appURL(bundleID: bundleID, appName: displayName) != nil }

    static func missingForBridge() -> [Dependency] {
        allCases.filter { $0.requiredForBridge && !$0.isInstalled }
    }
}

// ── Sunshine Web UI 凭据：优先用户设置，缺省回退 Sunshine 初始默认 1:1 ──
enum SunshineAuth {
    static var user: String {
        let u = UserDefaults.standard.string(forKey: UserDefaults.Key.webUIUser)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return u.isEmpty ? "1" : u
    }
    static var pass: String {
        let p = Keychain.get(account: "sunshine-webui") ?? ""
        return p.isEmpty ? "1" : p
    }
    /// curl -u 用的 "user:pass"
    static var basic: String { "\(user):\(pass)" }
}

// ── UserDefaults 持久化键 ──
extension UserDefaults {
    enum Key { static let sidecarDevice = "sidecarDeviceName", bridgeRes = "bridgeResolution",
               bridgeRefresh = "bridgeRefreshRate", bridgeFPS = "bridgeFPS", bridgePin = "bridgePin",
               sidecarMode = "sidecarConnectMode",        // auto | core | ui
               keepBDWarm = "keepBetterDisplayWarm",       // 断开副屏时保留 BetterDisplay 常驻（下次连接秒开）
               sleepAutoStop = "sleepAutoStopBridge",      // 电脑休眠超时唤醒后自动断开串流副屏
               sleepAutoStopMinutes = "sleepAutoStopMinutes",  // 休眠超时阈值（分钟：10/20/30，默认 30）
               loginAtLaunch = "loginAtLaunch",            // 登录时自动后台启动（LaunchAgent）
               webUIBrowser = "webUIBrowser",              // Sunshine Web UI 打开方式：default | safari | chrome | edge | firefox
               webUIUser = "webUIUser",                    // Sunshine Web UI 账号（密码存钥匙串）
               openDisplayAutoStop = "openDisplayAutoStopBridge",      // 合盖/休眠自动断开 OpenDisplay
               openDisplayAutoReconnect = "openDisplayAutoReconnect",  // 开盖自动重连 OpenDisplay
               openDisplayAutoStopMinutes = "openDisplayAutoStopMinutes", // 合盖后延迟断开分钟数（0=立即，10/20/30）
               virtualDisplayName = "virtualDisplayName" }   // BetterDisplay 虚拟屏名称（默认 display）
}

// ── 独立设置窗口管理器 ──
class SettingsWindowManager {
    static var window: NSWindow?
    static let frameKey = "settingsWindowFrame"

    static func open(onDismiss: @escaping () -> Void) {
        if let w = window, w.isVisible { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 400),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "DisplayBridge 设置"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.minSize = NSSize(width: 320, height: 380)
        w.maxSize = NSSize(width: 560, height: 640)
        w.contentView = NSHostingView(rootView: SettingsView(onDismiss: { onDismiss(); Self.window?.close() }))
        // 恢复上次的位置和大小（校验屏幕可见性）
        if let saved = UserDefaults.standard.string(forKey: frameKey) {
            let rect = NSRectFromString(saved)
            if !rect.isEmpty, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                w.setFrame(rect, display: true)
            }
        }
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        // 关闭时记住位置和大小
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: frameKey)
        }
        window = w
    }
}

struct ContentView: View {
    @State private var bridgeState: BridgeState = .starting
    @State private var sidecarState: SidecarState = .starting
    @State private var displayID: String = ""
    @State private var sidecarName: String = ""
    @State private var streamClientName: String = ""
    @State private var errorMsg: String = ""
    @State private var scriptTask: Process?
    @State private var showSettings = false
    @State private var sidecarDevices: [String] = []
    @AppStorage(UserDefaults.Key.sidecarDevice) private var savedSidecarDevice = ""
    @AppStorage(UserDefaults.Key.bridgeRes) private var bridgeResolution = "1920x1080"
    @AppStorage(UserDefaults.Key.bridgeRefresh) private var bridgeRefreshRate = "60"
    @AppStorage(UserDefaults.Key.bridgeFPS) private var bridgeFPS = "60"
    @AppStorage(UserDefaults.Key.bridgePin) private var bridgePin = ""
    @AppStorage(UserDefaults.Key.sidecarMode) private var sidecarMode = "auto"   // auto | core | ui
    @AppStorage(UserDefaults.Key.keepBDWarm) private var keepBDWarm = false
    @AppStorage(UserDefaults.Key.sleepAutoStop) private var sleepAutoStop = true

    @State private var sidecarBusy = false
    @State private var statusHint = ""     // 顶部一次性提示（离线回退等）
    @State private var autoRetryCount = 0  // 串流连接失败自动重试计数（最多 1 次，手动连接清零）
    @State private var openDisplayState: OpenDisplayState = .starting
    @State private var openDisplayConnectStart: Date? = nil   // 连接开始时间（用于 .connecting 超时判定）

    enum BridgeState { case starting, idle, processOnly, connecting, connected, error }  // processOnly = Sunshine/BetterDisplay 在后台运行但未连接（虚拟屏未建立）
    enum SidecarState { case starting, disconnected, connected }
    enum OpenDisplayState { case starting, stopped, idle, connecting, running }  // idle = 进程在后台运行但未连接（虚拟屏未建立）

    var anyConnected: Bool { bridgeState == .connected || sidecarState == .connected || openDisplayState == .running }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                titleBar.padding(.top, 14)

                DynamicIllustration(isConnected: anyConnected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 8)
                    .padding(.horizontal, 24)
                    .animation(.easeInOut(duration: 0.4), value: anyConnected)

                Spacer().frame(height: 18)

                HStack(alignment: .top, spacing: 10) {
                    sidecarColumn
                    Divider().frame(height: 110).padding(.vertical, 6)
                    bridgeColumn
                    Divider().frame(height: 110).padding(.vertical, 6)
                    openDisplayColumn
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)

                if !statusHint.isEmpty {
                    Text(statusHint)
                        .font(.system(size: 9))
                        .foregroundColor(.accentOrange)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                        .transition(.opacity)
                }

                Button(action: { NSApp.terminate(nil) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "power").font(.system(size: 9))
                        Text("退出").font(.system(size: 11))
                    }.foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VisualEffectView().ignoresSafeArea())
        .onAppear {
            // UI 立即渲染，后台检测延迟 0.3 秒执行，启动更快
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                checkAllStatus()
                refreshSidecarDevices()
            }
            // 预热 BetterDisplay：连接副屏链路里唯一会冷启动十几秒的环节，
            // 提前后台拉起后，用户点「连接副屏」时只剩虚拟屏 + 串流服务的 1~3 秒
            if keepBDWarm {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { warmUpBetterDisplay() }
            }
        }
        // ── 休眠超时唤醒后，自动断开串流副屏（后台已执行断开脚本，这里只刷新界面）──
        .onReceive(NotificationCenter.default.publisher(for: .sleepAutoStop)) { _ in
            displayID = ""; streamClientName = ""; bridgeState = .idle
            let m = UserDefaults.standard.integer(forKey: UserDefaults.Key.sleepAutoStopMinutes)
            statusHint = "已休眠超 \(m > 0 ? m : 30) 分钟，副屏已自动断开"
        }
        // ── 合盖自动断开 OpenDisplay（后台已退出进程，这里只刷新界面）──
        .onReceive(NotificationCenter.default.publisher(for: .openDisplayAutoStop)) { _ in
            openDisplayState = .stopped
            openDisplayConnectStart = nil
            statusHint = "合盖，OpenDisplay 已自动断开"
        }
        // ── 开盖/亮屏自动重连 OpenDisplay（后台已 open -a，这里进入连接中，延迟复核真实状态）──
        .onReceive(NotificationCenter.default.publisher(for: .openDisplayAutoReconnect)) { _ in
            openDisplayState = .connecting
            openDisplayConnectStart = Date()
            statusHint = "已自动重连 OpenDisplay"
            // 双条件判定要等虚拟屏真正建立（冷启动可能 3~8 秒），延迟多档重检
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { checkOpenDisplayStatus() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { checkOpenDisplayStatus() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { checkOpenDisplayStatus() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { checkOpenDisplayStatus() }
        }
        // ── 窗口每次显示都重新检测真实状态（修复：自动断开发生在窗口隐藏期间，UI 停留旧状态）──
        .onReceive(NotificationCenter.default.publisher(for: .windowDidShow)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { checkAllStatus() }
        }
    }

    // ── 标题栏 + 齿轮 ──
    var titleBar: some View {
        ZStack {
            VStack(spacing: 2) {
                Image(systemName: "laptopcomputer.and.ipad").font(.system(size: 24))
                Text("DisplayBridge").font(.system(size: 20, weight: .bold))
                Text("Mac 一键连接 iPad 副屏").font(.system(size: 11)).foregroundColor(.secondary)
            }
            HStack { Spacer()
                Button(action: { openSettingsWindow() }) {
                    Image(systemName: "gearshape.fill").font(.system(size: 14)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }.padding(.trailing, 16).padding(.top, -8)
        }
    }

    var sidecarColumn: some View { /** unchanged **/
        VStack(spacing: 6) {
            HStack(spacing: 4) { Image(systemName: "airplayvideo").font(.system(size: 10)).foregroundColor(.purple)
                Text("原生随航").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary) }
            sidecarBadge
            if sidecarState == .connected, !sidecarName.isEmpty { Text(sidecarName).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail).frame(maxWidth: 150) }
            sidecarAction
        }.frame(maxWidth: .infinity)
    }

    var sidecarBadge: some View {
        let (l, c, i): (String, Color, String) = switch sidecarState {
        case .starting: ("检测中", Color.secondary.opacity(0.4), "hourglass")
        case .disconnected: ("未连接", Color.switchOff, "circle")
        case .connected: ("已连接", Color.accentPurple, "checkmark.circle.fill")
        }
        return badgeView(l, i, c)
    }

    @ViewBuilder var sidecarAction: some View {
        if sidecarBusy {
            HStack(spacing: 6) { ProgressView().controlSize(.small).scaleEffect(0.7); Text("处理中…").font(.system(size: 11, weight: .semibold)).foregroundColor(.white) }
                .frame(width: 120, height: 32).background(RoundedRectangle(cornerRadius: 16).fill(Color.accentPurple))
        } else {
            switch sidecarState {
            case .starting: HStack(spacing: 4) { ProgressView().controlSize(.small).scaleEffect(0.6); Text("检测中").font(.system(size: 10)).foregroundColor(.secondary) }.frame(height: 32)
            case .disconnected: Button("连接随航") { toggleSidecar() }.buttonStyle(RoundButtonStyle(color: .accentPurple, width: 120))
            case .connected: Button("断开随航") { toggleSidecar() }.buttonStyle(RoundButtonStyle(color: .accentRed, width: 120))
            }
        }
    }

    var bridgeColumn: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) { Image(systemName: "cable.connector").font(.system(size: 10)).foregroundColor(.blue)
                Text("串流副屏").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary) }
            bridgeBadge
            if bridgeState == .connected { if !streamClientName.isEmpty { Text("设备: \(streamClientName)").font(.system(size: 9)).foregroundColor(.secondary) }; if !displayID.isEmpty { Text("ID: \(displayID)").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary) } }
            else if bridgeState == .error, !errorMsg.isEmpty { Text(errorMsg).font(.system(size: 9)).foregroundColor(.red).lineLimit(1).truncationMode(.tail).frame(maxWidth: 150) }
            bridgeAction
        }.frame(maxWidth: .infinity)
    }

    var openDisplayColumn: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) { Image(systemName: "display").font(.system(size: 10)).foregroundColor(.teal)
                Text("OpenDisplay").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary) }
            openDisplayBadge
            openDisplayAction
        }.frame(maxWidth: .infinity)
    }

    var openDisplayBadge: some View {
        let (l, c, i): (String, Color, String) = switch openDisplayState {
        case .starting: ("检测中", Color.secondary.opacity(0.4), "hourglass")
        case .stopped: ("未运行", Color.switchOff, "circle")
        case .idle: ("后台运行", Color.accentOrange, "circle.dashed")
        case .connecting: ("连接中", Color.accentOrange, "arrow.triangle.2.circlepath")
        case .running: ("运行中", Color.accentTeal, "checkmark.circle.fill")
        }
        return badgeView(l, i, c)
    }

    @ViewBuilder var openDisplayAction: some View {
        switch openDisplayState {
        case .starting: HStack(spacing: 4) { ProgressView().controlSize(.small).scaleEffect(0.6); Text("检测中").font(.system(size: 10)).foregroundColor(.secondary) }.frame(height: 32)
        case .stopped: Button("连接 OpenDisplay") { toggleOpenDisplay() }.buttonStyle(RoundButtonStyle(color: .accentTeal, width: 128))
        case .idle: Button("退出 OpenDisplay") { quitOpenDisplay() }.buttonStyle(RoundButtonStyle(color: .accentRed, width: 128))
        case .connecting: HStack(spacing: 6) { ProgressView().controlSize(.small).scaleEffect(0.7); Text("连接中...").font(.system(size: 11, weight: .semibold)).foregroundColor(.white) }.frame(width: 128, height: 32).background(RoundedRectangle(cornerRadius: 16).fill(Color.accentOrange))
        case .running: Button("断开 OpenDisplay") { toggleOpenDisplay() }.buttonStyle(RoundButtonStyle(color: .accentRed, width: 128))
        }
    }

    var bridgeBadge: some View {
        let (l, c, i): (String, Color, String) = switch bridgeState {
        case .starting: ("检测中", Color.secondary.opacity(0.4), "hourglass")
        case .idle: ("未连接", Color.switchOff, "circle")
        case .processOnly: ("后台运行", Color.accentOrange, "circle.dashed")
        case .connecting: ("连接中", Color.accentOrange, "arrow.triangle.2.circlepath")
        case .connected: ("已连接", Color.accentGreen, "checkmark.circle.fill")
        case .error: ("失败", Color.accentRed, "xmark.circle.fill")
        }
        return badgeView(l, i, c)
    }

    @ViewBuilder var bridgeAction: some View {
        switch bridgeState {
        case .starting: HStack(spacing: 4) { ProgressView().controlSize(.small).scaleEffect(0.6); Text("检测中").font(.system(size: 10)).foregroundColor(.secondary) }.frame(height: 32)
        case .idle: Button("连接副屏") { startConnecting() }.buttonStyle(RoundButtonStyle(color: .accentBlue, width: 120))
        case .processOnly: Button("退出软件") { quitBridge() }.buttonStyle(RoundButtonStyle(color: .accentRed, width: 120))
        case .connecting: HStack(spacing: 6) { ProgressView().controlSize(.small).scaleEffect(0.7); Text("连接中...").font(.system(size: 11, weight: .semibold)).foregroundColor(.white) }.frame(width: 120, height: 32).background(RoundedRectangle(cornerRadius: 16).fill(Color.accentOrange))
        case .connected: Button("断开连接") { disconnect() }.buttonStyle(RoundButtonStyle(color: .accentRed, width: 120))
        case .error: Button("重试") { errorMsg = ""; startConnecting() }.buttonStyle(RoundButtonStyle(color: .accentBlue, width: 120))
        }
    }

    func badgeView(_ text: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 3) { Image(systemName: icon).font(.system(size: 7)); Text(text).font(.system(size: 9, weight: .semibold)) }
            .foregroundColor(.white).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(color))
    }

    // ── Sunshine 操作（带自定义参数）──
    func startConnecting(manual: Bool = true) {
        if manual { autoRetryCount = 0 }
        // 依赖检查：缺 BetterDisplay / Sunshine 时给出可操作提示，而不是让脚本莫名失败
        let missing = Dependency.missingForBridge()
        if !missing.isEmpty {
            bridgeState = .error
            errorMsg = "缺少 " + missing.map(\.displayName).joined(separator: "、")
            statusHint = "请到设置 → 环境依赖 安装后重试"
            return
        }
        bridgeState = .connecting; errorMsg = ""; displayID = ""; statusHint = "副屏：正在启动…"
        let scriptPath = DBPaths.tool("ipad_sidecar_start_silent.sh")
        guard FileManager.default.fileExists(atPath: scriptPath) else { errorMsg = "找不到脚本"; bridgeState = .error; return }
        let proc = Process(); proc.launchPath = "/bin/bash"
        // 传入自定义参数（去掉 " Hz"/" FPS" 单位后缀，避免把带单位的字符串传给脚本）
        var args = [scriptPath]
        let refreshVal = bridgeRefreshRate.replacingOccurrences(of: " Hz", with: "").trimmingCharacters(in: .whitespaces)
        let fpsVal = bridgeFPS.replacingOccurrences(of: " FPS", with: "").trimmingCharacters(in: .whitespaces)
        if bridgeResolution != "1920x1080" { args.append(contentsOf: ["--res", bridgeResolution]) }
        if refreshVal != "60" { args.append(contentsOf: ["--refresh", refreshVal]) }
        if fpsVal != "60" { args.append(contentsOf: ["--fps", fpsVal]) }
        proc.arguments = args
        // 把本机配置传给脚本：虚拟屏名称 + Sunshine Web UI 凭据（不再写死）
        var env = ProcessInfo.processInfo.environment
        env["VD_NAME"] = DBPaths.virtualDisplayName
        env["SUNSHINE_USER"] = SunshineAuth.user
        env["SUNSHINE_PASS"] = SunshineAuth.pass
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = pipe
        var buf = ""
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if d.isEmpty { return }
            guard let o = String(data: d, encoding: .utf8) else { return }; buf += o
            for l in o.split(separator: "\n") {
                let t = l.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.contains("[OK] CGDirectDisplayID ="), let r = t.range(of: "CGDirectDisplayID = ") {
                    DispatchQueue.main.async { self.displayID = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
                } else if t.hasPrefix("[STEP]") {
                    // 实时把当前步骤显示在底部，避免"卡住不动"的错觉
                    let step = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    DispatchQueue.main.async { if self.bridgeState == .connecting { self.statusHint = "副屏：" + step } }
                } else                 if t == "[STATE] READY" {
                    // 核心链路已通：立即切「已连接」，最后的校验放到后台，不再拖慢界面
                    DispatchQueue.main.async {
                        guard self.bridgeState == .connecting else { return }
                        self.bridgeState = .connected; self.statusHint = ""; self.autoRetryCount = 0
                        self.fetchDisplayID(); self.fetchStreamClientName()
                    }
                }
            }
        }
        proc.terminationHandler = { p in
            DispatchQueue.main.async { pipe.fileHandleForReading.readabilityHandler = nil
                if p.terminationStatus == 0 {
                    self.bridgeState = .connected; self.statusHint = ""; self.autoRetryCount = 0
                    self.fetchDisplayID(); self.fetchStreamClientName()
                } else if self.bridgeState == .connecting {
                    // 断线重试：失败后自动重试一次（手动连接会清零计数，不会无限循环）
                    if self.autoRetryCount < 1 {
                        self.autoRetryCount += 1
                        self.statusHint = "连接失败，自动重试（第 \(self.autoRetryCount) 次）…"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            if self.bridgeState == .connecting || self.bridgeState == .error { self.startConnecting(manual: false) }
                        }
                    } else {
                        self.errorMsg = buf.split(separator: "\n").filter { $0.contains("[ERROR]") }.last.map(String.init) ?? "退出码 \(p.terminationStatus)"
                        self.bridgeState = .error
                        // 串流需要局域网；离线时提示可改走随航
                        self.statusHint = "串流需局域网"
                    }
                }
            }
        }
        do { try proc.run(); scriptTask = proc } catch { errorMsg = error.localizedDescription; bridgeState = .error }
    }
    func cancelConnecting() { scriptTask?.terminate(); scriptTask = nil; autoRetryCount = 0; bridgeState = .idle }

    func openSettingsWindow() { SettingsWindowManager.open(onDismiss: { refreshSidecarDevices() }) }
    /// 断开副屏：界面立即响应，停止脚本放后台跑（原来 waitUntilExit 会卡住界面）
    func disconnect() {
        displayID = ""; streamClientName = ""; bridgeState = .idle; statusHint = ""
        let keepWarm = keepBDWarm
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); p.launchPath = "/bin/bash"
            p.arguments = [DBPaths.tool("ipad_sidecar_stop_silent.sh")]
            // KEEP_BD=1：只关虚拟屏，保留 BetterDisplay 常驻 → 下次连接 1~2 秒
            var env = ProcessInfo.processInfo.environment
            env["KEEP_BD"] = keepWarm ? "1" : "0"
            env["VD_NAME"] = DBPaths.virtualDisplayName
            p.environment = env
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
        }
    }

    // ── 退出 Sunshine / BetterDisplay 软件（后台运行但未连接时，用这个把它们彻底退出）──
    func quitBridge() {
        displayID = ""; streamClientName = ""; bridgeState = .idle; statusHint = "Sunshine / BetterDisplay 已退出"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); p.launchPath = "/bin/bash"
            p.arguments = [DBPaths.tool("ipad_sidecar_stop_silent.sh")]
            // KEEP_BD=0：连 BetterDisplay 一起彻底退出（用户要的是「退出软件」，不是保留常驻）
            var env = ProcessInfo.processInfo.environment
            env["KEEP_BD"] = "0"
            env["VD_NAME"] = DBPaths.virtualDisplayName
            p.environment = env
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
        }
    }

    // ── OpenDisplay 连接 / 断开（主窗口第三列按钮）──
    func toggleOpenDisplay() {
        if openDisplayState == .running {
            openDisplayState = .stopped; openDisplayConnectStart = nil; statusHint = ""
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process(); p.launchPath = "/usr/bin/pkill"
                p.arguments = ["-x", "OpenDisplay"]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try? p.run(); p.waitUntilExit()
            }
        } else if openDisplayState != .connecting {
            // 连接中态：不立即标「运行中」，等虚拟屏真正建立（进程 + 虚拟屏双条件）再切换，
            // 否则按钮和插画会「运行中→未运行」来回抖，看起来像卡顿。
            openDisplayState = .connecting; openDisplayConnectStart = Date(); statusHint = "OpenDisplay：正在连接…"
            DispatchQueue.global(qos: .userInitiated).async {
                // 确保 OpenDisplay「自动连接」开启：启动后直接连上记住的 iPad（wifiRemembered），无需手动点
                let dw = Process(); dw.launchPath = "/usr/bin/defaults"
                dw.arguments = ["write", "com.peetzweg.opensidecar.mac", "autostart", "-bool", "true"]
                dw.standardOutput = FileHandle.nullDevice; dw.standardError = FileHandle.nullDevice
                try? dw.run(); dw.waitUntilExit()

                let p = Process(); p.launchPath = "/usr/bin/open"
                p.arguments = ["-a", "OpenDisplay"]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try? p.run(); p.waitUntilExit()
            }
            // 冷启动 + 连 iPad 需要几秒，分档重检，等虚拟屏建立后切成「运行中」
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { checkOpenDisplayStatus() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { checkOpenDisplayStatus() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { checkOpenDisplayStatus() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { checkOpenDisplayStatus() }
        }
    }

    // ── 退出 OpenDisplay 软件（后台运行但未连接时，用它彻底退出进程）──
    func quitOpenDisplay() {
        openDisplayState = .stopped
        openDisplayConnectStart = nil
        statusHint = "OpenDisplay 已退出"
        DispatchQueue.global(qos: .userInitiated).async {
            SleepWatcher.stopOpenDisplay()
        }
    }

    func checkOpenDisplayStatus() {
        DispatchQueue.global().async {
            let running = SleepWatcher.isOpenDisplayRunning()
            let screen = Self.isOpenDisplayScreenActive()
            DispatchQueue.main.async {
                if running && screen {
                    // 真正串流：进程 + 虚拟屏都在
                    self.openDisplayState = .running
                    self.openDisplayConnectStart = nil
                    self.statusHint = ""
                } else if self.openDisplayState == .connecting {
                    // 连接中但还没连上：保持连接中，等后续重检；超时（15s）才算失败
                    if let start = self.openDisplayConnectStart, Date().timeIntervalSince(start) >= 15 {
                        self.openDisplayConnectStart = nil
                        // 超时：进程起来了但虚拟屏没建立 → 后台运行（未连接），可退出重试
                        self.openDisplayState = running ? .idle : .stopped
                        self.statusHint = "OpenDisplay 连接失败，请重试"
                    }
                } else {
                    // 非连接中：进程在但虚拟屏没建立 → 后台运行（未连接），让用户手动退出
                    self.openDisplayState = running ? .idle : .stopped
                }
            }
        }
    }

    /// 后台预热 BetterDisplay（已在运行则什么都不做）
    /// 它是整条「连接副屏」链路里唯一会冷启动十几秒的环节，提前拉起可省掉这段等待
    func warmUpBetterDisplay() {
        DispatchQueue.global(qos: .utility).async {
            let pg = Process(); pg.launchPath = "/usr/bin/pgrep"
            pg.arguments = ["-q", "BetterDisplay"]
            pg.standardOutput = FileHandle.nullDevice; pg.standardError = FileHandle.nullDevice
            try? pg.run(); pg.waitUntilExit()
            guard pg.terminationStatus != 0 else { return }   // 已在运行，无需预热
            let p = Process(); p.launchPath = "/usr/bin/open"
            p.arguments = ["-g", "/Applications/BetterDisplay.app"]   // -g：后台启动，不抢焦点
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
    }

    // ── Sidecar ──
    /// 按钮 / 快捷键统一入口：已连接则断开，未连接则智能连接
    func toggleSidecar() {
        guard !sidecarBusy else { return }
        if sidecarState == .connected {
            sidecarBusy = true
            runSidecarCore { _ in
                DispatchQueue.main.async { self.waitSidecarOff(timeout: 3) }
            }
        } else {
            connectSidecarSmart()
        }
    }

    // ── 轮询式状态等待：替代原来的固定 sleep，连上/断开即刻返回 ──
    /// 轮询等待随航连上（每 0.2 秒检测一次 NSScreen），completion 主线程回调
    func waitSidecarOn(timeout: Double, completion: @escaping (Bool) -> Void) {
        pollSidecarOn(deadline: Date().addingTimeInterval(timeout), completion: completion)
    }
    private func pollSidecarOn(deadline: Date, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let hit = Self.detectSidecar()
            DispatchQueue.main.async {
                if let (_, name) = hit {
                    self.sidecarState = .connected; self.sidecarName = name
                    completion(true)
                    return
                }
                if Date() >= deadline {
                    self.sidecarState = .disconnected; self.sidecarName = ""
                    completion(false)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.pollSidecarOn(deadline: deadline, completion: completion)
                }
            }
        }
    }
    /// 轮询等待随航断开
    private func waitSidecarOff(timeout: Double) {
        pollSidecarOff(deadline: Date().addingTimeInterval(timeout))
    }
    private func pollSidecarOff(deadline: Date) {
        DispatchQueue.global(qos: .userInitiated).async {
            let stillOn = Self.detectSidecar() != nil
            DispatchQueue.main.async {
                if !stillOn || Date() >= deadline {
                    self.recheckSidecar()
                    self.sidecarBusy = false
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.pollSidecarOff(deadline: deadline)
                }
            }
        }
    }

    /// 智能连接：按设置选 SidecarCore / 系统设置界面 / 自动回退
    func connectSidecarSmart() {
        guard !sidecarBusy else { return }

        // 已经是连接态：只校正状态，不做任何连接动作
        if Self.detectSidecar() != nil { recheckSidecar(); return }

        sidecarBusy = true
        sidecarState = .starting
        statusHint = ""

        // 模式 3：直接用系统设置界面方式（无需网络，离线可用）
        if sidecarMode == "ui" { runUISidecarPath(); return }

        // 自动模式 + 无网络 → 设备发现必然失败，直接走系统设置方式
        if sidecarMode == "auto" && !hasActiveNetwork() {
            statusHint = "离线：改用系统设置方式…"
            runUISidecarPath()
            return
        }

        // 模式 1/2：先走 SidecarCore 接口（零窗口、最快）
        runSidecarCore { _ in
            DispatchQueue.main.async {
                // 接口返回后只轮询 1.6 秒：连上立刻收工，连不上才回退
                self.waitSidecarOn(timeout: 1.6) { ok in
                    if ok { self.statusHint = ""; self.sidecarBusy = false; return }
                    if self.sidecarMode == "core" {
                        self.statusHint = "接口连接失败（离线时可改用系统设置方式）"
                        self.sidecarBusy = false
                        return
                    }
                    self.statusHint = "系统接口未响应，改用系统设置方式…"
                    self.runUISidecarPath()
                }
            }
        }
    }

    /// 系统设置 UI 自动化路径（回滚为 AppleScript 方案）
    /// 脚本内部已做「后台打开 + 窗口移出屏幕 + 直接结束进程」，用户看不到设置界面
    func runUISidecarPath() {
        if statusHint.isEmpty { statusHint = "正在连接…" }
        runSidecarUIAutomation { ok in
            DispatchQueue.main.async {
                // 轮询等屏幕出现（最长 8 秒，连上即返回），不再固定等 3 秒
                self.waitSidecarOn(timeout: 8) { connected in
                    if connected { self.statusHint = "" }
                    else { self.statusHint = ok ? "已发送连接指令，请稍候" : "连接失败，请授予「辅助功能」权限" }
                    self.sidecarBusy = false
                }
            }
        }
    }

    /// 方式 A：SidecarCore 私有接口（sidecar_toggle 工具）
    func runSidecarCore(completion: @escaping (Bool) -> Void) {
        let toolPath = DBPaths.tool("sidecar_toggle")
        guard FileManager.default.fileExists(atPath: toolPath) else { completion(false); return }
        let task = Process(); task.launchPath = toolPath
        var args: [String] = []
        if !savedSidecarDevice.isEmpty { args += ["--device", savedSidecarDevice] }
        task.arguments = args
        task.standardOutput = Pipe(); task.standardError = Pipe()
        task.terminationHandler = { p in completion(p.terminationStatus == 0) }
        do { try task.run() } catch { completion(false) }
    }

    /// 方式 B：系统设置 → 显示器 UI 自动化（不依赖网络设备发现，离线可用）
    func runSidecarUIAutomation(completion: @escaping (Bool) -> Void) {
        // 优先用预编译 .scpt（osascript 免去现场编译，启动更快），退化到 .applescript
        let scpt = DBPaths.tool("sidecar_ui_connect.scpt")
        let applescript = DBPaths.tool("sidecar_ui_connect.applescript")
        let scriptPath = FileManager.default.fileExists(atPath: scpt) ? scpt : applescript
        if FileManager.default.fileExists(atPath: scriptPath) {
            let proc = Process(); proc.launchPath = "/usr/bin/osascript"
            var args = [scriptPath]
            if !savedSidecarDevice.isEmpty { args.append(savedSidecarDevice) }
            proc.arguments = args
            proc.standardOutput = Pipe(); proc.standardError = Pipe()
            proc.terminationHandler = { p in completion(p.terminationStatus == 0) }
            do { try proc.run() } catch { completion(false) }
            return
        }
        // 兜底：直接拉起「开启随航.app」（自带独立授权，不依赖本 App 权限）
        let appPath = DBPaths.tool("开启随航.app")
        guard FileManager.default.fileExists(atPath: appPath) else { completion(false); return }
        let p = Process(); p.launchPath = "/usr/bin/open"; p.arguments = [appPath]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); completion(true) } catch { completion(false) }
    }

    func recheckSidecar() {
        DispatchQueue.global().async {
            if let (_, name) = Self.detectSidecar() {
                DispatchQueue.main.async { self.sidecarState = .connected; self.sidecarName = name }
            } else { DispatchQueue.main.async { self.sidecarState = .disconnected; self.sidecarName = "" } }
        }
    }

    func refreshSidecarDevices() {
        DispatchQueue.global().async {
            guard let _ = dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY) else { return }
            guard let mClass = NSClassFromString("SidecarDisplayManager") as? NSObject.Type,
                  let mgr = mClass.perform(Selector(("sharedManager")))?.takeUnretainedValue(),
                  let devs = mgr.perform(Selector(("devices")))?.takeUnretainedValue() as? [AnyObject] else { return }
            let names = devs.compactMap { $0.perform(Selector(("name")))?.takeUnretainedValue() as? String }
            DispatchQueue.main.async { self.sidecarDevices = names }
        }
    }

    func checkAllStatus() {
        DispatchQueue.global().async {
            let sg = Process(); sg.launchPath = "/usr/bin/pgrep"; sg.arguments = ["-x", "Sunshine"]
            sg.standardError = FileHandle.nullDevice; sg.standardOutput = Pipe(); sg.launch(); sg.waitUntilExit()
            let sunRunning = sg.terminationStatus == 0
            let bg = Process(); bg.launchPath = "/usr/bin/pgrep"; bg.arguments = ["-x", "BetterDisplay"]
            bg.standardError = FileHandle.nullDevice; bg.standardOutput = Pipe(); bg.launch(); bg.waitUntilExit()
            let bdRunning = bg.terminationStatus == 0
            let vdOpen = Self.isVirtualDisplayOpen()
            let sidecar = Self.detectSidecar()
            let odRunning = SleepWatcher.isOpenDisplayRunning()
            let odScreen = Self.isOpenDisplayScreenActive()
            DispatchQueue.main.async {
                // 正在连接中不打断（避免把进行中的连接误判成未连接/已连接）
                if self.bridgeState != .connecting {
                    if sunRunning && vdOpen {
                        self.bridgeState = .connected; self.fetchDisplayID(); self.fetchStreamClientName()
                    } else if sunRunning || bdRunning {
                        // Sunshine / BetterDisplay 进程在但虚拟屏没建立 = 后台运行（未连接），
                        // 显示 processOnly 让用户手动「退出软件」，不再自动清理残留。
                        self.bridgeState = .processOnly
                    } else {
                        self.bridgeState = .idle
                    }
                }
                if let (_, name) = sidecar { self.sidecarState = .connected; self.sidecarName = name } else { self.sidecarState = .disconnected }
                // OpenDisplay：进程 + 虚拟屏「双条件」才算真正运行。
                // 「进程在但虚拟屏未建立」= 后台运行（未连接），显示 idle 让用户手动「退出 OpenDisplay」；
                // 「进程不在」= 未运行（stopped）。不再自动清理残留进程，交给用户控制。
                if odRunning && odScreen {
                    self.openDisplayState = .running
                    self.openDisplayConnectStart = nil
                } else if self.openDisplayState == .connecting {
                    // 连接中（虚拟屏还没建立）：不打断，交给 checkOpenDisplayStatus 的分档重检/超时处理
                } else if odRunning {
                    self.openDisplayState = .idle
                } else {
                    self.openDisplayState = .stopped
                }
            }
        }
    }
    /// 虚拟屏是否打开（get_virtual_display 退出码 0 = 存在；名称可在设置里配置）
    static func isVirtualDisplayOpen() -> Bool {
        let t = Process(); t.launchPath = DBPaths.tool("get_virtual_display")
        t.arguments = [DBPaths.virtualDisplayName]
        t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
        try? t.run(); t.waitUntilExit()
        return t.terminationStatus == 0
    }
    /// OpenDisplay 虚拟屏是否在线（NSScreen 里存在名称含 "OpenDisplay" 的外接屏）
    /// 判定「真正串流」的硬指标：OpenDisplay 进程在 ≠ 已连上 iPad，虚拟屏存在才是。
    static func isOpenDisplayScreenActive() -> Bool {
        for s in NSScreen.screens {
            let name = s.localizedName
            if !name.isEmpty && name.lowercased().contains("opendisplay") { return true }
        }
        return false
    }
    /// 后台清理残留 Sunshine（僵尸态：Sunshine 进程还在但虚拟屏已消失）
    static func cleanupStaleSunshine() {
        DispatchQueue.global(qos: .utility).async {
            let p = Process(); p.launchPath = "/bin/bash"
            p.arguments = [DBPaths.tool("ipad_sidecar_stop_silent.sh")]
            var env = ProcessInfo.processInfo.environment
            let keepWarm = UserDefaults.standard.bool(forKey: UserDefaults.Key.keepBDWarm)
            env["KEEP_BD"] = keepWarm ? "1" : "0"
            env["VD_NAME"] = DBPaths.virtualDisplayName
            p.environment = env
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
    }
    static func detectSidecar() -> (UInt32, String)? {
        for s in NSScreen.screens {
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let name = s.localizedName
            // 排除两类"伪外接屏"，否则会被误判成「原生随航已连接」：
            //   1. BetterDisplay 虚拟屏（名称由设置决定，默认 "display"）
            //   2. OpenDisplay 虚拟屏（localizedName = "OpenDisplay — iPad xxx"）
            if !(CGDisplayIsBuiltin(n.uint32Value) != 0) && name != DBPaths.virtualDisplayName && !name.isEmpty
               && !name.lowercased().contains("opendisplay") {
                return (n.uint32Value, name)
            }
        }; return nil
    }
    func fetchDisplayID() {
        DispatchQueue.global().async {
            let t = Process(); t.launchPath = DBPaths.tool("get_virtual_display")
            t.arguments = [DBPaths.virtualDisplayName]
            let p = Pipe(); t.standardOutput = p; t.standardError = FileHandle.nullDevice; t.launch(); t.waitUntilExit()
            if let o = String(data: p.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), o.allSatisfy({ $0.isNumber }), !o.isEmpty {
                DispatchQueue.main.async { self.displayID = o }
            }
        }
    }
    func fetchStreamClientName() {
        DispatchQueue.global().async {
            // 通过 Sunshine API 获取已配对设备列表
            let proc = Process(); proc.launchPath = "/usr/bin/curl"
            proc.arguments = ["-sk", "-u", SunshineAuth.basic, "--connect-timeout", "1", "https://localhost:47990/api/clients/list"]
            let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
            proc.launch(); proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let jsonStr = String(data: data, encoding: .utf8),
               let jsonData = jsonStr.data(using: .utf8) {
                if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String:Any],
                   let certs = obj["named_certs"] as? [[String:Any]],
                   let first = certs.first,
                   let name = first["name"] as? String {
                    DispatchQueue.main.async { self.streamClientName = name }
                } else {
                    // 兜底：读取 sunshine_state.json
                    let sunStatePath = NSHomeDirectory() + "/.config/sunshine/sunshine_state.json"
                    if let stateData = try? Data(contentsOf: URL(fileURLWithPath: sunStatePath)),
                       let stateObj = try? JSONSerialization.jsonObject(with: stateData) as? [String:Any],
                       let certs = stateObj["named_certs"] as? [[String:Any]],
                       let first = certs.first,
                       let name = first["name"] as? String {
                        DispatchQueue.main.async { self.streamClientName = name }
                    }
                }
            }
        }
    }
}

// ── 设置页签（自定义 tab，替代 TabView 的箭头导航菜单）──
enum SettingsTab: String, CaseIterable, Identifiable {
    case sidecar, bridge, openDisplay, webUI, conf, deps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sidecar: return "随航"
        case .bridge: return "串流"
        case .openDisplay: return "Open"
        case .webUI: return "Web"
        case .conf: return "配置"
        case .deps: return "依赖"
        }
    }
    var icon: String {
        switch self {
        case .sidecar: return "ipad.and.iphone"
        case .bridge: return "cable.connector"
        case .openDisplay: return "display"
        case .webUI: return "globe"
        case .conf: return "doc.text"
        case .deps: return "shippingbox"
        }
    }
}

struct SettingsTabBar: View {
    @Binding var selected: SettingsTab
    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selected = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon).font(.system(size: 13))
                        Text(tab.title).font(.system(size: 9))
                    }
                    .foregroundColor(selected == tab ? Color.accentBlue : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selected == tab ? Color.accentBlue.opacity(0.14) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
    }
}

// ── 设置面板 ──
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UserDefaults.Key.sidecarDevice) private var sidecarDevice = ""
    @AppStorage(UserDefaults.Key.bridgeRes) private var bridgeRes = "1920x1080"
    @AppStorage(UserDefaults.Key.bridgeRefresh) private var bridgeRefresh = "60"
    @AppStorage(UserDefaults.Key.bridgeFPS) private var bridgeFPS = "60"
    @AppStorage(UserDefaults.Key.bridgePin) private var bridgePin = ""
    @AppStorage(UserDefaults.Key.sidecarMode) private var sidecarMode = "auto"
    @AppStorage(UserDefaults.Key.keepBDWarm) private var keepBDWarm = false
    @AppStorage(UserDefaults.Key.sleepAutoStop) private var sleepAutoStop = true
    @AppStorage(UserDefaults.Key.sleepAutoStopMinutes) private var sleepAutoStopMinutes = 30
    @AppStorage(UserDefaults.Key.loginAtLaunch) private var loginAtLaunch = true
    @AppStorage(UserDefaults.Key.webUIBrowser) private var webUIBrowser = "default"
    @AppStorage(UserDefaults.Key.webUIUser) private var webUIUser = ""
    @AppStorage(UserDefaults.Key.openDisplayAutoStop) private var openDisplayAutoStop = true
    @AppStorage(UserDefaults.Key.openDisplayAutoReconnect) private var openDisplayAutoReconnect = true
    @AppStorage(UserDefaults.Key.openDisplayAutoStopMinutes) private var openDisplayAutoStopMinutes = 0
    @AppStorage(UserDefaults.Key.virtualDisplayName) private var virtualDisplayName = "display"
    @State private var selectedTab: SettingsTab = CommandLine.arguments.contains("--tab-od") ? .openDisplay : .sidecar
    @State private var odQuality = "best"      // OpenDisplay 画质（写 OpenDisplay 自己的 defaults）
    @State private var odMode = "extend"       // OpenDisplay 模式
    @State private var odAutostart = true      // OpenDisplay 自动连接
    @State private var odStatus = ""           // OpenDisplay 配置保存提示
    @State private var devices: [String] = []
    @State private var pairedClients: [String] = []
    @State private var testOutput = ""
    @State private var webUIPwd = ""
    @State private var showWebUIPwd = false
    @State private var webUIStatus = ""
    @State private var confText = ""
    @State private var confStatus = ""
    @State private var depsInstalled: [Dependency: Bool] = [:]   // 依赖安装状态快照
    @State private var vdCheckResult = ""                         // 虚拟屏名称检测结果
    private let confPath = NSHomeDirectory() + "/.config/sunshine/sunshine.conf"
    let onDismiss: () -> Void

    let resolutions = ["1280x720", "1920x1080", "2560x1440", "3440x1440", "3840x2160"]
    let refreshRates = ["30", "60", "120", "144"]
    let fpsOptions = ["30", "60", "120"]

    var body: some View {
        VStack(spacing: 0) {
            HStack { Spacer(); Button("完成") { onDismiss(); NSApplication.shared.keyWindow?.close() }.padding(12) }
            SettingsTabBar(selected: $selectedTab).padding(.bottom, 6)
            Group {
                switch selectedTab {
                case .sidecar: sidecarTab
                case .bridge: bridgeTab
                case .openDisplay: openDisplayTab
                case .webUI: webUITab
                case .conf: sunshineConfTab
                case .deps: dependenciesTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectView().ignoresSafeArea())
        .onAppear {
            loadDevices()
            // 钥匙串读取移到后台：首次访问可能触发系统授权弹窗/等待，别阻塞主线程
            DispatchQueue.global().async {
                let pwd = Keychain.get(account: "sunshine-webui") ?? ""
                DispatchQueue.main.async { self.webUIPwd = pwd }
            }
            loadConf()
        }
    }

    var sidecarTab: some View {
        VStack(alignment: .center, spacing: 14) {
            Text("选择原生随航目标设备").font(.title3).bold().padding(.top, 16)
            Text("连接随航时会使用此设备").font(.caption).foregroundColor(.secondary)

            if devices.isEmpty {
                HStack { ProgressView().scaleEffect(0.7); Text("正在搜索设备...").font(.caption) }
            } else {
                Picker("目标设备", selection: $sidecarDevice) {
                    Text("自动检测").tag("")
                    ForEach(devices, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.radioGroup)
            }

            Button("刷新设备列表") { loadDevices() }.font(.caption)

            Divider().padding(.vertical, 2)

            Text("连接方式").font(.headline)
            Picker("", selection: $sidecarMode) {
                Text("自动（接口失败时回退）").tag("auto")
                Text("仅系统接口（需联网发现）").tag("core")
                Text("系统设置界面（离线可用）").tag("ui")
            }.pickerStyle(.radioGroup).labelsHidden()
            if sidecarMode == "ui" {
                Text("走「系统设置 → 显示器」，不依赖网络设备发现")
                    .font(.caption2).foregroundColor(.secondary)
            }

            Divider().padding(.vertical, 2)

            Divider().padding(.vertical, 2)

            Text("后台常驻").font(.headline)
            Toggle("登录时自动启动", isOn: Binding(
                get: { loginAtLaunch },
                set: { v in
                    loginAtLaunch = v
                    if v { LoginAgent.enable() } else { LoginAgent.disable() }
                }
            )).font(.caption)
            Text("关闭窗口不会退出软件；休眠自动断开在后台持续有效")
                .font(.caption2).foregroundColor(.secondary)

            Spacer()
        }.padding(.horizontal, 24)
    }

    var bridgeTab: some View {
        VStack(alignment: .center, spacing: 8) {
            Text("串流副屏参数配置").font(.title3).bold().padding(.top, 10)
            Text("重启 Sunshine 串流后生效").font(.caption).foregroundColor(.secondary)

            HStack(spacing: 8) {
                Text("分辨率").frame(width: 48, alignment: .trailing)
                FixedWidthPicker(options: resolutions, selection: $bridgeRes)
                    .frame(width: 120, height: 32)
            }
            HStack(spacing: 8) {
                Text("刷新率").frame(width: 48, alignment: .trailing)
                FixedWidthPicker(options: refreshRates.map { "\($0) Hz" }, selection: $bridgeRefresh)
                    .frame(width: 120, height: 32)
            }
            HStack(spacing: 8) {
                Text("帧\u{3000}率").frame(width: 48, alignment: .trailing)
                FixedWidthPicker(options: fpsOptions.map { "\($0) FPS" }, selection: $bridgeFPS)
                    .frame(width: 120, height: 32)
            }

            Divider().padding(.vertical, 2)

            Text("后台服务").font(.headline)
            Toggle("BetterDisplay 隐形驻留（提速）", isOn: $keepBDWarm).font(.caption)
            Text(keepBDWarm ? "关闭副屏后 BetterDisplay 隐形驻留（无图标无 Dock），下次连接约 1~2 秒"
                            : "关闭副屏时 Sunshine 与 BetterDisplay 一起退出，下次连接需等 15~45 秒冷启动")
                .font(.caption2).foregroundColor(.secondary).padding(.leading, 4)

            Divider().padding(.vertical, 2)

            Text("休眠自动断开").font(.headline)
            Toggle("休眠超时自动断开副屏", isOn: $sleepAutoStop).font(.caption)
            if sleepAutoStop {
                Picker("", selection: $sleepAutoStopMinutes) {
                    Text("10 分钟").tag(10)
                    Text("20 分钟").tag(20)
                    Text("30 分钟").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 224)
            }
            Text(sleepAutoStop ? "电脑合盖/休眠 ≥\(sleepAutoStopMinutes) 分钟后唤醒，自动关闭 Sunshine 与虚拟屏"
                            : "休眠唤醒后保持原状态，不自动断开")
                .font(.caption2).foregroundColor(.secondary).padding(.leading, 4)

            Divider().padding(.vertical, 2)

            Text("设备配对").font(.headline)
            HStack(spacing: 8) {
                Text("配对码").frame(width: 48, alignment: .trailing)
                TextField("Moonlight 显示的 PIN", text: $bridgePin).textFieldStyle(.roundedBorder).frame(width: 150)
                Button("发送") { submitPin() }.font(.caption).disabled(bridgePin.isEmpty)
            }

            Button("刷新已配对设备") { loadPairedClients() }.font(.caption)
            if !pairedClients.isEmpty {
                Text("已配对: \(pairedClients.joined(separator: ", "))").font(.caption).foregroundColor(.secondary)
            }

            Spacer().frame(height: 6)
            HStack { Spacer(); Button("测试连接") { testBridge() }.buttonStyle(RoundButtonStyle(color: .accentBlue, width: 120)); Spacer() }.padding(.bottom, 8)
            if !testOutput.isEmpty {
                ScrollView { Text(testOutput).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary) }.frame(height: 60)
            }
        }.padding(.horizontal, 24).onAppear { loadPairedClients() }
    }

    var openDisplayTab: some View {
        VStack(alignment: .center, spacing: 12) {
            Text("OpenDisplay 副屏").font(.title3).bold().padding(.top, 16)
            Text("开源 Sidecar 替代品，iPad 端 App Store 下载，低延迟扩展屏").font(.caption).foregroundColor(.secondary)

            Divider().padding(.vertical, 2)

            Text("连接设置").font(.headline)
            HStack(spacing: 8) {
                Text("画　质").frame(width: 56, alignment: .trailing)
                Picker("", selection: Binding(
                    get: { odQuality },
                    set: { odQuality = $0; writeOpenDisplayConfig() }
                )) {
                    Text("最佳（18 Mbps）").tag("best")
                    Text("均衡（10 Mbps）").tag("balanced")
                    Text("流畅（6 Mbps）").tag("fast")
                }.labelsHidden().frame(width: 180)
            }
            HStack(spacing: 8) {
                Text("模　式").frame(width: 56, alignment: .trailing)
                Picker("", selection: Binding(
                    get: { odMode },
                    set: { odMode = $0; writeOpenDisplayConfig() }
                )) {
                    Text("扩展屏").tag("extend")
                    Text("镜像").tag("mirror")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            Toggle("启动时自动连接 iPad", isOn: Binding(
                get: { odAutostart },
                set: { odAutostart = $0; writeOpenDisplayConfig() }
            )).font(.caption)
            if !odStatus.isEmpty { Text(odStatus).font(.caption2).foregroundColor(.accentOrange) }
            Text("画质 / 模式 / 自动连接修改后，重新「连接 OpenDisplay」生效")
                .font(.caption2).foregroundColor(.secondary)

            Divider().padding(.vertical, 2)

            Text("合盖 / 息屏 / 休眠自动断开").font(.headline)
            Toggle("合盖 / 息屏时自动退出 OpenDisplay", isOn: $openDisplayAutoStop).font(.caption)
            if openDisplayAutoStop {
                HStack(spacing: 8) {
                    Text("延　迟").frame(width: 56, alignment: .trailing)
                    Picker("", selection: $openDisplayAutoStopMinutes) {
                        Text("立即").tag(0)
                        Text("10 分钟").tag(10)
                        Text("20 分钟").tag(20)
                        Text("30 分钟").tag(30)
                    }.pickerStyle(.segmented).frame(width: 224)
                }
            }
            Toggle("恢复时自动重连 OpenDisplay", isOn: $openDisplayAutoReconnect).font(.caption)
                .disabled(!openDisplayAutoStop)
            Text("OpenDisplay 的虚拟屏是外接显示器：合盖时 Mac 走 clamshell 模式（不睡眠）、主显示器息屏时系统仍在运行 —— 这两种情况 OpenDisplay 都不会自己退出，画面会一直留在 iPad 上。开启后，合盖 / 息屏 / 休眠持续超过设定时间（立即 / 10 / 20 / 30 分钟）即退出 OpenDisplay，副屏随之关闭；恢复时（开盖 / 亮屏 / 唤醒）自动重连。")
                .font(.caption2).foregroundColor(.secondary)

            Spacer()
        }
        .padding(.horizontal, 24)
        .onAppear { loadOpenDisplayConfig() }
    }

    // ── 环境依赖（开源分发用：检测安装状态 + 官方下载入口）──
    var dependenciesTab: some View {
        VStack(alignment: .center, spacing: 10) {
            Text("环境依赖").font(.title3).bold().padding(.top, 16)
            Text("按需安装；只用原生随航则不需要任何依赖").font(.caption).foregroundColor(.secondary)

            VStack(spacing: 10) {
                ForEach(Dependency.allCases) { dep in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Image(systemName: depsInstalled[dep] == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(depsInstalled[dep] == true ? .green : .orange)
                                .font(.system(size: 12))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(dep.displayName).font(.system(size: 11, weight: .semibold))
                                Text(depsInstalled[dep] == true
                                     ? (dep.requiredForBridge ? "已安装 · 串流需要" : "已安装")
                                     : "未安装 · \(dep.requiredForBridge ? "串流需要" : "可选")")
                                    .font(.system(size: 9)).foregroundColor(.secondary)
                            }
                            Spacer()
                            if depsInstalled[dep] == true {
                                Button("打开") { openDependencyApp(dep) }.font(.caption2)
                            } else {
                                Button("下载") {
                                    if let u = URL(string: dep.downloadURL) { NSWorkspace.shared.open(u) }
                                }.font(.caption2)
                            }
                        }
                        if depsInstalled[dep] != true && dep.requiredForBridge {
                            Text(dep.installHint)
                                .font(.system(size: 9)).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 19)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button("重新检测") { refreshDependencies() }.font(.caption)
                Button("打开应用程序文件夹") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                }.font(.caption)
            }

            Divider().padding(.vertical, 2)

            Text("虚拟屏名称").font(.headline)
            HStack(spacing: 6) {
                TextField("display", text: $virtualDisplayName)
                    .textFieldStyle(.roundedBorder).frame(width: 140)
                Button("检测") { checkVirtualDisplayName() }.font(.caption)
            }
            Text("需与 BetterDisplay 中虚拟屏名称一致（默认 display）")
                .font(.caption2).foregroundColor(.secondary)
            if !vdCheckResult.isEmpty {
                Text(vdCheckResult).font(.caption2)
                    .foregroundColor(vdCheckResult.hasPrefix("✓") ? .green : .accentOrange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .onAppear { refreshDependencies() }
    }

    func refreshDependencies() {
        var snapshot: [Dependency: Bool] = [:]
        for dep in Dependency.allCases { snapshot[dep] = dep.isInstalled }
        depsInstalled = snapshot
    }

    func openDependencyApp(_ dep: Dependency) {
        if let u = DBPaths.appURL(bundleID: dep.bundleID, appName: dep.displayName) {
            NSWorkspace.shared.open(u)
        }
    }

    func checkVirtualDisplayName() {
        let target = virtualDisplayName.trimmingCharacters(in: .whitespaces)
        let name = target.isEmpty ? "display" : target
        DispatchQueue.global().async {
            let t = Process(); t.launchPath = DBPaths.tool("get_virtual_display")
            t.arguments = [name]
            let out = Pipe()
            t.standardOutput = out; t.standardError = FileHandle.nullDevice
            try? t.run(); t.waitUntilExit()
            let did = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                vdCheckResult = t.terminationStatus == 0
                    ? "✓ 已找到，displayID = \(did)"
                    : "✗ 未找到名为「\(name)」的虚拟屏，请检查 BetterDisplay 里的名称"
            }
        }
    }

    // ── OpenDisplay 配置读写（写 OpenDisplay 自己的 UserDefaults 域，改后需重连生效）──
    func loadOpenDisplayConfig() {
        // 直接读 OpenDisplay 的偏好 plist（零进程、零 XPC），
        // 避免 spawn defaults 进程经 cfprefsd 与运行中的 OpenDisplay 通信造成停顿
        DispatchQueue.global().async {
            let dict = readODPlist()
            let q = dict["quality"] as? String ?? "best"
            let m = dict["mode"] as? String ?? "extend"
            let a = (dict["autostart"] as? NSNumber)?.boolValue ?? (dict["autostart"] as? Bool) ?? true
            DispatchQueue.main.async {
                self.odQuality = q
                self.odMode = m
                self.odAutostart = a
            }
        }
    }

    func writeOpenDisplayConfig() {
        // 后台写：spawn 3 个 defaults 进程（每个几十~几百 ms），放主线程会让 picker 拖动卡顿
        let q = odQuality; let m = odMode; let a = odAutostart
        DispatchQueue.global().async {
            writeODString("quality", q)
            writeODString("mode", m)
            writeODBool("autostart", a)
            DispatchQueue.main.async { self.odStatus = "已保存，重新「连接 OpenDisplay」生效" }
        }
    }

    // 读取 OpenDisplay 偏好 plist（~/Library/Preferences/com.peetzweg.opensidecar.mac.plist）
    func readODPlist() -> [String: Any] {
        let path = NSHomeDirectory() + "/Library/Preferences/com.peetzweg.opensidecar.mac.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    func writeODString(_ key: String, _ value: String) {
        runDefaults(["write", "com.peetzweg.opensidecar.mac", key, value])
    }

    func writeODBool(_ key: String, _ value: Bool) {
        runDefaults(["write", "com.peetzweg.opensidecar.mac", key, "-bool", value ? "true" : "false"])
    }

    func runDefaults(_ args: [String]) {
        let p = Process(); p.launchPath = "/usr/bin/defaults"
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }

    func loadDevices() {
        DispatchQueue.global().async {
            guard let _ = dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY) else { return }
            guard let mClass = NSClassFromString("SidecarDisplayManager") as? NSObject.Type,
                  let mgr = mClass.perform(Selector(("sharedManager")))?.takeUnretainedValue(),
                  let devs = mgr.perform(Selector(("devices")))?.takeUnretainedValue() as? [AnyObject] else { return }
            let names = devs.compactMap { $0.perform(Selector(("name")))?.takeUnretainedValue() as? String }
            DispatchQueue.main.async { self.devices = names }
        }
    }

    // ── Web UI tab ──
    var webUITab: some View {
        VStack(alignment: .center, spacing: 12) {
            Text("Sunshine 网页管理").font(.title3).bold().padding(.top, 16)
            Text("在浏览器打开 Sunshine 管理页（localhost:47990）").font(.caption).foregroundColor(.secondary)

            HStack(spacing: 8) {
                Text("浏览器").frame(width: 48, alignment: .trailing)
                Picker("", selection: $webUIBrowser) {
                    Text("系统默认").tag("default")
                    Text("Safari").tag("safari")
                    Text("Chrome").tag("chrome")
                    Text("Edge").tag("edge")
                    Text("Firefox").tag("firefox")
                }.labelsHidden().frame(width: 150)
            }
            Button("打开 Web UI") { openWebUI() }.font(.caption)

            Divider().padding(.vertical, 2)

            Text("网页账号和密码").font(.headline)
            Text("记录 Sunshine 网页登录凭据，密码保存在本机钥匙串").font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Text("账　号").frame(width: 48, alignment: .trailing)
                TextField("用户名", text: $webUIUser).textFieldStyle(.roundedBorder).frame(width: 150)
            }
            HStack(spacing: 8) {
                Text("密　码").frame(width: 48, alignment: .trailing)
                Group {
                    if showWebUIPwd { TextField("密码", text: $webUIPwd) } else { SecureField("密码", text: $webUIPwd) }
                }.textFieldStyle(.roundedBorder).frame(width: 100)
                Toggle("显示", isOn: $showWebUIPwd).font(.caption2).toggleStyle(.checkbox)
            }
            HStack(spacing: 12) {
                Button("保存密码") {
                    Keychain.set(webUIPwd, account: "sunshine-webui")
                    webUIStatus = "密码已保存到钥匙串"
                }.font(.caption)
                Button("复制密码") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(webUIPwd, forType: .string)
                    webUIStatus = "密码已复制"
                }.font(.caption).disabled(webUIPwd.isEmpty)
            }
            if !webUIStatus.isEmpty { Text(webUIStatus).font(.caption2).foregroundColor(.secondary) }
            Spacer()
        }.padding(.horizontal, 24)
    }

    func openWebUI() {
        let urlStr = "https://localhost:47990"
        guard let url = URL(string: urlStr) else { return }
        switch webUIBrowser {
        case "safari": launchBrowser(bundleID: "com.apple.Safari", appName: "Safari", urlStr: urlStr, fallback: url)
        case "chrome": launchBrowser(bundleID: "com.google.Chrome", appName: "Chrome", urlStr: urlStr, fallback: url)
        case "edge": launchBrowser(bundleID: "com.microsoft.edge", appName: "Edge", urlStr: urlStr, fallback: url)
        case "firefox": launchBrowser(bundleID: "org.mozilla.firefox", appName: "Firefox", urlStr: urlStr, fallback: url)
        default: NSWorkspace.shared.open(url)
        }
    }

    func launchBrowser(bundleID: String, appName: String, urlStr: String, fallback: URL) {
        // 未安装所选浏览器时回退到系统默认，不让按钮"没反应"
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSWorkspace.shared.open(fallback)
            webUIStatus = "未安装 \(appName)，已用默认浏览器打开"
            return
        }
        let p = Process(); p.launchPath = "/usr/bin/open"
        p.arguments = ["-a", appURL.path, urlStr]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
        webUIStatus = ""
    }

    // ── Sunshine 配置文件 tab ──
    var sunshineConfTab: some View {
        VStack(alignment: .center, spacing: 10) {
            Text("Sunshine 配置文件").font(.title3).bold().padding(.top, 16)
            Text(confPath).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            TextEditor(text: $confText)
                .font(.system(size: 10, design: .monospaced))
                .scrollContentBackground(.hidden)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .frame(minHeight: 150)
            HStack(spacing: 12) {
                Button("保存") { saveConf() }.font(.caption)
                Button("打开目录") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: (confPath as NSString).deletingLastPathComponent))
                }.font(.caption)
            }
            if !confStatus.isEmpty { Text(confStatus).font(.caption2).foregroundColor(.secondary) }
            Text("保存后重新「连接副屏」生效（Sunshine 启动时读取）").font(.caption2).foregroundColor(.secondary)
            Spacer()
        }.padding(.horizontal, 24)
    }

    func loadConf() {
        DispatchQueue.global().async {
            let s = (try? String(contentsOfFile: confPath, encoding: .utf8)) ?? ""
            DispatchQueue.main.async { self.confText = s }
        }
    }

    func saveConf() {
        let fm = FileManager.default
        let dir = (confPath as NSString).deletingLastPathComponent
        let stamp = Self.timestamp()
        let bak = dir + "/sunshine.conf.bak-\(stamp)"
        if fm.fileExists(atPath: confPath) { try? fm.copyItem(atPath: confPath, toPath: bak) }
        do {
            try confText.write(toFile: confPath, atomically: true, encoding: .utf8)
            confStatus = fm.fileExists(atPath: bak) ? "已保存（原文件备份为 sunshine.conf.bak-\(stamp)）" : "已保存"
        } catch {
            confStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    func testBridge() {
        let proc = Process(); proc.launchPath = "/usr/bin/curl"
        proc.arguments = ["-sk", "-u", SunshineAuth.basic, "--connect-timeout", "1", "https://localhost:47990/", "-o", "/dev/null", "-w", "HTTP %{http_code}"]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = pipe
        proc.launch(); proc.waitUntilExit()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        if let o = String(data: d, encoding: .utf8) { testOutput = "Sunshine: \(o.trimmingCharacters(in: .whitespacesAndNewlines))" }
        else { testOutput = "无响应" }
    }

    func submitPin() {
        guard !bridgePin.isEmpty else { return }
        let json = "{\"pin\":\"\(bridgePin)\"}"
        let proc = Process(); proc.launchPath = "/usr/bin/curl"
        proc.arguments = ["-sk", "-u", SunshineAuth.basic, "-X", "POST", "-H", "Content-Type: application/json", "-d", json, "https://localhost:47990/api/pin"]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = pipe
        proc.launch(); proc.waitUntilExit()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        if let o = String(data: d, encoding: .utf8) { testOutput = "PIN 发送: \(o.trimmingCharacters(in: .whitespacesAndNewlines))" }
        bridgePin = ""
    }

    func loadPairedClients() {
        DispatchQueue.global().async {
            let proc = Process(); proc.launchPath = "/usr/bin/curl"
            proc.arguments = ["-sk", "-u", SunshineAuth.basic, "--connect-timeout", "1", "https://localhost:47990/api/clients/list"]
            let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
            proc.launch(); proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            var names: [String] = []
            if let jsonStr = String(data: data, encoding: .utf8), let jsonData = jsonStr.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String:Any],
               let certs = obj["named_certs"] as? [[String:Any]] {
                names = certs.compactMap { $0["name"] as? String }
            }
            DispatchQueue.main.async { self.pairedClients = names }
        }
    }
}

// ── 按钮样式 ──
struct RoundButtonStyle: ButtonStyle {
    let color: Color; let width: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            .frame(width: width, height: 32)
            .background(Capsule().fill(configuration.isPressed ? color.opacity(0.8) : color))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}

// ── 插图组件 ──
struct DynamicIllustration: View {
    let isConnected: Bool
    // 基准尺寸：三个图标 + 连接线 + 间距 + 背景内边距的原始布局
    private let baseW: CGFloat = 240
    private let baseH: CGFloat = 112

    var body: some View {
        GeometryReader { geo in
            // 按可用空间等比缩放（contain：保持比例、不溢出），窗口拉伸时插图跟随变大
            let scale = min(geo.size.width / baseW, geo.size.height / baseH)
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.45)).shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 1)
                HStack(spacing: 10) {
                    MacBookProIcon(isConnected: isConnected).frame(width: 110, height: 90)
                    ConnectionLine(isActive: isConnected).frame(width: 24, height: 30)
                    IPadIcon(isConnected: isConnected).frame(width: 66, height: 92)
                }
            }
            .frame(width: baseW, height: baseH)
            .scaleEffect(scale)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// 按参考图风格画的 MacBook Pro：梯形键盘底座 + 转轴 + 屏幕 + Apple logo
struct MacBookProIcon: View {
    let isConnected: Bool

    var body: some View {
        ZStack(alignment: .center) {
            // ── 键盘底座（梯形） ──
            Trapezoid()
                .fill(Color.black)
                .frame(width: 82, height: 10)
                .offset(y: 34)

            // 触摸板槽（中间浅色细条）
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 19, height: 2)
                .offset(y: 37)

            // ── 转轴（屏幕下方的细金属条） ──
            Capsule()
                .fill(Color.gray.opacity(0.7))
                .frame(width: 75, height: 2)
                .offset(y: 27)

            // ── 屏幕外框 ──
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black)
                .frame(width: 75, height: 52)
                .offset(y: -2)

            // ── 屏幕内容 ──
            RoundedRectangle(cornerRadius: 2.5)
                .fill(screenBackground)
                .frame(width: 70, height: 46)
                .offset(y: -2)
                .overlay {
                    if isConnected {
                        Image(systemName: "applelogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 24)
                            .foregroundColor(.white.opacity(0.95))
                            .offset(y: -2)
                    } else {
                        // 未连接：屏幕中间显示彩色 "Mac" 文字
                        Text("Mac")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(colors: [Color.blue, Color.green, Color.orange, Color.pink],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                    }
                }
        }
    }

    var screenBackground: some ShapeStyle {
        if isConnected {
            return AnyShapeStyle(Color.black)  // 黑屏显示 Apple logo（开机状态）
        } else {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.purple.opacity(0.65), Color.blue.opacity(0.65)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
        }
    }
}

struct Trapezoid: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path(); let ti: CGFloat = rect.width * 0.08
        p.move(to: .init(x: ti, y: 0)); p.addLine(to: .init(x: rect.width - ti, y: 0)); p.addLine(to: .init(x: rect.width, y: rect.height)); p.addLine(to: .init(x: 0, y: rect.height)); p.closeSubpath(); return p
    }
}

struct ConnectionLine: View {
    let isActive: Bool
    var body: some View {
        ZStack {
            Rectangle().fill(isActive ? Color.green.opacity(0.7) : Color.secondary.opacity(0.3)).frame(width: 18, height: 1.5).offset(y: 2)
            Image(systemName: "cable.connector").font(.system(size: 13)).foregroundColor(isActive ? .green : .secondary)
        }
    }
}

/// iPad（更圆润的边框 + 屏幕内容）
struct IPadIcon: View {
    let isConnected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black)
                .frame(width: 50, height: 66)
            RoundedRectangle(cornerRadius: 4)
                .fill(screenBackground)
                .frame(width: 45, height: 60)
                .overlay {
                    if isConnected {
                        Image(systemName: "applelogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 20)
                            .foregroundColor(.white.opacity(0.95))
                    } else {
                        // 未连接：屏幕中间显示彩色 "iPad" 文字
                        Text("iPad")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(colors: [Color.cyan, Color.blue, Color.purple],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                    }
                }
        }
    }

    var screenBackground: some ShapeStyle {
        if isConnected {
            return AnyShapeStyle(Color.black)
        } else {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.cyan.opacity(0.4), Color.blue.opacity(0.6)],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        // 关键：不用 .behindWindow（实时采样窗口背后内容做模糊，两窗口叠加时极卡），
        // 改 .withinWindow 只模糊自身内容，性能高一个量级，观感几乎不变。
        let v = NSVisualEffectView(); v.material = .popover; v.state = .active; v.blendingMode = .withinWindow; return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// ── 固定宽度 NSPopUpButton 包装 ──
struct FixedWidthPicker: NSViewRepresentable {
    let options: [String]
    @Binding var selection: String

    func makeNSView(context: Context) -> NSPopUpButton {
        let btn = NSPopUpButton()
        // 关键：自动填充 SwiftUI 分配的 frame（在调用处用 .frame 控制大小）
        btn.autoresizingMask = [.width, .height]
        btn.font = NSFont.systemFont(ofSize: 12)
        btn.alignment = .center   // 文字居中
        btn.addItems(withTitles: options)
        btn.selectItem(withTitle: selection)
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.changed(_:))
        return btn
    }
    func updateNSView(_ btn: NSPopUpButton, context: Context) {
        btn.font = NSFont.systemFont(ofSize: 12)
        let current = btn.itemTitles
        if current != options {
            btn.removeAllItems()
            btn.addItems(withTitles: options)
        }
        btn.selectItem(withTitle: selection)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject {
        let parent: FixedWidthPicker
        init(_ parent: FixedWidthPicker) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            if let title = sender.titleOfSelectedItem { parent.selection = title }
        }
    }
}

// ══════════════════════════════════════════════════════════════════════
//  SystemSettingsAgent —— 系统设置「静默搬运 + UI 自动化」
//
//  静默原理（实测：旧方案窗口在屏上停留 1.9 秒，肉眼明显）：
//    1. 用 `open -g` 打开，不激活、不抢焦点
//    2. 以 2ms 间隔轮询窗口，窗口一被创建就立刻把 position 设成屏外坐标
//       —— 原生 AX 调用只要 0.1~1ms，所以窗口在屏上的时间 ≈ 0（肉眼不可见）
//    3. 全程不把窗口挪回屏内（旧版失败回退时会挪到 200,200，那是"弹一下"的元凶）
//    4. 收尾还原窗口原始位置，绝不让用户自己打开系统设置时找不到窗口
// ══════════════════════════════════════════════════════════════════════
final class SystemSettingsAgent {
    static let shared = SystemSettingsAgent()

    private let bundleID = "com.apple.systempreferences"
    private let offscreen = CGPoint(x: -4000, y: 120)

    /// 调试用：只定位不真正点击（DRY 演练）
    var dryRun = false

    private var origPosition: CGPoint?
    private var recordedOrigin = false
    private var didPin = false
    private var wasRunningBefore = false
    private let lock = NSLock()

    /// 屏幕左上角为原点的全局坐标（AX 与 CGWindow 一致）
    var pid: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }

    func appElement() -> AXUIElement? {
        guard let p = pid else { return nil }
        return AXUIElementCreateApplication(p)
    }

    func window() -> AXUIElement? {
        guard let app = appElement() else { return nil }
        let wins = AX.els(app, kAXWindowsAttribute as String)
        // 取面积最大的那个（排除浮层/提示条）
        return wins.max(by: { a, b in
            let sa = AX.size(a) ?? .zero, sb = AX.size(b) ?? .zero
            return sa.width * sa.height < sb.width * sb.height
        })
    }

    // ── 打开显示器设置页（后台、不激活、不抢焦点）──
    func openDisplaysPane() {
        wasRunningBefore = (pid != nil)
        let p = Process()
        p.launchPath = "/usr/bin/open"
        p.arguments = ["-g", "x-apple.systempreferences:com.apple.preference.displays"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // ── 抢占式把窗口钉到屏外：2ms 轮询，出现即搬走 ──
    /// 返回窗口出现的耗时（秒）；nil 表示超时没等到窗口
    @discardableResult
    func pinOffscreen(maxSeconds: Double = 4.0, holdSeconds: Double = 0.35) -> Double? {
        let t0 = Date()
        let deadline = t0.addingTimeInterval(maxSeconds)
        var holdUntil: Date?
        while Date() < deadline {
            if let w = window(), let p = AX.pos(w), let s = AX.size(w), s.width > 80, s.height > 80 {
                if holdUntil == nil {
                    if !recordedOrigin { origPosition = p; recordedOrigin = true }
                    AX.setPos(w, offscreen)
                    didPin = true
                    holdUntil = Date().addingTimeInterval(holdSeconds)
                } else if p.x > -1000 {   // 中途被系统挪回来了，再钉一次
                    AX.setPos(w, offscreen)
                } else if Date() >= holdUntil! {
                    return Date().timeIntervalSince(t0)
                }
            }
            usleep(2000)
        }
        return didPin ? Date().timeIntervalSince(t0) : nil
    }

    /// 还原窗口原始位置（x < -500 说明历史数据被污染过，回到常规位置）
    func restorePosition() {
        lock.lock(); let orig = origPosition; let pinned = didPin; lock.unlock()
        guard pinned, let w = window() else { return }
        var target = orig ?? CGPoint(x: 609, y: 368)
        if target.x < -500 || target.y < 0 { target = CGPoint(x: 150, y: 150) }
        AX.setPos(w, target)
    }

    /// 结束系统设置进程（比 quit 快，且不会留下屏外残留窗口）
    func killSystemSettings() {
        guard !wasRunningBefore else { return }   // 用户自己开着的就别关
        let p = Process()
        p.launchPath = "/usr/bin/killall"
        p.arguments = ["System Settings"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }

    /// 收尾：直接结束进程，绝不把窗口挪回屏内（挪回会造成末尾闪烁）
    /// 只有「用户自己本来就开着系统设置」时才把窗口放回原位，不碰用户的东西
    func cleanup() {
        if wasRunningBefore {
            restorePosition()          // 用户开着的：放回原位
        } else {
            killSystemSettings()       // 我们后台开的：直接杀，窗口在屏外消失，无闪烁
        }
    }

    // ── 菜单自动化 ──
    private func pressEscape() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: down) { e.post(tap: .cghidEventTap) }
        }
        usleep(80_000)
    }

    private func collectMenuButtons(_ root: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func walk(_ el: AXUIElement, _ d: Int) {
            guard d <= 14, out.count < 60 else { return }
            let r = AX.role(el)
            if r == "AXMenuButton" || r == "AXPopUpButton" { out.append(el) }
            for c in AX.children(el) { walk(c, d + 1) }
        }
        walk(root, 0)
        return out
    }

    private func menuItems(_ btn: AXUIElement) -> [AXUIElement] {
        var items: [AXUIElement] = []
        func dig(_ el: AXUIElement, _ d: Int) {
            guard d <= 4 else { return }
            for c in AX.children(el) {
                let r = AX.role(c)
                if r == "AXMenuItem" { items.append(c) }
                else if r == "AXMenu" { dig(c, d + 1) }
            }
        }
        dig(btn, 0)
        return items
    }

    /// 展开菜单后读取菜单项（菜单要几十毫秒才填充完，做短轮询）
    private func readItemsAfterPress(_ btn: AXUIElement) -> [AXUIElement] {
        for _ in 0..<6 {
            let items = menuItems(btn)
            if !items.isEmpty { return items }
            usleep(60_000)
        }
        return menuItems(btn)
    }

    /// 打开显示器页 → 钉到屏外 → 找到并点击「设备关键字」对应的菜单项
    /// 返回是否已发出连接指令
    func connect(deviceKeyword: String, timeout: Double = 5.0) -> Bool {
        openDisplaysPane()
        _ = pinOffscreen(maxSeconds: 3.0)
        let kw = deviceKeyword.lowercased()
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            guard let w = window() else { usleep(120_000); continue }
            for btn in collectMenuButtons(w) {
                guard AX.press(btn) else { continue }
                for item in readItemsAfterPress(btn) {
                    let t = AX.title(item).lowercased()
                    guard t.contains(kw) else { continue }
                    if dryRun {
                        FileHandle.standardError.write("DRY 命中菜单项: [\(AX.title(item))] 所在按钮 desc=[\(AX.desc(btn))]\n".data(using: .utf8)!)
                        return true
                    }
                    guard AX.press(item) else { break }
                    // 极少数系统里该设备项是子菜单，还要再选一次「扩展/镜像」
                    usleep(160_000)
                    for sub in menuItems(btn) {
                        let st = AX.title(sub)
                        if st == "镜像" || st == "镜像整个屏幕" || st == "镜像显示器"
                            || st.contains("扩展显示器") || st.contains("用作扩展") || st == "Separate" || st == "Mirror" {
                            AX.press(sub); break
                        }
                    }
                    return true
                }
                pressEscape()
            }
            usleep(200_000)
        } while Date() < deadline

        return false
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var startSilently = false   // --login（登录自启）时静默，不弹窗
    let frameKey = "mainWindowFrame"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // 注册默认值（@AppStorage 共用同一份 UserDefaults）
        UserDefaults.standard.register(defaults: [
            UserDefaults.Key.sidecarMode: "auto",
            UserDefaults.Key.keepBDWarm: false,
            UserDefaults.Key.sleepAutoStop: true,
            UserDefaults.Key.sleepAutoStopMinutes: 30,
            UserDefaults.Key.loginAtLaunch: true,
            UserDefaults.Key.webUIBrowser: "default",
            UserDefaults.Key.openDisplayAutoStop: true,
            UserDefaults.Key.openDisplayAutoReconnect: true,
            UserDefaults.Key.openDisplayAutoStopMinutes: 0,
            UserDefaults.Key.virtualDisplayName: "display"
        ])

        let loginAtLaunch = UserDefaults.standard.bool(forKey: UserDefaults.Key.loginAtLaunch)

        // 自愈：登录自启实例但开关已关 → 清理 LaunchAgent 后直接退出
        if startSilently && !loginAtLaunch {
            LoginAgent.disable()
            NSApp.terminate(nil)
            return
        }

        // 让 LaunchAgent 状态与开关保持一致（开→写文件，关→删文件）
        if loginAtLaunch { LoginAgent.enable() } else { LoginAgent.disable() }

        // 启动休眠监听：休眠超时（10/20/30 分钟）唤醒后自动断开串流副屏
        SleepWatcher.shared.start()

        // 静默启动（登录自启）不弹窗口；用户点 Dock 图标再显示
        if !startSilently {
            showMainWindow()
        }
        // --settings：启动时直接打开设置窗口（调试 / 快速入口）
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                SettingsWindowManager.open(onDismiss: {})
            }
        }
    }

    // 显示（或首次创建）主窗口
    func showMainWindow() {
        if window == nil {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "DisplayBridge"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(width: 470, height: 420)   // 可缩放最小尺寸（三列布局需要更宽）
            window.maxSize = NSSize(width: 600, height: 640)   // 可缩放最大尺寸
            restoreWindowFrame(window, key: frameKey)
            window.center()  // 无记忆时居中
            // 三列布局需更宽；旧版本记忆的窄窗口（335 宽）会被撑到 500，否则第三列挤不下
            if window.frame.width < 470 {
                var f = window.frame; f.size.width = 500
                window.setFrame(f, display: false)
            }
            window.contentView = NSHostingView(rootView: ContentView())
            window.isReleasedWhenClosed = false
            // 记住窗口大小和位置：缩放/移动时保存
            NotificationCenter.default.addObserver(self, selector: #selector(saveWindowFrame), name: NSWindow.didResizeNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(saveWindowFrame), name: NSWindow.didMoveNotification, object: window)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
        // 窗口每次显示（含关闭后唤回的复用场景）都广播一次，让 UI 重新检测真实状态。
        // 否则自动断开发生在窗口隐藏期间时，bridgeState 会停留在旧状态（如"已连接/连接中"）。
        NotificationCenter.default.post(name: .windowDidShow, object: nil)
    }

    // 从 UserDefaults 恢复窗口 frame（校验屏幕可见性）
    func restoreWindowFrame(_ w: NSWindow, key: String) {
        guard let saved = UserDefaults.standard.string(forKey: key) else { return }
        let rect = NSRectFromString(saved)
        guard !rect.isEmpty, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) else { return }
        w.setFrame(rect, display: true)
    }

    @objc func saveWindowFrame() {
        guard let w = window, !w.frame.isEmpty else { return }
        UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: frameKey)
    }

    // 点 Dock 图标：重新显示主窗口（关闭窗口后 app 仍在后台，靠这个唤回）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // 关键：关闭窗口只隐藏、不退出，热键 + 休眠断开持续有效
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// ── 调试探针：导出「系统设置 → 显示器」的 AX 结构（仅设置 DB_AX_PROBE 时运行）──
func runAXProbe() {
    var out = ""
    func log(_ s: String) {
        out += s + "\n"
        if let d = s.data(using: .utf8) { FileHandle.standardError.write(d); FileHandle.standardError.write("\n".data(using: .utf8)!) }
    }
    log("AXIsProcessTrusted = \(AXIsProcessTrusted())")
    let agent = SystemSettingsAgent.shared

    let k = Process(); k.launchPath = "/usr/bin/killall"; k.arguments = ["System Settings"]
    k.standardOutput = FileHandle.nullDevice; k.standardError = FileHandle.nullDevice
    try? k.run(); k.waitUntilExit()
    usleep(500_000)

    agent.openDisplaysPane()
    if let t = agent.pinOffscreen() {
        log(String(format: "窗口出现并被钉到屏外，耗时 %.3f 秒", t))
    } else {
        log("超时：没等到窗口")
        try? out.write(toFile: "/tmp/db_ax.txt", atomically: true, encoding: .utf8); agent.cleanup(); exit(0)
    }
    guard let win = agent.window() else {
        log("窗口不可用")
        try? out.write(toFile: "/tmp/db_ax.txt", atomically: true, encoding: .utf8); agent.cleanup(); exit(0)
    }
    let wp = AX.pos(win) ?? .zero, ws = AX.size(win) ?? .zero
    log(String(format: "窗口 pos=(%.0f,%.0f) size=%.0fx%.0f", wp.x, wp.y, ws.width, ws.height))

    var menuButtons: [AXUIElement] = []
    var count = 0
    func walk(_ el: AXUIElement, _ depth: Int, _ path: String) {
        guard depth <= 12, count < 6000 else { return }
        count += 1
        let r = AX.role(el), ti = AX.title(el), de = AX.desc(el), va = AX.value(el)
        if r.contains("Button") || !ti.isEmpty || !de.isEmpty || !va.isEmpty {
            log(String(repeating: " ", count: depth * 2) + "\(path) role=\(r) title=[\(ti)] desc=[\(de)] value=[\(va)]")
        }
        if r == "AXMenuButton" || r == "AXPopUpButton" { menuButtons.append(el) }
        for (i, c) in AX.children(el).enumerated() { walk(c, depth + 1, "\(path).\(i)") }
    }
    walk(win, 0, "w")
    log("=== 共遍历 \(count) 个元素，菜单按钮 \(menuButtons.count) 个 ===")
    for (i, b) in menuButtons.enumerated() {
        let kids = AX.children(b)
        log("[btn\(i)] title=[\(AX.title(b))] desc=[\(AX.desc(b))] pos=\(AX.pos(b) ?? .zero) 直接子元素=\(kids.count) roles=\(kids.map { AX.role($0) })")
        for kid in kids {
            let sub = AX.children(kid)
            log("     └ \(AX.role(kid)) children=\(sub.count)")
            for s in sub { log("          · \(AX.role(s)) title=[\(AX.title(s))]") }
        }
    }

    // ── 逐个按下，看菜单里到底有什么 ──
    func esc() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: down) { e.post(tap: .cghidEventTap) }
        }
        usleep(120_000)
    }
    log("")
    log("=== 按下各个菜单按钮，导出菜单项 ===")
    func dumpMenu(_ el: AXUIElement, _ tag: String) {
        guard AX.press(el) else { log("\(tag) 按下失败"); return }
        usleep(260_000)
        let kids = AX.children(el)
        log("\(tag) desc=[\(AX.desc(el))] value=[\(AX.value(el))] 子元素=\(kids.count)")
        for kid in kids {
            let items = AX.children(kid)
            log("   └ \(AX.role(kid)) 项数=\(items.count)")
            for (i, s) in items.enumerated() { log("       \(i). [\(AX.title(s))] role=\(AX.role(s))") }
        }
        esc()
    }
    for (i, b) in menuButtons.enumerated() { dumpMenu(b, "menuBtn\(i)") }
    // 用途 弹窗
    var popups: [AXUIElement] = []
    func collectPopup(_ el: AXUIElement, _ d: Int) {
        guard d <= 12 else { return }
        if AX.role(el) == "AXPopUpButton" { popups.append(el) }
        for c in AX.children(el) { collectPopup(c, d + 1) }
    }
    collectPopup(win, 0)
    for (i, p) in popups.enumerated() { dumpMenu(p, "popUp\(i)(当前值=\(AX.value(p)))") }
    try? out.write(toFile: "/tmp/db_ax.txt", atomically: true, encoding: .utf8)
    agent.cleanup()
    exit(0)
}

if ProcessInfo.processInfo.environment["DB_AX_PROBE"] != nil { runAXProbe() }
if ProcessInfo.processInfo.environment["DB_AX_DRY"] != nil {
    SystemSettingsAgent.shared.dryRun = true
    let t0 = Date()
    let ok = SystemSettingsAgent.shared.connect(deviceKeyword: "iPad")
    let el = Date().timeIntervalSince(t0)
    FileHandle.standardError.write("DRY 结果: \(ok ? "命中" : "未命中")，总耗时 \(String(format: "%.2f", el)) 秒\n".data(using: .utf8)!)
    SystemSettingsAgent.shared.cleanup()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
delegate.startSilently = CommandLine.arguments.contains("--login")   // 登录自启：静默后台，不弹窗
app.delegate = delegate
app.run()