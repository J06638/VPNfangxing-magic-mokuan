#!/system/bin/sh
# NetFix All-in-One Adaptive Performance v4.2
# BusyBox ash / POSIX-shell friendly. Designed to preserve VPN repair while avoiding standby polling storms.

MODDIR=${0%/*}
# Keep the old runtime directory for in-place upgrade/restore compatibility with v4.0.
RUNDIR=/data/local/tmp/netfix_allinone_v4
LOG="$RUNDIR/netfix.log"
PIDFILE="$RUNDIR/netfix.pid"
LOCKDIR="$RUNDIR/lock"
SYSSTATE="$RUNDIR/sysctl.state"
MTUSTATE="$RUNDIR/mtu.state"
CONFIG="$MODDIR/config.conf"
PERFSTATE="$RUNDIR/perf.state"
WIFISTATE="$RUNDIR/wifi_powersave.state"
WIFIAUTOBASE="$RUNDIR/wifi_auto_base.state"
ADAPTSTATE="$RUNDIR/adaptive.state"

# Defaults
AGGRESSIVE=1
ENABLE_IPV6=1
ENABLE_NAT=1
ENABLE_MSS_CLAMP=1
DISABLE_RP_FILTER=1
ENABLE_SRC_VALID_MARK=1
TARGET_MTU=1420
MAX_LOG_BYTES=524288

ENABLE_NET_PERFORMANCE=1
PREFERRED_CC="bbr cubic"
PREFER_FQ=1
SOCKET_BUFFER_MAX=16777216
TCP_BUFFER_MAX=16777216
NETDEV_MAX_BACKLOG=8192
NETDEV_BUDGET=600
NETDEV_BUDGET_USECS=8000
TCP_MTU_PROBING=1
TCP_SLOW_START_AFTER_IDLE=0
DISABLE_WIFI_POWERSAVE=0
PERF_REAPPLY_INTERVAL=1800

# Adaptive mode: BOOST only while real traffic is high; otherwise restore baseline Wi-Fi power save.
ADAPTIVE_MODE=1
ADAPTIVE_WIFI_POWER=1
BOOST_ENTER_BPS=524288
BOOST_EXIT_BPS=131072
BOOST_HOLD_SECONDS=20
BOOST_SCAN_INTERVAL=3
SCREEN_ON_IDLE_INTERVAL=3
SCREEN_ON_VPN_INTERVAL=5
SCREEN_OFF_IDLE_INTERVAL=60
SCREEN_OFF_VPN_INTERVAL=30
FIREWALL_VERIFY_BOOST=30
FIREWALL_VERIFY_NORMAL=180
FIREWALL_VERIFY_SCREEN_OFF=300

[ -f "$CONFIG" ] && . "$CONFIG"
mkdir -p "$RUNDIR" 2>/dev/null

log_rotate() {
    [ -f "$LOG" ] || return 0
    size=$(wc -c < "$LOG" 2>/dev/null)
    case "$size" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$size" -gt "$MAX_LOG_BYTES" ] 2>/dev/null; then
        tail -n 300 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
    fi
}

log() {
    log_rotate
    echo "[$(date '+%F %T')] $*" >> "$LOG"
}

# Prevent duplicate daemon instances. During an in-place upgrade, stale locks are recovered.
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    oldpid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        exit 0
    fi
    rm -rf "$LOCKDIR" 2>/dev/null
    mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi

echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE" 2>/dev/null; rm -rf "$LOCKDIR" 2>/dev/null' EXIT INT TERM

# Wait for Android boot completion.
i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    sleep 2
    i=$((i + 1))
    [ "$i" -ge 150 ] && break
done
sleep 3

IPT=$(command -v iptables 2>/dev/null)
IP6T=$(command -v ip6tables 2>/dev/null)
IPCMD=$(command -v ip 2>/dev/null)
IWCMD=$(command -v iw 2>/dev/null)
DUMPSYS=$(command -v dumpsys 2>/dev/null)

# Prefer cheap sysfs screen-state checks. Fall back to dumpsys only if needed.
BACKLIGHT_FILE=""
for f in /sys/class/backlight/*/actual_brightness /sys/class/backlight/*/brightness /sys/class/leds/lcd-backlight/brightness; do
    [ -r "$f" ] || continue
    BACKLIGHT_FILE="$f"
    break
done

is_screen_on() {
    if [ -n "$BACKLIGHT_FILE" ]; then
        b=$(cat "$BACKLIGHT_FILE" 2>/dev/null)
        case "$b" in ''|*[!0-9]*) ;; *) [ "$b" -gt 0 ] 2>/dev/null && return 0 || return 1 ;; esac
    fi
    [ -n "$DUMPSYS" ] && "$DUMPSYS" power 2>/dev/null | grep -q 'mWakefulness=Awake' && return 0
    return 1
}

read_num() {
    [ -r "$1" ] && cat "$1" 2>/dev/null
}

write_num() {
    path="$1"; val="$2"
    [ -e "$path" ] || return 1
    cur=$(cat "$path" 2>/dev/null)
    [ "$cur" = "$val" ] && return 0
    echo "$val" > "$path" 2>/dev/null
}

save_perf_path_once() {
    path="$1"
    [ -r "$path" ] || return 1
    touch "$PERFSTATE" 2>/dev/null
    grep -Fq "$path|" "$PERFSTATE" 2>/dev/null && return 0
    val=$(cat "$path" 2>/dev/null)
    printf '%s|%s\n' "$path" "$val" >> "$PERFSTATE"
}

set_perf_value() {
    path="$1"; val="$2"
    [ -e "$path" ] || return 1
    save_perf_path_once "$path"
    cur=$(cat "$path" 2>/dev/null)
    [ "$cur" = "$val" ] && return 0
    echo "$val" > "$path" 2>/dev/null
}

raise_perf_num() {
    path="$1"; target="$2"
    [ -r "$path" ] || return 1
    cur=$(cat "$path" 2>/dev/null)
    case "$cur:$target" in *[!0-9:]*|:*) return 1 ;; esac
    [ "$cur" -ge "$target" ] 2>/dev/null && return 0
    set_perf_value "$path" "$target"
}

raise_triplet_max() {
    path="$1"; target="$2"
    [ -r "$path" ] || return 1
    set -- $(cat "$path" 2>/dev/null)
    [ "$#" -ge 3 ] || return 1
    a="$1"; b="$2"; c="$3"
    case "$a:$b:$c:$target" in *[!0-9:]*|*::* ) return 1 ;; esac
    [ "$c" -ge "$target" ] 2>/dev/null && return 0
    set_perf_value "$path" "$a $b $target"
}

choose_congestion_control() {
    [ "$ENABLE_NET_PERFORMANCE" = "1" ] || return 0
    avail=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)
    [ -n "$avail" ] || return 0
    for cc in $PREFERRED_CC; do
        case " $avail " in
            *" $cc "*)
                set_perf_value /proc/sys/net/ipv4/tcp_congestion_control "$cc"
                if [ "$cc" = "bbr" ] && [ "$PREFER_FQ" = "1" ]; then
                    set_perf_value /proc/sys/net/core/default_qdisc fq >/dev/null 2>&1
                fi
                return 0
            ;;
        esac
    done
}

detect_wifi_ifaces() {
    out=""
    for p in /sys/class/net/*; do
        [ -e "$p" ] || continue
        n=${p##*/}
        lc=$(echo "$n" | tr 'A-Z' 'a-z')
        case "$lc" in wlan*|wifi*|swlan*) out="$out $n" ;; esac
    done
    echo "$out" | awk '{$1=$1; print}'
}

