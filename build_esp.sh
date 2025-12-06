#!/bin/bash
# Usage: ./build_esp.sh <esp_partition_size> <ufs_root_uuid> <ufs_root_partlabel> <sd_root_uuid> <sd_root_partlabel>

ESP_PARTITION_SIZE=$1
ROOT_PARTITION_UUID=$2
ROOT_PARTLABEL=$3
SD_ROOT_UUID=$4
SD_ROOT_PARTLABEL=$5

# GRUB_REPO must be provided as environment variable
: "${GRUB_REPO:?GRUB_REPO must be provided}"

# Create working directory
mkdir -p ESP/ && cd ESP
mkdir -p esp

# Download GRUB EFI binary from latest release
# Check if grub is downloaded
if [ ! -f grub2-esp-aarch64.tar.gz ]; then
    echo "Fetching latest GRUB release from ${GRUB_REPO}"
    GRUB_RELEASE_URL=$(curl -s "https://api.github.com/repos/${GRUB_REPO}/releases/latest" \
      | jq -r '.assets[] | select(.name=="grub2-esp-aarch64.tar.gz") | .browser_download_url')
    
    if [[ -z "${GRUB_RELEASE_URL}" || "${GRUB_RELEASE_URL}" == "null" ]]; then
        echo "Error: grub2-esp-aarch64.tar.gz not found in latest release of ${GRUB_REPO}" >&2
        exit 1
    fi
    
    echo "Downloading from ${GRUB_RELEASE_URL}"
    curl -L -o grub2-esp-aarch64.tar.gz "${GRUB_RELEASE_URL}"
fi

tar -xzf grub2-esp-aarch64.tar.gz -C esp

# remove unused grub modules exclude ext2,part_msdos and part_gpt
find esp/boot/grub/arm64-efi/ -type f ! -name 'ext2.mod' ! -name 'part_msdos.mod' ! -name 'part_gpt.mod' ! -name 'grub.cfg' -delete

cd esp
cat << EOF > boot/grub/grub.cfg
# Rootfs selection: prefer SD, fallback to UFS; else reboot
set sd_uuid=$SD_ROOT_UUID
set ufs_uuid=$ROOT_PARTITION_UUID

if search.fs_uuid \$sd_uuid root; then
    echo "Found SD rootfs (UUID=\$sd_uuid)"
    set prefix=(\$root)/boot/grub
    set partlabel=$SD_ROOT_PARTLABEL
elif search.fs_uuid \$ufs_uuid root; then
    echo "Found UFS rootfs (UUID=\$ufs_uuid)"
    set prefix=(\$root)/boot/grub
    set partlabel=$ROOT_PARTLABEL
else
    echo "ROOTFS DOES NOT EXIST"
    echo "Rebooting in 5 seconds..."
    sleep 5
    reboot
fi

# Load thirdparty efivar driver
insmod efivar

# Save DisplayPanelConfiguration to grub environment
efivar --set display_param "DisplayPanelConfiguration" 882F8C2B-9646-435F-8DE5-F208FF80C1BD

# Switch dtb and kernel paratmeters by display panel configuration
if [ "\$display_param" = " msm_drm.dsi_display0=qcom,mdss_dsi_wt0630_60hz_video:" ]; then
    set device_tree="sm8650-ayaneo-ps2.dtb"
    set extra_bootargs="fbcon=rotate:1"
elif [ "\$display_param" = " msm_drm.dsi_display0=qcom,mdss_dsi_wt0600_60hz_video:" ]; then
    set device_tree="sm8550-ayaneo-ps.dtb"
    set extra_bootargs="fbcon=rotate:1"
elif [ "\$display_param" = " msm_drm.dsi_display0=qcom,mdss_dsi_wt0600_1080p_60hz_video:" ]; then
    set device_tree="sm8550-ayaneo-ps.dtb"
    set extra_bootargs="fbcon=rotate:1"
elif [ "\$display_param" = " msm_drm.dsi_display0=qcom,mdss_dsi_ar02_3inch_video:" ]; then
    set device_tree="sm8550-ayaneo-dmg.dtb"
    set extra_bootargs="fbcon=rotate:3" # 270 degrees rotation for DMG's fbcon.
elif [ "\$display_param" = " msm_drm.dsi_display0=qcom,mdss_dsi_ar06_4inch_video:" ]; then
    set device_tree="sm8550-ayaneo-ace.dtb"
    set extra_bootargs="fbcon=rotate:1"
else
    # Default to nothing
    set device_tree=""
    set extra_bootargs=""
fi

save_env display_param
save_env device_tree
save_env partlabel
save_env extra_bootargs
configfile \$prefix/grub2.cfg
EOF
cd ..

# Check mkfs.vfat installation
if ! command -v mkfs.vfat > /dev/null
then
    sudo apt-get install -y dosfstools
fi

# Pack into ESP image
if [ -f esp.img ]; then
    rm -f esp.img
fi

truncate -s ${ESP_PARTITION_SIZE} esp.img
mkfs.vfat -F12 -S 4096 -n LOGFS esp.img
mkdir -p mnt
sudo mount -o loop esp.img mnt
sudo cp -r esp/* mnt/
sudo umount mnt

# compress the image
7z a -t7z -mx=9 esp.img.7z esp.img

# Clean up
rm -rf mnt esp
