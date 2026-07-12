#!/bin/bash
set -e

if [ "$DESKTOP_ENV" != "gnome" ]; then
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14] ⏭️  非 GNOME 桌面，跳过电源键配置"
	exit 0
fi

# 默认用户名，构建时由 USER_NAME 环境变量覆盖
POWER_KEY_USER="${USER_NAME:-user}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14] 🔘 配置电源键（用户: ${POWER_KEY_USER}，短按息屏/亮屏 / 长按1s关机菜单）"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 禁用 systemd 电源键行为"
install -d rootdir/etc/systemd/logind.conf.d
cat > rootdir/etc/systemd/logind.conf.d/power-key.conf << 'EOF'
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=ignore
PowerKeyIgnoreInhibited=yes
EOF

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 安装电源键守护进程"
install -d rootdir/usr/local/sbin
cat > rootdir/usr/local/sbin/power-key-handler.py << 'PYEOF'
#!/usr/bin/env python3
"""
Power Key Handler for GNOME Desktop
Ported from phosh/src/screen-saver-manager.c behavior:
  - Short press (< 1s): toggle screen blank/wake via ScreenSaver DBus
  - Long press (>= 1s): show power menu (shutdown dialog)
"""
import logging
import os
import select
import struct
import subprocess
import sys
import threading
import time

EV_KEY = 0x01
KEY_POWER = 116
EVENT_FMT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FMT)
LONG_PRESS_SEC = 1.0
# Raphael: volume on PMIC resin + gpio-keys; must not wake when screen is off
VOLUME_INPUT_NAMES = frozenset({"pm8941_resin", "gpio-keys"})


def eviocgrab(fd, grab: int):
    """EVIOCGRAB: keep volume keys away from gsd-media-keys while screen is off."""
    import fcntl
    eviocgrab_cmd = (1 << 30) | (ord("E") << 8) | 0x90 | (4 << 16)
    fcntl.ioctl(fd, eviocgrab_cmd, grab)


class VolumeInputGrabber:
    """Grab volume evdev nodes while blanked so only the power key can wake."""

    def __init__(self):
        self._fds = []

    def grab(self):
        if self._fds:
            return
        for name, dev in find_input_devices(VOLUME_INPUT_NAMES):
            try:
                vfd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
                eviocgrab(vfd, 1)
                self._fds.append((name, vfd))
                log.info("grabbed %s (%s) while screen off", name, dev)
            except OSError as e:
                log.warning("grab %s failed: %s", dev, e)

    def release(self):
        for name, vfd in self._fds:
            try:
                eviocgrab(vfd, 0)
            except OSError:
                pass
            try:
                os.close(vfd)
            except OSError:
                pass
            log.info("released %s", name)
        self._fds = []

    def fds(self):
        return [vfd for _, vfd in self._fds]

    def drain(self, vfd):
        try:
            while True:
                data = os.read(vfd, EVENT_SIZE * 32)
                if len(data) < EVENT_SIZE:
                    break
        except BlockingIOError:
            pass
        except OSError:
            pass

