# NetFix All-in-One / 安卓 VPN 放行解速模块

适用于 Magisk / KernelSU / APatch 的 Android 网络修复与吞吐优化模块。

当前版本：**v4.2 自动适应版**

## 功能

- 修复部分 Root / 隐藏环境 / 网络规则异常导致的 VPN 连接后瞬间有流量、随后断流问题。
- 支持常见 TUN / WireGuard / IPsec 接口的 IPv4 / IPv6 放行。
- 自动配置 TCP 拥塞控制（优先 BBR，回退 CUBIC）、fq、socket buffer、network backlog、PMTU 与 MSS clamp。
- 根据 **实时流量 + 屏幕状态 + VPN 状态** 自动在 BOOST / BALANCED / ECO 三档之间切换。
- 高流量时临时提高网络性能；低流量或熄屏待机时恢复 Wi-Fi 原始省电状态并降低轮询频率。
- 排除 `tunl0`、`ip6tnl0`、`gre0`、`gretap0`、`erspan0`、`sit0` 等内核占位隧道，避免误判为真实 VPN。
- 卸载时恢复模块修改过的 sysctl、MTU 与 Wi-Fi power-save 状态。

## 自动模式

### BOOST

实时总流量达到约 **512 KiB/s（约 4.2 Mbps）** 自动进入。高流量期间保持快速采样，并在设备支持时临时关闭 Wi-Fi Power Save。

### BALANCED

亮屏但没有持续大流量时使用。恢复系统/安装前 Wi-Fi 省电状态，同时保持较快的 VPN 接口变化检测。

### ECO

熄屏且低流量时自动进入。恢复 Wi-Fi 原始省电状态，显著降低守护与防火墙校验频率，减少待机耗电。

## v4.2 关键参数

```ini
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
DISABLE_WIFI_POWERSAVE=0
```

完整配置见 `module/config.conf`。

## 安装

1. 下载仓库 `dist/` 目录中的最新 ZIP。
2. 在 Magisk / KernelSU / APatch 模块管理器中刷入。
3. 重启手机。
4. 如从旧版升级，可直接覆盖安装。

## 查看运行状态

在支持模块操作按钮的管理器中点击“操作”，可查看当前 AUTO 模式、实时流量、扫描间隔、VPN 接口和最近日志。

也可以使用 Root 终端查看：

```sh
su
ps -A | grep netfix
cat /data/local/tmp/netfix_allinone_v4/netfix.log | tail -n 50
```

## 兼容性

- Android Root 环境
- Magisk
- KernelSU
- APatch

已在一加设备环境中测试；不同厂商 ROM、内核、防火墙实现可能存在差异。

## 注意

- 本模块会修改网络 sysctl、iptables/ip6tables、VPN 接口 MTU 等低层参数，请先确认具备恢复 Root 环境的能力。
- 不建议将 `DISABLE_WIFI_POWERSAVE` 手动改为 `1` 长期使用，否则可能增加待机耗电。
- 网络速度受运营商、Wi-Fi AP、VPN 节点、系统内核和链路质量共同影响，本模块不能突破物理带宽或服务端限速。

## 源码

完整模块源码位于 `module/` 目录，可直接审计 `service.sh`、`action.sh`、`uninstall.sh` 与 `config.conf`。

## License

MIT License。详见 `LICENSE`。

作者：故事予你
