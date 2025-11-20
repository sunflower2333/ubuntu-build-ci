#!/bin/bash

# Usage: ./build_esp.sh <device_name> <device_tree_name> <esp_partition_size> <root_partition_uuid>

DEVICE_NAME=$1
DEVICE_TREE_NAME=$2
ESP_PARTITION_SIZE=$3
ROOT_PARTITION_UUID=$4
ROOT_PARTLABEL=$5
GRUB_RELEASE_URL="https://github.com/sunflower2333/grub2/releases/download/grub-2.12-patch2/grub2-esp-aarch64.tar.gz"

# Create working directory
mkdir -p ESP/ && cd ESP
mkdir -p ${DEVICE_NAME}

# Download GRUB EFI binary
# Check if grub is downloaded
if [ ! -f grub2-esp-aarch64.tar.gz ]; then
    curl -L -o grub2-esp-aarch64.tar.gz $GRUB_RELEASE_URL
fi

tar -xzf grub2-esp-aarch64.tar.gz -C ${DEVICE_NAME}

# remove unused grub modules exclude ext2,part_msdos and part_gpt
find ${DEVICE_NAME}/boot/grub/arm64-efi/ -type f ! -name 'ext2.mod' ! -name 'part_msdos.mod' ! -name 'part_gpt.mod' ! -name 'grub.cfg' -delete

cd ${DEVICE_NAME}
cat << EOF > boot/grub/grub.cfg
search.fs_uuid $ROOT_PARTITION_UUID root
set prefix=(\$root)/boot/grub
set device_tree=$DEVICE_TREE_NAME
save_env device_tree
set partlabel=$ROOT_PARTLABEL
save_env partlabel
configfile \$prefix/grub2.cfg
EOF
cd ..

# Check mkfs.vfat installation
if ! command -v mkfs.vfat > /dev/null
then
    sudo apt-get install -y dosfstools
fi

# Pack into ESP image
if [ -f esp-${DEVICE_NAME}.img ]; then
    rm -f esp-${DEVICE_NAME}.img
fi

truncate -s ${ESP_PARTITION_SIZE} esp-${DEVICE_NAME}.img
mkfs.vfat -F12 -S 4096 -n LOGFS esp-${DEVICE_NAME}.img
mkdir -p mnt
sudo mount -o loop esp-${DEVICE_NAME}.img mnt
sudo cp -r ${DEVICE_NAME}/* mnt/
sudo umount mnt

# compress the image
7z a -t7z -mx=9 esp-${DEVICE_NAME}.img.7z esp-${DEVICE_NAME}.img

# Clean up
rm -rf mnt ${DEVICE_NAME}
