#!/usr/bin/env swift
import CoreGraphics
import AppKit

/// 获取 BetterDisplay 虚拟屏幕的 CGDirectDisplayID
///
/// 用法：
///   get_virtual_display            使用默认名称 "display"
///   get_virtual_display "我的虚拟屏"   指定虚拟屏名称
///   VD_NAME="我的虚拟屏" get_virtual_display   通过环境变量指定
///
/// 匹配策略：非内置屏 且 NSScreen.localizedName == 目标名称
/// 退出码：0=成功, 1=获取显示器列表失败, 2=未找到目标虚拟屏

let args = CommandLine.arguments
let envName = ProcessInfo.processInfo.environment["VD_NAME"]
let targetName: String = {
    if args.count > 1, !args[1].isEmpty { return args[1] }
    if let e = envName, !e.isEmpty { return e }
    return "display"
}()

// 建立 NSScreen Number → 名称的映射
var screenNameMap: [UInt32: String] = [:]
for screen in NSScreen.screens {
    if let screenNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
        let name = screen.localizedName
        screenNameMap[screenNum.uint32Value] = name
    }
}

var displayCount: UInt32 = 0
let maxDisplays: UInt32 = 32
var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))

let err = CGGetOnlineDisplayList(maxDisplays, &displayIDs, &displayCount)
guard err == .success, displayCount > 0 else {
    fputs("ERROR: 无法获取显示器列表\n", stderr)
    exit(1)
}

for i in 0..<Int(displayCount) {
    let did = displayIDs[i]
    let isBuiltin = CGDisplayIsBuiltin(did) != 0
    if isBuiltin { continue }

    let displayName = screenNameMap[did] ?? "unknown"
    fputs("DEBUG: CGDirectDisplayID=\(did) | 名称=\"\(displayName)\" | 内置=\(isBuiltin)\n", stderr)

    guard displayName == targetName else {
        fputs("DEBUG: 跳过 (名称不匹配: \"\(displayName)\" ≠ \"\(targetName)\")\n", stderr)
        continue
    }

    let serial = CGDisplaySerialNumber(did)
    let vendor = CGDisplayVendorNumber(did)
    let model = CGDisplayModelNumber(did)

    if let mode = CGDisplayCopyDisplayMode(did) {
        let w = mode.width
        let h = mode.height
        let pixelW = CGDisplayPixelsWide(did)
        let pixelH = CGDisplayPixelsHigh(did)

        fputs("INFO: ✓ 找到虚拟屏 \"\(targetName)\"", stderr)
        fputs(" → CGDirectDisplayID=\(did)", stderr)
        fputs(" | 分辨率=\(w)x\(h) (像素=\(pixelW)x\(pixelH))", stderr)
        fputs(" | Serial=\(serial) Vendor=\(vendor) Model=\(model)\n", stderr)

        print(did)
        exit(0)
    }
}

fputs("ERROR: 未检测到名称为 \"\(targetName)\" 的虚拟屏\n", stderr)
fputs("当前所有非内置屏幕（可在 DisplayBridge 设置里把虚拟屏名称改成其中之一）：\n", stderr)
for (id, name) in screenNameMap {
    let isB = CGDisplayIsBuiltin(id) != 0
    if !isB {
        fputs("  CGDirectDisplayID=\(id) → \"\(name)\"\n", stderr)
    }
}
exit(2)
