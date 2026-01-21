#!/bin/bash
# Generate SD-card image.
set -euo pipefail

usage() {
	echo "Usage: $0 <esp_image> <rootfs_image> <output_image> <sd_root_uuid> <sd_root_partlabel>" >&2
	echo "  - <esp_image>: Path to ESP FAT image (e.g., esp.img)" >&2
	echo "  - <rootfs_image>: Path to ext4 rootfs image to embed" >&2
	echo "  - <output_image>: Path to resulting SD card disk image" >&2
	echo "  - <sd_root_uuid>: Filesystem UUID to set on the rootfs image (ext4)" >&2
	echo "  - <sd_root_partlabel>: GPT PARTLABEL to assign to the rootfs partition" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "Error: required tool '$1' not found in PATH" >&2
		exit 1
	}
}

ceil_div() {
	local dividend="$1"
	local divisor="$2"
	echo $(( (dividend + divisor - 1) / divisor ))
}

align_up() {
	local value="$1"
	local alignment="$2"
	echo $(( ((value + alignment - 1) / alignment) * alignment ))
}

[ $# -eq 5 ] || usage

ESP_IMAGE="$1"
ROOTFS_IMAGE="$2"
OUTPUT_IMAGE="$3"
SD_ROOT_UUID="$4"
SD_ROOT_PARTLABEL="$5"

# Check Args
[ -f "$ESP_IMAGE" ] || { echo "Error: ESP image '$ESP_IMAGE' not found" >&2; exit 1; }
[ -f "$ROOTFS_IMAGE" ] || { echo "Error: rootfs image '$ROOTFS_IMAGE' not found" >&2; exit 1; }
[ -n "$SD_ROOT_UUID" ] || { echo "Error: sd_root_uuid must be provided" >&2; exit 1; }
[ -n "$SD_ROOT_PARTLABEL" ] || { echo "Error: sd_root_partlabel must be provided" >&2; exit 1; }

require_cmd sgdisk
require_cmd stat
require_cmd truncate
require_cmd dd
require_cmd tune2fs

SECTOR_SIZE=512
# GPT header is at sector 1, partition table starts at sector 2 (typically 33 sectors for 128 entries)
# First usable sector is typically 34 (2048 for 1MB alignment is common practice)
FIRST_USABLE_SECTOR=2048  # 1MB alignment, standard for modern disks
ALIGNMENT_BYTES=$((1 * 1024 * 1024))  # 1MB alignment for subsequent partitions
ALIGNMENT_SECTORS=$((ALIGNMENT_BYTES / SECTOR_SIZE))

esp_size_bytes=$(stat -c%s "$ESP_IMAGE")
rootfs_size_bytes=$(stat -c%s "$ROOTFS_IMAGE")

esp_size_sectors=$(ceil_div "$esp_size_bytes" "$SECTOR_SIZE")
rootfs_size_sectors=$(ceil_div "$rootfs_size_bytes" "$SECTOR_SIZE")

esp_start_sector=$FIRST_USABLE_SECTOR
rootfs_start_sector=$(align_up $((esp_start_sector + esp_size_sectors)) "$ALIGNMENT_SECTORS")

rootfs_end_sector=$((rootfs_start_sector + rootfs_size_sectors))
total_sectors=$(align_up "$rootfs_end_sector" "$ALIGNMENT_SECTORS")
total_sectors=$((total_sectors + 34))
total_bytes=$((total_sectors * SECTOR_SIZE))

esp_start_bytes=$((esp_start_sector * SECTOR_SIZE))
rootfs_start_bytes=$((rootfs_start_sector * SECTOR_SIZE))

output_dir=$(dirname "$OUTPUT_IMAGE")
mkdir -p "$output_dir"
tmp_image=$(mktemp "$output_dir/$(basename "$OUTPUT_IMAGE").tmp.XXXXXX")
trap 'rm -f "$tmp_image"' EXIT

truncate -s "$total_bytes" "$tmp_image"

# Create GPT partition table using sgdisk
sgdisk -o "$tmp_image" >/dev/null  # Create new GPT
sgdisk -n "1:${esp_start_sector}:+${esp_size_sectors}" \
       -t 1:ef00 \
       -c 1:ESP \
       -A 1:set:2 \
       "$tmp_image" >/dev/null  # EFI System Partition with legacy BIOS bootable flag
sgdisk -n "2:${rootfs_start_sector}:+${rootfs_size_sectors}" \
       -t 2:8300 \
       -c 2:"$SD_ROOT_PARTLABEL" \
       "$tmp_image" >/dev/null  # Linux filesystem partition

# Copy payloads directly into their partitions without mounting anything.
if [ -t 2 ]; then
	dd_status='status=progress'
else
	dd_status='status=none'
fi

dd if="$ESP_IMAGE" of="$tmp_image" bs=4M conv=notrunc,fsync oflag=seek_bytes seek="$esp_start_bytes" $dd_status

# Check filesystem before modifying UUID
sudo e2fsck -f -y "$ROOTFS_IMAGE"

# Rewrite filesystem UUID of the rootfs image
sudo tune2fs -U "$SD_ROOT_UUID" "$ROOTFS_IMAGE"

# Embed the rootfs image after UUID update
dd if="$ROOTFS_IMAGE" of="$tmp_image" bs=4M conv=notrunc,fsync oflag=seek_bytes seek="$rootfs_start_bytes" $dd_status

mv "$tmp_image" "$OUTPUT_IMAGE"
trap - EXIT

