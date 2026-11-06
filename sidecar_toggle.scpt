#!/usr/bin/osascript
(*
 Sidecar 一键切换脚本
 用法: osascript sidecar_toggle.scpt
 自动检测 iPad，已连接则断开，未连接则连接
*)

-- 检测当前是否已连接 Sidecar
on detectSidecarConnected()
	try
		set screenNames to do shell script "python3 -c \"import Quartz; [print(Quartz.CGDisplayIsBuiltin(did)) for did in Quartz.CGGetOnlineDisplayList(32, None, None)[1]]\" 2>/dev/null; swift -e 'import AppKit; for s in NSScreen.screens { print(s.localizedName) }' 2>/dev/null"
	on error
		set screenNames to ""
	end try
	return (screenNames contains "iPad") or (screenNames contains "随航") or (screenNames contains "Sidecar")
end detectSidecarConnected

-- 方法1：通过控制中心 → 屏幕镜像连接 iPad
on connectViaControlCenter()
	tell application "System Events"
		if not (exists process "ControlCenter") then
			error "ControlCenter not running"
		end if
		tell process "ControlCenter"
			-- 点击控制中心图标
			try
				click menu bar item "Control Center" of menu bar 1
			on error
				-- 尝试中文名称
				click menu bar item "控制中心" of menu bar 1
			end try
			delay 1.5
			
			-- 点击"屏幕镜像"（中英文）
			set mirrorNames to {"Screen Mirroring", "屏幕镜像"}
			set foundMirror to false
			repeat with mn in mirrorNames
				try
					if exists checkbox mn of window "Control Center" then
						click checkbox mn of window "Control Center"
						set foundMirror to true
						exit repeat
					end if
				end try
			end repeat
			
			if not foundMirror then
				-- 关闭控制中心
				key code 53
				return "not_found"
			end if
			
			delay 1.5
			
			-- 查找 iPad 并连接
			set checkboxList to every checkbox of window "Control Center"
			repeat with cb in checkboxList
				try
					set cbTitle to title of cb
					-- 匹配 iPad 名称（包含 "iPad" 的设备）
					if cbTitle contains "iPad" or title of cb contains "随航" then
						click cb
						-- 关闭控制中心
						delay 0.5
						key code 53
						delay 0.3
						key code 53
						return "connected"
					end if
				end try
			end repeat
			
			-- 没找到 iPad，关闭控制中心
			key code 53
			return "no_ipad"
		end tell
	end tell
end connectViaControlCenter

-- 方法2：断开 Sidecar（通过控制中心）
on disconnectViaControlCenter()
	tell application "System Events"
		tell process "ControlCenter"
			try
				click menu bar item "Control Center" of menu bar 1
			on error
				click menu bar item "控制中心" of menu bar 1
			end try
			delay 1.5
			
			set mirrorNames to {"Screen Mirroring", "屏幕镜像"}
			repeat with mn in mirrorNames
				try
					if exists checkbox mn of window "Control Center" then
						click checkbox mn of window "Control Center"
						exit repeat
					end if
				end try
			end repeat
			delay 1.5
			
			-- 查找并点击断开按钮
			set cbList to every checkbox of window "Control Center"
			repeat with cb in cbList
				try
					set cbTitle to title of cb
					if cbTitle contains "Disconnect" or cbTitle contains "断开" then
						click cb
						delay 0.5
						key code 53
						return "disconnected"
					end if
				end try
			end repeat
			
			key code 53
			return "no_disconnect"
		end tell
	end tell
end disconnectViaControlCenter

-- 方法3：通过系统设置连接（兜底方案）
on connectViaSettings()
	tell application "System Settings"
		activate
	end tell
	delay 1
	
	tell application "System Events"
		tell process "System Settings"
			-- 点击左侧"显示器"
			try
				click button "Displays" of group 1 of window 1
			on error
				try
					click button "显示器" of group 1 of window 1
				end try
			end try
			delay 1.5
			
			-- 点击右侧的 "+" 添加显示器按钮
			try
				tell group 1 of group 2 of splitter group 1 of group 1 of window 1
					if exists pop up button 1 then
						click pop up button 1
						delay 1
						-- 在弹出菜单中找到 iPad
						repeat with mi in (menu items of menu 1 of pop up button 1)
							if (name of mi contains "iPad") then
								click mi
								return "connected_via_settings"
							end if
						end repeat
					end if
				end tell
			end try
		end tell
	end tell
	return "settings_failed"
end connectViaSettings

-- 主流程
on run
	set isConnected to detectSidecarConnected()
	
	if isConnected then
		-- 已连接 → 断开
		set result to disconnectViaControlCenter()
		if result is "disconnected" then
			return "已断开随航连接"
		end if
		-- 如果控制中心断开失败，用设置断开
		tell application "System Settings" to activate
		return "请手动断开随航"
	else
		-- 未连接 → 连接
		set result to connectViaControlCenter()
		if result is "connected" then
			return "已连接随航"
		end if
		if result is "not_found" then
			-- 控制中心没找到屏幕镜像，用设置
			set result to connectViaSettings()
			if result is "connected_via_settings" then
				return "已通过系统设置连接随航"
			end if
		end if
		if result is "no_ipad" then
			return "未找到 iPad，请确认 iPad 已解锁并在附近"
		end if
		-- 兜底：打开系统设置
		tell application "System Settings" to activate
		return "已打开系统设置，请在显示器中连接 iPad"
	end if
end run