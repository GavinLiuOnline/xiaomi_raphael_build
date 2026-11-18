#!/bin/bash
set -e

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14] 🧠 配置 ZRAM Swap"

# Armbian's armbian-zram-config.service already provides zram0 (swap) and
# zram1 (/var/log). zram-tools' zramswap.service tries to set up the same
# zram0 and fails with "mkswap: /dev/zram0 is mounted". The board hook masks
# the unit; make sure it is not enabled either.
if [ -f rootdir/etc/default/zramswap ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 停用 zram-tools 的 zramswap（由 armbian-zram-config 管理 zram）"
    chroot rootdir systemctl disable zramswap 2> /dev/null || true
fi

# armbian-zram-config is enabled by default; keep it that way explicitly.
if [ -f rootdir/etc/default/armbian-zram-config ]; then
    sed -i 's/^#\?ENABLED=.*/ENABLED=true/' rootdir/etc/default/armbian-zram-config
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14] ✅ ZRAM 配置完成"
