#!/system/bin/sh
MODDIR=${0%/*}
RUNDIR=/data/local/tmp/netfix_allinone_v4
LOG="$RUNDIR/netfix.log"
CONFIG="$MODDIR/config.conf"
[ -f "$CONFIG" ] && . "$CONFIG"

echo "========== NetFix v4.2 自动适应版 =========="
echo "时间: $(date)"
echo "Android: $(getprop ro.build.version.release 2>/dev/null) / SDK $(getprop ro.build.version.sdk 2>/dev/null)"
echo "Kernel: $(uname -r 2>/dev/null)"
echo "守护PID: $(cat "$RUNDIR/netfix.pid" 2>/dev/null)"
echo

echo "--- 自动适应状态 ---"
if [ -f "$RUNDIR/adaptive.state" ]; then
    cat "$RUNDIR/adaptive.state"
else
    echo "尚无 adaptive.state；安装后重启一次。"
fi
echo
echo "阈值: BOOST进入=${BOOST_ENTER_BPS:-524288}B/s 退出=${BOOST_EXIT_BPS:-131072}B/s 保持=${BOOST_HOLD_SECONDS:-20}s"
echo "间隔: BOOST=${BOOST_SCAN_INTERVAL:-3}s 亮屏=${SCREEN_ON_IDLE_INTERVAL:-3}/${SCREEN_ON_VPN_INTERVAL:-5}s 熄屏=${SCREEN_OFF_IDLE_INTERVAL:-60}/${SCREEN_OFF_VPN_INTERVAL:-30}s"
echo "自动Wi-Fi性能切换: ${ADAPTIVE_WIFI_POWER:-1}; 始终关闭Wi-Fi省电: ${DISABLE_WIFI_POWERSAVE:-0}"
echo
echo "--- 网络性能 ---"
echo "拥塞控制: $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
echo "可用算法: $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
echo "默认qdisc: $(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
echo "rmem_max: $(cat /proc/sys/net/core/rmem_max 2>/dev/null)"
echo "wmem_max: $(cat /proc/sys/net/core/wmem_max 2>/dev/null)"
echo "netdev_max_backlog: $(cat /proc/sys/net/core/netdev_max_backlog 2>/dev/null)"
echo

echo "--- Wi-Fi ---"
IWCMD=$(command -v iw 2>/dev/null)
for p in /sys/class/net/*; do
    [ -e "$p" ] || continue
    n=${p##*/}; lc=$(echo "$n" | tr 'A-Z' 'a-z')
    case "$lc" in wlan*|wifi*|swlan*)
        echo "$n state=$(cat /sys/class/net/$n/operstate 2>/dev/null) mtu=$(cat /sys/class/net/$n/mtu 2>/dev/null)"
        [ -n "$IWCMD" ] && "$IWCMD" dev "$n" get power_save 2>/dev/null
    ;; esac
done

echo
echo "--- VPN候选（仅UP/UNKNOWN且IFF_UP；排除tunl0/gre0等）---"
IPCMD=$(command -v ip 2>/dev/null)
found=0
for p in /sys/class/net/*; do
    [ -e "$p" ] || continue
    n=${p##*/}; lc=$(echo "$n" | tr 'A-Z' 'a-z')
    case "$lc" in
        tunl*|ip6tnl*|gre*|gretap*|erspan*|sit*|ip_vti*|ip6_vti*) continue ;;
        tun[0-9]*|tap[0-9]*|wg[0-9]*|vpn[0-9]*|ppp[0-9]*|ipsec[0-9]*|vti[0-9]*|xfrm[0-9]*|clash*|mihomo*|singbox*|sing-*|tailscale*|warp*|zt*) ;;
        *) continue ;;
    esac
    state=$(cat "/sys/class/net/$n/operstate" 2>/dev/null)
    case "$state" in up|unknown) ;; *) continue ;; esac
    if [ -n "$IPCMD" ]; then "$IPCMD" link show dev "$n" 2>/dev/null | grep -q '<[^>]*UP' || continue; fi
    found=1
    echo "$n state=$state mtu=$(cat /sys/class/net/$n/mtu 2>/dev/null)"
done
[ "$found" = "0" ] && echo "当前没有活动VPN接口"

echo
echo "--- NetFix IPv4 chains ---"
iptables -S NFIX_IN 2>/dev/null
iptables -S NFIX_OUT 2>/dev/null
iptables -S NFIX_FWD 2>/dev/null
iptables -t nat -S NFIX_NAT 2>/dev/null
iptables -t mangle -S NFIX_MSSO 2>/dev/null

echo
echo "--- 最近日志 ---"
if [ -f "$LOG" ]; then tail -n 80 "$LOG"; else echo "尚无日志；安装后重启一次再查看。"; fi
