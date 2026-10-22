# Container support for the LineageOS Samsung sm8250 kernel

Stock LineageOS builds of this kernel leave out the namespaces and cgroups that
runc needs, so Docker, containerd, LXC and rootful podman can't start. This
branch adds one config fragment, `arch/arm64/configs/vendor/container.config`,
plus a few scripts. No kernel code is changed.

**Tested on:** r8q (Galaxy S20 FE, SM-G780G), LineageOS 23.2-20260523-NIGHTLY,
kernel `4.19.325-cip132-st16-perf-gafb0085a5dd6`, Magisk 30.7, Docker 26.1.5
in a Debian 13 chroot. The other devices in this tree (c1q, c2q, x1q, f2q,
gts7*, ...) use the same base config and should work, but they are untested.

## What the fragment enables

| Option | Why |
|---|---|
| `PID_NS`, `IPC_NS`, `SYSVIPC`, `POSIX_MQUEUE` | runc creates pid/ipc namespaces and mounts `/dev/mqueue` for every container |
| `USER_NS` | `--userns-remap`, rootless runtimes (not usable from inside a chroot, see below) |
| `CGROUP_DEVICE`, `CGROUP_PIDS` | device access control and `--pids-limit`; runc on cgroup v1 requires `devices` |
| `BRIDGE_NETFILTER`, `NETFILTER_XT_MATCH_ADDRTYPE`, `IP6_NF_NAT`, `IP6_NF_TARGET_MASQUERADE` | Docker's default bridge network and published ports |
| `IP_VS*`, `NETFILTER_XT_MATCH_IPVS`, `VXLAN`, `MACVLAN`, `IPVLAN` | swarm/overlay, macvlan and ipvlan network drivers |

The rest of the config is unchanged. The config chain
`kona-perf_defconfig` + `samsung/kona-sec-common.config` +
`samsung/r8q.config` reproduces the device's `/proc/config.gz` exactly, and
adding `container.config` reproduces the kernel that was flashed and tested,
again exactly (`scripts/diffconfig` prints nothing).

There are no loadable modules on these devices (`lsmod` is empty), so there's
no vermagic or modversions issue. Samsung's RKP, KDP, DEFEX and FIVE are
already disabled in the LineageOS config, so the extra namespaces don't clash
with them.

## Build

1. **Use the exact commit your device runs.** The 12-character hash after
   `-g` in `adb shell uname -r` is the commit. The branch head moves weekly,
   and Lineage nightlies are built from whatever the head was on that day.

   ```
   git fetch origin <hash> && git checkout <hash>
   git fetch https://github.com/EmirKurt09/android_kernel_samsung_sm8250 lineage-23.2-container
   git cherry-pick afb0085a5dd6..FETCH_HEAD      # container.config + container-kit/
   ```

2. **Use the same compiler.** LineageOS 23.2 builds with AOSP clang r563880c,
   and `build.sh` downloads it from AOSP (`android16-qpr2-release`). Check
   `adb shell cat /proc/version`. If your build says another `rNNNNNN`,
   point `CLANG_DIR` at that release instead.

3. **Build:**

   ```
   container-kit/build.sh r8q            # -> out/arch/arm64/boot/Image
   ```

   It needs `git make bc bison flex libssl-dev libelf-dev python3 cpio curl
   build-essential`. An LTO + CFI build took 3.5 min on 16 threads.

   On Windows or macOS, build inside Docker. Clone into a Linux filesystem (a
   Docker volume or WSL ext4), not NTFS/APFS: the kernel tree has files that
   differ only by case.

   ```
   docker run --rm -v ksrc:/src -w /src -e CLANG_DIR=/src/.clang debian:trixie sh -c \
     'apt-get update -qq && apt-get install -y -qq git make bc bison flex libssl-dev \
      libelf-dev python3 cpio curl build-essential && container-kit/build.sh r8q'
   ```

The version string matches stock, apart from the build user, host and date.

## Flash

Samsung has no `fastboot boot`, so a new kernel can't be test-booted without
flashing it. Keep a backup and know how to get back.

```
adb push out/arch/arm64/boot/Image container-kit/repack-boot.sh /sdcard/
adb shell su -c 'sh /sdcard/repack-boot.sh /sdcard/Image'           # backup + new-boot.img, no write
adb shell su -c 'sh /sdcard/repack-boot.sh /sdcard/Image --flash'   # dd + sha256 verify
adb reboot
```