# v4.0 recorded the original Wi-Fi power-save state. Restore it first on upgrade.
restore_legacy_wifi_power_if_needed() {
    [ -n "$IWCMD" ] || return 0
    [ -f "$WIFISTATE" ] || return 0
    while IFS='|' read iface state; do
        [ -n "$iface" ] || continue
        [ -e "/sys/class/net/$iface" ] || continue
        case "$state" in
            on|off) "$IWCMD" dev "$iface" set power_save "$state" >/dev/null 2>&1 ;;
        esac
    done < "$WIFISTATE"
    rm -f "$WIFISTATE" 2>/dev/null
    log "[POWER] restored legacy Wi-Fi power-save state"
}

# Save a stable baseline once. If a prior BOOST session was interrupted, this lets the next boot/uninstall restore it.
capture_wifi_base_state() {
    [ -n "$IWCMD" ] || return 0
    [ -s "$WIFIAUTOBASE" ] && return 0
    : > "$WIFIAUTOBASE"
    for w in $(detect_wifi_ifaces); do
        [ -e "/sys/class/net/$w" ] || continue
        state=$("$IWCMD" dev "$w" get power_save 2>/dev/null | awk -F': ' '/Power save/ {print $2; exit}')
        case "$state" in on|off) printf '%s|%s\n' "$w" "$state" >> "$WIFIAUTOBASE" ;; esac
    done
}

