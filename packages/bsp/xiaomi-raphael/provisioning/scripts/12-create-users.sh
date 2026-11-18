#!/bin/bash
set -e

ROOT_PASS="${ROOT_PASS:-1234}"
USER_NAME="${USER_NAME:-user}"
USER_PASS="${USER_PASS:-1234}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [12] 👤 创建用户和配置 SSH"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [12]   └─ 创建用户: ${USER_NAME}"
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [12]   └─ 启用 SSH 密码登录"

echo "root:${ROOT_PASS}" | chroot rootdir chpasswd
chroot rootdir useradd -m -G sudo,audio,input,video -s /bin/bash "${USER_NAME}"
# 蓝牙 / GPU(render) / U 盘(plugdev) 等桌面常用权限组，存在才加入
for grp in render plugdev bluetooth netdev; do
	if chroot rootdir getent group "${grp}" > /dev/null 2>&1; then
		chroot rootdir usermod -aG "${grp}" "${USER_NAME}"
	fi
done
# Armbian 打包镜像时会排除 /home/*，这里再显式确保家目录存在
chroot rootdir install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "/home/${USER_NAME}"
echo "${USER_NAME}:${USER_PASS}" | chroot rootdir chpasswd

echo "PermitRootLogin yes" >> rootdir/etc/ssh/sshd_config
echo "PasswordAuthentication yes" >> rootdir/etc/ssh/sshd_config

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [12] ✅ 用户创建完成"
