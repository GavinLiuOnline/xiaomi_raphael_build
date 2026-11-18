#!/bin/bash
# Raphael SLPI DIAG：通过 deb 安装
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEB_DIR="${SENSOR_DEB_DIR:-$SCRIPT_DIR/../debs}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10d] 📋 安装 DIAG deb"

install_one() {
	local pattern="$1"
	local deb
	deb="$(ls -1v "$DEB_DIR"/$pattern 2>/dev/null | tail -1)" || true
	if [ -z "$deb" ]; then
		echo "[10d] ❌ 缺少: $DEB_DIR/$pattern" >&2
		exit 1
	fi
	mkdir -p rootdir/tmp/diag-pkgs
	cp "$deb" rootdir/tmp/diag-pkgs/
	chroot rootdir dpkg -i "/tmp/diag-pkgs/$(basename "$deb")" || \
		chroot rootdir dpkg -i --force-depends "/tmp/diag-pkgs/$(basename "$deb")"
}

install_one 'diag-router_*_arm64.deb'
install_one 'diag-xiaomi-raphael_*_arm64.deb'

chroot rootdir apt-get install -f -y
rm -rf rootdir/tmp/diag-pkgs

# ---------------------------------------------------------------------------
# SLPI 必须保持运行：diag deb 的 raphael-diag-router.service 用 ExecStartPost 在
# 开机时 `echo stop > remoteproc0/state` 再重启 SLPI，实测重启失败后 SLPI 永久
# offline —— 于是 hexagonrpcd/传感器全部失败，且 SLIMbus QMI 拿不到服务，
# wcd9340 不枚举、没有声卡。这里取消该开机 reattach（需要时仍可手动跑脚本）。
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10d]   └─ 取消开机 SLPI reattach"
install -d rootdir/etc/systemd/system/raphael-diag-router.service.d
cat > rootdir/etc/systemd/system/raphael-diag-router.service.d/no-reattach.conf << 'EOF'
[Service]
# 空赋值清除 deb 里的 ExecStartPost=...raphael-diag-slpi-reattach.sh
ExecStartPost=
EOF

# SLIMbus 控制器不能随 udev 早加载：此时 SLPI 刚起来，QMI 服务未就绪，
# qmi init 1s 超时后驱动直接放弃，之后永不重试（声卡永远不出现）。
# 改为在 SLPI running 且稳定后由 unit 显式加载。
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10d]   └─ SLIMbus 延后到 SLPI 就绪后加载"
install -d rootdir/etc/modprobe.d
cat > rootdir/etc/modprobe.d/raphael-slimbus-delay.conf << 'EOF'
# Loaded explicitly by raphael-slimbus-init.service once SLPI is up.
blacklist slim_qcom_ngd_ctrl
EOF

cat > rootdir/usr/local/sbin/raphael-slimbus-init.sh << 'EOF'
#!/bin/sh
# Load the SLIMbus NGD controller only after SLPI (remoteproc0) is running and
# its QMI services are published. Loading it earlier times out (-110), so
# wcd9340 never enumerates and snd-sm8150-raphael stays deferred (-517).
set -eu

i=0
while [ "$i" -lt 60 ]; do
	[ "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" = running ] && break
	i=$((i + 1))
	sleep 1
done
if [ "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" != running ]; then
	echo "raphael-slimbus-init: SLPI not running after ${i}s" >&2
	exit 1
fi

# SLPI needs a few seconds past "running" to serve the slimbus QMI service.
sleep 10
modprobe slim_qcom_ngd_ctrl
echo "raphael-slimbus-init: slimbus controller loaded"
EOF
chmod 755 rootdir/usr/local/sbin/raphael-slimbus-init.sh

cat > rootdir/etc/systemd/system/raphael-slimbus-init.service << 'EOF'
[Unit]
Description=Raphael load SLIMbus controller after SLPI is ready
After=raphael-diag-router.service
Wants=raphael-diag-router.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/raphael-slimbus-init.sh

[Install]
WantedBy=multi-user.target
EOF
chroot rootdir systemctl enable raphael-slimbus-init.service

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10d] ✅ DIAG deb 安装完成"