restore_wifi_base_state() {
    [ -n "$IWCMD" ] || return 0
    [ -f "$WIFIAUTOBASE" ] || return 0
    while IFS='|' read iface state; do
        [ -n "$iface" ] || continue
        [ -e "/sys/class/net/$iface" ] || continue
        case "$state" in on|off) "$IWCMD" dev "$iface" set power_save "$state" >/dev/null 2>&1 ;; esac
    done < "$WIFIAUTOBASE"
}

set_wifi_profile() {
    profile="$1"
    [ -n "$IWCMD" ] || return 0
    capture_wifi_base_state

    # Manual compatibility switch still wins over adaptive behavior.
    if [ "$DISABLE_WIFI_POWERSAVE" = "1" ]; then
        desired="FORCE_OFF"
    elif [ "$ADAPTIVE_MODE" = "1" ] && [ "$ADAPTIVE_WIFI_POWER" = "1" ] && [ "$profile" = "BOOST" ]; then
        desired="BOOST_OFF"
    else
        desired="BASELINE"
    fi

    [ "$desired" = "$last_wifi_policy" ] && return 0
    case "$desired" in
        FORCE_OFF|BOOST_OFF)
            for w in $(detect_wifi_ifaces); do
                [ -e "/sys/class/net/$w" ] || continue
                "$IWCMD" dev "$w" set power_save off >/dev/null 2>&1
            done
        ;;
        BASELINE) restore_wifi_base_state ;;
    esac
    last_wifi_policy="$desired"
    log "[POWER] Wi-Fi policy -> $desired"
}

detect_mobile_data_ifaces() {
    out=""
    for p in /sys/class/net/*; do
        [ -e "$p" ] || continue
        n=${p##*/}
        lc=$(echo "$n" | tr 'A-Z' 'a-z')
        case "$lc" in
            rmnet_data[0-9]*|r_rmnet_data[0-9]*|ccmni[0-9]*|pdp[0-9]*|wwan[0-9]*)
                state=$(cat "/sys/class/net/$n/operstate" 2>/dev/null)
                case "$state" in up|unknown) out="$out $n" ;; esac
            ;;
        esac
    done
    echo "$out" | awk '{$1=$1; print}'
}

read_iface_bytes() {
    iface="$1"
    rx=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null)
    tx=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null)
    case "$rx" in ''|*[!0-9]*) rx=0 ;; esac
    case "$tx" in ''|*[!0-9]*) tx=0 ;; esac
    echo $((rx + tx))
}

get_total_uplink_bytes() {
    total=0
    seen=""
    for iface in $(detect_wifi_ifaces) $(detect_mobile_data_ifaces); do
        case " $seen " in *" $iface "*) continue ;; esac
        seen="$seen $iface"
        [ -e "/sys/class/net/$iface" ] || continue
        b=$(read_iface_bytes "$iface")
        case "$b" in ''|*[!0-9]*) b=0 ;; esac
        total=$((total + b))
    done
    echo "$total"
}

