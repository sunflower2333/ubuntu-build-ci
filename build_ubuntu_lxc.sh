#!/usr/bin/env bash

set -euo pipefail

#============================================================
# Build Ubuntu ARM64 rootfs via LXC and run provisioning inside container
# - Uses debootstrap to create rootfs
# - Launches an LXC container with that rootfs (systemd as PID1)
# - Runs the original chroot provisioning logic inside the container
# - Packages the rootfs to tar.zst
#============================================================

#-----------------------------
# System Info (editable)
#-----------------------------
export DISTRO="noble"
export ARCH="arm64"
export MIRROR="http://ports.ubuntu.com/ubuntu-ports"
export ROOTFS_DIR="${PWD}/ubuntu-${DISTRO}-${ARCH}-rootfs"
export OUT_TAR="${PWD}/${DISTRO}-${ARCH}-rootfs.tar.zst"

# Upstream assets and repos
export KERNEL_PACKS_REPO="sunflower2333/linux"
export FW_PACKS_REPO="sunflower2333/linux-firmware-ayaneo"
export PROTON_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton10-20/GE-Proton10-20.tar.zst"
export HANGOVER_URL="https://github.com/AndreRH/hangover/releases/download/hangover-10.14/hangover_10.14_ubuntu2404_noble_arm64.tar"
export RPCS3_URL="https://rpcs3.net/latest-linux-arm64"

# LXC
export LXC_NAME="ubuntufs-${DISTRO}-${ARCH}"
export LXC_DIR="/var/lib/lxc/${LXC_NAME}"
export LXC_CONFIG="${LXC_DIR}/config"

# Provisioning env inside container
export DEFAULT_USER_NAME="ubuntu"
export DEFAULT_USER_PASSWORD="passwd"
export DESKTOP_ENV="kde-standard"
export DEBIAN_FRONTEND="noninteractive"
export TZ_REGION="Asia/Shanghai"  # prefer canonical tz name

#-----------------------------
# Helpers
#-----------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    return 1
  }
}

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err()  { echo "[ERR ] $*" >&2; }

cleanup() {
  set +e
  if sudo lxc-info -n "${LXC_NAME}" >/dev/null 2>&1; then
    state=$(sudo lxc-info -n "${LXC_NAME}" -sH || true)
    if [[ "${state}" == "RUNNING" ]]; then
      info "Stopping container ${LXC_NAME}"
      sudo lxc-stop -n "${LXC_NAME}" || true
    fi
  fi
}
trap cleanup EXIT

#-----------------------------
# Ensure host dependencies
#-----------------------------
install_host_deps() {
  info "Installing host dependencies"
  sudo apt-get update
  sudo apt-get install -y \
    debootstrap lxc jq p7zip-full zstd curl wget ca-certificates \
    tar xz-utils gnupg dnsmasq-base uidmap

  # Optional: start lxc-net to provide lxcbr0 bridge for container networking
  if systemctl list-unit-files | grep -q '^lxc-net.service'; then
    sudo systemctl enable --now lxc-net || true
  else
    warn "lxc-net.service not found; ensure networking for LXC is available (lxcbr0)."
  fi

  require_cmd debootstrap
  require_cmd lxc-create
  require_cmd lxc-start
  require_cmd lxc-attach
  require_cmd jq
  require_cmd 7z
  require_cmd zstd
}

#-----------------------------
# Stage 1: Create rootfs and pre-stage assets
#-----------------------------
create_rootfs() {
  if [[ -d "${ROOTFS_DIR}" ]]; then
    info "Rootfs exists: ${ROOTFS_DIR} (skip debootstrap)"
  else
    info "Running debootstrap for ${DISTRO}/${ARCH}"
    sudo debootstrap --arch="${ARCH}" --variant=minbase "${DISTRO}" "${ROOTFS_DIR}" "${MIRROR}"
  fi

  sudo mkdir -p "${ROOTFS_DIR}/usr/local/bin" "${ROOTFS_DIR}/tmp"
}

configure_apt_sources() {
  info "Configuring apt sources inside rootfs"
  sudo tee "${ROOTFS_DIR}/etc/apt/sources.list" >/dev/null <<EOF
deb ${MIRROR} ${DISTRO} main restricted universe multiverse
deb ${MIRROR} ${DISTRO}-updates main restricted universe multiverse
deb ${MIRROR} ${DISTRO}-backports main restricted universe multiverse
deb ${MIRROR} ${DISTRO}-security main restricted universe multiverse
EOF

  # Ensure DNS works in container
  if [[ -f /etc/resolv.conf ]]; then
    sudo cp /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"
  fi
}

