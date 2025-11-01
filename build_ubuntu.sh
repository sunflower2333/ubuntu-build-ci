#!/usr/bin/env bash

set -euo pipefail

#============================================================
# Build Ubuntu ARM64 rootfs via LXC and run provisioning inside container
# - Uses debootstrap to create rootfs
# - Launches an LXC container with that rootfs (systemd as PID1)
# - Runs the original chroot provisioning logic inside the container
# - Packages the rootfs as 7z multi-volume
#============================================================

#-----------------------------
# System Info (overridable via environment)
# Top-level system / distro related variables can be provided by the workflow
# or environment. Defaults below preserve previous behavior so this is
# backwards-compatible.
#-----------------------------

# Basic distro selection
export DISTRO="${DISTRO:-noble}"
export ARCH="${ARCH:-arm64}"
export MIRROR="${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"

# Chunking / hostname (can be overridden by workflow)
export CHUNK_SIZE="${CHUNK_SIZE:-1500m}"  # default 1.5GB per part; can override via env
export HOSTNAME_NAME="${HOSTNAME_NAME:-${DISTRO}}"  # desired hostname inside rootfs/container

# Computed paths (can be overridden by env if desired)
export ROOTFS_DIR="${ROOTFS_DIR:-${PWD}/ubuntu-${DISTRO}-${ARCH}-rootfs}"
export SYS_OUTPUT="${SYS_OUTPUT:-${PWD}/${DISTRO}-${ARCH}-rootfs.7z}"

# Upstream assets and repos (overridable)
export KERNEL_PACKS_REPO="${KERNEL_PACKS_REPO:-sunflower2333/linux}"
export FW_PACKS_REPO="${FW_PACKS_REPO:-sunflower2333/linux-firmware-ayaneo}"
# export PROTON_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton10-20/GE-Proton10-20.tar.zst"
export HANGOVER_URL="${HANGOVER_URL:-https://github.com/AndreRH/hangover/releases/download/hangover-10.14/hangover_10.14_ubuntu2404_noble_arm64.tar}"
export RPCS3_URL="${RPCS3_URL:-https://rpcs3.net/latest-linux-arm64}"
export ALSA_UCM_URL="${ALSA_UCM_URL:-https://github.com/sunflower2333/alsa-ucm-conf/archive/refs/heads/master.tar.gz}"

# LXC names/paths (depend on DISTRO/ARCH but can be overridden)
export LXC_NAME="${LXC_NAME:-ubuntufs-${DISTRO}-${ARCH}}"
export LXC_DIR="${LXC_DIR:-/var/lib/lxc/${LXC_NAME}}"
export LXC_CONFIG="${LXC_CONFIG:-${LXC_DIR}/config}"

