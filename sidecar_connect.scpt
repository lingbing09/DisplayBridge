#!/usr/bin/osascript
(*
 Sidecar 一键连接 — macOS 26 (Tahoe) 版
 通过 系统设置 → 显示器 → "+" 添加 iPad
*)

-- 先检测是否已连接
on isSidecarConnected()
	try
		set screenOutput to do shell script "python3 -c \"
import AppKit
for s in AppKit.NSScreen.screens:
    n = s.localizedName
    if n and n != 'Built-in Retina Display' and n != 'display':
        print(n)
\" 2>/dev/null"
	on error
		return false
	end try
	if screenOutput is "" then return false
	return screenOutput contains "iPad"
end isSidecarConnected

on run
	set connected to isSidecarConnected()
	
	tell application "System Settings"
		activate
	end tell
	delay 0.8
	
	tell application "System Events"
		tell process "System Settings"
			-- 点左侧"显示器"
			set displayNames to {"显示器", "Displays"}
			set found to false
			repeat with dn in displayNames
				try
					-- 尝试找左侧列表中的 "显示器" 按钮
					set btn to button dn of group 1 of window 1
					click btn
					set found to true
					exit repeat
				on error
					-- 尝试嵌套结构
					try
						click button dn of group 1 of scroll area 1 of group 1 of window 1
						set found to true
						exit repeat
					on error
						-- 尝试更深的嵌套
						try
							click button dn of group 1 of group 1 of window 1
							set found to true
							exit repeat
						end try
					end try
				end try
			end repeat
			
			if not found then
				error "无法找到「显示器」设置项"
			end if
			
			delay 1.5
			
			if connected then
				-- 已连接 → 断开
				try
					-- 点击右侧代表 iPad 的显示器配置按钮并断开
					tell group 1 of group 2 of splitter group 1 of group 1 of window 1
						-- 找 "断开连接" 或 "Disconnect" 按钮
						repeat with b in buttons
							try
								set bName to name of b
								if bName contains "断开" or bName contains "Disconnect" then
									click b
									return "已断开随航"
								end if
							end try
						end repeat
					end tell
					return "未找到断开按钮，已打开设置页面"
				end try
			else
				-- 未连接 → 连接
				try
					tell group 1 of group 2 of splitter group 1 of group 1 of window 1
						-- 点击弹出按钮（"+" 或 "添加"）
						set popNames to {"添加显示器", "添加", "Add Display", "Add"}
						set popBtn to missing value
						repeat with pn in popNames
							try
								set popBtn to pop up button pn
								exit repeat
							on error
								try
									set popBtn to pop up button 1
									exit repeat
								end try
							end try
						end repeat
						
						if popBtn is not missing value then
							click popBtn
							delay 1
							-- 在弹出菜单中找 iPad
							repeat with mi in (menu items of menu 1 of popBtn)
								try
									if name of mi contains "iPad" then
										click mi
										return "已连接随航 → iPad"
									end if
								end try
							end repeat
							key code 53
							return "未在列表中找到 iPad，请确认 iPad 已解锁且在附近"
						end if
					end tell
				on error errMsg
					return "操作失败: " & errMsg
				end try
			end if
		end tell
	end tell
end run