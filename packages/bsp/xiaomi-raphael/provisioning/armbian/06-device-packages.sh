#!/bin/bash
# Armbian variant of 06-install-all-packages.sh.
#
# The base system and the desktop environment (and their packages) are already
# installed by the Armbian build framework, so this script only installs the
# device specific bits: QCOM userspace debs, sensor debs, ALSA UCM config and
# the systemd stop-timeout drop-ins that keep shutdown from hanging.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROVISION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEB_DIR="${QCOM_DEB_DIR:-$PROVISION_DIR/debs}"
ALSA_DEB="${ALSA_DEB:-$PROVISION_DIR/alsa-xiaomi-raphael.deb}"

export DEBIAN_FRONTEND=noninteractive

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] 📦 安装设备专用软件包"

chroot rootdir apt-get update

DEVICE_PACKAGES="wpasupplicant iw iproute2 alsa-ucm-conf alsa-utils \
	power-profiles-daemon gpsd gpsd-clients libmbim-utils liblzma5 \
	libprotobuf-c1 dnsmasq iptables zram-tools \
	plymouth plymouth-themes plymouth-label"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 设备包: $(echo "$DEVICE_PACKAGES" | tr -s ' \n' ' ')"
chroot rootdir apt-get install -y $DEVICE_PACKAGES

# ---------------------------------------------------------------- QCOM debs
install_qcom_local_debs() {
	local deb_dir="$1"
	local required=(
		libqrtr1_*_arm64.deb
		qrtr-tools_*_arm64.deb
		rmtfs_*_arm64.deb
		protection-domain-mapper_*_arm64.deb
		tqftpserv_*_arm64.deb
		audioreach-topology_*_all.deb
		modemmanager-qrtr-sm8150_*_jammy_arm64.deb
	)

	local missing=0
	for pattern in "${required[@]}"; do
		if ! compgen -G "$deb_dir/$pattern" >/dev/null; then
			echo "[06] ❌ 缺少: $deb_dir/$pattern" >&2
			missing=1
		fi
	done
	if [ "$missing" -ne 0 ]; then
		exit 1
	fi

	local mm_deb
	mm_deb="$(ls -1 "$deb_dir"/modemmanager-qrtr-sm8150_*_jammy_arm64.deb 2>/dev/null | sort -V | tail -1)"
	echo "[06]   └─ ModemManager: $(basename "$mm_deb") (QMAPv4 patch, 禁用 v5)"

	chroot rootdir sh -c "apt-get remove -y --allow-remove-essential \
		modemmanager libqmi-utils libqmi-proxy libqmi-glib5"

	mkdir -p rootdir/tmp/qcom-debs
	cp "$deb_dir"/libqrtr1_*_arm64.deb rootdir/tmp/qcom-debs/
	cp "$deb_dir"/qrtr-tools_*_arm64.deb \
		"$deb_dir"/rmtfs_*_arm64.deb \
		"$deb_dir"/protection-domain-mapper_*_arm64.deb \
		"$deb_dir"/tqftpserv_*_arm64.deb \
		"$deb_dir"/audioreach-topology_*_all.deb \
		rootdir/tmp/qcom-debs/
	cp "$mm_deb" rootdir/tmp/qcom-debs/

	chroot rootdir sh -c "dpkg -i /tmp/qcom-debs/libqrtr1_*_arm64.deb"
	chroot rootdir sh -c "dpkg -i /tmp/qcom-debs/qrtr-tools_*_arm64.deb \
		/tmp/qcom-debs/rmtfs_*_arm64.deb \
		/tmp/qcom-debs/protection-domain-mapper_*_arm64.deb \
		/tmp/qcom-debs/tqftpserv_*_arm64.deb"
	chroot rootdir sh -c '
		export DEBIAN_FRONTEND=noninteractive
		dpkg -i --auto-deconfigure /tmp/qcom-debs/modemmanager-qrtr-sm8150_*.deb
		apt-get install -f -y
	'
	chroot rootdir sh -c "dpkg -i /tmp/qcom-debs/audioreach-topology_*_all.deb"
	chroot rootdir apt-get install -f -y
	rm -rf rootdir/tmp/qcom-debs

	mkdir -p rootdir/var/lib/rmtfs

	chroot rootdir systemctl enable qrtr-ns.service
	chroot rootdir systemctl disable rmtfs-dir.service 2>/dev/null || true
	chroot rootdir systemctl mask rmtfs-dir.service 2>/dev/null || true
	chroot rootdir systemctl unmask rmtfs.service 2>/dev/null || true
	chroot rootdir systemctl enable rmtfs.service pd-mapper.service tqftpserv.service

	# rmtfs/tqftpserv 关机时常卡在 QRTR 收发包；超时后 SIGKILL 可接受。
	for unit in rmtfs tqftpserv; do
		install -d "rootdir/etc/systemd/system/${unit}.service.d"
		cat > "rootdir/etc/systemd/system/${unit}.service.d/zz-raphael-timeout-stop.conf" << 'EOF'
[Service]
TimeoutStopSec=3
EOF
	done

	install -d rootdir/etc/systemd/system/ModemManager.service.d
	cat > rootdir/etc/systemd/system/ModemManager.service.d/zz-raphael-timeout-stop.conf << 'EOF'
[Service]
TimeoutStopSec=3
EOF

	install -d rootdir/etc/systemd/system/hexagonrpcd-sdsp.service.d
	cat > rootdir/etc/systemd/system/hexagonrpcd-sdsp.service.d/zz-raphael-timeout-stop.conf << 'EOF'
[Service]
TimeoutStopSec=3
TimeoutStartSec=15
EOF

	install -d rootdir/etc/systemd/system/user@.service.d
	cat > rootdir/etc/systemd/system/user@.service.d/zz-raphael-timeout-stop.conf << 'EOF'
[Service]
TimeoutStopSec=3
EOF

	install -d rootdir/etc/systemd/system/gdm.service.d
	cat > rootdir/etc/systemd/system/gdm.service.d/zz-raphael-timeout-stop.conf << 'EOF'
[Service]
TimeoutStopSec=3
EOF

	install -d rootdir/etc/systemd/system/unattended-upgrades.service.d
	cat > rootdir/etc/systemd/system/unattended-upgrades.service.d/zz-raphael-timeout-stop.conf << 'EOF'
[Service]
TimeoutStopSec=5
EOF

	install -d rootdir/etc/systemd/system.conf.d
	cat > rootdir/etc/systemd/system.conf.d/raphael-timeout.conf << 'EOF'
[Manager]
DefaultTimeoutStopSec=8s
EOF
}

