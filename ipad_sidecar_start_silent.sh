#!/bin/bash
# ============================================================
#  iPad 副屏一键启动（静默加速版 v3）
#  BetterDisplay 虚拟屏 → 检测 displayID → 同步 Sunshine 配置 → 启动 Sunshine
#  全程不打开浏览器、不发送键盘事件、不抢焦点
#
#  可配置项（环境变量，由 DisplayBridge 传入）：
#    VD_NAME          BetterDisplay 虚拟屏名称，默认 display
#    SUNSHINE_USER    Sunshine Web UI 账号，默认 1
#    SUNSHINE_PASS    Sunshine Web UI 密码，默认 1
#    BETTERDISPLAY_APP / SUNSHINE_APP  手动指定 app 路径（可选，默认自动查找）
#
#  输出协议（供 Swift 解析）：
#    [STEP] / [INFO] / [OK] / [WARN] / [ERROR] / [STATE] READY|CONNECTED|ERROR
# ============================================================

set -e
export LANG="${LANG:-en_US.UTF-8}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPLAY_TOOL="$SCRIPT_DIR/get_virtual_display"
SUNSHINE_CONF="${SUNSHINE_CONF:-$HOME/.config/sunshine/sunshine.conf}"
SUNSHINE_URL="https://localhost:47990/"

# 虚拟屏名称（BetterDisplay 默认虚拟屏就叫 display；用户改过名时由 App 传入）
VD_NAME="${VD_NAME:-display}"

# Sunshine Web UI 凭据（首次安装 Sunshine 时用户自设；默认 1:1）
SUNSHINE_USER="${SUNSHINE_USER:-1}"
SUNSHINE_PASS="${SUNSHINE_PASS:-1}"

VIRTUAL_DISPLAY_ID=""
CONFIG_CHANGED=0
POLL=0.2