logging.basicConfig(
    level=logging.INFO,
    format="power-key: %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("power-key")


def get_user():
    """Get target username: USER_NAME env var, or fallback to current user."""
    user = os.environ.get("USER_NAME")
    if user:
        return user
    import pwd
    return pwd.getpwuid(os.getuid()).pw_name


def find_input_devices(names):
    """Return [(name, /dev/input/eventN), ...] for matching input device names."""
    from pathlib import Path
    out = []
    base = Path("/sys/class/input")
    for name_path in sorted(base.glob("input*/name")):
        name = name_path.read_text().strip()
        if name not in names:
            continue
        num = name_path.parent.name.replace("input", "")
        dev = Path(f"/dev/input/event{num}")
        if dev.exists():
            out.append((name, str(dev)))
    return out


def find_power_input():
    """Locate pm8941_pwrkey evdev device."""
    found = find_input_devices({"pm8941_pwrkey"})
    if found:
        return found[0][1]
    return "/dev/input/event0"


def get_env():
    """Build user session environment for gdbus calls."""
    user = get_user()
    import pwd
    uid = pwd.getpwnam(user).pw_uid
    runtime = f"/run/user/{uid}"
    env = os.environ.copy()
    env.update({
        "HOME": f"/home/{user}",
        "USER": user,
        "LOGNAME": user,
        "XDG_RUNTIME_DIR": runtime,
        "DBUS_SESSION_BUS_ADDRESS": f"unix:path={runtime}/bus",
    })
    for disp in ("wayland-0", "wayland-1"):
        if os.path.exists(f"{runtime}/{disp}"):
            env["WAYLAND_DISPLAY"] = disp
            break
    return env


def run_cmd(cmd, env=None, timeout=5, ignore_timeout=True):
    """Run a command; never raise on timeout (Lock can block when already locked)."""
    try:
        return subprocess.run(
            cmd, env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        if ignore_timeout:
            log.warning("timeout (ignored): %s", " ".join(cmd))
            return None
        raise


def query_screensaver_active():
    """Query org.gnome.ScreenSaver.GetActive (true when blanked or lock shield active)."""
    env = get_env()
    r = run_cmd(
        ["gdbus", "call", "--session",
         "--dest", "org.gnome.ScreenSaver",
         "--object-path", "/org/gnome/ScreenSaver",
         "--method", "org.gnome.ScreenSaver.GetActive"],
        env=env, timeout=2)
    if r is None or r.returncode != 0:
        return False
    return "(true" in (r.stdout or "")


def query_dpms_off():
    """True if any connected DRM connector reports DPMS Off."""
    from pathlib import Path
    for p in Path("/sys/class/drm").glob("card*-*/dpms"):
        try:
            if p.read_text().strip() == "Off":
                return True
        except OSError:
            pass
    return False


def session_property(sid, prop):
    try:
        r = subprocess.run(
            ["loginctl", "show-session", sid, "-p", prop, "--value"],
            capture_output=True, text=True, timeout=2)
        return (r.stdout or "").strip()
    except Exception:
        return ""


def find_seat_session():
    """Return logind session id for the local seat0 graphical session.

    Prefer Wayland seat0; ignore Remote Login sessions (Remote=yes).
    """
    user = get_user()
    try:
        r = subprocess.run(
            ["loginctl", "show-user", user, "-p", "Sessions", "--value"],
            capture_output=True, text=True, timeout=2)
        sessions = (r.stdout or "").split()
    except Exception:
        sessions = []
    candidates = []
    for sid in sessions:
        seat = session_property(sid, "Seat")
        remote = session_property(sid, "Remote")
        stype = session_property(sid, "Type")
        if seat != "seat0" or remote == "yes":
            continue
        if stype not in ("wayland", "x11"):
            continue
        candidates.append((0 if stype == "wayland" else 1, sid))
    candidates.sort()
    return candidates[0][1] if candidates else None


def set_power_save_mode(mode: int):
    """Mutter DisplayConfig PowerSaveMode: 0=on, 1=standby, 2=suspend, 3=off."""
    env = get_env()
    run_cmd(
        ["busctl", "--user", "set-property",
         "org.gnome.Mutter.DisplayConfig",
         "/org/gnome/Mutter/DisplayConfig",
         "org.gnome.Mutter.DisplayConfig",
         "PowerSaveMode", "i", str(mode)],
        env=env, timeout=3)


def set_idle_hint(active: bool):
    """Tell logind the user is active so gnome-shell redraws the lock greeter."""
    sid = find_seat_session()
    if not sid:
        log.warning("no seat0 graphical session for SetIdleHint")
        return
    run_cmd(
        ["busctl", "call",
         "org.freedesktop.login1",
         f"/org/freedesktop/login1/session/{sid}",
         "org.freedesktop.login1.Session", "SetIdleHint", "b",
         "true" if active else "false"],
        timeout=3)
    log.info("SetIdleHint(%s) session=%s", active, sid)


def screensaver_lock():
    env = get_env()
    run_cmd(
        ["gdbus", "call", "--session",
         "--dest", "org.gnome.ScreenSaver",
         "--object-path", "/org/gnome/ScreenSaver",
         "--method", "org.gnome.ScreenSaver.Lock"],
        env=env, timeout=8)


def screensaver_set_active(active: bool):
    env = get_env()
    run_cmd(
        ["gdbus", "call", "--session",
         "--dest", "org.gnome.ScreenSaver",
         "--object-path", "/org/gnome/ScreenSaver",
         "--method", "org.gnome.ScreenSaver.SetActive",
         "true" if active else "false"],
        env=env, timeout=5)


def emit_wakeup_screen_signal():
    """Best-effort: some shell paths redraw lock UI on WakeUpScreen."""
    env = get_env()
    run_cmd(
        ["gdbus", "emit", "--session",
         "--object-path", "/org/gnome/ScreenSaver",
         "--signal", "org.gnome.ScreenSaver.WakeUpScreen"],
        env=env, timeout=2)


def restore_backlight():
    """Always force a readable panel brightness after wake (not only when ~0)."""
    from pathlib import Path
    bl = Path("/sys/class/backlight/panel0-backlight")
    try:
        cur = int((bl / "brightness").read_text().strip())
        maxb = int((bl / "max_brightness").read_text().strip())
        # After DPMS-only wake, brightness can stay low/odd; ensure readable level.
        floor = max(maxb // 5, 80)
        if cur < floor:
            (bl / "brightness").write_text(str(floor))
            log.info("restored backlight %s -> %s", cur, floor)
    except OSError as e:
        log.info("backlight restore skipped: %s", e)


class UInputActivity:
    """
    Persistent /dev/uinput keyboard. Creating a new device per wake races
    udev/Mutter and often yields backlight-only wakes when inject fails.
    """

    UI_SET_EVBIT = 0x40045564
    UI_SET_KEYBIT = 0x40045565
    UI_DEV_SETUP = 0x405c5503
    UI_DEV_CREATE = 0x5501
    UI_DEV_DESTROY = 0x5502
    BUS_USB = 0x03

    def __init__(self):
        self._fd = -1

    def _ensure(self):
        if self._fd >= 0:
            return True
        try:
            fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        except OSError as e:
            log.warning("open /dev/uinput failed: %s (need udev MODE=0666)", e)
            return False
        try:
            import fcntl

            fcntl.ioctl(fd, self.UI_SET_EVBIT, EV_KEY)
            fcntl.ioctl(fd, self.UI_SET_EVBIT, 0x00)  # EV_SYN
            for code in (1, 42, 29, 125):  # ESC, LSHIFT, LCTRL, LEFTMETA
                fcntl.ioctl(fd, self.UI_SET_KEYBIT, code)

            # struct uinput_setup: input_id(bustype,u16 vendor,u16 product,u16 version) + name[80] + ff_effects_max
            name = b"raphael-wake"
            setup = struct.pack(
                "HHHH80sI",
                self.BUS_USB, 0x0001, 0x0001, 0x0001,
                name.ljust(80, b"\0"),
                0,
            )
            fcntl.ioctl(fd, self.UI_DEV_SETUP, setup)
            fcntl.ioctl(fd, self.UI_DEV_CREATE)
            time.sleep(0.15)
            self._fd = fd
            log.info("uinput wake device ready")
            return True
        except OSError as e:
            log.warning("uinput setup failed: %s", e)
            try:
                os.close(fd)
            except OSError:
                pass
            self._fd = -1
            return False

    def _emit(self, etype, code, value):
        ev = struct.pack(EVENT_FMT, 0, 0, etype, code, value)
        os.write(self._fd, ev)

    def pulse(self):
        """Synthetic modifier tap → Mutter user-active → lock shield redraw."""
        if not self._ensure():
            # Fallback binary (same uinput perms required)
            r = run_cmd(["/usr/local/sbin/inject-activity"], timeout=2)
            if r is None or r.returncode != 0:
                log.warning("inject-activity failed")
                return False
            log.info("injected user activity (helper)")
            return True
        try:
            # LEFTMETA down/up — ignored by lock UI text fields, wakes idle monitor
            for code in (125, 42):
                self._emit(EV_KEY, code, 1)
                self._emit(0, 0, 0)  # SYN_REPORT
                self._emit(EV_KEY, code, 0)
                self._emit(0, 0, 0)
                time.sleep(0.02)
            log.info("injected user activity (uinput)")
            return True
        except OSError as e:
            log.warning("uinput pulse failed: %s", e)
            try:
                os.close(self._fd)
            except OSError:
                pass
            self._fd = -1
            return False

    def close(self):
        if self._fd < 0:
            return
        try:
            import fcntl
            fcntl.ioctl(self._fd, self.UI_DEV_DESTROY)
        except OSError:
            pass
        try:
            os.close(self._fd)
        except OSError:
            pass
        self._fd = -1


_uinput_wake = UInputActivity()


def inject_user_activity():
    """Inject synthetic keys so Mutter redraws the lock screen (not backlight-only)."""
    return _uinput_wake.pulse()


def blank_screen():
    """
    Blank AND lock.
    - From desktop: Lock then SetActive(true) then DPMS off.
    - From lock UI: skip Lock (it blocks when already locked) and only
      SetActive(true)+DPMS off.
    Never call SetActive(false) on wake — that unlocks to desktop.
    """
    active = query_screensaver_active()
    log.info("blank+lock active=%s", active)
    if not active:
        screensaver_lock()
    screensaver_set_active(True)
    # Wait for lock animation + lightbox fade before forcing DPMS off.
    time.sleep(0.7)
    set_power_save_mode(3)


def wake_screen():
    """
    Turn the panel back on while staying on the lock screen.
    PowerSaveMode alone often only enables backlight; Mutter needs a real
    user-activity event (uinput) to paint the lock UI.
    Do NOT call SetActive(false) or Session.Unlock.
    """
    log.info("wake locked screen")
    set_idle_hint(False)
    for attempt in range(6):
        set_power_save_mode(0)
        restore_backlight()
        # Give DRM/panel a beat before activity, else shell paints to a dead CRTC
        time.sleep(0.12 if attempt == 0 else 0.05)
        inject_user_activity()
        emit_wakeup_screen_signal()
        screensaver_set_active(True)
        time.sleep(0.2)
        if not query_dpms_off():
            # Second activity pulse after DPMS is confirmed on — fixes
            # intermittent "backlight on, black/empty lock".
            inject_user_activity()
            emit_wakeup_screen_signal()
            return
        log.info("DPMS still Off after wake attempt %s", attempt + 1)
    set_power_save_mode(0)
    restore_backlight()
    inject_user_activity()
    emit_wakeup_screen_signal()
    screensaver_set_active(True)


def toggle_screen(volume_grabber):
    """Toggle display off+lock / wake-still-locked. Use DPMS only (lock UI keeps GetActive true)."""
    off = query_dpms_off()
    log.info("display_off(dpms)=%s", off)
    if off:
        wake_screen()
        volume_grabber.release()
    else:
        blank_screen()
        volume_grabber.grab()


def show_power_menu():
    """Show GNOME shutdown dialog."""
    env = get_env()
    log.info("show power menu (long press)")
    r = subprocess.run(
        ["busctl", "--user", "call",
         "org.gnome.SessionManager",
         "/org/gnome/SessionManager",
         "org.gnome.SessionManager",
         "RequestShutdown"],
        env=env, capture_output=True, text=True, timeout=3)
    if r.returncode != 0:
        subprocess.Popen(["gnome-session-quit", "--power-off"], env=env)


def wait_for_session(timeout=120):
    """Wait for user's GNOME session to be ready."""
    user = get_user()
    import pwd
    uid = pwd.getpwnam(user).pw_uid
    bus_path = f"/run/user/{uid}/bus"
    log.info("waiting for %s GNOME session", user)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(bus_path):
            try:
                subprocess.run(
                    ["pgrep", "-u", user, "-x", "gnome-shell"],
                    check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                time.sleep(3)
                log.info("session ready")
                return True
            except subprocess.CalledProcessError:
                pass
        time.sleep(1)
    log.error("session not ready after %ss", timeout)
    return False


def main():
    if not wait_for_session():
        sys.exit(1)

    dev = find_power_input()
    fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
    eviocgrab(fd, 1)
    log.info("listening on %s (grabbed — GNOME must not see power key)", dev)
    volume_grabber = VolumeInputGrabber()
    # If display is off (e.g. service restart), grab volume keys.
    if query_dpms_off():
        volume_grabber.grab()

    press_time = None
    long_fired = False
    long_timer = None
    is_pressed = False

    def cancel_long_timer():
        nonlocal long_timer
        if long_timer is not None:
            long_timer.cancel()
            long_timer = None

    def on_long_press():
        nonlocal long_fired
        if not is_pressed:
            return
        long_fired = True
        show_power_menu()

    while True:
        watch = [fd] + volume_grabber.fds()
        r, _, _ = select.select(watch, [], [], 1.0)
        for ready in r:
            if ready != fd:
                volume_grabber.drain(ready)
                continue
            data = os.read(fd, EVENT_SIZE)
            if len(data) < EVENT_SIZE:
                continue
            _sec, _usec, ev_type, code, value = struct.unpack(EVENT_FMT, data)
            if ev_type != EV_KEY or code != KEY_POWER:
                continue

            log.info("KEY_POWER value=%s", value)

            if value == 1:
                if not is_pressed:
                    is_pressed = True
                    press_time = time.monotonic()
                    long_fired = False
                    cancel_long_timer()
                    long_timer = threading.Timer(LONG_PRESS_SEC, on_long_press)
                    long_timer.daemon = True
                    long_timer.start()
            elif value == 0 and press_time is not None:
                is_pressed = False
                cancel_long_timer()
                if not long_fired:
                    duration = time.monotonic() - press_time
                    if duration < LONG_PRESS_SEC:
                        toggle_screen(volume_grabber)
                press_time = None


if __name__ == "__main__":
    main()
PYEOF
chmod 755 rootdir/usr/local/sbin/power-key-handler.py

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 编译 inject-activity（uinput 唤醒锁屏重绘）"
cat > rootdir/usr/local/src/inject-activity.c << 'CEOF'
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static void emit(int fd, int type, int code, int val)
{
	struct input_event ev = { .type = type, .code = code, .value = val };
	write(fd, &ev, sizeof(ev));
}

int main(void)
{
	int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
	if (fd < 0)
		return 1;

	ioctl(fd, UI_SET_EVBIT, EV_SYN);
	ioctl(fd, UI_SET_EVBIT, EV_KEY);
	ioctl(fd, UI_SET_KEYBIT, KEY_ESC);

	struct uinput_setup setup = { 0 };
	setup.id.bustype = BUS_USB;
	strncpy(setup.name, "raphael-wake", sizeof(setup.name) - 1);
	if (ioctl(fd, UI_DEV_SETUP, &setup) < 0) {
		close(fd);
		return 1;
	}
	if (ioctl(fd, UI_DEV_CREATE) < 0) {
		close(fd);
		return 1;
	}
	/* Wait for udev/Mutter to discover the device (50ms was too short). */
	usleep(200000);

	emit(fd, EV_KEY, KEY_LEFTMETA, 1);
	emit(fd, EV_SYN, SYN_REPORT, 0);
	emit(fd, EV_KEY, KEY_LEFTMETA, 0);
	emit(fd, EV_SYN, SYN_REPORT, 0);
	usleep(30000);
	emit(fd, EV_KEY, KEY_LEFTSHIFT, 1);
	emit(fd, EV_SYN, SYN_REPORT, 0);
	emit(fd, EV_KEY, KEY_LEFTSHIFT, 0);
	emit(fd, EV_SYN, SYN_REPORT, 0);
	usleep(50000);
	ioctl(fd, UI_DEV_DESTROY);
	close(fd);
	return 0;
}
CEOF
chroot rootdir gcc -O2 -o /usr/local/sbin/inject-activity /usr/local/src/inject-activity.c 2>/dev/null \
	|| gcc -O2 -o rootdir/usr/local/sbin/inject-activity rootdir/usr/local/src/inject-activity.c
chmod 755 rootdir/usr/local/sbin/inject-activity

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 创建并启用 systemd 用户服务"
install -d rootdir/etc/systemd/user
cat > rootdir/etc/systemd/user/power-key-handler.service << EOF
[Unit]
Description=Power key handler (short press: toggle screen, long press: power menu)
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
Environment=USER_NAME=${POWER_KEY_USER}
ExecStart=/usr/bin/python3 /usr/local/sbin/power-key-handler.py
Restart=always
RestartSec=5

[Install]
WantedBy=graphical-session.target
EOF
install -d rootdir/etc/systemd/user/graphical-session.target.wants
ln -sf /etc/systemd/user/power-key-handler.service rootdir/etc/systemd/user/graphical-session.target.wants/power-key-handler.service
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 启用用户 lingering（确保用户服务开机自启）"
install -d rootdir/var/lib/systemd/linger
touch rootdir/var/lib/systemd/linger/"${POWER_KEY_USER}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 禁用 GNOME 自带电源键；熄屏自动锁屏，亮屏不自动解锁"
install -d rootdir/etc/dconf/db/local.d rootdir/etc/dconf/profile
cat > rootdir/etc/dconf/db/local.d/01-power-key << 'EOF'
[org/gnome/settings-daemon/plugins/power]
power-button-action='nothing'
# 避免电池空闲走 suspend（本机唤醒不可靠，表现为黑屏只能重启）
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
# ALS claim 失败时环境光自动亮度可能把屏拉到接近 0（看视频像“自动黑屏”）
ambient-enabled=false
# 看视频时不要空闲先 dim；由 screensaver / 电源键负责熄屏
idle-dim=false

[org/gnome/desktop/session]
# 空闲锁屏；播放视频时 Firefox 应通过 portal Inhibit 抑制
idle-delay=uint32 600

[org/gnome/desktop/screensaver]
# 空闲/熄屏后锁定；电源键唤醒只亮屏，不调用 Unlock
lock-enabled=true
lock-delay=uint32 0
ubuntu-lock-on-suspend=true

[org/gnome/desktop.lockdown]
disable-lock-screen=false

# Dock「行为」→ 关闭「显示卷」（vendor/cust/多挂载点否则堆在左侧）
[org/gnome/shell/extensions/dash-to-dock]
show-mounts=false
show-mounts-network=false
EOF
if [ ! -f rootdir/etc/dconf/profile/user ]; then
	cat > rootdir/etc/dconf/profile/user << 'EOF'
user-db:user
system-db:local
EOF
fi
chroot rootdir dconf update 2>/dev/null || true
# 背光恢复：电源键用户服务可能需写 brightness
if ! grep -q 'panel0-backlight' rootdir/etc/udev/rules.d/99-raphael-fastrpc-backlight.rules 2>/dev/null; then
	:
fi
# 允许 seat 用户写背光，便于黑屏唤醒时恢复亮度
cat > rootdir/etc/udev/rules.d/98-raphael-backlight-wake.rules << 'EOF'
SUBSYSTEM=="backlight", KERNEL=="panel0-backlight", ACTION=="add|change", MODE="0666"
EOF
cat > rootdir/etc/udev/rules.d/97-raphael-uinput.rules << 'EOF'
# power-key wake injects synthetic keys; node is often created before rules run
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0666", GROUP="input", OPTIONS+="static_node=uinput"
KERNEL=="uinput", MODE="0666", GROUP="input"
EOF

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 添加 udev 规则（电源键 + 音量键可读；熄屏时由 handler grab 音量）"
cat > rootdir/etc/udev/rules.d/99-power-key.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="pm8941_pwrkey", MODE="0666"
ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="pm8941_resin", MODE="0666"
ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="gpio-keys", MODE="0666"
EOF

# uinput wake: ensure desktop user can open /dev/uinput
if [ -n "${POWER_KEY_USER}" ]; then
	chroot rootdir usermod -aG input "${POWER_KEY_USER}" 2>/dev/null || true
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14] ✅ 电源键配置完成"