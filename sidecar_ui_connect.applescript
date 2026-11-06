-- ==========================================
-- sidecar_ui_connect.applescript  (v2 静默加速版)
-- 通过「系统设置 → 显示器」UI 自动化连接 iPad 随航
--
-- v2 相比 v1 的改动（全部经实测验证）：
--   1) `open -g` 后台打开系统设置 —— 不激活、不抢焦点，窗口不跳到面前
--   2) 窗口一出现立刻移到屏幕外坐标（-4000）—— 实测移出后 UI 仍可完整操作，
--      菜单项照样能枚举和点击，所以用户全程看不到任何窗口
--   3) 所有固定 delay（1.2s / 0.6s / 0.4s）改成 0.15s 密集轮询，就绪即走
--   4) 收尾直接 `killall` 结束系统设置进程 —— 无关闭动画、无残留窗口
--      （注意：不要用「隐藏 app」的方式，实测隐藏后菜单项读不出来）
--   5) 兜底：静默模式失败时把窗口挪回屏内重试一次，保证功能不退化
--
-- 调用：osascript sidecar_ui_connect.applescript ["设备名关键字"]
-- 退出码：0 = 已点击连接，非 0 = 失败
-- ==========================================

property MAX_SEARCH_DEPTH : 8
property POLL : 0.15

on run argv
	set deviceKeyword to "iPad"
	if (count of argv) > 0 then
		set deviceKeyword to item 1 of argv
		if deviceKeyword is "" then set deviceKeyword to "iPad"
	end if

	set ok to false

	try
		-- 1. 后台打开显示器设置页（-g：不把「系统设置」带到前台，不抢焦点）
		do shell script "open -g 'x-apple.systempreferences:com.apple.preference.displays' >/dev/null 2>&1 || true"

		-- 2. 轮询等窗口出现（出现即继续，不再盲等）
		if not my waitForWindow("System Settings", 4) then
			-- 兜底：允许激活的方式再开一次，确保窗口一定出现（功能优先）
			do shell script "open 'x-apple.systempreferences:com.apple.preference.displays' >/dev/null 2>&1 || true"
			if not my waitForWindow("System Settings", 4) then error "无法打开系统设置"
		end if

		-- 3. 窗口一出现立刻移出可视区域，用户全程看不到
		try
			tell application "System Events" to tell process "System Settings" to set position of window 1 to {-4000, 200}
		end try

		-- 4. 连接（静默模式）
		set ok to my connectOnce(deviceKeyword)

		-- 5. 兜底：静默模式没成功，把窗口挪回屏内用可视模式再试一次
		if not ok then
			log "sidecar_ui_connect: 静默模式未成功，改用可视模式重试"
			try
				tell application "System Events" to tell process "System Settings" to set position of window 1 to {200, 200}
			end try
			delay 0.3
			set ok to my connectOnce(deviceKeyword)
		end if

	on error errMsg
		-- 静默失败：不发声、不改音量，只记录日志
		log "sidecar_ui_connect 失败: " & errMsg
	end try

	-- 收尾：直接结束系统设置进程（不做位置还原——挪回屏内会造成闪烁）
	do shell script "killall 'System Settings' >/dev/null 2>&1 || true"

	if ok then
		return "OK"
	else
		error "FAILED"
	end if
end run

-- ==========================================
-- 工具函数库
-- ==========================================

-- 单次尝试：找下拉按钮 → 点开 → 选中目标设备
-- 提速核心：先用「快速查找」（只认 menu button / pop up button，不做 exists menu 1 检查）
-- 实测 `exists menu 1 of button` 对每个普通按钮都是一次会超时的 AX 查询，
-- 是原来单次查找耗时 4.1 秒的罪魁祸首；目标按钮 role 本来就是 AXMenuButton。
-- 快速查找失败时才退回「完整查找」（含 menu 检查），保证兼容性。
on connectOnce(deviceKeyword)
	try
		if my firstWindow() is missing value then return false

		-- 1) 立即快速查找（UI 已渲染完时毫秒级命中）
		set btn to my findMenuButtonFast(my firstWindow(), 0)

		-- 2) 没找到：等 UI 渲染，再轮询快速查找
		if btn is missing value then
			delay 0.5
			repeat 16 times
				set btn to my findMenuButtonFast(my firstWindow(), 0)
				if btn is not missing value then exit repeat
				delay POLL
			end repeat
		end if

		-- 3) 仍没找到：完整查找兜底（兼容「普通按钮内嵌菜单」的旧系统）
		if btn is missing value then
			set btn to my findMenuButtonFull(my firstWindow(), 0)
		end if
		if btn is missing value then return false

		tell application "System Events" to tell process "System Settings" to click btn
		return my selectDeviceFromMenu(btn, deviceKeyword, 14)
	on error
		return false
	end try