write_adaptive_state() {
    mode="$1"; rate="$2"; screen="$3"; vpn="$4"; interval="$5"
    {
        echo "mode=$mode"
        echo "rate_bps=$rate"
        echo "screen_on=$screen"
        echo "vpn_ifaces=$vpn"
        echo "scan_interval=$interval"
        echo "wifi_policy=${last_wifi_policy:-unknown}"
        echo "updated=$(date '+%F %T')"
    } > "$ADAPTSTATE.tmp" 2>/dev/null
    mv -f "$ADAPTSTATE.tmp" "$ADAPTSTATE" 2>/dev/null
}

apply_network_performance() {
    [ "$ENABLE_NET_PERFORMANCE" = "1" ] || return 0
    raise_perf_num /proc/sys/net/core/rmem_max "$SOCKET_BUFFER_MAX"
    raise_perf_num /proc/sys/net/core/wmem_max "$SOCKET_BUFFER_MAX"
    raise_triplet_max /proc/sys/net/ipv4/tcp_rmem "$TCP_BUFFER_MAX"
    raise_triplet_max /proc/sys/net/ipv4/tcp_wmem "$TCP_BUFFER_MAX"
    raise_perf_num /proc/sys/net/core/netdev_max_backlog "$NETDEV_MAX_BACKLOG"
    raise_perf_num /proc/sys/net/core/netdev_budget "$NETDEV_BUDGET"
    raise_perf_num /proc/sys/net/core/netdev_budget_usecs "$NETDEV_BUDGET_USECS"
    set_perf_value /proc/sys/net/ipv4/tcp_window_scaling 1 >/dev/null 2>&1
    set_perf_value /proc/sys/net/ipv4/tcp_sack 1 >/dev/null 2>&1
    set_perf_value /proc/sys/net/ipv4/tcp_mtu_probing "$TCP_MTU_PROBING" >/dev/null 2>&1
    set_perf_value /proc/sys/net/ipv4/tcp_slow_start_after_idle "$TCP_SLOW_START_AFTER_IDLE" >/dev/null 2>&1
    choose_congestion_control
}

save_sysctl_state_once() {
    [ -f "$SYSSTATE" ] && return 0
    {
        echo "IP_FORWARD=$(read_num /proc/sys/net/ipv4/ip_forward)"
        echo "RP_ALL=$(read_num /proc/sys/net/ipv4/conf/all/rp_filter)"
        echo "RP_DEFAULT=$(read_num /proc/sys/net/ipv4/conf/default/rp_filter)"
        echo "SRC_VALID_MARK=$(read_num /proc/sys/net/ipv4/conf/all/src_valid_mark)"
    } > "$SYSSTATE.tmp" 2>/dev/null
    mv -f "$SYSSTATE.tmp" "$SYSSTATE" 2>/dev/null
}

apply_sysctls() {
    write_num /proc/sys/net/ipv4/ip_forward 1
    if [ "$DISABLE_RP_FILTER" = "1" ]; then
        write_num /proc/sys/net/ipv4/conf/all/rp_filter 0
        write_num /proc/sys/net/ipv4/conf/default/rp_filter 0
    fi
    if [ "$ENABLE_SRC_VALID_MARK" = "1" ]; then
        write_num /proc/sys/net/ipv4/conf/all/src_valid_mark 1
    fi
}

# Exclude kernel placeholder tunnels such as tunl0/ip6tnl0/gre0.
# Only names that are commonly created by real user-space VPNs are candidates.
is_vpn_name() {
    n=$(echo "$1" | tr 'A-Z' 'a-z')
    case "$n" in
        tunl*|ip6tnl*|gre*|gretap*|erspan*|sit*|ip_vti*|ip6_vti*) return 1 ;;
        tun[0-9]*|tap[0-9]*|wg[0-9]*|vpn[0-9]*|ppp[0-9]*|ipsec[0-9]*|vti[0-9]*|xfrm[0-9]*|clash*|mihomo*|singbox*|sing-*|tailscale*|warp*|zt*) return 0 ;;
        *) return 1 ;;
    esac
}

iface_is_up() {
    n="$1"
    [ -e "/sys/class/net/$n" ] || return 1
    state=$(cat "/sys/class/net/$n/operstate" 2>/dev/null)
    case "$state" in up|unknown) ;; *) return 1 ;; esac
    # Real Android TUN/WG interfaces may report operstate=unknown, so verify IFF_UP from ip flags.
    if [ -n "$IPCMD" ]; then
        "$IPCMD" link show dev "$n" 2>/dev/null | grep -q '<[^>]*UP' || return 1
    fi
    return 0
}

