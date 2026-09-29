#!/bin/busybox sh
# bmap-write: write a raw image from stdin onto a block device, touching only the
# ranges listed in a bmap file, then verify what landed by reading it back.
#
# busybox only (dd, awk, sha256sum, od), no python: this runs inside the flash
# initramfs, where the only userspace is a static busybox.
#
# The image stream is sequential and the bmap ranges are in ascending offset
# order, so one pass over the stream is enough: for every range, discard the gap
# blocks with dd on /dev/null, then write that range at its offset with
# dd of=$device seek=<offset in blocks> conv=notrunc.
#
# Unmapped blocks are never written. The target must therefore already be zero
# there (a fresh card, or a card this tool wrote before): on a used card, stale
# data survives in the holes. Use --full to write every byte instead.
#
# usage: bmap-write -b <bmap> -t <device> [-n] [-q] [--full]
#   -b <bmap>    bmap file (bmaptool XML v2.0 with per-range chksum)
#   -t <device>  whole-disk block device to write
#   -n           skip the read-back verification
#   -q           quiet: only errors and the final summary
#   --full       ignore the bmap and write the whole stream sequentially
#
# Exit: 0 ok, 1 usage/target problem, 2 bmap problem, 3 stream read failed,
#       4 write failed, 5 verification mismatch.

set -u

sed_cmd="sed"
# These applets are ordinary PATH lookups in the initramfs (static busybox
# provides all of them); fall back to an explicit busybox if PATH is bare.
dd_cmd="dd"
sha_cmd="sha256sum"
aw_cmd="awk"

die() { echo "[error] $*" >&2; exit "$2"; }

usage() {
	cat >&2 <<'EOF'
usage: bmap-write -b <bmap> -t <device> [-n] [-q] [--full] [--check-gaps]
  -b <bmap>      bmap file (bmaptool XML v2.0 with per-range chksum)
  -t <device>    whole-disk block device to write
  -n             skip read-back verification
  -q             quiet
  --full         write every byte, ignore the bmap
  --check-gaps   write nothing: only check that the blocks the image leaves out
                 (the gaps between ranges) are already zero on the target
EOF
	exit 1
}

BMAP=""
TARGET=""
VERIFY=1
QUIET=0
FULL=0
CHECKGAPS=0

while [ $# -gt 0 ]; do
	case "$1" in
	-b) [ $# -ge 2 ] || usage; BMAP="$2"; shift 2 ;;
	-t) [ $# -ge 2 ] || usage; TARGET="$2"; shift 2 ;;
	-n) VERIFY=0; shift ;;
	-q) QUIET=1; shift ;;
	--full) FULL=1; shift ;;
	--check-gaps) CHECKGAPS=1; shift ;;
	*) usage ;;
	esac
done

[ -n "$TARGET" ] || usage
[ -b "$TARGET" ] || die "$TARGET is not a block device" 1

say() { [ "$QUIET" = 1 ] || echo "$@"; }

# dd reports "N+M records out" and still exits 0 when the input ends early:
# count the full blocks it wrote so a truncated stream fails right here.
dd_blocks_written() { # $1 = dd stderr file
	$aw_cmd '/records out/ { print $1; exit }' "$1" | $sed_cmd 's/+.*//'
}

# The one above counts full blocks, which is only right while dd reads in small
# blocks. Given bs=4M on a pipe, busybox dd reports "0+N records out" - the
# partial count, not bytes - so a complete 4 GiB write looks like zero blocks
# written and a short stream cannot be told from a good one. For big blocks read
# the byte count instead: "N bytes ... copied" is the same line shape in busybox
# and GNU dd. A truncated stream still reports its short byte count, because dd
# counts what it has copied before the input ends, not full blocks only.
dd_bytes_copied() { # $1 = dd stderr file
	$aw_cmd '/copied/ { print $1; exit }' < "$1"
}

