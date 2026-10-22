#!/bin/sh
# Build the kernel Image with container support for a Samsung sm8250 LineageOS device.
#
#   container-kit/build.sh [device]        device = r8q (default), c1q, c2q, x1q, ...
#
# Env: OUT (default: out), CLANG_DIR (default: ../clang-r563880c, downloaded if missing),
#      JOBS (default: nproc)
# Needs: git make bc bison flex libssl-dev libelf-dev python3 cpio curl build-essential
set -e

DEVICE=${1:-r8q}
SRC=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$SRC/out}
CLANG_DIR=${CLANG_DIR:-$SRC/../clang-r563880c}
JOBS=${JOBS:-$(nproc)}
# LineageOS 23.2 builds this tree with AOSP clang r563880c (see /proc/version on the device)
CLANG_URL=https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android16-qpr2-release/clang-r563880c.tar.gz

[ -f "$SRC/arch/arm64/configs/vendor/samsung/$DEVICE.config" ] ||
    { echo "unknown device: $DEVICE (no vendor/samsung/$DEVICE.config)"; exit 1; }

if [ ! -x "$CLANG_DIR/bin/clang" ]; then
    echo "fetching clang r563880c -> $CLANG_DIR"
    mkdir -p "$CLANG_DIR"
    curl -fsSL "$CLANG_URL" | tar xz -C "$CLANG_DIR"
fi
export PATH="$CLANG_DIR/bin:$PATH"

# same config chain as device/samsung/sm8250-common + device/samsung/$DEVICE, plus ours
CONFIGS="vendor/kona-perf_defconfig vendor/samsung/kona-sec-common.config
         vendor/samsung/$DEVICE.config vendor/container.config"

set -- O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi-

cd "$SRC"
make "$@" $CONFIGS
make -j"$JOBS" "$@" Image

IMG=$OUT/arch/arm64/boot/Image
echo
strings "$IMG" | grep -m1 '^Linux version'
sha256sum "$IMG"
