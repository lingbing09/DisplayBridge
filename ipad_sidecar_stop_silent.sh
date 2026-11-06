#!/bin/bash
# ============================================================
#  iPad 副屏一键关闭（v4）
#  停止 Sunshine → 关闭虚拟屏 → 按需退出 BetterDisplay
#
#  默认「一起退出」：关闭副屏时 Sunshine 和 BetterDisplay 都退出。
#  需要保留 BetterDisplay 常驻（下次连接更快）时传 --keep-bd 或 KEEP_BD=1。
#
#  可配置项（环境变量）：
#    VD_NAME           BetterDisplay 虚拟屏名称，默认 display
#    KEEP_BD=1         保留 BetterDisplay 常驻
#    BETTERDISPLAY_APP 手动指定 BetterDisplay 路径（可选）
# ============================================================

set -e
export LANG="${LANG:-en_US.UTF-8}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL=0.2

VD_NAME="${VD_NAME:-display}"

KEEP_BD="${KEEP_BD:-0}"
for a in "$@"; do
    [ "$a" = "--keep-bd" ] && KEEP_BD=1
done

log_info()  { echo "[INFO] $1"; }
log_ok()    { echo "[OK] $1"; }
log_step()  { echo "[STEP] $1"; }

# ---- 查找已安装的 App（不写死 /Applications）----
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
CLI="${BETTERDISPLAY_APP:+$BETTERDISPLAY_APP/Contents/MacOS/BetterDisplay}"

# ---- 停止 Sunshine ----
stop_sunshine() {
    log_step "正在停止串流服务"
    # 若用户配了 Sunshine 的 KeepAlive 自启，先 bootout，否则 pkill 后会被 launchd 立即拉起。
    # 没配过就跳过（不再依赖本机专属文件）。
    local agent="$HOME/Library/LaunchAgents/com.sunshine.autostart.plist"
    if [ -f "$agent" ]; then
        launchctl bootout "gui/$(id -u)/com.sunshine.autostart" 2>/dev/null || true
    fi
    if ! pgrep -x Sunshine >/dev/null 2>&1; then
        log_info "Sunshine 未运行"
        return 0
    fi
    pkill -x Sunshine 2>/dev/null || true
    local w=0
    while [ $w -lt 20 ]; do
        pgrep -x Sunshine >/dev/null 2>&1 || break
        sleep $POLL; w=$((w + 1))
    done
    pkill -9 -x Sunshine 2>/dev/null || true
    log_ok "Sunshine 已停止"
}

# ---- 关闭虚拟屏 ----
close_virtual_display() {
    log_step "正在关闭虚拟屏"
    if ! pgrep -q BetterDisplay 2>/dev/null; then
        log_info "BetterDisplay 未运行，虚拟屏随进程一并消失"
        return 0
    fi
    if [ -n "$CLI" ] && [ -x "$CLI" ]; then
        "$CLI" set --name="$VD_NAME" --connected=off >/dev/null 2>&1 || true
        log_ok "虚拟屏已关闭"
    else
        log_info "未找到 BetterDisplay 命令行工具，跳过虚拟屏关闭"
    fi
}

# ---- 退出 BetterDisplay ----
quit_betterdisplay() {
    log_step "正在退出 BetterDisplay"
    if ! pgrep -q BetterDisplay 2>/dev/null; then
        log_info "BetterDisplay 未运行"
        return 0
    fi
    osascript -e 'quit app "BetterDisplay"' 2>/dev/null || true
    local w=0
    while [ $w -lt 20 ]; do
        pgrep -q BetterDisplay 2>/dev/null || break
        sleep $POLL; w=$((w + 1))
    done
    pkill -x BetterDisplay 2>/dev/null || true
    log_ok "BetterDisplay 已退出"
}

main() {
    stop_sunshine
    close_virtual_display

    if [ "$KEEP_BD" = "1" ]; then
        log_ok "BetterDisplay 保持隐形驻留（下次连接只需 1~2 秒）"
    else
        quit_betterdisplay
    fi

    echo "[DONE] iPad 副屏已关闭"
}

main
