#!/bin/bash
# ============================================================
#  iPad 副屏一键关闭
#  停止 Sunshine + 退出 BetterDisplay
# ============================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC} $1" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_step()  { echo -e "\n${CYAN}═══ $1 ═══${NC}" >&2; }

stop_sunshine() {
    log_step "1/2  停止 Sunshine"
    if pgrep -x Sunshine > /dev/null 2>&1; then
        log_info "正在停止 Sunshine..."
        pkill -x Sunshine 2>/dev/null || true
        sleep 2
        pgrep -x Sunshine > /dev/null 2>&1 && pkill -9 -x Sunshine 2>/dev/null || true
        sleep 1
        log_ok "Sunshine 已停止"
    else
        log_info "Sunshine 未在运行"
    fi
}

quit_betterdisplay() {
    log_step "2/2  退出 BetterDisplay"
    if pgrep -q BetterDisplay 2>/dev/null; then
        log_info "正在退出 BetterDisplay（自动断开虚拟屏幕）..."
        osascript -e 'quit app "BetterDisplay"' 2>/dev/null || true
        sleep 2
        pgrep -q BetterDisplay 2>/dev/null && pkill -x BetterDisplay 2>/dev/null || true
        log_ok "BetterDisplay 已退出，虚拟屏幕已断开"
    else
        log_info "BetterDisplay 未在运行"
    fi
}

main() {
    clear 2>/dev/null || true
    echo ""
    echo "  ╔══════════════════════════════════╗"
    echo "  ║     📱 关闭 iPad 副屏          ║"
    echo "  ╚══════════════════════════════════╝"
    echo ""

    stop_sunshine
    quit_betterdisplay

    echo ""
    echo "  ╔══════════════════════════════════╗"
    echo "  ║   ✅ iPad 副屏已关闭           ║"
    echo "  ╚══════════════════════════════════╝"
    echo ""
}

main
