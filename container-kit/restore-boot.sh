#!/system/bin/sh
# Write a boot image back to the boot partition and verify it.
# Works from Android (su) and from Lineage Recovery (Advanced > Enable ADB; adb shell is root):
#
#   adb push boot-backup-XXXX.img /tmp/boot.img
#   adb push restore-boot.sh /tmp/
#   adb shell sh /tmp/restore-boot.sh /tmp/boot.img
set -e
F=$1
P=/dev/block/by-name/boot

[ "$(id -u)" = 0 ] || { echo "needs root"; exit 1; }
[ -f "$F" ] || { echo "usage: $0 <boot.img>"; exit 1; }
head -c 8 "$F" | grep -q 'ANDROID!' || { echo "$F is not an Android boot image"; exit 1; }

WANT=$(sha256sum "$F" | cut -c1-64)
dd if="$F" of=$P bs=4M && sync
[ "$(sha256sum $P | cut -c1-64)" = "$WANT" ] && echo "restored, sha $WANT" || { echo "verify FAILED"; exit 1; }
