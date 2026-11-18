#!/bin/bash
# Device provisioning adapter for the Armbian image chroot.
#
# The scripts in ../scripts were written for a hand rolled debootstrap build:
# they expect the root filesystem to be mounted at "rootdir/" and use
# "chroot rootdir <cmd>". Inside the Armbian image there is no nested rootdir:
# we run in the target rootfs itself, so "rootdir" is symlinked to "/" and the
# chroot helper is replaced by an exported shell function that just runs the
# command in place.
#
# Usage: run.sh <release> <build_desktop> <desktop_env> <distribution>
set -e

RELEASE="${1:?release is required}"
BUILD_DESKTOP="${2:-no}"
DESKTOP_ENV="${3:-xfce}"
DISTRIBUTION="${4:-Ubuntu}"

WORK_DIR="/tmp/raphael-provision"

if [[ "${DISTRIBUTION}" == "Debian" ]]; then
	DEBIAN_VERSION="${RELEASE}"
	UBUNTU_VERSION=""
	SYSTEM_TYPE="debian-server"
	DESKTOP_ENV=""
	if [[ "${BUILD_DESKTOP}" == "yes" ]]; then
		DESKTOP_ENV="${3:-xfce}"
		SYSTEM_TYPE="debian-${DESKTOP_ENV}"
	fi
else
	DEBIAN_VERSION=""
	UBUNTU_VERSION="${RELEASE}"
	SYSTEM_TYPE="ubuntu-server"
	DESKTOP_ENV=""
	if [[ "${BUILD_DESKTOP}" == "yes" ]]; then
		DESKTOP_ENV="${3:-xfce}"
		SYSTEM_TYPE="ubuntu-${DESKTOP_ENV}"
	fi
fi

export SYSTEM_TYPE DESKTOP_ENV DISTRIBUTION DEBIAN_VERSION UBUNTU_VERSION
export HOSTNAME="xiaomi-raphael"
export USER_NAME="${USER_NAME:-user}"
export USER_PASS="${USER_PASS:-1234}"
export ROOT_PASS="${ROOT_PASS:-1234}"
export TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
export LANG_DEFAULT="${LANG_DEFAULT:-zh_CN.UTF-8}"
export DEBIAN_FRONTEND="noninteractive"

# chroot rootdir <cmd>  ->  <cmd>
function chroot() {
	shift
	"$@"
}
export -f chroot