# Provisioning env inside container (overridable)
export DEFAULT_USER_NAME="${DEFAULT_USER_NAME:-ubuntu}"
export DEFAULT_USER_PASSWORD="${DEFAULT_USER_PASSWORD:-passwd}"
export DESKTOP_ENV="${DESKTOP_ENV:-kde-standard}"
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
export TZ_REGION="${TZ_REGION:-Asia/Shanghai}"
export CONTAINER_PACKAGES="${CONTAINER_PACKAGES:-ubuntu-minimal systemd dbus locales tzdata ca-certificates gnupg wget curl network-manager flatpak gcc python3 python3-pip linux-firmware zip unzip p7zip-full zstd nano vim mesa-utils vulkan-tools kde-standard sddm plasma-workspace-wayland breeze sddm-theme-breeze plasma-mobile-tweaks maliit-keyboard systemsettings xinput firefox firefox-l10n-zh-cn language-pack-zh-hans language-pack-kde-zh-hans}"

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
# Stage 1: Create rootfs and pre-stage assets
#-----------------------------
create_rootfs() {
  if [[ -d "${ROOTFS_DIR}" ]]; then
    info "Rootfs exists: ${ROOTFS_DIR} (skip debootstrap)"
  else
    info "Running debootstrap for ${DISTRO}/${ARCH}"
    sudo debootstrap --arch="${ARCH}" --variant=minbase "${DISTRO}" "${ROOTFS_DIR}" "${MIRROR}"
  fi

  sudo mkdir -p "${ROOTFS_DIR}/usr/local/bin" "${ROOTFS_DIR}/var/opt"
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

#-----------------------------
# Hostname setup inside rootfs
#-----------------------------
configure_hostname() {
  info "Configuring hostname in rootfs: ${HOSTNAME_NAME}"
  # /etc/hostname
  echo "${HOSTNAME_NAME}" | sudo tee "${ROOTFS_DIR}/etc/hostname" >/dev/null

  # Ensure 127.0.1.1 mapping in /etc/hosts
  sudo touch "${ROOTFS_DIR}/etc/hosts"
  # Remove any existing 127.0.1.1 line to avoid duplicates
  sudo sed -i '/^127\.0\.1\.1\b.*/d' "${ROOTFS_DIR}/etc/hosts"
  # Keep localhost entries intact, append our hostname mapping
  echo "127.0.1.1 ${HOSTNAME_NAME}" | sudo tee -a "${ROOTFS_DIR}/etc/hosts" >/dev/null
}

pre_download_assets() {
  info "Downloading application assets into rootfs"
  # wget -q -O "${ROOTFS_DIR}/usr/local/bin/proton.tar.zst" "${PROTON_URL}" || warn "Failed to download proton"
  wget -q -O "${ROOTFS_DIR}/usr/local/bin/hangover.tar" "${HANGOVER_URL}" || warn "Failed to download hangover"
  wget -q -O "${ROOTFS_DIR}/var/opt/rpcs3-arm64.AppImage" "${RPCS3_URL}" || warn "Failed to download RPCS3"

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

  # Create target dir for kernel debs
  sudo mkdir -p "${ROOTFS_DIR}/var/opt/linux_debs/"

  if [[ -f linux_debs.7z ]]; then
    info "Extracting kernel debs into rootfs var/opt"
    sudo 7z x linux_debs.7z -o"${ROOTFS_DIR}/var/opt/linux_debs/" >/dev/null
    rm -f linux_debs.7z
  fi
  if [[ -f firmware_deb.7z ]]; then
    info "Extracting firmware debs into rootfs var/opt"
    sudo 7z x firmware_deb.7z -o"${ROOTFS_DIR}/var/opt/linux_debs/" >/dev/null
    rm -f firmware_deb.7z
  fi

  info "Downloading ALSA UCM2 config to rootfs"
  wget -q -O "${ROOTFS_DIR}/var/opt/alsa-ucm-conf.tar.gz" "${ALSA_UCM_URL}" || warn "Failed to download ALSA UCM2 config"
}

write_provision_script() {
  info "Writing provisioning script into rootfs"
  sudo tee "${ROOTFS_DIR}/root/provision.sh" >/dev/null <<EOS
#!/usr/bin/env bash
set -euo pipefail

# Environment for provisioning (passed from host)
export DEFAULT_USER_NAME="${DEFAULT_USER_NAME}"
export DEFAULT_USER_PASSWORD="${DEFAULT_USER_PASSWORD}"
export DESKTOP_ENV="${DESKTOP_ENV}"
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND}"
export TZ_REGION="${TZ_REGION}"
export CONTAINER_PACKAGES="${CONTAINER_PACKAGES}"

# echo "[container] Setup Box64 apt source"
# mkdir -p /usr/share/keyrings
# wget -qO- "https://pi-apps-coders.github.io/box64-debs/KEY.gpg" | gpg --dearmor -o /usr/share/keyrings/box64-archive-keyring.gpg
# # create .sources file
# echo "Types: deb
# URIs: https://Pi-Apps-Coders.github.io/box64-debs/debian
# Suites: ./
# Signed-By: /usr/share/keyrings/box64-archive-keyring.gpg" | tee /etc/apt/sources.list.d/box64.sources >/dev/null

echo "[container] Setup Firefox apt source"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc
# Convert to APT keyring and verify fingerprint without touching /root/.gnupg
gpg --batch --yes --dearmor -o /etc/apt/keyrings/packages.mozilla.org.gpg /etc/apt/keyrings/packages.mozilla.org.asc
chmod 0644 /etc/apt/keyrings/packages.mozilla.org.gpg
expected="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"
actual="$(gpg --batch --no-tty --show-keys --with-fingerprint --with-colons /etc/apt/keyrings/packages.mozilla.org.asc | awk -F: '/^fpr:/{print $10; exit}')"
if [[ "${actual}" != "${expected}" ]]; then
  echo "Verification failed: the fingerprint (${actual}) does not match the expected one (${expected})." >&2
  exit 1
else
  echo "The key fingerprint matches (${actual})."
fi

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/packages.mozilla.org.gpg] https://mirrors.tuna.tsinghua.edu.cn/mozilla/apt mozilla main" | tee /etc/apt/sources.list.d/mozilla.list > /dev/null
echo '
Package: *
Pin: origin mirrors.tuna.tsinghua.edu.cn
Pin-Priority: 1000
' | tee /etc/apt/preferences.d/mozilla > /dev/null