`repack-boot.sh` dumps the current boot partition to
`/sdcard/container-kit/boot-backup-*.img` and swaps only the kernel with
`magiskboot`. It then checks that the dtb and the Magisk ramdisk are
byte-identical and verifies the partition sha256 after writing. Copy the
backup to your PC.

**Restore.** The recovery partition is never touched, so recovery always boots:

1. Power off. With the cable plugged in, hold Vol Up + Power to reach
   Lineage Recovery.
2. Go to Advanced > Enable ADB.
3. Run:

   ```
   adb push boot-backup-XXXX.img /tmp/boot.img
   adb push container-kit/restore-boot.sh /tmp/
   adb shell sh /tmp/restore-boot.sh /tmp/boot.img && adb reboot
   ```

If recovery doesn't boot either, use Download mode (Vol Up + Vol Down while
plugging in the cable) and flash a tar containing `boot.img` in Odin's AP
slot, or run `heimdall flash --BOOT boot.img`.

Every LineageOS OTA rewrites boot, which replaces the kernel and drops Magisk.
After an update, rebuild for the new commit and flash again.

## Userspace: Docker in a chroot on Android

The kernel is only half of it. These problems came up running Docker in a
Debian chroot under `/data`. Each fix is in
`userspace/service.d-debian.sh`, a Magisk `service.d` script.

| Symptom | Cause | Fix |
|---|---|---|
| `overlayfs: filesystem on '.../upper' not supported` | `/data` is f2fs with casefolding; 4.19 overlayfs rejects it as upperdir | put `/var/lib/docker` on an ext4 image |
| loop device reads 0 bytes / `EXT4-fs: unable to read superblock` | loop can't read files in FBE (inline-crypto) encrypted dirs such as `/data/local/<yours>` | keep the image in an unencrypted dir, e.g. `/data/local/tmp/docker/` (**data at rest is unencrypted**) |
| ext4 image won't mount | Debian 13 `mkfs.ext4` enables `orphan_file` (5.15+) | `mkfs.ext4 -O ^orphan_file,^metadata_csum_seed` |
| `failed to register layer: remount /, flags: 0x84000: invalid argument` | chroot root isn't a mount point | `mount --bind $R $R; mount --make-rprivate $R` before entering |
| `pivot_root .: invalid argument` | the rootfs' parent mount (`/data`) is shared | start dockerd in its own mount ns: `busybox unshare -m --propagation private chroot $R dockerd` |
| `iptables -N DOCKER: No chain/target/match by that name` | netd's `xt_bpf` rules point at pinned programs by path, which don't resolve inside the chroot; `quota2` is unknown to Debian iptables | `mount --rbind /sys/fs/bpf $R/sys/fs/bpf`, `apt install xtables-addons-common`, use `iptables-legacy` (no nf_tables) |
| containers have no network | netd's policy routing only matches `iif lo`/fwmarked traffic; forwarded packets hit `32000: unreachable` | `ip rule add to 172.16.0.0/12 lookup main prio 4999` and `from 172.16.0.0/12 lookup wlan0 prio 5000`; the `wlan0` table appears only once Wi-Fi is up and its id follows the ifindex, so the script re-applies the rule in a loop |
| `ip: invalid table ID 'wlan0'`, `losetup: unknown option --show` at boot only | Magisk runs `service.d` in busybox standalone mode | call `/system/bin/ip`, `/system/bin/losetup`, `/system/bin/mount` explicitly |

Cgroups: mount `devices`, `pids`, `freezer` and `cpuacct` as v1 under the
chroot's `/sys/fs/cgroup` (tmpfs), and bind Android's `/dev/cpuctl` and
`/dev/blkio`. Set `"exec-opts": ["native.cgroupdriver=cgroupfs"]`.
Write `1` to `ip_forward` before dockerd starts, otherwise dockerd switches
the `FORWARD` policy to `DROP`.

## Limitations

- **No memory or CPU limits.** Android keeps `memory` on cgroup2
  (`androidboot.memcg=1`), so it can't be mounted as v1. `docker info` warns;
  containers run unlimited.
- **No user namespaces from inside the chroot.** The kernel refuses
  `CLONE_NEWUSER` for chrooted processes. Rootful Docker doesn't need them.
- Root inside the chroot is root on the phone. A chroot is not a security
  boundary.

## License

GPL-2.0, same as the kernel.
