#!/system/bin/sh
# Magisk late_start service (/data/adb/service.d/, root:root 755): Debian chroot + sshd + dockerd.
# Chroot rootfs in $R; docker storage image in $DIMG (see ../README.md, "Userspace").
R=/data/local/debian
BB=/data/adb/magisk/busybox
# service.d runs in busybox standalone mode: use Android's ip (knows netd table names)
IP=/system/bin/ip
LOG=/data/local/tmp/debian-boot.log

exec >>"$LOG" 2>&1
echo "=== $(date) ==="

is_mnt() { grep -q " $1 " /proc/mounts; }
# busybox pgrep (standalone mode) misses some processes; match /proc/*/comm directly
running() {
    for p in /proc/[0-9]*; do
        [ "$(cat "$p/comm" 2>/dev/null)" = "$1" ] && return 0
    done
    return 1
}

# /data defaults to nosuid,nodev
$BB mount -o remount,dev,suid /data || echo "remount /data failed"

# make the chroot root a real mount point: dockerd/unshare need to remount / private
if ! is_mnt "$R"; then
    $BB mount --bind "$R" "$R"
    # keep docker/container mounts from propagating back into Android's /data peers
    $BB mount --make-rprivate "$R"
fi
is_mnt "$R/dev"     || $BB mount --bind /dev "$R/dev"
is_mnt "$R/dev/pts" || $BB mount --bind /dev/pts "$R/dev/pts"
is_mnt "$R/proc"    || $BB mount -t proc proc "$R/proc"
is_mnt "$R/sys"     || $BB mount -t sysfs sysfs "$R/sys"
is_mnt "$R/tmp"     || $BB mount -t tmpfs -o mode=1777 tmpfs "$R/tmp"
# fresh /run each boot so stale pid files (docker, containerd, sshd) can't block startup
is_mnt "$R/run"     || $BB mount -t tmpfs -o mode=755 tmpfs "$R/run"

mkdir -p "$R/run/sshd" "$R/run/lock"
chmod 755 "$R/run/sshd"

ch() {
    $BB chroot "$R" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root TERM=xterm-256color LANG=C.UTF-8 "$@"
}

if [ -x "$R/usr/sbin/sshd" ]; then
    PID=$(cat "$R/run/sshd.pid" 2>/dev/null)
    if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
        echo "sshd already running ($PID)"
    else
        ch /usr/sbin/sshd && echo "sshd started"
    fi
fi

# docker (needs the custom kernel with PID/IPC ns, CGROUP_DEVICE, ...)
# storage: ext4 image outside the FBE tree; loop can't read inline-encrypted files and
# overlayfs rejects casefolded f2fs as upperdir
DIMG=/data/local/tmp/docker/docker.img
if [ -x "$R/usr/sbin/dockerd" ] && [ -f "$DIMG" ]; then
    CG=$R/sys/fs/cgroup
    is_mnt "$CG" || $BB mount -t tmpfs -o mode=755 cgroup_root "$CG"
    # memory is on Android's cgroup2 hierarchy and can't also be mounted as v1
    for c in devices pids freezer cpuacct; do
        mkdir -p "$CG/$c"
        is_mnt "$CG/$c" || $BB mount -t cgroup -o "$c" cgroup "$CG/$c"
    done
    for c in cpu:cpuctl blkio:blkio; do
        mkdir -p "$CG/${c%%:*}"
        is_mnt "$CG/${c%%:*}" || $BB mount --bind "/dev/${c##*:}" "$CG/${c%%:*}"
    done
    # netd's xt_bpf rules reference pinned programs by path; chroot iptables must resolve them
    is_mnt "$R/sys/fs/bpf" || $BB mount --rbind /sys/fs/bpf "$R/sys/fs/bpf"
    if ! is_mnt "$R/var/lib/docker"; then
        L=$(/system/bin/losetup -f --show "$DIMG") && /system/bin/mount -t ext4 -o noatime "$L" "$R/var/lib/docker"
    fi
    # enable forwarding ourselves so dockerd doesn't flip the FORWARD policy to DROP
    echo 1 > /proc/sys/net/ipv4/ip_forward
    # Android policy routing only covers iif lo / fwmarked traffic: route container
    # egress via wlan0's table and replies to containers via main (docker bridges)
    $IP rule show | grep -q "to 172.16.0.0/12 lookup main" ||
        $IP rule add to 172.16.0.0/12 lookup main prio 4999
    # netd creates the wlan0 table only once wifi is up, and its id follows the
    # ifindex, so keep re-pointing the egress rule (wifi toggles recreate wlan0)
    if ! running docker-netwatch; then
        # generated into the /run tmpfs each boot; a shebang script's comm is its file name
        W=$R/run/docker-netwatch
        cat > "$W" <<EOF
#!/system/bin/sh
while :; do
    if ! $IP rule show | grep -q "from 172.16.0.0/12 lookup wlan0" &&
        $IP route show table wlan0 >/dev/null 2>&1; then
        while $IP rule del prio 5000 2>/dev/null; do :; done
        $IP rule add from 172.16.0.0/12 lookup wlan0 prio 5000 &&
            echo "\$(date +%T) docker egress rule -> wlan0"
    fi
    sleep 30
done
EOF
        chmod 700 "$W"
        "$W" &
        echo "docker-netwatch started"
    fi
    if running dockerd; then
        echo "dockerd already running"
    else
        # own mount ns with private propagation: runc's pivot_root refuses when the
        # rootfs' parent (Android's shared /data) is shared
        nohup $BB unshare -m --propagation private $BB chroot "$R" /usr/bin/env -i \
            PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
            /usr/sbin/dockerd >>"$R/var/log/dockerd.log" 2>&1 &
        echo "dockerd started"
    fi
fi
