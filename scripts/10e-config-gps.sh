#!/bin/bash
set -e

# Raphael GPS：ModemManager QMI LOC NMEA → PTY(/dev/gps0) → gpsd
#
#   Qualcomm SoC GPS 没有独立 NMEA 串口，gpsd 无法直接读硬件。
#   本脚本安装桥接服务，把 mmcli 拿到的 NMEA 喂给伪终端，供系统 gpsd 使用。
#
#   1) /usr/local/sbin/raphael-gpsd-bridge —— Python 桥接（上电/解锁引擎/开 GPS/喂 NMEA）
#   2) raphael-gpsd-bridge.service —— After=ModemManager，自动拉起
#   3) /etc/default/gpsd —— 关闭 USBAUTO，由桥接 gpsdctl add /dev/gps0
#   4) 启用 gpsd.socket + raphael-gpsd-bridge.service

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10e] 📡 配置 GPS：ModemManager → gpsd 桥接"

install -d rootdir/usr/local/sbin
install -d rootdir/etc/systemd/system
install -d rootdir/etc/default

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10e]   └─ raphael-gpsd-bridge"
cat > rootdir/usr/local/sbin/raphael-gpsd-bridge << 'EOF'
#!/usr/bin/env python3
# Raphael: feed ModemManager QMI LOC NMEA into a PTY for system gpsd.
import os
import re
import pty
import time
import signal
import subprocess

GPS_LINK = "/dev/gps0"
QRTR_DEV = "qrtr://0"
REFRESH_SEC = 1
MODEM_WAIT_SEC = 180
SETUP_RETRY_SEC = 5
POS_CACHE = "/var/lib/raphael-gps/last-position"
NO_FIX_RESEED_SEC = 90

def run(cmd, timeout=30):
    try:
        return subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        return subprocess.CompletedProcess(cmd, 124, exc.stdout or "", exc.stderr or "")

def log(msg):
    print(f"raphael-gpsd-bridge: {msg}", flush=True)

def wait_modem(timeout=MODEM_WAIT_SEC):
    for _ in range(timeout):
        r = run(["mmcli", "-L"])
        m = re.search(r"/Modem/(\d+)", r.stdout or "")
        if m:
            return m.group(1)
        time.sleep(1)
    return None

def load_cached_position():
    try:
        with open(POS_CACHE, "r", encoding="utf-8") as fh:
            lat_s, lon_s = fh.read().strip().split()
            return float(lat_s), float(lon_s)
    except (OSError, ValueError):
        return None

def save_cached_position(lat, lon):
    try:
        os.makedirs(os.path.dirname(POS_CACHE), exist_ok=True)
        with open(POS_CACHE, "w", encoding="utf-8") as fh:
            fh.write(f"{lat:.8f} {lon:.8f}\n")
    except OSError as exc:
        log(f"cache write failed: {exc}")

def inject_assistance():
    # Speed up cold TTFF: unlock + UTC time + last-known approx position.
    run(["qmicli", "-p", "-d", QRTR_DEV, "--loc-set-engine-lock=none"])
    run(["qmicli", "-p", "-d", QRTR_DEV, "--loc-inject-time"])
    cached = load_cached_position()
    if cached:
        lat, lon = cached
        run([
            "qmicli", "-p", "-d", QRTR_DEV,
            f"--loc-inject-position-latitude={lat}",
            f"--loc-inject-position-longitude={lon}",
        ])
        log(f"injected cached position {lat:.6f},{lon:.6f}")

def setup_gps(mid):
    run(["mmcli", "-m", mid, "--set-power-state-on"])
    inject_assistance()
    run(["mmcli", "-m", mid, f"--location-set-gps-refresh-rate={REFRESH_SEC}"])
    r = run(["mmcli", "-m", mid, "--location-enable-gps-raw", "--location-enable-gps-nmea"])
    return r.returncode == 0

def extract_nmea(text):
    return re.findall(r"\$[A-Z]{2}[A-Z0-9]+,[^*]*\*[0-9A-Fa-f]{2}", text or "")

def parse_fix(text):
    lat = re.search(r"latitude:\s*([-0-9.]+)", text or "")
    lon = re.search(r"longitude:\s*([-0-9.]+)", text or "")
    if lat and lon:
        return float(lat.group(1)), float(lon.group(1))
    return None