pre_download_assets() {
  info "Downloading application assets into rootfs"
  wget -q -O "${ROOTFS_DIR}/usr/local/bin/proton.tar.zst" "${PROTON_URL}" || warn "Failed to download proton"
  wget -q -O "${ROOTFS_DIR}/usr/local/bin/hangover.tar" "${HANGOVER_URL}" || warn "Failed to download hangover"
  wget -q -O "${ROOTFS_DIR}/tmp/rpcs3-arm64.AppImage" "${RPCS3_URL}" || warn "Failed to download RPCS3"

  info "Downloading kernel/firmware packs metadata"
  URL=$(curl -s "https://api.github.com/repos/${KERNEL_PACKS_REPO}/releases/latest" \
    | jq -r '.assets[] | select(.name=="linux_debs.7z") | .browser_download_url') || URL=""
  if [[ -n "${URL}" && "${URL}" != "null" ]]; then
    curl -sL --fail -o linux_debs.7z "${URL}" || warn "Failed to fetch linux_debs.7z"
  else
    warn "Asset linux_debs.7z not found"
  fi

  URL=$(curl -s "https://api.github.com/repos/${FW_PACKS_REPO}/releases/latest" \
    | jq -r '.assets[] | select(.name=="firmware_deb.7z") | .browser_download_url') || URL=""
  if [[ -n "${URL}" && "${URL}" != "null" ]]; then
    curl -sL --fail -o firmware_deb.7z "${URL}" || warn "Failed to fetch firmware_deb.7z"
  else
    warn "Asset firmware_deb.7z not found"
  fi

  if [[ -f linux_debs.7z ]]; then
    info "Extracting kernel debs into rootfs tmp"
    sudo 7z x linux_debs.7z -o"${ROOTFS_DIR}/tmp/linux_debs" >/dev/null
    rm -f linux_debs.7z
  fi
  if [[ -f firmware_deb.7z ]]; then
    info "Extracting firmware debs into rootfs tmp"
    sudo 7z x firmware_deb.7z -o"${ROOTFS_DIR}/tmp/linux_debs" >/dev/null
    rm -f firmware_deb.7z
  fi
}

