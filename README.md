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

## 下载

最新版刷入包：`墙梯节点WiFi数据放行优化模块-All-v4.2省电自适应版.zip`

## 安装

1. 下载最新版 ZIP。
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

## License

MIT License。详见 `LICENSE`。

作者：故事予你