# ------------------------------------------------------------------ full write
if [ "$FULL" = 1 ]; then
	say "[write] full write to $TARGET (no bmap)"
	# The stream is the whole image, so this is one long dd. This busybox has no
	# dd status=progress (its dd stops at conv=), so sample what the kernel has
	# handed to the device instead: /sys/class/block/<dev>/stat field 7 counts
	# sectors written. Only the sampler is backgrounded and the write stays in
	# the foreground: an asynchronous command in ash gets /dev/null as its stdin,
	# so a backgrounded dd would throw the image away and still look like it
	# succeeded. Sampling also must not steal stdin: awk given a missing file
	# falls back to reading stdin, so always redirect the file in.
	dev_stat="/sys/class/block/$(basename "$TARGET")/stat"
	before=$($aw_cmd '{ print $7 }' < "$dev_stat" 2>/dev/null)
	# The bmap is only parsed further down, after this branch: a full write knows
	# the image size only if its bmap was given (flash mode always gives one).
	# With no size there is no percentage and no short-stream check.
	IMAGE_SIZE=${IMAGE_SIZE:-}
	if [ -z "$IMAGE_SIZE" ] && [ -n "$BMAP" ] && [ -r "$BMAP" ]; then
		IMAGE_SIZE=$($aw_cmd '/<ImageSize>/ { gsub(/<[^>]*>/, " "); print $1; exit }' < "$BMAP")
	fi
	case "$IMAGE_SIZE" in ''|*[!0-9]*) IMAGE_SIZE=0 ;; esac
	(
		started=$(date +%s)
		while :; do
			sleep 5
			[ "$QUIET" = 0 ] && [ -n "$before" ] && [ "$IMAGE_SIZE" -gt 0 ] || continue
			now=$($aw_cmd '{ print $7 }' < "$dev_stat" 2>/dev/null)
			[ -n "$now" ] || continue
			written=$(( (now - before) * 512 ))
			[ "$written" -lt 0 ] && written=0
			pct=$((written * 100 / IMAGE_SIZE))
			[ "$pct" -gt 99 ] && pct=99
			waited=$(( $(date +%s) - started ))
			eta=""
			[ "$written" -gt 0 ] && [ "$waited" -gt 0 ] &&
				eta=", $(( (IMAGE_SIZE - written) * waited / written / 60 ))m$(( ((IMAGE_SIZE - written) * waited / written) % 60 ))s left"
			echo "[write]  $pct%  $((written / 1048576))/$((IMAGE_SIZE / 1048576)) MiB written$eta"
		done
	) &
	progpid=$!
	start=$(date +%s)
	full_err=/tmp/bmap-full-dd.err
	$dd_cmd of="$TARGET" bs=4M conv=fsync 2>"$full_err"
	rc=$?
	kill "$progpid" 2>/dev/null
	wait "$progpid" 2>/dev/null
	elapsed=$(( $(date +%s) - start ))
	[ "$rc" = 0 ] || die "write failed (dd exit $rc)" 4
	if [ "$IMAGE_SIZE" -gt 0 ]; then
		# dd exits 0 when its input ends early, exactly as in the sparse path:
		# compare the byte count it reported against the image size.
		wrote=$(dd_bytes_copied "$full_err")
		case "$wrote" in ''|*[!0-9]*) wrote=0 ;; esac
		[ "$wrote" -ge "$IMAGE_SIZE" ] ||
			die "short stream: dd copied $((wrote / 1048576)) MiB of $((IMAGE_SIZE / 1048576)) MiB" 3
	else
		say "[warn] no bmap given: cannot tell a short stream from a complete one"
	fi
	say "[write] full write done in ${elapsed}s"
	[ "$VERIFY" = 0 ] || say "[verify] skipped: full writes are verified with the image sha256"
	exit 0
fi

[ -n "$BMAP" ] || usage
[ -r "$BMAP" ] || die "cannot read bmap $BMAP" 2