write_provision_script() {
  info "Writing provisioning script into rootfs"
  sudo tee "${ROOTFS_DIR}/root/provision.sh" >/dev/null <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

# Environment for provisioning
export DEFAULT_USER_NAME="ubuntu"
export DEFAULT_USER_PASSWORD="passwd"
export DESKTOP_ENV="kde-standard"
export DEBIAN_FRONTEND="noninteractive"
export TZ_REGION="Asia/Shanghai"

echo "[container] Updating and installing base packages"
apt-get update && apt-get upgrade -y
apt-get install -y --no-install-recommends ubuntu-minimal systemd \
  dbus locales tzdata ca-certificates gnupg wget curl sudo \
  network-manager snap flatpak gcc python3 python3-pip \
  linux-firmware zip unzip p7zip-full zstd \
  mesa-utils vulkan-tools \
  ${DESKTOP_ENV}

echo "[container] Configure locale/timezone"
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
ln -sf "/usr/share/zoneinfo/${TZ_REGION}" /etc/localtime || true
dpkg-reconfigure -f noninteractive tzdata || true

echo "[container] Create default user"
if ! id -u "${DEFAULT_USER_NAME}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${DEFAULT_USER_NAME}"
fi
echo "${DEFAULT_USER_NAME}:${DEFAULT_USER_PASSWORD}" | chpasswd
usermod -aG sudo "${DEFAULT_USER_NAME}"

echo "[container] Flatpak setup and Dolphin install"
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
flatpak remote-add --if-not-exists dolphin https://flatpak.dolphin-emu.org/releases.flatpakrepo || true
flatpak update --appstream -y || true
flatpak update -y || true
flatpak install dolphin org.DolphinEmu.dolphin-emu -y || true

echo "[container] Install Waydroid"
curl -s https://repo.waydro.id | bash || true
apt-get update || true
apt-get install -y waydroid || true

echo "[container] Install Proton GE"
if [[ -f /usr/local/bin/proton.tar.zst ]]; then
  mkdir -p /usr/local/bin/proton/
  tar -C /usr/local/bin/proton/ --zstd -xf /usr/local/bin/proton.tar.zst
  rm -f /usr/local/bin/proton.tar.zst
fi

echo "[container] Install Hangover"
if [[ -f /usr/local/bin/hangover.tar ]]; then
  mkdir -p /usr/local/bin/hangover/
  tar -C /usr/local/bin/hangover/ -xf /usr/local/bin/hangover.tar
  rm -f /usr/local/bin/hangover.tar
fi

echo "[container] Place RPCS3 AppImage to user's home"
if [[ -f /tmp/rpcs3-arm64.AppImage ]]; then
  chmod a+x /tmp/rpcs3-arm64.AppImage
  mv /tmp/rpcs3-arm64.AppImage "/home/${DEFAULT_USER_NAME}/RPCS3.AppImage"
  chown "${DEFAULT_USER_NAME}:${DEFAULT_USER_NAME}" "/home/${DEFAULT_USER_NAME}/RPCS3.AppImage"
fi

echo "[container] Install custom kernel/modules/firmware if present"
if compgen -G "/tmp/linux_debs/*.deb" > /dev/null; then
  dpkg -i /tmp/linux_debs/*.deb || apt-get -f install -y
  rm -rf /tmp/linux_debs
fi

echo "[container] Cleanup"
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.bash_history
EOS

  sudo chmod +x "${ROOTFS_DIR}/root/provision.sh"
}

#-----------------------------
# Stage 2: Create and run LXC container
#-----------------------------
create_lxc_container() {
  info "Preparing LXC container config at ${LXC_CONFIG}"
  sudo mkdir -p "${LXC_DIR}"

  sudo tee "${LXC_CONFIG}" >/dev/null <<EOF
lxc.include = /usr/share/lxc/config/common.conf
lxc.arch = aarch64
lxc.uts.name = ${LXC_NAME}

# Use our debootstrapped rootfs
lxc.rootfs.path = dir:${ROOTFS_DIR}

# Systemd as init inside container
lxc.init.cmd = /lib/systemd/systemd

# Allow nesting/systemd-friendly defaults
lxc.apparmor.profile = unconfined
lxc.cap.drop =
lxc.mount.auto = proc:rw sys:rw cgroup:rw
lxc.cgroup2.devices.allow = a
lxc.autodev = 1
lxc.console.path = none
lxc.pty.max = 1024

# Networking via lxcbr0
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
EOF

  # Register container (no template, external rootfs)
  if ! sudo lxc-ls --fancy | grep -q "^${LXC_NAME}\b"; then
    sudo lxc-create -n "${LXC_NAME}" -t none -f "${LXC_CONFIG}"
  fi
}

start_container() {
  info "Starting container ${LXC_NAME}"
  # Optional debug logging
  if [[ "${LXC_DEBUG:-0}" == "1" ]]; then
    sudo lxc-start -n "${LXC_NAME}" -d -o "${LXC_DIR}/lxc-start.log" -l DEBUG
  else
    sudo lxc-start -n "${LXC_NAME}" -d
  fi

  # Wait for running state
  for i in {1..30}; do
    state=$(sudo lxc-info -n "${LXC_NAME}" -sH || true)
    if [[ "${state}" == "RUNNING" ]]; then
      info "Container is RUNNING"
      break
    fi
    sleep 1
  done
  if [[ "${state:-}" != "RUNNING" ]]; then
    err "Container failed to reach RUNNING state"
    exit 1
  fi

  # Give systemd a moment to settle
  sleep 5
}

run_provision() {
  info "Running provisioning inside container"
  # Ensure DNS inside container (in case overwritten)
  if [[ -f /etc/resolv.conf ]]; then
    sudo lxc-attach -n "${LXC_NAME}" -- bash -lc 'cp /etc/resolv.conf /run/systemd/resolve/resolv.conf 2>/dev/null || true'
  fi
  sudo lxc-attach -n "${LXC_NAME}" -- bash -lc '/root/provision.sh'
}

stop_container() {
  info "Stopping container ${LXC_NAME}"
  sudo lxc-stop -n "${LXC_NAME}" || true
}

package_rootfs() {
  info "Packaging rootfs into ${OUT_TAR}"
  sudo tar -C "${ROOTFS_DIR}" --zstd -cf "${OUT_TAR}" .
  ls -lh "${OUT_TAR}"
}

#-----------------------------
# Stage 1.5: Prime rootfs with systemd before LXC start
#-----------------------------
prime_rootfs_for_lxc() {
  info "Priming rootfs for LXC (ensure systemd present)"

  # If /sbin/init (systemd) already exists, skip
  if sudo chroot "${ROOTFS_DIR}" test -x /sbin/init 2>/dev/null; then
    info "systemd already present in rootfs"
    return 0
  fi

  # Bind mounts for chroot apt operations
  sudo mount --bind /proc "${ROOTFS_DIR}/proc"
  sudo mount --bind /sys  "${ROOTFS_DIR}/sys"
  sudo mount --bind /dev  "${ROOTFS_DIR}/dev"
  sudo mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts" || true
  [[ -f /etc/resolv.conf ]] && sudo cp /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"

  set +e
  sudo chroot "${ROOTFS_DIR}" bash -lc "apt-get update"
  sudo chroot "${ROOTFS_DIR}" bash -lc "DEBIAN_FRONTEND=noninteractive apt-get install -y systemd systemd-sysv dbus"
  status=$?
  set -e

  # Ensure machine-id exists (systemd requirement)
  if [[ ! -f "${ROOTFS_DIR}/etc/machine-id" ]]; then
    sudo touch "${ROOTFS_DIR}/etc/machine-id"
  fi

  # Unmount regardless of result
  sudo umount -l "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
  sudo umount -l "${ROOTFS_DIR}/dev" 2>/dev/null || true
  sudo umount -l "${ROOTFS_DIR}/proc" 2>/dev/null || true
  sudo umount -l "${ROOTFS_DIR}/sys" 2>/dev/null || true

  if [[ $status -ne 0 ]]; then
    err "Failed to install systemd into rootfs; LXC may fail to start. See logs."
    exit 1
  fi

  info "systemd installed in rootfs"
}

#-----------------------------
# Main
#-----------------------------
main() {
  install_host_deps
  create_rootfs
  configure_apt_sources
  pre_download_assets
  write_provision_script
  prime_rootfs_for_lxc
  create_lxc_container
  start_container
  run_provision
  stop_container
  package_rootfs
  info "Done. Output: ${OUT_TAR}"
}

main "$@"