end connectOnce

-- 快速查找：只认 menu button / pop up button
on findMenuButtonFast(theElement, currentDepth)
	if currentDepth > MAX_SEARCH_DEPTH then return missing value
	try
		tell application "System Events"
			set elClass to class of theElement
			if (elClass is menu button) or (elClass is pop up button) then return theElement
			set children to every UI element of theElement
			repeat with child in children
				set r to my findMenuButtonFast(child, currentDepth + 1)
				if r is not missing value then return r
			end repeat
		end tell
	end try
	return missing value
end findMenuButtonFast

-- 完整查找：兼容「普通按钮里内嵌菜单」的老系统写法
on findMenuButtonFull(theElement, currentDepth)
	if currentDepth > MAX_SEARCH_DEPTH then return missing value
	try
		tell application "System Events"
			set elClass to class of theElement
			if (elClass is menu button) or (elClass is pop up button) then return theElement
			if elClass is button then
				if exists menu 1 of theElement then return theElement
			end if
			set children to every UI element of theElement
			repeat with child in children
				set r to my findMenuButtonFull(child, currentDepth + 1)
				if r is not missing value then return r
			end repeat
		end tell
	end try
	return missing value
end findMenuButtonFull

on firstWindow()
	try
		tell application "System Events"
			tell process "System Settings"
				return window 1
			end tell
		end tell
	end try
	return missing value
end firstWindow

-- 等待进程窗口真正出现（不只是进程存在）
on waitForWindow(appName, maxSeconds)
	set steps to (maxSeconds / POLL) as integer
	repeat steps times
		try
			tell application "System Events"
				if exists (process appName) then
					if (count of windows of process appName) > 0 then return true
				end if
			end tell
		end try
		delay POLL
	end repeat
	return false
end waitForWindow

-- 递归查找具有菜单功能的按钮（适配不同系统版本）
on findAddButton(theElement, currentDepth)
	if currentDepth > MAX_SEARCH_DEPTH then return missing value
	try
		tell application "System Events"
			set elClass to class of theElement
			-- 弹出按钮 / 菜单按钮
			if (elClass is menu button) or (elClass is pop up button) then
				return theElement
			end if
			-- 普通按钮但内含菜单
			if elClass is button then
				if exists menu 1 of theElement then return theElement
			end if
			-- 递归子元素
			set children to every UI element of theElement
			repeat with child in children
				set resultBtn to my findAddButton(child, currentDepth + 1)
				if resultBtn is not missing value then return resultBtn
			end repeat
		end tell
	end try
	return missing value
end findAddButton

-- 轮询等待菜单项出现并点击设备（支持关键字模糊匹配）
-- 两轮匹配：优先「扩展/镜像/用作」这类真正出副屏的项，没有再退化为任意含关键字的项
on selectDeviceFromMenu(btn, keyword, maxSteps)
	repeat maxSteps times
		try
			tell application "System Events"
				set menuItems to name of menu items of menu 1 of btn
			end tell

			-- 第一轮：要能真正出副屏的项
			repeat with i from (count of menuItems) to 1 by -1
				set itemName to item i of menuItems
				if itemName is not missing value then
					if itemName contains keyword then
						if (itemName contains "扩展") or (itemName contains "镜像") or (itemName contains "用作") or (itemName contains "Separate") or (itemName contains "Mirror") then
							tell application "System Events" to tell process "System Settings" to click menu item i of menu 1 of btn
							return true
						end if
					end if
				end if
			end repeat

			-- 第二轮：退化匹配（任意含关键字的项）
			repeat with i from (count of menuItems) to 1 by -1
				set itemName to item i of menuItems
				if itemName is not missing value then
					if itemName contains keyword then
						tell application "System Events" to tell process "System Settings" to click menu item i of menu 1 of btn
						return true
					end if
				end if
			end repeat
		end try
		delay POLL
	end repeat
	return false
end selectDeviceFromMenu
