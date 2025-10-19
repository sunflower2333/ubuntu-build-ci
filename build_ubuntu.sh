#!/bin/sh

# System Info
export DISTRO=noble
export ARCH=arm64
export MIRROR='http://ports.ubuntu.com/ubuntu-ports'
export ROOTFS_DIR="$PWD/ubuntu-${DISTRO}-${ARCH}-rootfs"
export OUT_TAR="$PWD/${DISTRO}-${ARCH}-rootfs.tar.gz"

export KERNEL_PACKS_REPO="sunflower2333/linux"
export PROTON_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton10-20/GE-Proton10-20.tar.zst"
export HANGOVER_URL="https://github.com/AndreRH/hangover/releases/download/hangover-10.14/hangover_10.14_ubuntu2204_jammy_arm64.tar"

# Get minimal rootfs
sudo debootstrap --arch="$ARCH" --variant=minbase "$DISTRO" "$ROOTFS_DIR" "$MIRROR"

# Download application packages
wget -O "$ROOTFS_DIR/usr/local/bin/proton.tar.zst" "$PROTON_URL"
wget -O "$ROOTFS_DIR/usr/local/bin/hangover.tar" "$HANGOVER_URL"

# Download kernel packages
# Get lastest debs link
URL=$(curl -s "https://api.github.com/repos/$KERNEL_PACKS_REPO/releases/latest" \
  | jq -r '.assets[] | select(.name=="linux_debs.7z") | .browser_download_url')

if [ -z "$URL" ] || [ "$URL" = "null" ]; then
  echo "Asset linux_debs.7z not found" >&2
  exit 1
fi

curl -L --fail -o linux_debs.7z "$URL"
7z x linux_debs.7z -ols x"$ROOTFS_DIR/tmp/linux_debs"
rm linux_debs.7z

# Set apt source list
# cat > $ROOTFS_DIR/etc/apt/sources.list <<EOF
# deb $MIRROR $DISTRO main restricted universe multiverse
# deb $MIRROR $DISTRO-updates main restricted universe multiverse
# deb $MIRROR $DISTRO-backports main restricted universe multiverse
# deb $MIRROR $DISTRO-security main restricted universe multiverse
# EOF

cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $MIRROR
Suites: $DISTRO $DISTRO-updates $DISTRO-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $MIRROR
Suites: $DISTRO-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
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

# Install packages
apt-get update
apt-get install -y --no-install-recommends ubuntu-minimal systemd \
        dbus locales tzdata ca-certificates gnupg wget curl sudo \
        network-manager snap flatpak gcc python3 python3-pip \
        linux-firmware \
        mesa-utils vulkan-tools \
        $DESKTOP_ENV
 
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

# Install proton ge
tar -C /usr/local/bin/proton/ -xvf /usr/local/bin/proton.tar.zst
rm /usr/local/bin/proton.tar.zst

# Install hangover
tar -C /usr/local/bin/hangover/ -xvf /usr/local/bin/hangover.tar
rm /usr/local/bin/hangover.tar

# Locale
locale-gen en_US.UTF-8 zh_CN.UTF-8
update-locale LANG=en_US.UTF-8

# Register default user
useradd -m -s /bin/bash $DEFAULT_USER_NAME || true
echo '$DEFAULT_USER_NAME:passwd' | chpasswd
usermod -aG sudo $DEFAULT_USER_NAME

# Install custom kernel and modules
dpkg -i /tmp/linux_debs/*.deb
rm -rf /tmp/linux_debs

# Clean up
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* ~/.bash_history
EOF

sudo umount -l "$ROOTFS_DIR/dev/pts" || true
sudo umount -l "$ROOTFS_DIR/dev" || true
sudo umount -l "$ROOTFS_DIR/proc" || true
sudo umount -l "$ROOTFS_DIR/sys" || true



sudo tar -C "$ROOTFS_DIR" -czf "$OUT_TAR" .
zstd --rm --ultra -22 "$OUT_TAR"
ls -lh "$OUT_TAR".zst 
