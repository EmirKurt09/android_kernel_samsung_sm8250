#!/system/bin/sh
# Run on the device as root (Magisk). Swaps only the kernel inside the *current* boot
# image, so the Magisk ramdisk, dtb, cmdline and header stay untouched.
#
#   sh repack-boot.sh /sdcard/Image            -> backup + new-boot.img, no write
#   sh repack-boot.sh /sdcard/Image --flash    -> same, then dd + verify
#
# Output dir: /sdcard/container-kit/ (boot-backup-<date>.img, new-boot.img, SHA256SUMS)
set -e
IMG=$1
MB=/data/adb/magisk/magiskboot
P=/dev/block/by-name/boot
D=/sdcard/container-kit
W=/data/local/tmp/container-kit

[ "$(id -u)" = 0 ] || { echo "needs root"; exit 1; }
[ -f "$IMG" ] || { echo "usage: $0 <Image> [--flash]"; exit 1; }
[ -x "$MB" ] || { echo "magiskboot not found ($MB)"; exit 1; }
head -c 64 "$IMG" | grep -q ARMd || { echo "$IMG is not a raw arm64 Image"; exit 1; }

mkdir -p "$D"
rm -rf "$W"; mkdir -p "$W"; cd "$W"

BK=$D/boot-backup-$(date +%Y%m%d-%H%M%S).img
dd if=$P of="$BK" bs=4M 2>/dev/null
[ "$(sha256sum $P | cut -c1-64)" = "$(sha256sum "$BK" | cut -c1-64)" ] ||
    { echo "backup verify failed"; exit 1; }
echo "backup: $BK"

$MB unpack "$BK" >/dev/null 2>&1
cp "$IMG" kernel
$MB repack "$BK" "$D/new-boot.img" >/dev/null 2>&1

# re-unpack and make sure only the kernel changed
mkdir v; cd v; $MB unpack "$D/new-boot.img" >/dev/null 2>&1; cd ..
[ "$(sha256sum v/kernel | cut -c1-64)" = "$(sha256sum "$IMG" | cut -c1-64)" ] || { echo "kernel mismatch"; exit 1; }
for f in dtb ramdisk.cpio; do
    [ ! -f $f ] || cmp -s $f v/$f || { echo "$f changed, aborting"; exit 1; }
done
NEW=$(sha256sum "$D/new-boot.img" | cut -c1-64)
(cd "$D" && sha256sum "$(basename "$BK")" new-boot.img > SHA256SUMS)
echo "new-boot.img: $NEW"

[ "$2" = --flash ] || { echo "not flashed (pass --flash)"; exit 0; }
dd if="$D/new-boot.img" of=$P bs=4M 2>/dev/null && sync
[ "$(sha256sum $P | cut -c1-64)" = "$NEW" ] || {
    echo "partition verify FAILED, restoring backup"
    dd if="$BK" of=$P bs=4M && sync
    exit 1
}
echo "flashed and verified, reboot when ready"
