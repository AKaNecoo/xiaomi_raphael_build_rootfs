#!/bin/bash
set -e

# Raphael GPS + IMU/地磁：统一喂入 /dev/gps0 → gpsd → xgps
#
#   Qualcomm SoC GPS 没有独立 NMEA 串口，gpsd 无法直接读硬件。
#   IMU/地磁走 SSC(ssccli)。为避免 xgps 在多设备间来回切换，全部写入同一 PTY：
#
#   1) /usr/local/sbin/raphael-gpsd-bridge
#        - mmcli NMEA（GNSS）
#        - 紧凑 $OHPR（heading/pitch/roll + mag XYZ + accel + gyro）
#   2) raphael-gpsd-bridge.service —— After=ModemManager，自动拉起
#   3) /etc/default/gpsd —— 关闭 USBAUTO，由桥接 gpsdctl add /dev/gps0
#   4) 启用 gpsd.socket + raphael-gpsd-bridge.service
#
#   说明：$OHPR 会让该设备识别为 OceanServer，但仍走 NMEA 解析，GNSS TPV 可用。
#   $OHPR 必须短于 gpsd NMEA_MAX(110)，否则会被丢弃。

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10e] 📡 配置 GPS+IMU：ModemManager/SSC → gpsd 桥接"

install -d rootdir/usr/local/sbin
install -d rootdir/etc/systemd/system
install -d rootdir/etc/default

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10e]   └─ raphael-gpsd-bridge"
cat > rootdir/usr/local/sbin/raphael-gpsd-bridge << 'EOF'
#!/usr/bin/env python3
# Raphael: feed ModemManager GNSS NMEA + SSC IMU/mag ($OHPR) into one PTY for gpsd/xgps.
import math
import os
import pty
import re
import select
import signal
import subprocess
import threading
import time

GPS_LINK = "/dev/gps0"
QRTR_DEV = "qrtr://0"
REFRESH_SEC = 1
MODEM_WAIT_SEC = 180
SETUP_RETRY_SEC = 5
POS_CACHE = "/var/lib/raphael-gps/last-position"
NO_FIX_RESEED_SEC = 90
IMU_INTERVAL_SEC = 0.2
SSC_RESTART_SEC = 2
NMEA_MAX = 110

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

def nmea_checksum(body):
    c = 0
    for ch in body:
        c ^= ord(ch)
    return f"{c:02X}"

def nmea_sentence(body):
    return f"${body}*{nmea_checksum(body)}\r\n"

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
    os.close(slave)
    try:
        os.unlink(GPS_LINK)
    except FileNotFoundError:
        pass
    os.symlink(slave_name, GPS_LINK)
    return master, slave_name

def drain_master(master):
    while True:
        r, _, _ = select.select([master], [], [], 0)
        if not r:
            return
        try:
            os.read(master, 4096)
        except OSError:
            return

