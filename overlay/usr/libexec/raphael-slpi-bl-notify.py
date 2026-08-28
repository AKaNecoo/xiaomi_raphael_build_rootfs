#!/usr/bin/python3
"""Backlight2Slpi daemon — AP-side push of panel brightness to TCS3701 on SLPI.

Reverse-engineered from vendor libssccalapi.so (transfer_ssc_oem_test_msg) +
citsensorservice Backlight2SlpiNotifier / Client2Slpi RGB:

  libssccalapi transfer_ssc_oem_test_msg (ambient_light_back / tcs3701):
    Android Backlight2Slpi order (separate msg_type calls):
      1. send_brightness_parse_result_rgb_msg — config_type=10, parsed_r/g/b (+ lux field 18)
      2. send_backlight_notify_msg            — config_type=5,  field 9 = DBV int32
      3. send_dc_state_notify_msg             — config_type=6,  dc_state + screenInDCMode
    SLPI sub_B2083A00 reads OEM backlight from decoded field 9 (+0x9C), NOT field 17 alone.

  Wire stack (same as libssc send_phycial_sensor_config_msg → send_basic_req):
    QRTR SSC node 9 port 12 → QMI 0x0020 → SscClientRequest msg_id=515 → oem_config pb

  SLPI does NOT poll /sys/class/backlight; hexagonrpcd only sees init-time fopen.
  This daemon replaces Android AP-side Backlight2SlpiNotifier.

  Run as systemd service (raphael-slpi-bl-notify.service) or:
    raphael-slpi-bl-notify.py --daemon
"""
from __future__ import annotations

import argparse
import os
import socket
import struct
import subprocess
import sys
import time


# Actual backlight node is ae94000.dsi.0 (DRM panel driver name);
# panel0-backlight is the expected/legacy name — probe both.
def resolve_backlight_path(attr: str) -> str:
    for name in ("panel0-backlight", "ae94000.dsi.0"):
        path = "/sys/class/backlight/" + name + "/" + attr
        if os.path.exists(path):
            return path
    return "/sys/class/backlight/panel0-backlight/" + attr

AF_QIPCRTR = 42

# TCS3701 proximity default SUID (amsTCS37 / 01PROX__)
SUID_LOW = 3977614444543044961   # b"amsTCS37"
SUID_HIGH = 6872308654097314096  # b"01PROX__"

SSC_NODE = 9
SSC_PORT = 12

QMI_SNS_CLIENT_REQ = 0x0020
# Android libssccalapi send_phycial_sensor_config_msg → send_basic_req(..., 0x800)
SNS_MSG_PHYSICAL_SENSOR_OEM_CONFIG = 2048
# Android send_sensor_selftest_msg → send_basic_req(..., 0x203) — OLED gate only
SNS_MSG_PHYSICAL_SENSOR_TEST = 515
OEM_CONFIG_BACKLIGHT = 5
# SLPI enum DC_STATE=6; fields 10/16 (libssc). Default 6 — type=2 came from libssccalapi
# internal struct, caused raw_adc drop from ~50-80 to 0 when combined with field fix.
OEM_CONFIG_DC_STATE = 6
OEM_FIELD_DC_STATE = 10
OEM_FIELD_SCREEN_TYPE = 16


def encode_dc_config(dc_state: int, screen_in_dc: int) -> bytes:
    """send_dc_state_notify_msg — config_type=6 + dc/screen fields.

    libssc names: dc_state=10, screen_type=16. SLPI tcs3701 on raphael still
    accepts legacy wire fields 11/12 (was ~50-80 raw_adc); fields 10/16 gave 0.
    """
    dc_type = int(os.environ.get("RAPHAEL_DC_CONFIG_TYPE", str(OEM_CONFIG_DC_STATE)))
    if os.environ.get("RAPHAEL_DC_LEGACY_FIELDS", "1") == "1":
        f_dc, f_screen = 11, 12
    else:
        f_dc, f_screen = OEM_FIELD_DC_STATE, OEM_FIELD_SCREEN_TYPE
    msg = bytearray()
    msg += _tag(1, 0) + _varint(dc_type)
    msg += _tag(f_dc, 0) + _varint(1 if dc_state else 0)
    msg += _tag(f_screen, 0) + _varint(1 if screen_in_dc else 0)
    return bytes(msg)


