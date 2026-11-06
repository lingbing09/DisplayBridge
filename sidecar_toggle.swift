#!/usr/bin/env swift
// sidecar_toggle.swift — 用 NSScreen 判断连接状态 + SidecarCore 连接/断开
// 修复：之前用 connectedDevices 判断不准确，改用 NSScreen 检测 Sidecar Display

import Foundation
import AppKit

// 参数解析：--device 指定设备名
let args = CommandLine.arguments
let deviceOverride: String? = {
    if let idx = args.firstIndex(of: "--device"), idx + 1 < args.count { return args[idx + 1] }
    return nil
}()

// ── 判断是否已连接 Sidecar（通过 NSScreen 检测） ──
func isSidecarConnected() -> Bool {
    for screen in NSScreen.screens {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
        if CGDisplayIsBuiltin(num.uint32Value) != 0 { continue }
        let name = screen.localizedName
        // Sidecar 屏幕名称通常包含 "Sidecar" 或 "AirPlay"
        if name.contains("Sidecar") || name.contains("AirPlay") {
            return true
        }
    }
    return false
}

// 加载 SidecarCore 框架
guard let _ = dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY) else {
    fputs("ERROR: 无法加载 SidecarCore 框架\n", stderr); exit(1)
}
guard let managerClass = NSClassFromString("SidecarDisplayManager") as? NSObject.Type,
      let manager = managerClass.perform(Selector(("sharedManager")))?.takeUnretainedValue() else {
    fputs("ERROR: 无法初始化 SidecarDisplayManager\n", stderr); exit(1)
}
guard let devices = manager.perform(Selector(("devices")))?.takeUnretainedValue() as? [AnyObject], !devices.isEmpty else {
    fputs("ERROR: 未发现任何 Sidecar 设备\n", stderr); exit(1)
}

// 找到目标设备
let ipad: AnyObject? = {
    if let override = deviceOverride {
        return devices.first(where: { ($0.perform(Selector(("name")))?.takeUnretainedValue() as? String) == override })
    }
    return devices.first(where: {
        let name = ($0.perform(Selector(("name")))?.takeUnretainedValue() as? String ?? "").lowercased()
        let model = ($0.perform(Selector(("model")))?.takeUnretainedValue() as? String ?? "").lowercased()
        return name.contains("ipad") || model.contains("ipad")
    })
}()

guard let ipad else { fputs("ERROR: 未找到目标设备\n", stderr); exit(1) }
let ipadName = ipad.perform(Selector(("name")))?.takeUnretainedValue() as? String ?? "iPad"

let alreadyConnected = isSidecarConnected()

let sema = DispatchSemaphore(value: 0)
let closure: AnyObject = {
    if #available(macOS 26, *) {
        return ({ sema.signal() } as @convention(block) () -> Void) as AnyObject
    } else {
        return ({ _, _ in sema.signal() } as @convention(block) (AnyObject?, AnyObject?) -> Void) as AnyObject
    }
}()

if alreadyConnected {
    print("正在断开 \(ipadName)...")
    let _ = manager.perform(Selector(("disconnectFromDevice:completion:")), with: ipad, with: closure)
    sema.wait()
    print("OK 已断开 \(ipadName)")
} else {
    print("正在连接 \(ipadName)...")
    let _ = manager.perform(Selector(("connectToDevice:completion:")), with: ipad, with: closure)
    sema.wait()
    print("OK 已连接 \(ipadName)")
}