class SensorHub:
    RE_XYZ = re.compile(
        r"(Accelerometer|Gyroscope|Magnetometer) sensor measurement:\s*"
        r"X=([-0-9.eE+]+)\s+Y=([-0-9.eE+]+)\s+Z=([-0-9.eE+]+)"
    )
    RE_COMPASS = re.compile(r"Compass sensor measurement:\s*([-0-9.eE+]+)\s*")

    def __init__(self):
        self.lock = threading.Lock()
        self.accel = self.gyro = self.mag = None
        self.heading = None
        self._stop = threading.Event()

    def start(self):
        for sensor in ("accelerometer", "gyroscope", "magnetometer", "compass"):
            threading.Thread(target=self._reader, args=(sensor,), daemon=True).start()

    def stop(self):
        self._stop.set()

    def _reader(self, sensor):
        while not self._stop.is_set():
            try:
                proc = subprocess.Popen(
                    ["ssccli", f"--sensor={sensor}", "--timeout=3600"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    bufsize=1,
                )
            except OSError as exc:
                log(f"ssccli {sensor} failed: {exc}")
                time.sleep(SSC_RESTART_SEC)
                continue
            try:
                while not self._stop.is_set():
                    line = proc.stdout.readline()
                    if not line:
                        break
                    m = self.RE_XYZ.search(line)
                    if m:
                        kind = m.group(1)
                        sample = (float(m.group(2)), float(m.group(3)), float(m.group(4)))
                        with self.lock:
                            if kind == "Accelerometer":
                                self.accel = sample
                            elif kind == "Gyroscope":
                                self.gyro = sample
                            elif kind == "Magnetometer":
                                self.mag = sample
                        continue
                    m = self.RE_COMPASS.search(line)
                    if m:
                        with self.lock:
                            self.heading = float(m.group(1))
            finally:
                try:
                    proc.terminate()
                    proc.wait(timeout=2)
                except Exception:
                    try:
                        proc.kill()
                    except Exception:
                        pass
            if not self._stop.is_set():
                time.sleep(SSC_RESTART_SEC)

    def snapshot(self):
        with self.lock:
            return self.accel, self.gyro, self.mag, self.heading

def pitch_roll(ax, ay, az):
    return (
        math.degrees(math.atan2(-ax, math.sqrt(ay * ay + az * az))),
        math.degrees(math.atan2(ay, az)),
    )

def build_ohpr(accel, gyro, mag, heading):
    ax = ay = az = gx = gy = mx = my = mz = 0.0
    pitch = roll = 0.0
    if accel:
        ax, ay, az = accel
        pitch, roll = pitch_roll(ax, ay, az)
    if gyro:
        gx, gy = (gyro[0] * 180.0 / math.pi, gyro[1] * 180.0 / math.pi)
    if mag:
        mx, my, mz = mag
    if heading is None and mag:
        heading = (math.degrees(math.atan2(-my, mx)) + 360.0) % 360.0
    if heading is None:
        heading = 0.0

    mag_len = math.sqrt(mx * mx + my * my + mz * mz)
    acc_len = math.sqrt(ax * ax + ay * ay + az * az)
    body = (
        "OHPR,"
        f"{heading:.1f},{pitch:.1f},{roll:.1f},"
        "25,0,"
        f"{mag_len:.1f},{mx:.1f},{my:.1f},{mz:.1f},"
        f"{acc_len:.2f},{ax:.2f},{ay:.2f},{az:.2f},"
        f"0,{gx:.1f},{gy:.1f},0,0"
    )
    sentence = nmea_sentence(body)
    if len(sentence) - 2 > NMEA_MAX:
        return None
    return sentence

def imu_writer(master, sensors, stop_event, write_lock):
    log("IMU/mag feeder started")
    while not stop_event.is_set():
        drain_master(master)
        accel, gyro, mag, heading = sensors.snapshot()
        if accel or gyro or mag or heading is not None:
            sentence = build_ohpr(accel, gyro, mag, heading)
            if sentence:
                try:
                    with write_lock:
                        os.write(master, sentence.encode())
                except OSError as exc:
                    log(f"IMU pty write failed: {exc}")
                    stop_event.set()
                    return
        time.sleep(IMU_INTERVAL_SEC)
    log("IMU/mag feeder stopped")

def main():
    stop = False
    stop_event = threading.Event()

    def _stop(*_):
        nonlocal stop
        stop = True
        stop_event.set()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    # Remove legacy separate ATT device if still present.
    for stale in ("/dev/gps-att0", "/dev/gps-imu0"):
        run(["gpsdctl", "remove", stale])
        try:
            os.unlink(stale)
        except FileNotFoundError:
            pass

    master, slave_name = create_pty()
    write_lock = threading.Lock()
    log(f"pty {slave_name} -> {GPS_LINK}")

    sensors = SensorHub()
    sensors.start()
    imu_thread = threading.Thread(
        target=imu_writer,
        args=(master, sensors, stop_event, write_lock),
        daemon=True,
    )
    imu_thread.start()

    mid = None
    while not stop and mid is None:
        mid = wait_modem(timeout=MODEM_WAIT_SEC)
        if mid is None:
            log("waiting for ModemManager modem...")
    if stop:
        sensors.stop()
        return 0

    log(f"modem {mid}")
    while not stop and not setup_gps(mid):
        log("GPS setup failed, retrying...")
        time.sleep(SETUP_RETRY_SEC)

    ensure_gpsd(GPS_LINK)
    log("feeding NMEA+OHPR to gpsd")

    last_add = time.monotonic()
    last_fix_at = None
    last_reseed = time.monotonic()
    while not stop:
        r = run(["mmcli", "-m", mid, "--location-get"], timeout=10)
        if r.returncode != 0:
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
                with write_lock:
                    os.write(master, (sentence + "\r\n").encode())
            except OSError as exc:
                log(f"pty write failed: {exc}")
                stop = True
                stop_event.set()
                break

        now = time.monotonic()
        if now - last_add > 60:
            ensure_gpsd(GPS_LINK)
            last_add = now

        if (last_fix_at is None or now - last_fix_at > NO_FIX_RESEED_SEC) and (
            now - last_reseed > NO_FIX_RESEED_SEC
        ):
            log("no fix yet, re-injecting assistance")
            inject_assistance()
            last_reseed = now

        time.sleep(REFRESH_SEC)

    stop_event.set()
    sensors.stop()
    imu_thread.join(timeout=3)
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
Description=Raphael ModemManager NMEA + SSC IMU to gpsd bridge
Documentation=man:gpsd(8)
After=ModemManager.service gpsd.socket
Wants=ModemManager.service gpsd.socket

[Service]
Type=simple
ExecStart=/usr/local/sbin/raphael-gpsd-bridge
Restart=on-failure
RestartSec=5
# Bridge must create /dev/gps0 and talk to gpsdctl / mmcli / qmicli / ssccli.
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_DAC_OVERRIDE
PrivateTmp=no

[Install]
WantedBy=multi-user.target
EOF

cat > rootdir/etc/default/gpsd << 'EOF'
# Raphael: GNSS + IMU/mag come from raphael-gpsd-bridge via a single PTY
# (/dev/gps0). Do not point DEVICES at a missing node at boot.
DEVICES=""

# -n: do not wait for a client before opening devices (bridge adds ASAP).
# -b: readonly — ignore OceanServer configure probes on the PTY.
GPSD_OPTIONS="-n -b"

# No USB GPS on this device; avoid gpsdctl USB auto-add races.
USBAUTO="false"
EOF

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10e]   └─ 启用服务"
chroot rootdir systemctl enable gpsd.socket
chroot rootdir systemctl enable raphael-gpsd-bridge.service

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10e] ✅ GPS+IMU / gpsd 单设备桥接配置完成"