def send_oem_payload(
    payload: bytes,
    lo: int,
    hi: int,
    verbose: bool,
    label: str,
    wrap: bool = False,
    msg_id: int | None = None,
) -> bool:
    inner = payload
    if wrap or os.environ.get("RAPHAEL_OEM_WRAP") == "1":
        inner = encode_sns_client_request(payload)
    if msg_id is None:
        msg_id = SNS_MSG_PHYSICAL_SENSOR_OEM_CONFIG
    outer = encode_ssc_client_request(msg_id, lo, hi, inner)
    qmi = encode_ssc_control(outer)
    if verbose:
        print(f"{label} msgid=0x{msg_id:x} suid={hi}/{lo} qmi={len(qmi)}", file=sys.stderr)
    resp = qrtr_send(qmi)
    if resp is None:
        if verbose:
            print(f"  {label}: no QMI response", file=sys.stderr)
        return False
    ok = qmi_result_ok(resp)
    if verbose:
        print(f"  {label} resp ({len(resp)}): ok={ok}", file=sys.stderr)
    return ok

# libssc QMI TLV layout (sns_client_api_v01)
TLV_REQUEST_DATA = 0x01
TLV_REQUEST_REPORT_TYPE = 0x10
TLV_RESPONSE_RESULT = 0x02
REPORT_TYPE_LARGE = 1

# TCS3701 ALS SUID (01ALS___ / amsTCS37) — Android libssccalapi targets "tcs3701"
SUID_ALS_LOW = 3977614444543044961
SUID_ALS_HIGH = 6872316367756931376

_tx_id = 0
_compute_rgb_mod = None


def _get_compute_rgb_module():
    """Load raphael-compute-panel-rgb.py (HWC parseBrightness / Client2Slpi)."""
    global _compute_rgb_mod
    if _compute_rgb_mod is not None:
        return _compute_rgb_mod
    import importlib.util

    for path in (
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "raphael-compute-panel-rgb.py"),
        "/usr/libexec/raphael-compute-panel-rgb.py",
    ):
        if not os.path.isfile(path):
            continue
        spec = importlib.util.spec_from_file_location("raphael_compute_panel_rgb", path)
        if spec is None or spec.loader is None:
            continue
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _compute_rgb_mod = mod
        return mod
    return None


def _varint(n: int) -> bytes:
    out = bytearray()
    while n > 0x7F:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n & 0x7F)
    return bytes(out)


def _tag(field: int, wire: int) -> bytes:
    return _varint((field << 3) | wire)

# libssc sns_physical_sensor_oem_config_type enum (NOT 4=BIAS, NOT 0=COLOR sub-cal):
OEM_CONFIG_BRIGHTNESS_PARSE_RGB = 10  # SNS_PHYSICAL_SENSOR_CONFIG_BRIGHTNESS_PARSE_REULT_RGB


def _signed_varint(n: int) -> bytes:
    """Protobuf int32 varint (two's complement for negatives, e.g. backlight=-2)."""
    n &= 0xFFFFFFFF
    return _varint(n)


def encode_oem_config(
    backlight_on: int,
    brightness: int,
    *,
    include_bl_bool: bool = True,
    screen_in_hbm: int | None = None,
    bmax: int = 2047,
) -> bytes:
    """sns_physical_sensor_oem_config — config_type=5.

    SLPI sub_B2083A00: memw(r23+0x9C) → internal BL (+0x3C0). Android calapi puts DBV in
    field 9 (int32). Sending field 9=1 (bool) made SLPI think BL=1 while AP RGB/lux used
    real DBV → OLED compensation wrong → lux stuck ~0.x, no ambient response.

    RAPHAEL_BL_FIELD9=dbv (default): field 9 = panel DBV + field 17 float ratio.
    RAPHAEL_BL_FIELD9=bool: field 9 = on-flag + field 17 varint DBV (internal BL=1 bug risk).
    brightness=-2: SLPI fopen Path A — syncs +0x3C8 from panel0-backlight (sub_B21F1E1C).
    """
    if screen_in_hbm is None:
        screen_in_hbm = 1 if os.environ.get("RAPHAEL_BACKLIGHT_HBM", "1") == "1" else 0
    field9_mode = os.environ.get("RAPHAEL_BL_FIELD9", "dbv").lower()
    msg = bytearray()
    msg += _tag(1, 0) + _varint(OEM_CONFIG_BACKLIGHT)
    if brightness == -2:
        msg += _tag(9, 0) + _signed_varint(-2)
    elif field9_mode == "bool" and include_bl_bool:
        on = 1 if backlight_on > 0 else 0
        msg += _tag(9, 0) + _varint(on)
        if brightness > 0:
            msg += _tag(17, 0) + _varint(brightness)
    elif brightness > 0:
        msg += _tag(9, 0) + _varint(brightness)
        if os.environ.get("RAPHAEL_BL_FIELD17_FLOAT", "1") == "1" and bmax > 0:
            ratio = min(1.0, max(0.0, brightness / bmax))
            msg += _tag(17, 5) + struct.pack("<f", ratio)
    elif include_bl_bool and backlight_on > 0:
        msg += _tag(9, 0) + _varint(1)
    if screen_in_hbm:
        msg += _tag(13, 0) + _varint(1 if screen_in_hbm else 0)
    return bytes(msg)


