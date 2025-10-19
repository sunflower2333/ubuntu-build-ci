#!/bin/sh

# System Info
export DISTRO=jammy
export ARCH=arm64
export MIRROR='https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/'
export ROOTFS_DIR="$PWD/ubuntu-${DISTRO}-${ARCH}-rootfs"
export OUT_TAR="$PWD/${DISTRO}-${ARCH}-rootfs.tar.gz"

# Get minimal rootfs
sudo debootstrap --arch="$ARCH" --variant=minbase "$DISTRO" "$ROOTFS_DIR" "$MIRROR"

# Set apt source list
cat > $ROOTFS_DIR/etc/apt/sources.list <<EOF
deb $MIRROR jammy main restricted universe multiverse
deb $MIRROR jammy-updates main restricted universe multiverse
deb $MIRROR jammy-backports main restricted universe multiverse
deb $MIRROR jammy-security main restricted universe multiverse
EOF

# Setup chroot
sudo mount --bind /dev "$ROOTFS_DIR/dev"
sudo mount -t devpts devpts "$ROOTFS_DIR/dev/pts"
sudo mount -t proc proc "$ROOTFS_DIR/proc"
sudo mount -t sysfs sysfs "$ROOTFS_DIR/sys"
sudo cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

# Add packages in chroot
sudo chroot "$ROOTFS_DIR" /bin/bash -e <<'EOF'
# Envs
export DEFAULT_USER_NAME="ubuntu"
export DESKTOP_ENV="kde-standard"
export DEBIAN_FRONTEND=noninteractive
export PROTON_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton10-20/GE-Proton10-20.tar.zst"
export HANGOVER_URL="https://github.com/AndreRH/hangover/releases/download/hangover-10.14/hangover_10.14_ubuntu2204_jammy_arm64.tar"

# Install packages
apt-get update
apt-get install -y --no-install-recommends ubuntu-minimal systemd \
        dbus locales tzdata ca-certificates gnupg wget curl sudo \
        network-manager snap flatpak
#       $DESKTOP_ENV

# Install box64
# TODO

# Install RPCS3
curl -JLO https://rpcs3.net/latest-linux-arm64
chmod a+x ./rpcs3-*linux_aarch64.AppImage && ./rpcs3-*_linux_aarch64.AppImage
rm ./rpcs3-*_linux_aarch64.AppImage

# Install Dolphin
flatpak remote-add --if-not-exists dolphin https://flatpak.dolphin-emu.org/releases.flatpakrepo
sudo flatpak install dolphin org.DolphinEmu.dolphin-emu -y

# Install Waydroid
curl -s https://repo.waydro.id | sudo bash

# Install custom kernel modules

# Install firmware pack

# Install proton ge

# Locale
locale-gen en_US.UTF-8 zh_CN.UTF-8
update-locale LANG=en_US.UTF-8

# Register default user
useradd -m -s /bin/bash $DEFAULT_USER_NAME || true
echo '$DEFAULT_USER_NAME:passwd' | chpasswd
usermod -aG sudo $$DEFAULT_USER_NAME

# Clean up
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* ~/.bash_history
EOF

sudo umount -l "$ROOTFS_DIR/dev/pts" || true
sudo umount -l "$ROOTFS_DIR/dev" || true
sudo umount -l "$ROOTFS_DIR/proc" || true
sudo umount -l "$ROOTFS_DIR/sys" || true

#sudo tar -C "$ROOTFS_DIR" -czf "$OUT_TAR" .
#ls -lh "$OUT_TAR"