def ensure_gpsd(device):
    run(["systemctl", "start", "gpsd.socket"])
    run(["systemctl", "start", "gpsd.service"])
    time.sleep(0.3)
    r = run(["gpsdctl", "add", device])
    if r.returncode != 0:
        log(f"gpsdctl add failed: {r.stderr.strip() or r.stdout.strip()}")
    return r.returncode == 0

def create_pty():
    master, slave = pty.openpty()
    slave_name = os.ttyname(slave)
    os.chmod(slave_name, 0o666)
    # Close slave fd so gpsd can be the sole reader.
    os.close(slave)
    try:
        os.unlink(GPS_LINK)
    except FileNotFoundError:
        pass
    os.symlink(slave_name, GPS_LINK)
    return master, slave_name

def main():
    stop = False

    def _stop(*_):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    master, slave_name = create_pty()
    log(f"pty {slave_name} -> {GPS_LINK}")

    mid = None
    while not stop and mid is None:
        mid = wait_modem(timeout=MODEM_WAIT_SEC)
        if mid is None:
            log("waiting for ModemManager modem...")
    if stop:
        return 0

    log(f"modem {mid}")
    while not stop and not setup_gps(mid):
        log("GPS setup failed, retrying...")
        time.sleep(SETUP_RETRY_SEC)

    ensure_gpsd(GPS_LINK)
    log("feeding NMEA to gpsd")

    last_add = time.monotonic()
    last_fix_at = None
    last_reseed = time.monotonic()
    while not stop:
        r = run(["mmcli", "-m", mid, "--location-get"], timeout=10)
        if r.returncode != 0:
            # Modem may have re-probed; rediscover and re-setup.
            new_mid = wait_modem(timeout=15)
            if new_mid and new_mid != mid:
                mid = new_mid
                log(f"modem reappeared as {mid}")
            setup_gps(mid)
            time.sleep(SETUP_RETRY_SEC)
            continue

        fix = parse_fix(r.stdout)
        if fix:
            save_cached_position(*fix)
            last_fix_at = time.monotonic()

        for sentence in extract_nmea(r.stdout):
            try:
                os.write(master, (sentence + "\r\n").encode())
            except OSError as exc:
                log(f"pty write failed: {exc}")
                stop = True
                break

        now = time.monotonic()
        # Periodically re-add in case gpsd restarted via socket activation.
        if now - last_add > 60:
            ensure_gpsd(GPS_LINK)
            last_add = now

        # If no fix for a while, re-inject time/position (cold start helper).
        if (last_fix_at is None or now - last_fix_at > NO_FIX_RESEED_SEC) and (
            now - last_reseed > NO_FIX_RESEED_SEC
        ):
            log("no fix yet, re-injecting assistance")
            inject_assistance()
            last_reseed = now

        time.sleep(REFRESH_SEC)

    run(["gpsdctl", "remove", GPS_LINK])
    try:
        os.unlink(GPS_LINK)
    except FileNotFoundError:
        pass
    try:
        os.close(master)
    except OSError:
        pass
    log("stopped")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
EOF
chmod 755 rootdir/usr/local/sbin/raphael-gpsd-bridge

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10e]   └─ systemd unit + gpsd defaults"
cat > rootdir/etc/systemd/system/raphael-gpsd-bridge.service << 'EOF'
[Unit]
Description=Raphael ModemManager NMEA to gpsd bridge
Documentation=man:gpsd(8)
After=ModemManager.service gpsd.socket
Wants=ModemManager.service gpsd.socket

[Service]
Type=simple
ExecStart=/usr/local/sbin/raphael-gpsd-bridge
Restart=on-failure
RestartSec=5
# Bridge must create /dev/gps0 and talk to gpsdctl / mmcli / qmicli.
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_DAC_OVERRIDE
PrivateTmp=no

[Install]
WantedBy=multi-user.target
EOF

cat > rootdir/etc/default/gpsd << 'EOF'
# Raphael: GNSS comes from ModemManager QMI LOC via raphael-gpsd-bridge,
# which creates /dev/gps0 (PTY) and hot-adds it with gpsdctl.
# Do not point DEVICES at a missing node at boot.
DEVICES=""

# -n: do not wait for a client before opening devices (bridge adds ASAP).
GPSD_OPTIONS="-n"

# No USB GPS on this device; avoid gpsdctl USB auto-add races.
USBAUTO="false"
EOF

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10e]   └─ 启用服务"
chroot rootdir systemctl enable gpsd.socket
chroot rootdir systemctl enable raphael-gpsd-bridge.service

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10e] ✅ GPS / gpsd 桥接配置完成"
