#!/bin/bash
# Generate a flashable SD-card image composed of separate ESP and rootfs blobs
# without relying on mounting loop devices. The script creates a DOS partition
# table with two partitions and places each payload directly at the aligned
# offsets inside the resulting disk image.
set -euo pipefail

usage() {
	echo "Usage: $0 <esp_image> <rootfs_image> <output_image>" >&2
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

[ $# -eq 3 ] || usage

ESP_IMAGE="$1"
ROOTFS_IMAGE="$2"
OUTPUT_IMAGE="$3"

# Check Args
[ -f "$ESP_IMAGE" ] || { echo "Error: ESP image '$ESP_IMAGE' not found" >&2; exit 1; }
[ -f "$ROOTFS_IMAGE" ] || { echo "Error: rootfs image '$ROOTFS_IMAGE' not found" >&2; exit 1; }

require_cmd sfdisk
require_cmd stat
require_cmd truncate
require_cmd dd

SECTOR_SIZE=512
ALIGNMENT_BYTES=$((4 * 1024 * 1024))
ALIGNMENT_SECTORS=$((ALIGNMENT_BYTES / SECTOR_SIZE))

esp_size_bytes=$(stat -c%s "$ESP_IMAGE")
rootfs_size_bytes=$(stat -c%s "$ROOTFS_IMAGE")

esp_size_sectors=$(ceil_div "$esp_size_bytes" "$SECTOR_SIZE")
rootfs_size_sectors=$(ceil_div "$rootfs_size_bytes" "$SECTOR_SIZE")

esp_start_sector=$ALIGNMENT_SECTORS
rootfs_start_sector=$(align_up $((esp_start_sector + esp_size_sectors)) "$ALIGNMENT_SECTORS")

rootfs_end_sector=$((rootfs_start_sector + rootfs_size_sectors))
total_sectors=$(align_up "$rootfs_end_sector" "$ALIGNMENT_SECTORS")
total_bytes=$((total_sectors * SECTOR_SIZE))

esp_start_bytes=$((esp_start_sector * SECTOR_SIZE))
rootfs_start_bytes=$((rootfs_start_sector * SECTOR_SIZE))

output_dir=$(dirname "$OUTPUT_IMAGE")
mkdir -p "$output_dir"
tmp_image=$(mktemp "$output_dir/$(basename "$OUTPUT_IMAGE").tmp.XXXXXX")
trap 'rm -f "$tmp_image"' EXIT

truncate -s "$total_bytes" "$tmp_image"

sfdisk "$tmp_image" >/dev/null <<EOF
label: dos
unit: sectors

1 : start=$esp_start_sector, size=$esp_size_sectors, type=0x0c, bootable
2 : start=$rootfs_start_sector, size=$rootfs_size_sectors, type=0x83
EOF

# Copy payloads directly into their partitions without mounting anything.
if [ -t 2 ]; then
	dd_status='status=progress'
else
	dd_status='status=none'
fi

dd if="$ESP_IMAGE" of="$tmp_image" bs=4M conv=notrunc,fsync oflag=seek_bytes seek="$esp_start_bytes" $dd_status
dd if="$ROOTFS_IMAGE" of="$tmp_image" bs=4M conv=notrunc,fsync oflag=seek_bytes seek="$rootfs_start_bytes" $dd_status

mv "$tmp_image" "$OUTPUT_IMAGE"
trap - EXIT

