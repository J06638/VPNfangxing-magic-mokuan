NetFix All-in-One v4.2 自动适应版

核心逻辑：不是“亮屏永远激进、熄屏永远省电”，而是按真实上下行流量 + 屏幕状态 + VPN状态自动切换。

【BOOST 高性能】
- 实时总流量达到 512 KiB/s（约4.2Mbps）自动进入。
- 临时关闭 Wi-Fi Power Save（设备/iw支持时）。
- 保留 BBR/CUBIC、fq、buffer、backlog、PMTU、MSS clamp。
- 3秒轻量采样，VPN防火墙30秒校验。
- 熄屏下载/视频/大文件仍可保持BOOST，不会因为灭屏强制降速。

【BALANCED 平衡】
- 亮屏但没有持续大流量时使用。
- Wi-Fi省电恢复系统/安装前原始状态。
- 无VPN3秒、存在VPN5秒做轻量接口检测。

【ECO 待机】
- 熄屏且低流量时自动进入。
- Wi-Fi省电恢复系统/安装前原始状态，不再长期power_save off。
- 无VPN60秒、存在VPN30秒轻量检查。
- 防火墙完整校验降到300秒，只有检测到规则真的丢失才修复。

【防抖】
- 进入BOOST阈值：524288 B/s。
- 退出阈值：131072 B/s。
- 低流量后继续保持BOOST 20秒，避免视频分片/网页突发流量导致反复切换。

【继续保留v4.1修复】
- 排除 tunl0/ip6tnl0/gre0/gretap0/erspan0/sit0 等内核占位隧道。
- 只有真实UP/IFF_UP的常见VPN接口才进入VPN修复。
- 不再2秒不停全量扫描iptables。
- sysctl仅启动、进入BOOST和30分钟兜底时复查。
- 卸载恢复sysctl、MTU以及Wi-Fi原始power-save状态。

可在KernelSU/Magisk模块“操作”按钮查看当前 AUTO 模式、实时B/s、扫描间隔和最近日志。
