# Changelog

## v4.2 - 2026-08-22

- 新增基于实时流量、屏幕状态和 VPN 状态的 BOOST / BALANCED / ECO 自动性能档。
- 高流量达到 512 KiB/s 自动进入 BOOST，低流量采用 128 KiB/s 退出阈值并保留 20 秒防抖。
- BOOST 时按需临时关闭 Wi-Fi Power Save，退出后恢复安装前/系统原始状态。
- 熄屏低流量时将接口轮询降低到 30–60 秒，防火墙完整校验降低到 300 秒。
- 排除 tunl0、ip6tnl0、gre0、gretap0、erspan0、sit0 等内核占位隧道，避免误判 VPN。
- 仅对真实 UP/IFF_UP 的常见 VPN 接口应用修复。
- 防火墙从高频全量扫描改为“接口变化立即修复 + 定时轻量校验 + 规则丢失时重建”。
- 网络 sysctl 从 30 秒反复写入调整为启动/BOOST/30 分钟兜底复查。
- 保留 BBR/CUBIC、fq、buffer、backlog、PMTU、MSS clamp、IPv4/IPv6、TUN/WireGuard/IPsec 兼容逻辑。
- 卸载时恢复 sysctl、MTU 与 Wi-Fi power-save 基线状态。

## v4.1

- 修复 tunl0 被误识别为真实 VPN 的问题。
- 默认不再永久关闭 Wi-Fi Power Save。
- 降低无 VPN 与熄屏时的守护频率。

## v4.0

- VPN 瞬断流修复与 Wi-Fi / 移动数据吞吐增强整合版。