echo "[container] Updating and installing base packages"
apt-get update && apt-get upgrade -y
apt-get install -y \${CONTAINER_PACKAGES}
  # box64-generic-arm 

systemctl enable sddm || true
systemctl enable NetworkManager || true

echo "[container] Configure locale/timezone"
locale-gen en_US.UTF-8 zh_CN.UTF-8
update-locale LANG=en_US.UTF-8 # tty UTF-8
echo "LANG=zh_CN.UTF-8" > /etc/default/locale
mkdir -p /etc/systemd/system/sddm.service.d/
cat <<EOL >/etc/systemd/system/sddm.service.d/EnvironmentFile.conf
[Service]
EnvironmentFile=/etc/default/locale
EOL

ln -sf "/usr/share/zoneinfo/${TZ_REGION}" /etc/localtime || true
dpkg-reconfigure -f noninteractive tzdata || true

echo "[container] Create default user"
if ! id -u "${DEFAULT_USER_NAME}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${DEFAULT_USER_NAME}"
fi
echo "${DEFAULT_USER_NAME}:${DEFAULT_USER_PASSWORD}" | chpasswd
usermod -aG sudo "${DEFAULT_USER_NAME}"

# SDDM Rotate
echo "[container] Configure display rotation for DSI-1"
cat <<'EOR' >>/usr/share/sddm/scripts/Xsetup
xrandr --output DSI-1 --rotate right --scale 0.5x0.5
xinput set-prop 7 "Coordinate Transformation Matrix" 0 1 0 -1 0 1 0 0 1
EOR

# KDE Rotate and DPI
echo "[container] Configure display rotation in Plasma"
mkdir -p /home/ubuntu/.local/share/kscreen/outputs/
# For APS2
cat <<'EOR' >/home/ubuntu/.local/share/kscreen/b5350822fc24a835e633b5bf90f2b56d
[
    {
        "enabled": true,
        "id": "DSI-1",
        "metadata": {
            "name": "DSI-1"
        },
        "mode": {
            "refresh": 60,
            "size": {
                "height": 2560,
                "width": 1440
            }
        },
        "overscan": 0,
        "pos": {
            "x": 0,
            "y": 0
        },
        "priority": 1,
        "rgbrange": 0,
        "rotation": 8,
        "scale": 2,
        "vrrpolicy": 0
    }
]
EOR
cat <<'EOR' >/home/ubuntu/.local/share/kscreen/outputs/b5350822fc24a835e633b5bf90f2b56d
{
    "id": "DSI-1",
    "metadata": {
        "name": "DSI-1"
    },
    "mode": {
        "refresh": 60,
        "size": {
            "height": 2560,
            "width": 1440
        }
    },
    "overscan": 0,
    "rgbrange": 0,
    "rotation": 8,
    "scale": 2,
    "vrrpolicy": 0
}
EOR
# Disable X11 Plasma
sudo mv /usr/share/xsessions/plasma.desktop /usr/share/xsessions/plasma.desktop.disabled

chown -R "${DEFAULT_USER_NAME}:${DEFAULT_USER_NAME}" /home/ubuntu/.local
chmod -R 700 /home/ubuntu/.local

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

# echo "[container] Install Proton GE"
# if [[ -f /usr/local/bin/proton.tar.zst ]]; then
#   mkdir -p /usr/local/bin/proton/
#   tar -C /usr/local/bin/proton/ --zstd -xf /usr/local/bin/proton.tar.zst
#   rm -f /usr/local/bin/proton.tar.zst
# fi

