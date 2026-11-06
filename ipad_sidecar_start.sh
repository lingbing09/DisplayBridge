#!/bin/bash
# ============================================================
#  iPad 副屏一键启动
#  静默运行，零浏览器干扰
#  BetterDisplay → 虚拟屏 → Sunshine → curl 验证 → 完成
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPLAY_TOOL="$SCRIPT_DIR/get_virtual_display"
SUNSHINE_CONF="$HOME/.config/sunshine/sunshine.conf"
BETTERDISPLAY_APP="/Applications/BetterDisplay.app"
SUNSHINE_APP="/Applications/Sunshine.app"
SUNSHINE_AUTH="1:1"

VIRTUAL_DISPLAY_ID=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC} $1" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERR ]${NC} $1" >&2; }
log_step()  { echo -e "\n${CYAN}═══ $1 ═══${NC}" >&2; }

check_env() {
    [ -x "$DISPLAY_TOOL" ] || { log_error "缺少: $DISPLAY_TOOL"; exit 1; }
    [ -d "$BETTERDISPLAY_APP" ] || { log_error "缺少: $BETTERDISPLAY_APP"; exit 1; }
    [ -d "$SUNSHINE_APP" ] || { log_error "缺少: $SUNSHINE_APP"; exit 1; }
}

launch_betterdisplay() {
    log_step "1/4  启动 BetterDisplay"
    if pgrep -q BetterDisplay; then
        log_ok "BetterDisplay 已在运行中"
    else
        log_info "正在启动 BetterDisplay..."
        open -a "$BETTERDISPLAY_APP"
        sleep 2
        log_ok "BetterDisplay 已启动"
    fi
}

detect_virtual_display() {
    log_step "2/4  检测虚拟屏幕"
    local max_wait=20 waited=0

    log_info "等待虚拟屏幕 'display' 就绪（最多 ${max_wait}s）..."
    while [ $waited -lt $max_wait ]; do
        local raw_output
        raw_output=$("$DISPLAY_TOOL" 2>/dev/null) || true
        if [ -n "$raw_output" ]; then
            VIRTUAL_DISPLAY_ID=$(echo "$raw_output" | tail -1 | tr -d '[:space:]')
            if [[ "$VIRTUAL_DISPLAY_ID" =~ ^[0-9]+$ ]]; then
                return 0
            fi
        fi
        sleep 1; waited=$((waited + 1))
        printf "." >&2
    done
    echo "" >&2
    log_error "超时：虚拟屏幕 'display' 未出现"
    return 1
}

update_sunshine_config() {
    log_step "3/4  更新 Sunshine 配置"
    [ -f "$SUNSHINE_CONF" ] || { log_error "找不到 $SUNSHINE_CONF"; exit 1; }

    cp "$SUNSHINE_CONF" "$SUNSHINE_CONF.backup" 2>/dev/null || true
    local old_id
    old_id=$(grep "^output_name" "$SUNSHINE_CONF" | awk -F'= ' '{print $2}' | tr -d ' ')

    if [ "$old_id" = "$VIRTUAL_DISPLAY_ID" ]; then
        log_ok "Sunshine output_name 已是最新 ($VIRTUAL_DISPLAY_ID)"
        return 0
    fi

    awk -v new_id="$VIRTUAL_DISPLAY_ID" \
        '/^output_name/ {print "output_name = " new_id; next} {print}' \
        "$SUNSHINE_CONF" > "$SUNSHINE_CONF.tmp" && \
        mv "$SUNSHINE_CONF.tmp" "$SUNSHINE_CONF"

    log_ok "Sunshine output_name: $old_id → $VIRTUAL_DISPLAY_ID"
}

launch_sunshine() {
    log_step "4/4  启动 Sunshine"

    local sunshine_pid
    sunshine_pid=$(pgrep -x Sunshine 2>/dev/null || true)

    if [ -n "$sunshine_pid" ]; then
        log_warn "Sunshine 正在运行，重启以应用新配置..."
        kill "$sunshine_pid" 2>/dev/null || true
        sleep 3
        pgrep -x Sunshine > /dev/null 2>&1 && kill -9 "$sunshine_pid" 2>/dev/null || true
        sleep 1
        log_info "Sunshine 已停止"
    fi

    log_info "正在启动 Sunshine..."
    open -a "$SUNSHINE_APP"
    sleep 2

    if ! pgrep -x Sunshine > /dev/null 2>&1; then
        log_error "Sunshine 启动失败！"
        return 1
    fi
    log_ok "Sunshine 进程已启动"

    # 等待 Web 服务就绪
    log_info "等待 Sunshine Web 服务就绪..."
    local ws_waited=0 ws_max=20
    while [ $ws_waited -lt $ws_max ]; do
        if curl -sk --connect-timeout 2 "https://localhost:47990/" > /dev/null 2>&1; then
            break
        fi
        sleep 1; ws_waited=$((ws_waited + 1))
        printf "." >&2
    done

    # 验证 Sunshine 已认证可用
    sleep 1
    local status
    status=$(curl -sk -u "$SUNSHINE_AUTH" --connect-timeout 5 "https://localhost:47990/" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")

    if [ "$status" = "200" ]; then
        log_ok "Sunshine 串流就绪 ✓"
        return 0
    else
        log_warn "Sunshine HTTP $status — 可能需手动确认"
        return 1
    fi
}

main() {
    clear 2>/dev/null || true
    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║        📱 iPad 副屏 · 一键启动             ║"
    echo "  ║   静默模式 · 不打开浏览器 · 零干扰          ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo ""

    check_env
    launch_betterdisplay

    if ! detect_virtual_display; then
        log_error "未检测到虚拟屏幕，退出"
        exit 1
    fi
    log_ok "虚拟屏幕就绪 → CGDirectDisplayID = $VIRTUAL_DISPLAY_ID"

    update_sunshine_config
    launch_sunshine

    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║                                              ║"
    echo "  ║   ✅ 全部就绪！静默完成                     ║"
    echo "  ║                                              ║"
    printf "  ║   虚拟屏幕 : CGDirectDisplayID = %-10s  ║\n" "$VIRTUAL_DISPLAY_ID"
    echo "  ║   Sunshine  : https://localhost:47990        ║"
    echo "  ║                                              ║"
    echo "  ║   📱 iPad 打开 Moonlight → 连接 → 开始串流   ║"
    echo "  ║                                              ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo ""
}

main