def encode_test_config(test_type: int) -> bytes:
    """sns_physical_sensor_test_config { test_type } — OLED gate SW(0)/HW(1)."""
    return _tag(1, 0) + _varint(test_type & 0xFF)


def send_oled_gate(
    on: bool,
    *,
    verbose: bool = False,
    als_only: bool = True,
    retries: int | None = None,
) -> bool:
    """Open/close backlight_is_on latch (Android msg_type=16 → self-test 0x203).

    SLPI sub_B2086738: SW test_type=0 sets instance+0x300=1; HW(1) clears it.
    sub_B21F1E1C fopen and sub_B2085080 RVED2 path require +0x300 != 0.
    """
    test_type = 0 if on else 1
    label = "OLED-gate-SW" if on else "OLED-gate-HW"
    inner = encode_test_config(test_type)
    if retries is None:
        retries = int(os.environ.get("RAPHAEL_GATE_RETRIES", "3"))
    targets = [(SUID_ALS_LOW, SUID_ALS_HIGH)]
    if not als_only:
        targets.append((SUID_LOW, SUID_HIGH))
    ok = False
    for attempt in range(max(1, retries)):
        for lo, hi in targets:
            if send_oem_payload(
                inner,
                lo,
                hi,
                verbose,
                label if attempt == 0 else f"{label}-r{attempt + 1}",
                msg_id=SNS_MSG_PHYSICAL_SENSOR_TEST,
            ):
                ok = True
        if ok:
            break
        time.sleep(0.15)
    return ok


def encode_color_config(red: float, green: float, blue: float, lux: float | None = None) -> bytes:
    """Android send_brightness_parse_result_rgb_msg (libssccalapi + SLPI strings).

    config_type = BRIGHTNESS_PARSE_RESULT_RGB (10), fields parsed_r/g/b/lux:
      19  parsed_r (float)
      20  parsed_g (float)
      21  parsed_b (float)
      18  parsed_lux (float, optional)
    """
    msg = bytearray()
    msg += _tag(1, 0) + _varint(OEM_CONFIG_BRIGHTNESS_PARSE_RGB)
    msg += _tag(19, 5) + struct.pack("<f", red)
    msg += _tag(20, 5) + struct.pack("<f", green)
    msg += _tag(21, 5) + struct.pack("<f", blue)
    if lux is not None and lux >= 0:
        msg += _tag(18, 5) + struct.pack("<f", lux)
    return bytes(msg)


def encode_sns_client_request(payload: bytes) -> bytes:
    """sns_client_request { payload = 1 } — inner body for SscClientRequest.request.msg."""
    msg = bytearray()
    msg += _tag(1, 2) + _varint(len(payload)) + payload
    return bytes(msg)


def encode_ssc_uid(suid_low: int, suid_high: int) -> bytes:
    msg = bytearray()
    msg += _tag(1, 1) + struct.pack("<Q", suid_low)
    msg += _tag(2, 1) + struct.pack("<Q", suid_high)
    return bytes(msg)


def encode_ssc_client_request(msg_id: int, suid_low: int, suid_high: int, inner: bytes) -> bytes:
    """libssc SscClientRequest (ssc-common.proto) — what ssccli/qmi_client_ssc_control sends."""
    uid = encode_ssc_uid(suid_low, suid_high)
    config = _tag(1, 0) + _varint(1) + _tag(2, 0) + _varint(0)  # APSS + WAKEUP
    body = _tag(2, 2) + _varint(len(inner)) + inner

    msg = bytearray()
    msg += _tag(1, 2) + _varint(len(uid)) + uid
    msg += _tag(2, 5) + struct.pack("<I", msg_id)
    msg += _tag(3, 2) + _varint(len(config)) + config
    msg += _tag(4, 2) + _varint(len(body)) + body
    return bytes(msg)


def encode_ssc_control(protobuf: bytes, tx_id: int | None = None) -> bytes:
    """QMI SSC control request — libssc wire format (7-byte LE header + TLVs)."""
    global _tx_id
    if tx_id is None:
        _tx_id = (_tx_id + 1) & 0xFFFF
        tx_id = _tx_id

    body = bytearray()
    body += struct.pack("<BHB", TLV_REQUEST_REPORT_TYPE, 1, REPORT_TYPE_LARGE)
    inner = len(protobuf)
    body += struct.pack("<BHH", TLV_REQUEST_DATA, inner + 2, inner)
    body += protobuf
    hdr = struct.pack("<BHHH", 0, tx_id, QMI_SNS_CLIENT_REQ, len(body))
    return hdr + bytes(body)