log_info()  { echo "[INFO] $1"; }
log_ok()    { echo "[OK] $1"; }
log_warn()  { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1"; }
log_step()  { echo "[STEP] $1"; }

# ---- 查找已安装的 App（不写死 /Applications）----
# 优先用 LaunchServices 元数据（能找到任何位置已注册的 app），再退回常见目录
find_app() {
    local bundle_id="$1"
    local app_name="$2"
    local found=""

    if [ -n "$bundle_id" ]; then
        found=$(mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2>/dev/null | head -1)
        if [ -n "$found" ] && [ -d "$found" ]; then
            echo "$found"
            return 0
        fi
    fi

    local candidate
    for candidate in "/Applications/$app_name.app" \
                     "$HOME/Applications/$app_name.app" \
                     "/Applications/Utilities/$app_name.app" \
                     "/System/Applications/$app_name.app"; do
        if [ -d "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

BETTERDISPLAY_APP="${BETTERDISPLAY_APP:-$(find_app 'pro.betterdisplay.BetterDisplay' 'BetterDisplay' || true)}"
SUNSHINE_APP="${SUNSHINE_APP:-$(find_app 'dev.lizardbyte.app.Sunshine' 'Sunshine' || true)}"

# ---- 前置检查：缺依赖时给明确报错，而不是后续莫名失败 ----
require_dependencies() {
    local missing=0
    if [ -z "$BETTERDISPLAY_APP" ] || [ ! -d "$BETTERDISPLAY_APP" ]; then
        log_error "未检测到 BetterDisplay，请先安装（https://betterdisplay.pro）"
        missing=1
    fi
    if [ -z "$SUNSHINE_APP" ] || [ ! -d "$SUNSHINE_APP" ]; then
        log_error "未检测到 Sunshine，请先安装（https://app.lizardbyte.dev/Sunshine）"
        missing=1
    fi
    if [ ! -x "$DISPLAY_TOOL" ]; then
        log_error "缺少虚拟屏检测工具 get_virtual_display"
        missing=1
    fi
    if [ "$missing" = "1" ]; then
        echo "[STATE] ERROR"
        exit 1
    fi
}

# ---- 启动 BetterDisplay（-g：后台启动，不抢焦点、不弹到最前）----
launch_betterdisplay() {
    log_step "正在准备显示器服务"
    if pgrep -q BetterDisplay; then
        log_ok "BetterDisplay 已在运行"
        return 0
    fi
    log_info "正在启动 BetterDisplay"
    open -gj "$BETTERDISPLAY_APP" 2>/dev/null || true
    local w=0
    while [ $w -lt 30 ]; do
        pgrep -q BetterDisplay && { log_ok "BetterDisplay 就绪"; return 0; }
        sleep $POLL; w=$((w + 1))
    done
    log_warn "BetterDisplay 启动较慢，继续后续检测"
}

# ---- 确保虚拟屏已打开 ----
ensure_virtual_screen_open() {
    log_step "正在检查虚拟屏"
    local cli="$BETTERDISPLAY_APP/Contents/MacOS/BetterDisplay"

    # 已打开则直接返回（快路径）
    if "$DISPLAY_TOOL" "$VD_NAME" >/dev/null 2>&1; then
        log_ok "虚拟屏已处于打开状态"
        return 0
    fi

    log_step "正在唤起虚拟屏（首次较慢）"
    log_info "虚拟屏未打开，正在打开..."
    if [ -x "$cli" ]; then
        "$cli" set --name="$VD_NAME" --connected=on 2>/dev/null || true
    else
        log_warn "未找到 BetterDisplay 命令行工具，请在 BetterDisplay 中手动开启虚拟屏"
    fi

    local w=0
    while [ $w -lt 25 ]; do
        if "$DISPLAY_TOOL" "$VD_NAME" >/dev/null 2>&1; then
            log_ok "虚拟屏已打开"
            return 0
        fi
        sleep $POLL; w=$((w + 1))
    done
    log_warn "虚拟屏打开可能未生效，继续后续检测"
}

# ---- 检测虚拟屏并取出 CGDirectDisplayID ----
detect_virtual_display() {
    log_step "正在检测虚拟屏"
    local max_wait=10 waited=0
    while [ $waited -lt $((max_wait * 5)) ]; do
        local raw_output
        raw_output=$("$DISPLAY_TOOL" "$VD_NAME" 2>/dev/null) || true
        if [ -n "$raw_output" ]; then
            local candidate
            candidate=$(echo "$raw_output" | tail -1 | tr -d '[:space:]')
            if [[ "$candidate" =~ ^[0-9]+$ ]]; then
                VIRTUAL_DISPLAY_ID="$candidate"
                log_ok "CGDirectDisplayID = $VIRTUAL_DISPLAY_ID"
                return 0
            fi
        fi
        sleep $POLL; waited=$((waited + 1))
    done
    log_error "未检测到虚拟屏「$VD_NAME」。请在 BetterDisplay 中创建名为 $VD_NAME 的虚拟屏，或到 DisplayBridge 设置里改成你的虚拟屏名称"
    return 1
}

# ---- 同步 Sunshine 配置（output_name 指向当前虚拟屏）----
update_sunshine_config() {
    log_step "正在同步串流配置"

    if [ ! -f "$SUNSHINE_CONF" ]; then
        log_error "未找到 Sunshine 配置：$SUNSHINE_CONF（请先打开一次 Sunshine 完成初始化）"
        return 1
    fi

    local old_id
    old_id=$(grep "^output_name" "$SUNSHINE_CONF" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' ')

    if [ "$old_id" = "$VIRTUAL_DISPLAY_ID" ]; then
        log_ok "output_name 已是最新 ($VIRTUAL_DISPLAY_ID)"
        CONFIG_CHANGED=0
        return 0
    fi

    cp "$SUNSHINE_CONF" "$SUNSHINE_CONF.backup" 2>/dev/null || true
    awk -v new_id="$VIRTUAL_DISPLAY_ID" \
        '/^output_name/ {print "output_name = " new_id; next} {print}' \
        "$SUNSHINE_CONF" > "$SUNSHINE_CONF.tmp" && \
        mv "$SUNSHINE_CONF.tmp" "$SUNSHINE_CONF"
    log_ok "output_name: $old_id → $VIRTUAL_DISPLAY_ID"
    CONFIG_CHANGED=1
}

# ---- 启动 Sunshine ----
launch_sunshine() {
    log_step "正在启动串流服务"
    local sunshine_pid
    sunshine_pid=$(pgrep -x Sunshine 2>/dev/null || true)

    if [ -n "$sunshine_pid" ] && [ "$CONFIG_CHANGED" != "1" ]; then
        log_ok "串流服务已在运行"
        return 0
    fi

    if [ -n "$sunshine_pid" ]; then
        log_info "配置已变，重启串流服务..."
        kill "$sunshine_pid" 2>/dev/null || true
        local k=0
        while [ $k -lt 15 ]; do
            pgrep -x Sunshine >/dev/null 2>&1 || break
            sleep $POLL; k=$((k + 1))
        done
        pkill -9 -x Sunshine 2>/dev/null || true
    fi

    log_info "启动 Sunshine 进程"
    # 若用户自己配了 Sunshine 登录自启（KeepAlive），先确保它是加载状态。
    # 没配过就跳过 —— 不再依赖这个本机专属文件。
    local agent="$HOME/Library/LaunchAgents/com.sunshine.autostart.plist"
    if [ -f "$agent" ]; then
        launchctl bootstrap "gui/$(id -u)" "$agent" 2>/dev/null || true
    fi
    open -gj "$SUNSHINE_APP" 2>/dev/null || true

    local p_waited=0
    while [ $p_waited -lt 40 ]; do
        pgrep -x Sunshine >/dev/null 2>&1 && break
        sleep $POLL; p_waited=$((p_waited + 1))
    done

    if ! pgrep -x Sunshine >/dev/null 2>&1; then
        log_error "Sunshine 启动失败，请手动打开一次 Sunshine 确认能正常运行"
        return 1
    fi

    local ws_waited=0
    while [ $ws_waited -lt 40 ]; do
        if curl -sk --connect-timeout 1 "$SUNSHINE_URL" >/dev/null 2>&1; then
            log_ok "串流服务就绪"
            return 0
        fi
        sleep $POLL; ws_waited=$((ws_waited + 1))
    done
    log_warn "Web 服务响应慢"
}

# ---- 校验 Sunshine 串流就绪（纯 API，不打开浏览器）----
verify_streaming() {
    log_step "正在校验串流状态"
    local status
    status=$(curl -sk -u "$SUNSHINE_USER:$SUNSHINE_PASS" --connect-timeout 2 \
        "$SUNSHINE_URL" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
    if [ "$status" = "200" ]; then
        log_ok "Sunshine 串流已就绪"
        return 0
    fi
    log_warn "Sunshine 状态: HTTP $status（若为 401，请到设置里填写正确的 Web UI 账号密码）"
    return 1
}

# ---- 主流程 ----
main() {
    require_dependencies
    launch_betterdisplay
    ensure_virtual_screen_open

    if ! detect_virtual_display; then
        echo "[STATE] ERROR"
        exit 1
    fi

    update_sunshine_config || { echo "[STATE] ERROR"; exit 1; }

    if ! launch_sunshine; then
        echo "[STATE] ERROR"
        exit 1
    fi

    # 核心链路已通，立即上报 READY，界面秒切"已连接"
    echo "[STATE] READY"

    verify_streaming || true

    echo "[STATE] CONNECTED"
    echo "[DONE] 全部就绪，CGDirectDisplayID=$VIRTUAL_DISPLAY_ID"
}

main