echo "[container] Install Hangover"
if [[ -f /usr/local/bin/hangover.tar ]]; then
  mkdir -p /usr/local/bin/hangover/
  tar -C /usr/local/bin/hangover/ -xf /usr/local/bin/hangover.tar
  cd /usr/local/bin/hangover/
  apt install -y ./hangover*.deb
  rm -rf /usr/local/bin/hangover.tar /usr/local/bin/hangover/
fi

echo "[container] Place RPCS3 AppImage to user's desktop"
if [[ -f /var/opt/rpcs3-arm64.AppImage ]]; then
  chmod a+x /var/opt/rpcs3-arm64.AppImage
  mkdir -p "/home/${DEFAULT_USER_NAME}/Desktop"
  mv /var/opt/rpcs3-arm64.AppImage "/home/${DEFAULT_USER_NAME}/Desktop/RPCS3.AppImage"
  chown -R "${DEFAULT_USER_NAME}:${DEFAULT_USER_NAME}" "/home/${DEFAULT_USER_NAME}/Desktop"
fi

echo "[container] Install custom kernel/modules/firmware if present"
if compgen -G "/var/opt/linux_debs/*.deb" > /dev/null; then
  dpkg -i /var/opt/linux_debs/*.deb || apt-get -f install -y
  rm -rf /var/opt/linux_debs
fi

echo "[container] Decompress firmware files"
find /usr/lib/firmware/ath12k/ /usr/lib/firmware/qcom/ -name "*.zst" -exec unzstd --rm {} \;

echo "[container] Copy custom ucm2 conf"
if [[ ! -d /usr/share/alsa ]]; then
  mkdir -p /usr/share/alsa
fi

if [[ -f /var/opt/alsa-ucm-conf.tar.gz ]]; then
  tar xzf /var/opt/alsa-ucm-conf.tar.gz -C /usr/share/alsa --strip-components=1 --wildcards "*/ucm" "*/ucm2"
  rm -f /var/opt/alsa-ucm-conf.tar.gz
fi

echo "[container] Finished installing packages."

echo "[container] Cleanup"
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /var/log/* /var/opt/* /root/.bash_history
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
lxc.uts.name = ${HOSTNAME_NAME}

# Use our debootstrapped rootfs
lxc.rootfs.path = dir:${ROOTFS_DIR}

# Systemd as init inside container
lxc.init.cmd = /sbin/init

# Container specific configuration
lxc.apparmor.profile = generated
lxc.apparmor.allow_nesting = 1

lxc.net.0.type = none
EOF

  # Register container (no template, external rootfs)
  if ! sudo lxc-ls --fancy | grep -q "^${LXC_NAME}\b"; then
    sudo lxc-create -n "${LXC_NAME}" -t none -f "${LXC_CONFIG}"
  fi
}

start_container() {
  info "Starting container ${LXC_NAME}"
  # Optional debug logging
  sudo lxc-start -n "${LXC_NAME}" --logfile "${LXC_DIR}/lxc-start.log" --logpriority DEBUG

  cat "${LXC_DIR}/lxc-start.log"

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
  info "Packaging rootfs using tar stream -> 7z multi-volume archive"

  require_cmd tar || return 1
  require_cmd 7z  || return 1

  local tar_name="${DISTRO}-${ARCH}-rootfs.tar"
  info "Creating tar -> 7z multi-volume: ${SYS_OUTPUT}.* (chunk=${CHUNK_SIZE}, comp=mx=9, threads=on)"

  (
    cd "${ROOTFS_DIR}" && \
    sudo tar -cpf - . \
      | sudo 7z a "${SYS_OUTPUT}" -t7z -m0=lzma2 -mx=9 -mmt=on -v${CHUNK_SIZE} -si"${tar_name}"
  )

  ls -lh "${SYS_OUTPUT}".* 2>/dev/null || true
  info "Done. 7z parts: ${SYS_OUTPUT}.*"
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
  sudo chroot "${ROOTFS_DIR}" bash -lc "DEBIAN_FRONTEND=noninteractive apt-get install -y systemd systemd-sysv dbus wget curl sudo gpg openssh-server"
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
  create_rootfs
  configure_apt_sources
  configure_hostname
  pre_download_assets
  write_provision_script
  prime_rootfs_for_lxc
  create_lxc_container
  start_container
  run_provision
  stop_container
  package_rootfs
  info "Done. Output: ${SYS_OUTPUT}.*"
}

main "$@"