BLOCK=$($aw_cmd '/<BlockSize>/ { gsub(/<[^>]*>/, " "); print $1; exit }' "$BMAP")
case "$BLOCK" in
''|*[!0-9]*) die "no usable BlockSize in $BMAP" 2 ;;
esac
IMAGE_SIZE=$($aw_cmd '/<ImageSize>/ { gsub(/<[^>]*>/, " "); print $1; exit }' "$BMAP")
MAPPED=$($aw_cmd '/<MappedBlocksCount>/ { gsub(/<[^>]*>/, " "); print $1; exit }' "$BMAP")

RANGES=/tmp/bmap-ranges
ERRLOG=/tmp/bmap-dd.err
$aw_cmd '
	/<Range/ {
		line = $0
		chksum = ""
		if (match(line, /chksum="[0-9a-fA-F]+"/))
			chksum = substr(line, RSTART + 8, RLENGTH - 9)
		gsub(/<[^>]*>/, " ", line)
		n = split(line, f, " ")
		c = 0
		for (i = 1; i <= n; i++)
			if (f[i] != "") { c++; v[c] = f[i] }
		if (c >= 2) print v[1], v[2], chksum
	}
' "$BMAP" > "$RANGES" || die "cannot parse ranges from $BMAP" 2

COUNT=$(wc -l < "$RANGES")
[ "$COUNT" -gt 0 ] || die "no ranges in $BMAP" 2
say "[bmap] $COUNT ranges, block $BLOCK, image $((IMAGE_SIZE / 1048576)) MiB, mapped $((MAPPED * BLOCK / 1048576)) MiB to write"

# ------------------------------------------------------------- the gap check
# A sparse write leaves the blocks between ranges exactly as they were, and the
# image is zero there by construction, so those blocks must already be zero on
# the target. Run this before anything is written: a target that fails here can
# still be re-flashed with --full while the installed system is untouched.
if [ "$CHECKGAPS" = 1 ]; then
	image_blocks=$((IMAGE_SIZE / BLOCK))
	say "[check] the target must be zero outside the image's mapped blocks"
	checked=0
	vpos=0
	next_pct=5
	start=$(date +%s)
	check_gap() { # $1 = first block, $2 = block count
		zero_sha=$($dd_cmd if=/dev/zero bs="$BLOCK" count="$2" 2>/dev/null |
			$sha_cmd | $aw_cmd '{ print $1 }')
		card_sha=$($dd_cmd if="$TARGET" bs="$BLOCK" skip="$1" count="$2" 2>/dev/null |
			$sha_cmd | $aw_cmd '{ print $1 }')
		[ "$card_sha" = "$zero_sha" ] ||
			die "the target is not zero at offset $(( $1 * BLOCK )) ($(( $2 * BLOCK )) bytes): a sparse write leaves those blocks untouched and the image holds zeros there. Write every byte instead, or zero the target first." 6
		checked=$((checked + $2 * BLOCK))
	}
	exec 3< "$RANGES"
	while read -r off len chksum <&3; do
		[ -n "${off:-}" ] || continue
		off_blocks=$((off / BLOCK))
		[ "$off_blocks" -gt "$vpos" ] && check_gap "$vpos" "$((off_blocks - vpos))"
		vpos=$((off_blocks + len / BLOCK))
		if [ "$QUIET" = 0 ]; then
			pct=$((vpos * 100 / image_blocks))
			if [ "$pct" -ge "$next_pct" ]; then
				next_pct=$((pct + 5))
				echo "[check]  $pct%  $((vpos * BLOCK / 1048576))/$((IMAGE_SIZE / 1048576)) MiB of the image position checked"
			fi
		fi
	done
	exec 3<&-
	[ "$image_blocks" -gt "$vpos" ] && check_gap "$vpos" "$((image_blocks - vpos))"
	say "[check]  the $((checked / 1048576)) MiB the image does not map are zero on the target, in $(( $(date +%s) - start ))s"
	exit 0
fi

# ------------------------------------------------------------------- the write
pos=0            # stream position, in blocks
written=0
start=$(date +%s)

