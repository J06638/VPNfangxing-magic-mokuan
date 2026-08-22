#!/system/bin/sh
RUNDIR=/data/local/tmp/netfix_allinone_v4
PIDFILE="$RUNDIR/netfix.pid"
SYSSTATE="$RUNDIR/sysctl.state"
MTUSTATE="$RUNDIR/mtu.state"
PERFSTATE="$RUNDIR/perf.state"
WIFISTATE="$RUNDIR/wifi_powersave.state"
WIFIAUTOBASE="$RUNDIR/wifi_auto_base.state"

pid=$(cat "$PIDFILE" 2>/dev/null)
[ -n "$pid" ] && kill "$pid" 2>/dev/null
sleep 1

cleanup_family() {
    cmd="$1"
    [ -n "$cmd" ] || return 0
    chains=$("$cmd" -S 2>/dev/null | awk '$1=="-P" || $1=="-N" {print $2}')
    for c in $chains; do
        for child in NFIX_IN NFIX_OUT NFIX_FWD; do
            while "$cmd" -C "$c" -j "$child" >/dev/null 2>&1; do
                "$cmd" -D "$c" -j "$child" >/dev/null 2>&1 || break
            done
        done
    done
    for c in NFIX_IN NFIX_OUT NFIX_FWD; do
        "$cmd" -F "$c" >/dev/null 2>&1
        "$cmd" -X "$c" >/dev/null 2>&1
    done
    for parent in OUTPUT FORWARD; do
        child=NFIX_MSSO
        [ "$parent" = "FORWARD" ] && child=NFIX_MSSF
        while "$cmd" -t mangle -C "$parent" -j "$child" >/dev/null 2>&1; do
            "$cmd" -t mangle -D "$parent" -j "$child" >/dev/null 2>&1 || break
        done
    done
    for c in NFIX_MSSO NFIX_MSSF; do
        "$cmd" -t mangle -F "$c" >/dev/null 2>&1
        "$cmd" -t mangle -X "$c" >/dev/null 2>&1
    done
}

IPT=$(command -v iptables 2>/dev/null)
IP6T=$(command -v ip6tables 2>/dev/null)
cleanup_family "$IPT"
cleanup_family "$IP6T"

if [ -n "$IPT" ]; then
    while "$IPT" -t nat -C POSTROUTING -j NFIX_NAT >/dev/null 2>&1; do
        "$IPT" -t nat -D POSTROUTING -j NFIX_NAT >/dev/null 2>&1 || break
    done
    "$IPT" -t nat -F NFIX_NAT >/dev/null 2>&1
    "$IPT" -t nat -X NFIX_NAT >/dev/null 2>&1
fi

if [ -f "$MTUSTATE" ]; then
    while read iface mtu; do
        [ -n "$iface" ] || continue
        [ -e "/sys/class/net/$iface" ] || continue
        ip link set dev "$iface" mtu "$mtu" >/dev/null 2>&1 || ifconfig "$iface" mtu "$mtu" >/dev/null 2>&1
    done < "$MTUSTATE"
fi

if [ -f "$SYSSTATE" ]; then
    . "$SYSSTATE"
    [ -n "$IP_FORWARD" ] && echo "$IP_FORWARD" > /proc/sys/net/ipv4/ip_forward 2>/dev/null
    [ -n "$RP_ALL" ] && echo "$RP_ALL" > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null
    [ -n "$RP_DEFAULT" ] && echo "$RP_DEFAULT" > /proc/sys/net/ipv4/conf/default/rp_filter 2>/dev/null
    [ -n "$SRC_VALID_MARK" ] && echo "$SRC_VALID_MARK" > /proc/sys/net/ipv4/conf/all/src_valid_mark 2>/dev/null
fi

if [ -f "$PERFSTATE" ]; then
    while IFS='|' read path value; do
        [ -n "$path" ] || continue
        [ -e "$path" ] || continue
        echo "$value" > "$path" 2>/dev/null
    done < "$PERFSTATE"
fi

IWCMD=$(command -v iw 2>/dev/null)
if [ -n "$IWCMD" ] && [ -f "$WIFIAUTOBASE" ]; then
    while IFS='|' read iface state; do
        [ -n "$iface" ] || continue
        [ -e "/sys/class/net/$iface" ] || continue
        case "$state" in on|off) "$IWCMD" dev "$iface" set power_save "$state" >/dev/null 2>&1 ;; esac
    done < "$WIFIAUTOBASE"
fi
if [ -n "$IWCMD" ] && [ -f "$WIFISTATE" ]; then
    while IFS='|' read iface state; do
        [ -n "$iface" ] || continue
        [ -e "/sys/class/net/$iface" ] || continue
        case "$state" in on|off) "$IWCMD" dev "$iface" set power_save "$state" >/dev/null 2>&1 ;; esac
    done < "$WIFISTATE"
fi

rm -rf "$RUNDIR" 2>/dev/null