detect_vpn_ifaces() {
    out=""
    for p in /sys/class/net/*; do
        [ -e "$p" ] || continue
        n=${p##*/}
        is_vpn_name "$n" || continue
        iface_is_up "$n" || continue
        out="$out $n"
    done
    echo "$out" | awk '{$1=$1; print}'
}

chain_exists() {
    "$1" -S "$2" >/dev/null 2>&1
}

ensure_chain() {
    cmd="$1"; table="$2"; chain="$3"
    "$cmd" -t "$table" -S "$chain" >/dev/null 2>&1 || "$cmd" -t "$table" -N "$chain" >/dev/null 2>&1
}

ensure_jump() {
    cmd="$1"; table="$2"; parent="$3"; child="$4"
    "$cmd" -t "$table" -S "$parent" >/dev/null 2>&1 || return 1
    "$cmd" -t "$table" -C "$parent" -j "$child" >/dev/null 2>&1 && return 0
    "$cmd" -t "$table" -I "$parent" 1 -j "$child" >/dev/null 2>&1
}

ensure_rule() {
    cmd="$1"; table="$2"; chain="$3"; shift 3
    "$cmd" -t "$table" -C "$chain" "$@" >/dev/null 2>&1 && return 0
    "$cmd" -t "$table" -I "$chain" 1 "$@" >/dev/null 2>&1
}

ensure_append_rule() {
    cmd="$1"; table="$2"; chain="$3"; shift 3
    "$cmd" -t "$table" -C "$chain" "$@" >/dev/null 2>&1 && return 0
    "$cmd" -t "$table" -A "$chain" "$@" >/dev/null 2>&1
}

hook_oem_chains() {
    cmd="$1"
    [ -n "$cmd" ] || return 0
    for c in fw_INPUT bw_INPUT oem_in oem_INPUT st_INPUT vendor_INPUT oplus_INPUT coloros_INPUT miui_INPUT hw_INPUT sec_INPUT firewall_INPUT; do
        chain_exists "$cmd" "$c" && ensure_jump "$cmd" filter "$c" NFIX_IN
    done
    for c in fw_OUTPUT bw_OUTPUT oem_out oem_OUTPUT st_OUTPUT vendor_OUTPUT oplus_OUTPUT coloros_OUTPUT miui_OUTPUT hw_OUTPUT sec_OUTPUT firewall_OUTPUT; do
        chain_exists "$cmd" "$c" && ensure_jump "$cmd" filter "$c" NFIX_OUT
    done
    for c in fw_FORWARD bw_FORWARD oem_fwd oem_FORWARD st_FORWARD vendor_FORWARD oplus_FORWARD coloros_FORWARD miui_FORWARD hw_FORWARD sec_FORWARD firewall_FORWARD; do
        chain_exists "$cmd" "$c" && ensure_jump "$cmd" filter "$c" NFIX_FWD
    done
    [ "$AGGRESSIVE" = "1" ] || return 0
    "$cmd" -S 2>/dev/null | awk '$1=="-N" {print $2}' | while read c; do
        [ -n "$c" ] || continue
        lc=$(echo "$c" | tr 'A-Z' 'a-z')
        case "$lc" in
            fw_*|bw_*|oem_*|st_*|vendor_*|oplus_*|coloros_*|miui_*|hw_*|sec_*|firewall_*|netd_*)
                case "$lc" in
                    *input*|*_in) ensure_jump "$cmd" filter "$c" NFIX_IN ;;
                    *output*|*_out) ensure_jump "$cmd" filter "$c" NFIX_OUT ;;
                    *forward*|*fwd*) ensure_jump "$cmd" filter "$c" NFIX_FWD ;;
                esac
            ;;
        esac
    done
}

