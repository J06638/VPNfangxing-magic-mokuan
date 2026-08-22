#!/system/bin/sh
ui_print "****************************************"
ui_print " NetFix All-in-One v4.2 自动适应版"
ui_print " VPN断流修复 + Wi-Fi/移动数据吞吐增强"
ui_print " 自动BOOST/BALANCED/ECO / 修复tunl0误判"
ui_print " 高流量自动提速 / 熄屏低流量省电"
ui_print " Magisk / KernelSU / APatch 通用结构"
ui_print "****************************************"
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/config.conf" 0 0 0644