install_qcom_local_debs "$DEB_DIR"

# -------------------------------------------------------------- sensor debs
install_sensor_local_debs() {
	local deb_dir="$1"

	mkdir -p rootdir/tmp/sensor-debs
	cp "$(ls -1v "$deb_dir"/libssc0_*_arm64.deb | tail -1)" \
		"$(ls -1v "$deb_dir"/hexagonrpcd_*_arm64.deb | tail -1)" \
		"$(ls -1v "$deb_dir"/iio-sensor-proxy_*_arm64.deb | tail -1)" \
		rootdir/tmp/sensor-debs/

	# 替换发行版自带的无 SSC 版 iio-sensor-proxy
	chroot rootdir apt-get remove -y iio-sensor-proxy 2>/dev/null || true

	chroot rootdir apt-get install -y libprotobuf-c1
	chroot rootdir sh -c '
		export DEBIAN_FRONTEND=noninteractive
		dpkg -i /tmp/sensor-debs/libssc0_*_arm64.deb \
			/tmp/sensor-debs/hexagonrpcd_*_arm64.deb \
			/tmp/sensor-debs/iio-sensor-proxy_*_arm64.deb || true
		apt-get install -f -y
	'
	rm -rf rootdir/tmp/sensor-debs
}

install_sensor_local_debs "$DEB_DIR"

if [[ "$DISTRIBUTION" == "Debian" ]]; then
	sed -i '/ConditionKernelVersion/d' rootdir/lib/systemd/system/pd-mapper.service 2>/dev/null || true
