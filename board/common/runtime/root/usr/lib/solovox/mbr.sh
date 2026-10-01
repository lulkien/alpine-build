# mbr.sh: partition-table helpers, sourced by the RAM initramfs modes that touch a
# partition table. Both of them do the same thing for different reasons - flash
# mode hands the rest of the disk to the root partition after writing an image,
# grow mode does it on a medium that was flashed as a plain image copy (dd), where
# the partition is image-sized and the filesystem already fills it.
#
# An MBR entry is 16 bytes at 446 + 16 * slot: 0 bootable, 1-3 CHS start, 4 type,
# 5-7 CHS end, 8-11 LBA start sector, 12-15 LBA sector count, little-endian. Read
# through `od -An -v -tu1` those are 16 fields, so the type is $5, the start is
# $9..$12 and the count is $13..$16.
#
# The byte dance in mbr_write_count is the flasher's, unchanged: nested printf for
# the little-endian value, dd at one absolute offset, then read it back. It is the
# part that silently writes a plausible-but-wrong table when it goes wrong, so it
# is never used without a read-back.

mbr_entry() { # $1 = device, $2 = slot 0..3 -> "type start count", empty if unreadable
	dd if="$1" bs=1 skip=$((446 + 16 * $2)) count=16 2>/dev/null |
		od -An -v -tu1 |
		awk '{ printf "%d %d %d\n", $5, $9 + $10 * 256 + $11 * 65536 + $12 * 16777216,
			$13 + $14 * 256 + $15 * 65536 + $16 * 16777216 }'
}

mbr_write_count() { # $1 = device, $2 = slot, $3 = sector count
	count=$3
	offset=$((446 + 16 * $2 + 12))
	printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
		$(( count & 255 )) $(( (count >> 8) & 255 )) $(( (count >> 16) & 255 )) $(( (count >> 24) & 255 )))" |
		dd of="$1" bs=1 seek="$offset" conv=notrunc 2>/dev/null
}

mbr_slot_of_start() { # $1 = device, $2 = start sector -> slot number, or nothing
	dev=$1
	want=$2
	slot=0
	while [ "$slot" -lt 4 ]; do
		entry=$(mbr_entry "$dev" "$slot")
		set -- $entry
		if [ "${2:-}" = "$want" ]; then
			echo "$slot"
			return 0
		fi
		slot=$((slot + 1))
	done
	return 1
}

mbr_next_start() { # $1 = device, $2 = a start sector -> smallest later start, or nothing
	dev=$1
	after=$2
	best=""
	slot=0
	while [ "$slot" -lt 4 ]; do
		entry=$(mbr_entry "$dev" "$slot")
		set -- $entry
		start=${2:-0}
		if [ "$start" -gt "$after" ] && { [ -z "$best" ] || [ "$start" -lt "$best" ]; }; then
			best=$start
		fi
		slot=$((slot + 1))
	done
	[ -n "$best" ] && echo "$best"
	return 0
}

mbr_whole_disk_of() { # $1 = device name or path -> the whole disk node name
	case "$1" in
	*nvme* | *mmcblk*)
		case "$1" in
		*p[0-9]*) printf '%s' "${1%p[0-9]*}" ;;
		*) printf '%s' "$1" ;;
		esac
		;;
	*[0-9]*) printf '%s' "${1%[0-9]}" ;;
	*) printf '%s' "$1" ;;
	esac
	return 0
}