setup_filter_family() {
    cmd="$1"; ifaces="$2"
    [ -n "$cmd" ] || return 0
    ensure_chain "$cmd" filter NFIX_IN
    ensure_chain "$cmd" filter NFIX_OUT
    ensure_chain "$cmd" filter NFIX_FWD
    ensure_jump "$cmd" filter INPUT NFIX_IN
    ensure_jump "$cmd" filter OUTPUT NFIX_OUT
    ensure_jump "$cmd" filter FORWARD NFIX_FWD
    hook_oem_chains "$cmd"
    for v in $ifaces; do
        ensure_rule "$cmd" filter NFIX_IN  -i "$v" -j ACCEPT
        ensure_rule "$cmd" filter NFIX_OUT -o "$v" -j ACCEPT
        ensure_rule "$cmd" filter NFIX_FWD -i "$v" -j ACCEPT
        ensure_rule "$cmd" filter NFIX_FWD -o "$v" -j ACCEPT
    done
}

setup_ipv4_nat() {
    ifaces="$1"
    [ "$ENABLE_NAT" = "1" ] || return 0
    [ -n "$IPT" ] || return 0
    ensure_chain "$IPT" nat NFIX_NAT
    ensure_jump "$IPT" nat POSTROUTING NFIX_NAT
    for v in $ifaces; do
        ensure_append_rule "$IPT" nat NFIX_NAT -o "$v" -j MASQUERADE
    done
}

setup_mss_family() {
    cmd="$1"; ifaces="$2"
    [ "$ENABLE_MSS_CLAMP" = "1" ] || return 0
    [ -n "$cmd" ] || return 0
    ensure_chain "$cmd" mangle NFIX_MSSO
    ensure_chain "$cmd" mangle NFIX_MSSF
    ensure_jump "$cmd" mangle OUTPUT NFIX_MSSO
    ensure_jump "$cmd" mangle FORWARD NFIX_MSSF
    for v in $ifaces; do
        ensure_append_rule "$cmd" mangle NFIX_MSSO -o "$v" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        ensure_append_rule "$cmd" mangle NFIX_MSSF -o "$v" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        ensure_append_rule "$cmd" mangle NFIX_MSSF -i "$v" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    done
}

flush_own_rules() {
    if [ -n "$IPT" ]; then
        for c in NFIX_IN NFIX_OUT NFIX_FWD; do "$IPT" -F "$c" >/dev/null 2>&1; done
        "$IPT" -t nat -F NFIX_NAT >/dev/null 2>&1
        for c in NFIX_MSSO NFIX_MSSF; do "$IPT" -t mangle -F "$c" >/dev/null 2>&1; done
    fi
    if [ -n "$IP6T" ]; then
        for c in NFIX_IN NFIX_OUT NFIX_FWD; do "$IP6T" -F "$c" >/dev/null 2>&1; done
        for c in NFIX_MSSO NFIX_MSSF; do "$IP6T" -t mangle -F "$c" >/dev/null 2>&1; done
    fi
}

save_mtu_once() {
    v="$1"; mtu="$2"
    [ -n "$mtu" ] || return 0
    touch "$MTUSTATE" 2>/dev/null
    grep -q "^$v " "$MTUSTATE" 2>/dev/null || echo "$v $mtu" >> "$MTUSTATE"
}

fix_interface_sysctls_and_mtu() {
    for v in $1; do
        [ -e "/sys/class/net/$v" ] || continue
        if [ "$DISABLE_RP_FILTER" = "1" ]; then
            write_num "/proc/sys/net/ipv4/conf/$v/rp_filter" 0
        fi
        if [ "$ENABLE_SRC_VALID_MARK" = "1" ]; then
            write_num "/proc/sys/net/ipv4/conf/$v/src_valid_mark" 1
        fi
        mtu=$(cat "/sys/class/net/$v/mtu" 2>/dev/null)
        case "$mtu" in ''|*[!0-9]*) continue ;; esac
        case "$TARGET_MTU" in ''|*[!0-9]*) continue ;; esac
        save_mtu_once "$v" "$mtu"
        if [ "$mtu" -gt "$TARGET_MTU" ] 2>/dev/null; then
            if [ -n "$IPCMD" ]; then
                "$IPCMD" link set dev "$v" mtu "$TARGET_MTU" >/dev/null 2>&1 && log "[MTU] $v: $mtu -> $TARGET_MTU"
            else
                ifconfig "$v" mtu "$TARGET_MTU" >/dev/null 2>&1 && log "[MTU] $v: $mtu -> $TARGET_MTU"
            fi
        fi
    done
}