fi

# --------------------------------------------------------------- ALSA UCM
if [ -f "$ALSA_DEB" ]; then
	echo "[06]   └─ 安装 ALSA 配置 (alsa-xiaomi-raphael)"
	cp "$ALSA_DEB" rootdir/tmp/
	chroot rootdir apt-get install -y /tmp/alsa-xiaomi-raphael.deb \
		|| chroot rootdir sh -c 'dpkg -i /tmp/alsa-xiaomi-raphael.deb; apt-get install -fy'
	rm -f rootdir/tmp/alsa-xiaomi-raphael.deb

	if ! chroot rootdir dpkg -s alsa-xiaomi-raphael >/dev/null 2>&1; then
		echo "[06] ❌ alsa-xiaomi-raphael 未安装成功，设备声音会异常，终止构建" >&2
		exit 1
	fi

	# 麦克风守卫：WirePlumber/PulseAudio 在枚举 profile 时会先 open("hw:0,2")
	# 探测采集设备。Q6 采集路由必须已经在 SectionVerb 里建立，否则探测返回
	# EINVAL，整个采集设备被丢弃，设备表现为"没有麦克风"。
	UCM_HIFI="rootdir/usr/share/alsa/ucm2/conf.d/sm8150_raphael/HiFi.conf"
	ucm_ok=1
	grep -q 'SectionDevice."Mic"' "$UCM_HIFI" 2>/dev/null || ucm_ok=0
	grep -q 'CapturePCM "hw:0,2"' "$UCM_HIFI" 2>/dev/null || ucm_ok=0
	sed -n '/^SectionVerb/,/^SectionDevice/p' "$UCM_HIFI" 2>/dev/null \
		| grep -q "MultiMedia3 Mixer SLIMBUS_0_TX" || ucm_ok=0
	if [ "$ucm_ok" != 1 ]; then
		echo "[06] ❌ $UCM_HIFI 缺少采集路由（SectionVerb 内的 MultiMedia3 Mixer SLIMBUS_0_TX，或 Mic/CapturePCM），设备将没有麦克风，终止构建" >&2
		exit 1
	fi
	echo "[06]   └─ UCM 采集路由校验通过 ✅"
else
	echo "[06] ❌ 缺少 $(basename "$ALSA_DEB")，设备声音会异常，终止构建" >&2
	exit 1
fi

# 桌面自动登录（13c Remote Login 在 GNOME 下会改回关闭）
if [[ "$SYSTEM_TYPE" != *"server"* ]]; then
	if [[ "$DESKTOP_ENV" == "gnome" ]]; then
		install -d rootdir/etc/gdm3
		cat > rootdir/etc/gdm3/custom.conf << EOF
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=${USER_NAME:-user}
EOF
	elif [[ "$DESKTOP_ENV" == "xfce" ]]; then
		install -d rootdir/etc/lightdm/lightdm.conf.d
		cat > rootdir/etc/lightdm/lightdm.conf.d/90-raphael-autologin.conf << EOF
[Seat:*]
autologin-user=${USER_NAME:-user}
autologin-user-timeout=0
autologin-session=xfce
EOF
		# light-locker 在 X 屏保（600 s）触发后经 lightdm Session.Lock 建 greeter，
		# 设备会无故跳回登录页。构建期还没有 /home/user（首启才建用户），因此直接
		# 隐藏系统级 autostart。
		if [ -f rootdir/etc/xdg/autostart/light-locker.desktop ]; then
			grep -qx 'Hidden=true' rootdir/etc/xdg/autostart/light-locker.desktop || \
				echo 'Hidden=true' >> rootdir/etc/xdg/autostart/light-locker.desktop
			echo "[06]   └─ 已禁用 light-locker 自动锁屏"
		fi
	fi
	chroot rootdir systemctl disable brltty.service 2>/dev/null || true
	chroot rootdir systemctl mask brltty.service 2>/dev/null || true
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ✅ 设备软件包安装完成"