def qmi_result_ok(resp: bytes) -> bool:
    if len(resp) < 7:
        return False
    body = resp[7 : 7 + struct.unpack_from("<H", resp, 5)[0]]
    i = 0
    while i + 3 <= len(body):
        ty, ln = body[i], struct.unpack_from("<H", body, i + 1)[0]
        val = body[i + 3 : i + 3 + ln]
        if ty == TLV_RESPONSE_RESULT and len(val) >= 2:
            return struct.unpack_from("<H", val, 0)[0] == 0
        i += 3 + ln
    return False


def read_panel_brightness() -> tuple[int, int]:
    """Return live (brightness, max_brightness) from kernel panel0-backlight sysfs."""
    b = 0
    bmax = 2047
    bl_path = resolve_backlight_path("brightness")
    max_path = resolve_backlight_path("max_brightness")
    try:
        with open(max_path) as f:
            bmax = int(f.read().strip())
    except OSError:
        pass
    if bmax <= 0:
        bmax = 2047
    try:
        with open(bl_path) as f:
            b = int(f.read().strip())
    except OSError:
        pass
    if b < 0:
        b = 0
    if b > bmax:
        b = bmax
    return b, bmax


def load_rgb_lux_from_run() -> tuple[tuple[float, float, float], float] | None:
    """Prefer L3 gate files (dbv / als_lux / norm255) over sysfs-derived defaults."""
    rgbdir = "/run/raphael-slpi-rgb"
    try:
        with open(f"{rgbdir}/r") as f:
            r = float(f.read().strip())
        with open(f"{rgbdir}/g") as f:
            g = float(f.read().strip())
        with open(f"{rgbdir}/b") as f:
            b = float(f.read().strip())
        lux = -1.0
        with open(f"{rgbdir}/lux") as f:
            lux = float(f.read().strip())
        if lux < 0:
            lux = float(r)
        return (r, g, b), lux
    except (OSError, ValueError):
        return None


def default_rgb_lux(brightness: int, bmax: int) -> tuple[tuple[float, float, float], float]:
    """Android Client2Slpi RGB + parseBrightness lux (field 18 in type-10 OEM)."""
    cached = load_rgb_lux_from_run()
    if cached is not None:
        return cached

    if bmax <= 0:
        bmax = 2047
    mode = os.environ.get("RAPHAEL_PROX_RGB_MODE", "scaled")
    mod = _get_compute_rgb_module()
    if mod is not None:
        try:
            rgb = mod.compute_rgb(float(brightness), bmax=float(bmax), mode=mode)
            lux = mod.compute_lux(rgb[0], rgb[1], rgb[2], float(brightness), mode=mode)
            return rgb, lux
        except (AttributeError, TypeError, ValueError):
            pass

    scale = min(1.0, max(0.0, brightness / bmax))
    rgb = (scale * 255.0, scale * 255.0, scale * 255.0)
    return rgb, float(brightness)