repair_for_vpn_ifaces() {
    ifaces="$1"
    [ -n "$ifaces" ] || return 0
    flush_own_rules
    apply_sysctls
    setup_filter_family "$IPT" "$ifaces"
    if [ "$ENABLE_IPV6" = "1" ]; then setup_filter_family "$IP6T" "$ifaces"; fi
    setup_ipv4_nat "$ifaces"
    setup_mss_family "$IPT" "$ifaces"
    if [ "$ENABLE_IPV6" = "1" ]; then setup_mss_family "$IP6T" "$ifaces"; fi
    fix_interface_sysctls_and_mtu "$ifaces"
}

firewall_needs_repair() {
    ifaces="$1"
    [ -n "$ifaces" ] || return 1
    if [ -n "$IPT" ]; then
        "$IPT" -C OUTPUT -j NFIX_OUT >/dev/null 2>&1 || return 0
        for v in $ifaces; do
            "$IPT" -C NFIX_OUT -o "$v" -j ACCEPT >/dev/null 2>&1 || return 0
        done
    fi
    if [ "$ENABLE_IPV6" = "1" ] && [ -n "$IP6T" ]; then
        "$IP6T" -C OUTPUT -j NFIX_OUT >/dev/null 2>&1 || return 0
        for v in $ifaces; do
            "$IP6T" -C NFIX_OUT -o "$v" -j ACCEPT >/dev/null 2>&1 || return 0
        done
    fi
    return 1
}

restore_legacy_wifi_power_if_needed
capture_wifi_base_state
# In case the previous boot ended while BOOST had Wi-Fi power save forced off.
restore_wifi_base_state
save_sysctl_state_once
apply_sysctls
apply_network_performance

last_ifaces="__INIT__"
last_wifi_policy=""
current_mode="INIT"
boost_until=0
last_perf_epoch=$(date +%s 2>/dev/null)
last_fw_epoch="$last_perf_epoch"
prev_epoch="$last_perf_epoch"
prev_bytes=$(get_total_uplink_bytes)
case "$last_perf_epoch" in ''|*[!0-9]*) last_perf_epoch=0 ;; esac
case "$last_fw_epoch" in ''|*[!0-9]*) last_fw_epoch=0 ;; esac
case "$prev_epoch" in ''|*[!0-9]*) prev_epoch=0 ;; esac
case "$prev_bytes" in ''|*[!0-9]*) prev_bytes=0 ;; esac

log "NetFix v4.2 adaptive started; target_mtu=$TARGET_MTU; adaptive=$ADAPTIVE_MODE wifi_auto=$ADAPTIVE_WIFI_POWER"
log "thresholds enter=$BOOST_ENTER_BPS exit=$BOOST_EXIT_BPS hold=${BOOST_HOLD_SECONDS}s; intervals boost=$BOOST_SCAN_INTERVAL on=$SCREEN_ON_IDLE_INTERVAL/$SCREEN_ON_VPN_INTERVAL off=$SCREEN_OFF_IDLE_INTERVAL/$SCREEN_OFF_VPN_INTERVAL"