rm -rf "${WORK_DIR}"
cp -a /usr/share/raphael-provision "${WORK_DIR}"
cd "${WORK_DIR}"
ln -sfn / rootdir
chmod +x scripts/*.sh armbian/*.sh

echo "[raphael-provision] system=${SYSTEM_TYPE} desktop=${DESKTOP_ENV} release=${RELEASE}"

# Base packages / desktop are provided by Armbian; install only device bits.
bash "${WORK_DIR}/armbian/06-device-packages.sh"

# Same order as xiaomi_raphael_build_rootfs/build.sh, minus bootstrap/image/
# kernel-install/cleanup/packaging steps which Armbian already did.
for script in \
	04-config-network.sh \
	06b-config-audio.sh \
	07-config-locale.sh \
	08-add-screen-commands.sh \
	08b-config-plymouth.sh \
	10-config-ncm.sh \
	10b-config-modem.sh \
	10c-config-sensors.sh \
	10d-config-diag.sh \
	10e-config-gps.sh \
	10f-config-imu-gpsd.sh \
	11-config-fstab.sh \
	12-create-users.sh \
	13-config-power.sh \
	13b-config-power-key.sh \
	13c-config-remote-desktop.sh \
	14-config-zram.sh; do
	echo "[raphael-provision] === ${script} ==="
	bash "${WORK_DIR}/scripts/${script}"
done

# GNOME Snapshot opens the camera with the default 1024 fd limit and dies with
# EMFILE while libcamera probes the sensor; raise the limit for that app only.
SNAPSHOT_DESKTOP="/usr/share/applications/org.gnome.Snapshot.desktop"
if [[ -f "${SNAPSHOT_DESKTOP}" ]]; then
	sed -i -E 's|^Exec=(/usr/bin/)?snapshot|Exec=prlimit --nofile=65536:65536 /usr/bin/snapshot|' \
		"${SNAPSHOT_DESKTOP}"
fi

echo "[raphael-provision] rebuilding initramfs"
update-initramfs -c -k all

# The stock recovery's update-binary is an old minzip that cannot read ZIP64
# archives, so system.img (and the whole zip) must stay below 4 GiB. The apt
# archives and package lists downloaded above take a few hundred megabytes and
# are useless on the phone; drop them before the image is assembled.
echo "[raphael-provision] cleaning apt caches"

# Kernel headers are a build-time artifact; they are never used on the phone and
# cost ~85 MB inside the 4 GiB budget.
if dpkg -s linux-headers-current-sm8150 > /dev/null 2>&1; then
	echo "[raphael-provision] removing kernel headers"
	apt-get -q purge -y linux-headers-current-sm8150
fi

# Packages the desktop tiers install that this phone either cannot use or that
# cost hundreds of megabytes of the 4 GiB budget:
#   * Vulkan ICDs (~140 MB): the Adreno GPU uses Mesa's freedreno GL driver;
#     XFCE never touches Vulkan.
#   * compiler toolchain + dkms (~200 MB): kernel modules are built in the
#     Armbian build, headers are not shipped and nothing compiles on the phone.
#   * armbian-imager (~12 MB): an SD-card flasher, useless on a phone, and it
#     drags in WebKitGTK + JavaScriptCore (~130 MB) for its UI.
#   * git (~37 MB): developer-only payload.
#
# Deliberately NOT purged even though they look like build tooling, because
# they are runtime dependencies of the desktop / device stack:
#   * cpp / cpp-15: x11-xserver-utils depends on cpp, and xfce4-session depends
#     on x11-xserver-utils. Purging cpp cascades into xfce4-session, xfce4,
#     xfwm4, xfce4-panel, ... being removed and leaves the phone without a DE.
#   * unicode-data: python3-fonttools depends on it, python3-matplotlib depends
#     on python3-fonttools and gpsd-clients depends on python3-matplotlib.
#     Purging it silently removes gpsd-clients and breaks GPS.
RAPHAEL_PURGE_PKGS=(
	mesa-vulkan-drivers vulkan-tools mesa-utils
	glmark2-x11 glmark2-es2-x11 glmark2-wayland glmark2-es2-wayland
	dkms gcc g++ gcc-15 g++-15
	gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
	gcc-15-aarch64-linux-gnu g++-15-aarch64-linux-gnu
	libstdc++-15-dev libgcc-15-dev
	git armbian-imager
	# Help browser + docs pull in WebKitGTK (4.1 and 6.0, ~220 MB together).
	yelp gnome-user-docs ubuntu-docs
)
RAPHAEL_PURGE_INSTALLED=()
for pkg in "${RAPHAEL_PURGE_PKGS[@]}"; do
	dpkg -s "${pkg}" > /dev/null 2>&1 && RAPHAEL_PURGE_INSTALLED+=("${pkg}")
done
if [[ ${#RAPHAEL_PURGE_INSTALLED[@]} -gt 0 ]]; then
	echo "[raphael-provision] purging ${#RAPHAEL_PURGE_INSTALLED[@]} non-device packages"
	apt-get -q purge -y "${RAPHAEL_PURGE_INSTALLED[@]}" || echo "[raphael-provision] WARNING: purge failed, see apt output above"
fi
apt-get -q autoremove --purge -y || echo "[raphael-provision] WARNING: autoremove failed, see apt output above"

# Hard guard: a trim step must never take the desktop or the GPS stack with it.
# Failing here is much better than shipping an image that boots to a greeter.
RAPHAEL_REQUIRED_PKGS=(gpsd gpsd-clients)
if [[ "${BUILD_DESKTOP}" == "yes" ]]; then
	RAPHAEL_REQUIRED_PKGS+=(lightdm xfce4-session xfwm4 xfce4-panel xfdesktop4 xfce4-settings xfce4-appfinder)
fi
RAPHAEL_MISSING_PKGS=()
for pkg in "${RAPHAEL_REQUIRED_PKGS[@]}"; do
	dpkg -s "${pkg}" > /dev/null 2>&1 || RAPHAEL_MISSING_PKGS+=("${pkg}")
done
if [[ ${#RAPHAEL_MISSING_PKGS[@]} -gt 0 ]]; then
	echo "[raphael-provision] ERROR: trim removed required packages: ${RAPHAEL_MISSING_PKGS[*]}" >&2
	exit 1
fi

apt-get -q clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/partial

# Ship only Chinese/English translations and no documentation; this is a phone
# image with a hard 4 GiB budget and these files are never read at runtime.
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
	! -name 'en*' ! -name 'zh*' -exec rm -rf {} + 2> /dev/null || true

rm -f rootdir
cd /
rm -rf "${WORK_DIR}"

echo "[raphael-provision] done"