def qrtr_send(payload: bytes, node: int = SSC_NODE, port: int = SSC_PORT, timeout: float = 2.0) -> bytes | None:
    sock = socket.socket(AF_QIPCRTR, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    addr = (node, port)
    sock.sendto(payload, addr)
    try:
        data, _ = sock.recvfrom(8192)
        return data
    except socket.timeout:
        return None
    finally:
        sock.close()


def client2slpi_push(
    brightness: int,
    *,
    bmax: int = 2047,
    rgb: tuple[float, float, float] | None = None,
    lux: float | None = None,
    suid_low: int = SUID_ALS_LOW,
    suid_high: int = SUID_ALS_HIGH,
    verbose: bool = False,
) -> int:
    """Android Client2Slpi — type-10 RGB+parsed_lux only (no BL/DC/fopen).

    libssccalapi msg_type=19 → config_type=10. Separate from Backlight2Slpi (17/18).
    """
    return notify_backlight(
        brightness,
        suid_low=suid_low,
        suid_high=suid_high,
        verbose=verbose,
        both_suids=False,
        rgb=rgb,
        lux=lux,
        bmax=bmax,
        send_dc=False,
        send_rgb=True,
        include_bl_bool=False,
        oem_order="android",
        fopen_sync=False,
        rgb_only=True,
    )

def backlight2slpi_push(
    brightness: int,
    *,
    bmax: int = 2047,
    rgb: tuple[float, float, float] | None = None,
    lux: float | None = None,
    suid_low: int = SUID_ALS_LOW,
    suid_high: int = SUID_ALS_HIGH,
    verbose: bool = False,
    both_suids: bool = True,
    send_dc: bool = True,
    send_rgb: bool = True,
    include_bl_bool: bool = True,
    oem_order: str = "android",
    fopen_sync: bool | None = None,
) -> int:
    """One Backlight2Slpi cycle: RGB → BL → DC (android order)."""
    return notify_backlight(
        brightness,
        suid_low=suid_low,
        suid_high=suid_high,
        verbose=verbose,
        both_suids=both_suids,
        rgb=rgb,
        lux=lux,
        bmax=bmax,
        send_dc=send_dc,
        send_rgb=send_rgb,
        include_bl_bool=include_bl_bool,
        oem_order=oem_order,
        fopen_sync=fopen_sync,
    )


def notify_backlight(
    brightness: int,
    suid_low: int = SUID_ALS_LOW,
    suid_high: int = SUID_ALS_HIGH,
    verbose: bool = False,
    both_suids: bool = True,
    rgb: tuple[float, float, float] | None = None,
    lux: float | None = None,
    bmax: int = 2047,
    send_dc: bool = True,
    send_rgb: bool = True,
    include_bl_bool: bool = True,
    oem_order: str = "android",
    fopen_sync: bool | None = None,
    rgb_only: bool = False,
) -> int:
    bl_on = 1 if brightness > 0 else 0
    if rgb is None and brightness > 0:
        rgb, lux_default = default_rgb_lux(brightness, bmax)
        # Field 18 parsed_lux — SLPI uses @0x3D4 for OLED subtract (sub_B2085080).
        if lux is None and os.environ.get("RAPHAEL_COLOR_LUX", "1") == "1":
            lux = lux_default
    targets = [(suid_low, suid_high)]
    if both_suids and (suid_low, suid_high) != (SUID_LOW, SUID_HIGH):
        targets.append((SUID_LOW, SUID_HIGH))
    if both_suids and (suid_low, suid_high) != (SUID_ALS_LOW, SUID_ALS_HIGH):
        targets.append((SUID_ALS_LOW, SUID_ALS_HIGH))

    if fopen_sync is None:
        fopen_sync = os.environ.get("RAPHAEL_ALS_FOPEN_SYNC", "1") == "1"

    rc = 0
    for lo, hi in targets:
        # SLPI: OEM writes +0x3C0, get_brightness/lb_sample reads +0x3C8.
        # backlight=-2 → sub_B21F1E1C fopen panel0-backlight → refresh +0x3C8.
        if fopen_sync and brightness > 0:
            bl_fopen = encode_oem_config(0, -2, include_bl_bool=False)
            send_oem_payload(bl_fopen, lo, hi, verbose, "BACKLIGHT-fopen")
        bl = encode_oem_config(
            bl_on, brightness, include_bl_bool=include_bl_bool, bmax=bmax
        )
        dc = encode_dc_config(0, 0) if send_dc else None
        color = encode_color_config(rgb[0], rgb[1], rgb[2], lux) if send_rgb and rgb else None

        if rgb_only:
            steps = [("COLOR", color)] if color is not None else []
        elif oem_order == "legacy":
            steps = [("BACKLIGHT", bl)]
            if send_dc:
                steps.append(("DC_STATE", dc))
            if color is not None:
                steps.append(("COLOR", color))
        elif oem_order == "color-first" and send_dc:
            steps = [("COLOR", color), ("DC_STATE", dc), ("BACKLIGHT", bl)]
        elif oem_order == "android":
            # Android Backlight2Slpi: BL then DC (RGB is separate Client2Slpi msg_type=19).
            steps = [("BACKLIGHT", bl)]
            if send_dc:
                steps.append(("DC_STATE", dc))
            if color is not None:
                steps.append(("COLOR", color))
        else:
            steps = [("BACKLIGHT", bl)]
            if send_dc:
                steps.append(("DC_STATE", dc))

        for label, payload in steps:
            if payload is None:
                continue
            send_oem_payload(payload, lo, hi, verbose, label)
    return rc


def push_tcs_adc_path(
    brightness: int | None = None,
    *,
    suid_low: int = SUID_ALS_LOW,
    suid_high: int = SUID_ALS_HIGH,
    verbose: bool = False,
    als_only: bool = True,
    settle_sec: float | None = None,
) -> bool:
    """Push SLPI messages to enter TCS3701 RVED2 lux path (sub_B2085080).

    Decompile chain:
      1. msg 0x203 SW (test_type=0) → backlight_is_on @ instance+0x300
      2. OEM config_type=5 field9=-2 → sub_B21F1E1C fopen + memb(+0x21)=2
      3. Client2Slpi type-10 RGB/lux → OLED compensation @ +0x3D4
      4. Backlight2Slpi type-5 DBV + type-6 DC
      5. Re-gate (OEM BL does not set +0x300; only self-test does)
    """
    if settle_sec is None:
        settle_sec = float(os.environ.get("RAPHAEL_TCS_PATH_SETTLE", "0.5"))
    b, bmax = read_panel_brightness()
    if brightness is not None:
        b = brightness

    def _sleep() -> None:
        if settle_sec > 0:
            time.sleep(settle_sec)

    gate_ok = send_oled_gate(True, verbose=verbose, als_only=als_only)
    _sleep()

    # fopen Path A; requires gate open (sub_B21F1E1C checks +0x300).
    notify_backlight(
        -2,
        suid_low=suid_low,
        suid_high=suid_high,
        verbose=verbose,
        both_suids=not als_only,
        send_dc=False,
        send_rgb=False,
        include_bl_bool=False,
        oem_order="android",
        fopen_sync=False,
    )
    _sleep()
    gate_ok = send_oled_gate(True, verbose=verbose, als_only=als_only) or gate_ok
    _sleep()

    rgb, lux = default_rgb_lux(b, bmax)
    notify_backlight(
        b,
        suid_low=suid_low,
        suid_high=suid_high,
        verbose=verbose,
        both_suids=not als_only,
        rgb=rgb,
        lux=lux,
        bmax=bmax,
        send_dc=False,
        send_rgb=True,
        include_bl_bool=False,
        oem_order="android",
        fopen_sync=False,
        rgb_only=True,
    )
    _sleep()

    notify_backlight(
        b,
        suid_low=suid_low,
        suid_high=suid_high,
        verbose=verbose,
        both_suids=not als_only,
        rgb=rgb,
        lux=lux,
        bmax=bmax,
        send_dc=True,
        send_rgb=False,
        include_bl_bool=True,
        oem_order="android",
        fopen_sync=True,
    )
    _sleep()
    gate_ok = send_oled_gate(True, verbose=verbose, als_only=als_only) or gate_ok
    if verbose:
        print(
            f"TCS ADC path: brightness={b}/{bmax} rgb={rgb} lux={lux} gate={'ok' if gate_ok else 'FAIL'}",
            file=sys.stderr,
        )
    return gate_ok


def _als_stream_popen(timeout_sec: float = 35.0):
    """Background ssccli stream — gate/OEM apply to active SLPI instance only."""
    if os.environ.get("RAPHAEL_TCS_STREAM_SYNC", "1") != "1":
        return None
    ssccli = "/usr/bin/ssccli"
    if not os.path.isfile(ssccli):
        return None
    return subprocess.Popen(
        [
            "timeout",
            str(int(timeout_sec) + 5),
            ssccli,
            "--sensor",
            "light",
            "--timeout",
            str(int(timeout_sec)),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def _als_stream_sync_push(
    brightness: int | None,
    *,
    suid_low: int,
    suid_high: int,
    verbose: bool,
    als_only: bool,
) -> bool:
    """Warm ALS stream, push TCS path, keep stream briefly for settle."""
    proc = _als_stream_popen()
    if proc is not None:
        time.sleep(2.0)
    ok = push_tcs_adc_path(
        brightness,
        suid_low=suid_low,
        suid_high=suid_high,
        verbose=verbose,
        als_only=als_only,
    )
    if proc is not None:
        time.sleep(3.0)
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
    return ok


def run_daemon(
    *,
    interval: float,
    continuous: bool,
    suid_low: int,
    suid_high: int,
    verbose: bool,
    als_only: bool,
    bl_only: bool,
    no_dc: bool,
    no_rgb: bool,
    no_bl_bool: bool,
    no_gate: bool,
    order: str,
) -> int:
    """Watch panel brightness and push Backlight2Slpi OEM configs to SLPI."""
    bl_path = resolve_backlight_path("brightness")
    last = -1
    tick = 0
    gate_ok = False
    mode = "continuous" if continuous else "on-change"
    print(
        f"backlight2slpi daemon: {bl_path} interval={interval}s mode={mode}",
        file=sys.stderr,
        flush=True,
    )
    gate_refresh = float(os.environ.get("RAPHAEL_GATE_REFRESH_SEC", "30"))
    last_gate = 0.0
    if not no_gate:
        if os.environ.get("RAPHAEL_ALS_RESET_ON_START", "1") == "1":
            b, _ = read_panel_brightness()
            ok = _als_stream_sync_push(
                b,
                suid_low=suid_low,
                suid_high=suid_high,
                verbose=verbose,
                als_only=als_only,
            )
            print(f"TCS path init (stream-sync): {'ok' if ok else 'FAIL'}", file=sys.stderr, flush=True)
            gate_ok = ok
            last_gate = time.monotonic()
        else:
            gate_ok = send_oled_gate(True, verbose=verbose, als_only=als_only)
            print(f"OLED gate SW: {'ok' if gate_ok else 'FAIL'}", file=sys.stderr, flush=True)
            last_gate = time.monotonic()
    while True:
        b, bmax = read_panel_brightness()
        tick += 1
        changed = b != last
        if (
            not no_gate
            and gate_refresh > 0
            and time.monotonic() - last_gate >= gate_refresh
        ):
            send_oled_gate(True, verbose=verbose, als_only=als_only)
            last_gate = time.monotonic()
        if continuous or changed:
            rgb, lux = default_rgb_lux(b, bmax)
            backlight2slpi_push(
                b,
                bmax=bmax,
                rgb=rgb,
                lux=lux,
                suid_low=suid_low,
                suid_high=suid_high,
                verbose=verbose,
                both_suids=not als_only,
                send_dc=not bl_only and not no_dc,
                send_rgb=not bl_only and not no_rgb,
                include_bl_bool=not no_bl_bool,
                oem_order=order,
                # Path A fopen only when BL changes — avoid resetting lb_sample every 0.2s.
                fopen_sync=changed,
            )
            tag = "change" if changed else "heartbeat"
            print(f"[{tag} #{tick}] brightness={b}/{bmax} rgb={rgb}", flush=True)
            last = b
        time.sleep(interval)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Backlight2Slpi daemon — push panel brightness to TCS3701 SLPI via QMI"
    )
    ap.add_argument("brightness", nargs="?", type=int, help="panel brightness 0..2047 (default: read sysfs)")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--prox", action="store_true", help="target TCS3701 prox SUID (default: ALS)")
    ap.add_argument("--als-only", action="store_true", help="do not mirror oem to prox SUID")
    ap.add_argument("--no-rgb", action="store_true", help="skip COLOR rgb oem_config (debug)")
    ap.add_argument("--no-dc", action="store_true", help="skip DC_STATE oem_config (debug)")
    ap.add_argument(
        "--backlight-only",
        action="store_true",
        help="runtime minimal: BACKLIGHT only (default: legacy triple BL+DC+RGB)",
    )
    ap.add_argument(
        "--no-bl-bool",
        action="store_true",
        help="omit protobuf field 9 (backlight bool); default sends field 9+17",
    )
    ap.add_argument(
        "--rgb-only",
        action="store_true",
        help="Client2Slpi: COLOR type-10 only (no BL/DC/fopen)",
    )
    ap.add_argument(
        "--legacy-order",
        action="store_true",
        help="OEM order BACKLIGHT->DC->COLOR (debug; default: android RGB->BL->DC)",
    )
    ap.add_argument(
        "--color-first",
        action="store_true",
        help="OEM order COLOR->DC->BACKLIGHT (debug)",
    )
    ap.add_argument(
        "--reset-als",
        action="store_true",
        help="send OEM BL=-2 (fopen Path A reset) before normal push",
    )
    ap.add_argument(
        "--tcs-path-init",
        action="store_true",
        help="full TCS RVED2 path: gate -> BL=-2 -> RGB -> BL+DC -> gate (sub_B2085080)",
    )
    ap.add_argument(
        "--rgb",
        nargs=3,
        type=float,
        metavar=("R", "G", "B"),
        help="panel RGB 0..255 norm255 (default: brightness/max*255)",
    )
    ap.add_argument("--lux", type=float, help="optional lux for COLOR oem_config")
    ap.add_argument(
        "--no-gate",
        action="store_true",
        help="skip OLED gate 0x203 SW at daemon start (debug)",
    )
    ap.add_argument(
        "--daemon",
        action="store_true",
        help="daemon loop: poll sysfs and push Backlight2Slpi (implies --continuous)",
    )
    ap.add_argument(
        "--watch",
        action="store_true",
        help="alias for --daemon (systemd service uses this)",
    )
    ap.add_argument(
        "--continuous",
        action="store_true",
        help="push BL+DC+RGB every interval even if brightness unchanged (libssccalapi heartbeat)",
    )
    ap.add_argument(
        "--on-change-only",
        action="store_true",
        help="only push when sysfs brightness changes (debug)",
    )
    ap.add_argument(
        "--interval",
        type=float,
        default=float(os.environ.get("RAPHAEL_BL_NOTIFY_INTERVAL", "0.2")),
        help="poll/push period in seconds (default: 0.2)",
    )
    args = ap.parse_args()

    bl_path = resolve_backlight_path("brightness")

    def read_bl() -> int:
        if args.brightness is not None and not args.watch and not args.daemon:
            return args.brightness
        try:
            with open(bl_path) as f:
                return int(f.read().strip())
        except OSError as e:
            print(f"FAIL: read {bl_path}: {e}", file=sys.stderr)
            return 0

    suid_low = SUID_LOW if args.prox else SUID_ALS_LOW
    suid_high = SUID_HIGH if args.prox else SUID_ALS_HIGH

    if args.legacy_order:
        order = "legacy"
    elif args.color_first:
        order = "color-first"
    elif os.environ.get("RAPHAEL_OEM_ORDER", "").lower() == "legacy":
        order = "legacy"
    else:
        order = "android"
    bl_only = args.backlight_only
    daemon = args.daemon or args.watch
    # Default on-change: continuous RGB/BL OEM every 0.2s perturbs lb_sample (sub_B2085424 reset).
    if daemon and os.environ.get("RAPHAEL_BL_NOTIFY_CONTINUOUS", "0") == "1":
        continuous = not args.on_change_only
    elif args.continuous:
        continuous = True
    else:
        continuous = False

    if daemon:
        try:
            run_daemon(
                interval=args.interval,
                continuous=continuous,
                suid_low=suid_low,
                suid_high=suid_high,
                verbose=args.verbose,
                als_only=args.als_only,
                bl_only=bl_only,
                no_dc=args.no_dc,
                no_rgb=args.no_rgb,
                no_bl_bool=args.no_bl_bool,
                no_gate=args.no_gate,
                order=order,
            )
        except KeyboardInterrupt:
            return 0

    b = read_bl()
    b, bmax = read_panel_brightness()
    if args.brightness is not None and not args.watch:
        b = args.brightness
    if args.tcs_path_init and not daemon:
        b = read_bl()
        if args.brightness is not None:
            b = args.brightness
        ok = push_tcs_adc_path(
            b,
            suid_low=suid_low,
            suid_high=suid_high,
            verbose=args.verbose,
            als_only=args.als_only,
        )
        print(f"OK: TCS ADC path init brightness={b}" if ok else "WARN: TCS path gate failed")
        return 0 if ok else 1

    if not args.no_gate and not daemon:
        send_oled_gate(True, verbose=args.verbose, als_only=args.als_only)
    if args.reset_als and not daemon:
        notify_backlight(
            -2,
            suid_low=suid_low,
            suid_high=suid_high,
            verbose=args.verbose,
            both_suids=not args.als_only,
            send_dc=False,
            send_rgb=False,
            include_bl_bool=False,
            oem_order=order,
        )
        if not args.no_gate:
            send_oled_gate(True, verbose=args.verbose, als_only=args.als_only)
    rgb = None
    lux = args.lux
    if not args.no_rgb:
        if args.rgb:
            rgb = tuple(args.rgb)
        else:
            rgb, lux_default = default_rgb_lux(b, bmax)
            if lux is None:
                lux = lux_default
    if args.rgb_only and not daemon:
        rgb = None
        lux = args.lux
        if not args.no_rgb:
            if args.rgb:
                rgb = tuple(args.rgb)
            else:
                rgb, lux_default = default_rgb_lux(b, bmax)
                if lux is None and os.environ.get("RAPHAEL_COLOR_LUX", "1") == "1":
                    lux = lux_default
        rc = notify_backlight(
            b,
            suid_low=suid_low,
            suid_high=suid_high,
            verbose=args.verbose,
            both_suids=not args.als_only,
            rgb=rgb,
            lux=lux,
            bmax=bmax,
            send_dc=False,
            send_rgb=rgb is not None,
            include_bl_bool=False,
            oem_order=order,
            fopen_sync=False,
            rgb_only=True,
        )
        print(f"OK: Client2Slpi rgb={rgb}" + (f" lux={lux}" if lux is not None else ""))
        return rc
    rc = notify_backlight(
        b,
        suid_low=suid_low,
        suid_high=suid_high,
        verbose=args.verbose,
        both_suids=not args.als_only,
        rgb=rgb,
        lux=lux,
        bmax=bmax,
        send_dc=not bl_only and not args.no_dc,
        send_rgb=not bl_only and not args.no_rgb and rgb is not None,
        include_bl_bool=not args.no_bl_bool,
        oem_order=order,
    )
    print(f"OK: BACKLIGHT notify brightness={b}" + (f" rgb={rgb}" if rgb and not bl_only else ""))
    return rc


if __name__ == "__main__":
    sys.exit(main())