while true; do
    VPN_IFACES=$(detect_vpn_ifaces)
    now=$(date +%s 2>/dev/null)
    case "$now" in ''|*[!0-9]*) now=0 ;; esac

    total_bytes=$(get_total_uplink_bytes)
    case "$total_bytes" in ''|*[!0-9]*) total_bytes="$prev_bytes" ;; esac
    elapsed=$((now - prev_epoch))
    delta=$((total_bytes - prev_bytes))
    [ "$elapsed" -le 0 ] 2>/dev/null && elapsed=1
    [ "$delta" -lt 0 ] 2>/dev/null && delta=0
    rate=$((delta / elapsed))
    prev_bytes="$total_bytes"
    prev_epoch="$now"

    if is_screen_on; then screen_on=1; else screen_on=0; fi

    # Hysteresis: enter BOOST on meaningful traffic, leave only after rate is low and hold time expires.
    new_mode="$current_mode"
    if [ "$ADAPTIVE_MODE" != "1" ]; then
        new_mode="BALANCED"
    else
        if [ "$current_mode" = "BOOST" ]; then
            if [ "$rate" -ge "$BOOST_EXIT_BPS" ] 2>/dev/null; then
                boost_until=$((now + BOOST_HOLD_SECONDS))
                new_mode="BOOST"
            elif [ "$now" -lt "$boost_until" ] 2>/dev/null; then
                new_mode="BOOST"
            elif [ "$screen_on" = "1" ]; then
                new_mode="BALANCED"
            else
                new_mode="ECO"
            fi
        elif [ "$rate" -ge "$BOOST_ENTER_BPS" ] 2>/dev/null; then
            boost_until=$((now + BOOST_HOLD_SECONDS))
            new_mode="BOOST"
        elif [ "$screen_on" = "1" ]; then
            new_mode="BALANCED"
        else
            new_mode="ECO"
        fi
    fi

    if [ "$new_mode" != "$current_mode" ]; then
        log "[AUTO] mode $current_mode -> $new_mode; rate=${rate}B/s screen=$screen_on vpn=${VPN_IFACES:-none}"
        current_mode="$new_mode"
        set_wifi_profile "$current_mode"
        # Re-assert persistent throughput parameters once when a real transfer enters BOOST.
        [ "$current_mode" = "BOOST" ] && apply_network_performance
    else
        set_wifi_profile "$current_mode"
    fi

    # VPN interface changes always trigger immediate repair.
    if [ "$VPN_IFACES" != "$last_ifaces" ]; then
        if [ -n "$VPN_IFACES" ]; then
            log "[VPN] active interfaces: $VPN_IFACES"
            repair_for_vpn_ifaces "$VPN_IFACES"
            last_fw_epoch="$now"
        else
            [ "$last_ifaces" != "__INIT__" ] && log "[VPN] no active VPN interface"
            flush_own_rules
        fi
        last_ifaces="$VPN_IFACES"
    elif [ -n "$VPN_IFACES" ]; then
        if [ "$current_mode" = "BOOST" ]; then
            fw_interval="$FIREWALL_VERIFY_BOOST"
        elif [ "$screen_on" = "0" ]; then
            fw_interval="$FIREWALL_VERIFY_SCREEN_OFF"
        else
            fw_interval="$FIREWALL_VERIFY_NORMAL"
        fi
        if [ "$now" -eq 0 ] || [ $((now - last_fw_epoch)) -ge "$fw_interval" ] 2>/dev/null; then
            if firewall_needs_repair "$VPN_IFACES"; then
                log "[VPN] firewall hook lost; repairing"
                repair_for_vpn_ifaces "$VPN_IFACES"
            fi
            last_fw_epoch="$now"
        fi
    fi

    # Slow safety-net only; sysctl values are not rewritten every few seconds.
    if [ "$now" -eq 0 ] || [ $((now - last_perf_epoch)) -ge "$PERF_REAPPLY_INTERVAL" ] 2>/dev/null; then
        apply_sysctls
        apply_network_performance
        last_perf_epoch="$now"
    fi

    if [ "$current_mode" = "BOOST" ]; then
        interval="$BOOST_SCAN_INTERVAL"
    elif [ "$screen_on" = "1" ]; then
        if [ -n "$VPN_IFACES" ]; then interval="$SCREEN_ON_VPN_INTERVAL"; else interval="$SCREEN_ON_IDLE_INTERVAL"; fi
    else
        if [ -n "$VPN_IFACES" ]; then interval="$SCREEN_OFF_VPN_INTERVAL"; else interval="$SCREEN_OFF_IDLE_INTERVAL"; fi
    fi

    write_adaptive_state "$current_mode" "$rate" "$screen_on" "$VPN_IFACES" "$interval"
    sleep "$interval"
done