exec 3< "$RANGES"
while read -r off len chksum <&3; do
	[ -n "${off:-}" ] || continue
	case "$off$len" in *[!0-9]*) die "malformed range: $off $len" 2 ;; esac
	off_blocks=$((off / BLOCK))
	len_blocks=$((len / BLOCK))
	gap_blocks=$((off_blocks - pos))

	if [ "$gap_blocks" -gt 0 ]; then
		$dd_cmd bs="$BLOCK" count="$gap_blocks" of=/dev/null 2>"$ERRLOG" ||
			die "stream ended early (discarding a gap at $off): $(head -1 "$ERRLOG")" 3
		skipped=$(dd_blocks_written "$ERRLOG")
		[ "${skipped:-0}" -eq "$gap_blocks" ] ||
			die "stream ended early: skipped ${skipped:-0} of $gap_blocks blocks before offset $off" 3
		pos=$off_blocks
	fi

	$dd_cmd bs="$BLOCK" count="$len_blocks" seek="$off_blocks" of="$TARGET" conv=notrunc 2>"$ERRLOG" ||
		die "write failed at offset $off: $(head -1 "$ERRLOG")" 4
	wrote=$(dd_blocks_written "$ERRLOG")
	[ "${wrote:-0}" -eq "$len_blocks" ] ||
		die "short write at offset $off: dd wrote ${wrote:-0} of $len_blocks blocks (the stream ended early)" 4
	pos=$((pos + len_blocks))
	written=$((written + len))

	if [ "$QUIET" = 0 ]; then
		streamed=$((pos * BLOCK))
		pct=$((streamed * 100 / IMAGE_SIZE))
		if [ "$pct" -ge "${next_pct:-2}" ]; then
			next_pct=$((pct + 2))
			el=$(( $(date +%s) - start ))
			[ "$streamed" -gt 0 ] || streamed=1
			eta=$(( (IMAGE_SIZE - streamed) * el / streamed ))
			echo "[write]  $pct%  $((streamed / 1048576))/$((IMAGE_SIZE / 1048576)) MiB streamed, $((written / 1048576)) MiB written, $((eta / 60))m$((eta % 60))s left"
		fi
	fi
done

exec 3<&-
write_el=$(( $(date +%s) - start ))
echo "[write]  100%  $((IMAGE_SIZE / 1048576)) MiB streamed, $((written / 1048576)) MiB written in ${write_el}s"
sync

# ------------------------------------------------------------------ verification
if [ "$VERIFY" = 1 ]; then
	bad=0
	checked=0
	mapped_bytes=$((MAPPED * BLOCK))
	verify_start=$(date +%s)
	exec 3< "$RANGES"
	while read -r off len chksum <&3; do
		[ -n "${off:-}" ] || continue
		[ -n "$chksum" ] || continue
		got=$($dd_cmd if="$TARGET" bs="$BLOCK" skip=$((off / BLOCK)) count=$((len / BLOCK)) 2>"$ERRLOG" |
			$sha_cmd | $aw_cmd '{ print $1 }')
		if [ "$got" != "$chksum" ]; then
			echo "[error] range at $off ($len bytes) read back wrong" >&2
			echo "        expected $chksum" >&2
			echo "        got      $got" >&2
			bad=$((bad + 1))
			[ "$bad" -lt 3 ] || break
		fi
		checked=$((checked + len))
		if [ "$QUIET" = 0 ] && [ "$mapped_bytes" -gt 0 ]; then
			vpct=$((checked * 100 / mapped_bytes))
			if [ "$vpct" -ge "${verify_next:-2}" ]; then
				verify_next=$((vpct + 2))
				echo "[verify]  $vpct%  $((checked / 1048576))/$((mapped_bytes / 1048576)) MiB read back"
			fi
		fi
	done
	exec 3<&-
	[ "$bad" = 0 ] || die "verification failed: re-flash the card in a reader" 5
	echo "[verify]  100%  $((checked / 1048576)) MiB read back, all ranges match, in $(( $(date +%s) - verify_start ))s"
fi

rm -f "$RANGES"
exit 0
