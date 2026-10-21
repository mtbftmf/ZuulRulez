#!/usr/bin/env python3
"""
Mac Studio System Monitor
Run: python3 mac_monitor.py
Requirements: pip3 install psutil Pillow flask --break-system-packages
Background image: /Users/ewagner/.local/bin/TxtSysMonBkgd.webp
Web dashboard: http://<studio-ip>:9090
"""

import tkinter as tk
import subprocess
import threading
import psutil
import re
import time
import os
import json
import signal
import logging
import urllib.request
import urllib.error
from PIL import Image, ImageDraw, ImageTk
from flask import Flask, jsonify, render_template_string

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mac_monitor")

# ── Config ───────────────────────────────────────────────────────────────────
UPDATE_MS       = 5000
PM_INTERVAL     = 15
LMS_URL         = "http://localhost:1234"
LMS_BIN         = os.path.expanduser("~/.lmstudio/bin/lms")
TPS_GRAPH_SCALE = 125.0     # 125 t/s = 100% of graph (gemma peaks ~118)
WIN_WIDTH       = 360
WIN_HEIGHT      = 490       # 14 stat rows + taller graph
STATS_HEIGHT    = 325
GRAPH_HEIGHT    = 160
STATS_WIDTH     = 160
MINI_WIDTH      = 130   # vertical mini strip width
MINI_ROW_H      = 22    # height per stat row in mini strip
FONT_FAMILY     = "Courier"
FONT_SIZE       = 11
TITLE_SIZE      = 9
BORDER_COLOR    = "#ff6eb4"
BG_COLOR        = "#08080f"
BG_IMAGE        = "/Users/ewagner/.local/bin/TxtSysMonBkgd.webp"
IMG_CROP_LEFT   = 0.38
HISTORY_FILE    = os.path.expanduser("~/.local/bin/mem_history.json")
STATE_FILE      = os.path.expanduser("~/.local/bin/monitor_state.json")
MAX_HISTORY     = 25920
GRAPH_WINDOW    = 36000     # 10h desktop window (web JS uses its own WS=129600)
WEB_PORT        = 9090
EFF_GRAPH_SCALE = 500.0     # 500 %/W = 100% of graph (M5 Max GPU/W peaks ~300-400)
LMS_IDLE_TIMEOUT  = 30      # seconds of silence before status → Idle

MEM_DELTA_SAMPLES = 6
SWP_DELTA_SAMPLES = 12

# ── Precompiled regex ─────────────────────────────────────────────────────────
SWP_USED_RE  = re.compile(r"used\s*=\s*([\d.]+)M")
SWP_TOTAL_RE = re.compile(r"total\s*=\s*([\d.]+)M")
GPU_RE       = re.compile(r"GPU HW active residency:\s*([\d.]+)%")
CPU_PWR_RE   = re.compile(r"^CPU Power:\s*([\d.]+)\s*mW", re.MULTILINE)
CPU_FREQ_RE  = re.compile(r"(?:CPU \d+ frequency):\s*([\d.]+)\s*MHz")
CPU_PFREQ_RE = re.compile(r"P0-Cluster HW active frequency:\s*([\d.]+)\s*MHz")
THERMAL_RE   = re.compile(r"Current pressure level:\s*(\w+)")

# ── 508-compliant label colors (all ≥4.5:1 on #08080f) ───────────────────────
# GPU: #006666 was 2.94:1 (FAIL) → #00b4b4 (7.78:1)
# SSD: #ff4500 was 5.23:1 → #ff6633 (6.84:1, warmer)
# delta grey: #555555 was 2.68:1 (FAIL) → #aaaaaa (8.59:1)
# grid labels: #444466 was 2.15:1 (FAIL) → #7777aa (4.76:1)
STAT_COLORS = {
    "USE": "#ff6eb4",   # 7.74:1
    "RAM": "#00bfff",   # 9.41:1
    "MEM": "#ffffff",   # 18.6:1
    "SSD": "#ff6633",   # 6.84:1
    "GHz": "#c084fc",   #  8.21:1  purple — distinct from GPU teal
    "GPU": "#b4b4bc",   # 7.4:1   light grey — matches graph line
    "PWR": "#ffd700",   # 14.23:1
    "SWP": "#ff8c00",   # 8.56:1
    "THM": "#00e676",   # 11.96:1
    "EFF": "#88aaff",   # 8.78:1
    "G4":  "#e040fb",   #  7.21:1  violet — Gemma t/s, matches TPS graph line
    "FLS": "#c060e0",   #  5.98:1  lighter violet — Flash t/s
    "SD1": "#ff9966",   #  8.12:1  warm orange — SSD1 temp (disk4)
    "SD2": "#ffb347",   #  9.34:1  amber — SSD2 temp (disk6)
}

PRESSURE_COLORS = {"Green": "#00e676", "Yellow": "#ffd600", "Red": "#ff1744"}
THERMAL_COLORS  = {
    "Nominal": "#00e676", "Fair": "#ffd600",
    "Serious": "#ff8c00", "Critical": "#ff1744", "…": "#ffffff",
}

# ── Graph line colors as PIL-compatible RGB tuples (all ≥3:1 on #08080f) ─────
GRAPH_COLORS = {
    "mem_green":  (0,   230, 118),   # 11.96:1
    "mem_yellow": (255, 214,   0),   # 14.14:1
    "mem_red":    (255,  68,  68),   #  5.86:1
    "gpu":        (180, 180, 188),   #  ~8.5:1  light grey — background context, WU-style
    "swp":        (255, 100,   0),   #  7.08:1  distinct orange (was same red as mem_red)
    "delta":      (170, 170, 170),   #  8.59:1  (was 85,85,85 — FAIL 2.68:1)
    "eff":        (80,  100, 180),   #  3.42:1  muted blue-grey (context line, not primary)
    "tps":        (224,  64, 251),   #  7.21:1  violet — distinct from SWP orange
    "grid":       (26,   26,  42),   #  decorative — contrast not required
    "label":      (119, 119, 170),   #  4.76:1  (was 68,68,102 — FAIL 2.15:1)
}

# ── Shared state ─────────────────────────────────────────────────────────────
_state       = {}
_mem_min     = None
_mem_max     = None
_mem_history = []
_gpu_history = []
_swp_history = []
_eff_history = []
_tps_history = []
_state_lock  = threading.Lock()


# ── History helpers ───────────────────────────────────────────────────────────

def _prune_history(history, now):
    cutoff = now - GRAPH_WINDOW
    while history and history[0][0] < cutoff:
        history.pop(0)
    if len(history) > MAX_HISTORY:
        del history[:-MAX_HISTORY]


def _load_history():
    global _mem_min, _mem_max
    try:
        if os.path.exists(HISTORY_FILE):
            with open(HISTORY_FILE, 'r') as f:
                data = json.load(f)
            cutoff = time.time() - GRAPH_WINDOW
            if isinstance(data, dict):
                _mem_history.extend((ts, v) for ts, v in data.get("history",     []) if ts > cutoff)
                _gpu_history.extend((ts, v) for ts, v in data.get("gpu_history", []) if ts > cutoff)
                _swp_history.extend((ts, v) for ts, v in data.get("swp_history", []) if ts > cutoff)
                _eff_history.extend((ts, v) for ts, v in data.get("eff_history", []) if ts > cutoff)
                _tps_history.extend((ts, v) for ts, v in data.get("tps_history", []) if ts > cutoff)
                _mem_min = data.get("min")
                _mem_max = data.get("max")
            else:
                _mem_history.extend((ts, v) for ts, v in data if ts > cutoff)
    except Exception as e:
        log.warning("_load_history error: %s", e)


def _save_history():
    try:
        with open(HISTORY_FILE, 'w') as f:
            json.dump({
                "history":     _mem_history, "min": _mem_min, "max": _mem_max,
                "gpu_history": _gpu_history, "swp_history": _swp_history,
                "eff_history": _eff_history, "tps_history": _tps_history,
            }, f)
    except Exception as e:
        log.warning("_save_history error: %s", e)


def _save_window_state(x, y, minimized):
    try:
        data = {}
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE, 'r') as f:
                data = json.load(f)
        if minimized:
            data["mini_x"] = x; data["mini_y"] = y; data["minimized"] = True
        else:
            data["x"] = x; data["y"] = y; data["minimized"] = False
        with open(STATE_FILE, 'w') as f:
            json.dump(data, f)
    except Exception as e:
        log.warning("_save_window_state error: %s", e)


def _load_window_state():
    try:
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE, 'r') as f:
                return json.load(f)
    except Exception as e:
        log.warning("_load_window_state error: %s", e)
    return {"x": None, "y": None, "mini_x": None, "mini_y": None, "minimized": False}


def _sigterm_handler(signum, frame):
    _save_history()
    raise SystemExit(0)


def _parse_vm_stat(vm_output):
    values = {}
    for line in vm_output.splitlines():
        parts = line.split(':')
        if len(parts) != 2:
            continue
        key = parts[0].strip()
        num = ''.join(ch for ch in parts[1] if ch.isdigit())
        if num:
            values[key] = int(num)
    return values


# ── LMS log stream ────────────────────────────────────────────────────────────

def _model_abbrev(model_id):
    """Shorten a modelIdentifier to a compact GUI label."""
    m = model_id.lower()
    if "gemma" in m:   return "g4"
    if "flash" in m:   return "flash"
    if "llama" in m:   return "llama"
    if "mistral" in m: return "mist"
    if "qwen" in m:    return "qwen"
    # fallback: first 6 chars of the last path component
    base = model_id.split("/")[-1]
    return base[:6]


def _lms_log_stream():
    """
    Stream `lms log stream --source model --filter output --stats --json`.
    Each completed generation emits a JSONL event with stats.tokensPerSecond
    and modelIdentifier.  We use arrival of any event as the Active signal;
    silence for LMS_IDLE_TIMEOUT seconds → Idle; process death → Off.
    """
    while True:
        if not os.path.exists(LMS_BIN):
            _state["lms_status"] = "Off"
            time.sleep(10)
            continue
        try:
            proc = subprocess.Popen(
                [LMS_BIN, "log", "stream",
                 "--source", "model", "--filter", "output",
                 "--stats", "--json"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True,
            )
            _state["lms_status"] = "Idle"
            _state["lms_last_event"] = time.time()

            for raw_line in proc.stdout:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    obj = json.loads(raw_line)
                except json.JSONDecodeError:
                    continue

                data = obj.get("data", {})
                if data.get("type") != "llm.prediction.output":
                    continue

                stats    = data.get("stats", {})
                tps      = stats.get("tokensPerSecond")
                model_id = data.get("modelIdentifier", "")
                now      = time.time()

                _state["lms_last_event"] = now
                _state["lms_status"]     = "Active"

                if tps and tps > 0:
                    abbrev = _model_abbrev(model_id)
                    _state["lms_tps"]       = tps
                    _state["lms_model"]     = abbrev
                    _state["lms_tps_ts"]    = now
                    # Per-model tracking: store tps and timestamp keyed by abbrev
                    pm = _state.setdefault("lms_tps_per_model", {})
                    pm[abbrev] = {"tps": tps, "ts": now}
                    with _state_lock:
                        _tps_history.append((now, tps))
                        _prune_history(_tps_history, now)

                # Mark idle if no event for LMS_IDLE_TIMEOUT seconds
                # (checked on next iteration via the timeout trick below)

            # process ended — LM Studio stopped
            _state["lms_status"] = "Off"
            proc.wait()

        except Exception as e:
            log.warning("lms log stream error: %s", e)
            _state["lms_status"] = "Off"
            time.sleep(5)


def _lms_idle_watchdog():
    """Demote Active → Idle when no event arrives within LMS_IDLE_TIMEOUT s."""
    while True:
        time.sleep(5)
        if _state.get("lms_status") == "Active":
            last = _state.get("lms_last_event", 0)
            if time.time() - last > LMS_IDLE_TIMEOUT:
                _state["lms_status"] = "Idle"


def get_lms_status():
    return _state.get("lms_status", "Off")

def get_lms_color():
    s = _state.get("lms_status", "Off")
    return "#e040fb" if s == "Active" else "#777799" if s == "Idle" else "#444455"

def get_lms_display():
    """Return the LMS stat value string: t/s + model when available, else status."""
    s   = _state.get("lms_status", "Off")
    tps = _state.get("lms_tps")
    ts  = _state.get("lms_tps_ts")
    mdl = _state.get("lms_model", "")
    # Show last t/s only if it's recent (within last hour) and LMS isn't Off
    # GUI label is already "t/s" so value is just number + model abbrev
    if s != "Off" and tps and ts and (time.time() - ts < 3600):
        return f"{tps:.1f} {mdl}"
    return s

def get_lms_model_display(abbrev):
    """Return t/s for a specific model abbrev, or dash if not seen recently."""
    s  = _state.get("lms_status", "Off")
    pm = _state.get("lms_tps_per_model", {})
    entry = pm.get(abbrev)
    if s != "Off" and entry and (time.time() - entry["ts"] < 3600):
        return f"{entry['tps']:.1f}"
    return "—"

def get_lms_model_color(abbrev, stat_key):
    """Color for a per-model row: bright when that model was last active."""
    s  = _state.get("lms_status", "Off")
    pm = _state.get("lms_tps_per_model", {})
    entry = pm.get(abbrev)
    base = STAT_COLORS[stat_key]
    if s == "Off" or not entry or (time.time() - entry["ts"] >= 3600):
        return "#444455"
    # Dim if another model is currently the active one
    if s == "Active" and _state.get("lms_model") != abbrev:
        return "#777799"
    return base


# ── Background data collection thread ────────────────────────────────────────

def _data_loop():
    global _mem_min, _mem_max
    pm_cmd = [
        "sudo", "/usr/bin/powermetrics",
        "--samplers", "cpu_power,gpu_power,thermal",
        "-n", "1", "-i", str(PM_INTERVAL * 1000),
        "--hide-cpu-duty-cycle",
    ]
    while True:
        try:
            result = subprocess.run(pm_cmd, capture_output=True, text=True, timeout=PM_INTERVAL + 5)
            out = result.stdout
            if not out:
                log.warning("powermetrics returned empty output")
                time.sleep(PM_INTERVAL)
                continue

            m = GPU_RE.search(out)
            if m: _state["gpu_residency"] = float(m.group(1))
            m = CPU_PWR_RE.search(out)
            if m: _state["cpu_power_mw"] = float(m.group(1))
            m = CPU_PFREQ_RE.search(out) or CPU_FREQ_RE.search(out)
            if m: _state["cpu_ghz"] = float(m.group(1)) / 1000
            m = THERMAL_RE.search(out)
            if m: _state["thermal"] = m.group(1)

            pct = _state.get("gpu_residency")
            if pct is not None:
                now = time.time()
                with _state_lock:
                    _gpu_history.append((now, pct))
                    _prune_history(_gpu_history, now)

            gpu = _state.get("gpu_residency")
            mw  = _state.get("cpu_power_mw")
            if gpu is not None and mw is not None and mw >= 10:
                now = time.time()
                with _state_lock:
                    _eff_history.append((now, gpu / (mw / 1000)))
                    _prune_history(_eff_history, now)

        except Exception as e:
            log.warning("powermetrics error: %s", e)
            time.sleep(PM_INTERVAL)
            continue

        try:
            vals = _parse_vm_stat(subprocess.check_output(["vm_stat"], text=True))
            free = vals.get("Pages free", 0); inact = vals.get("Pages inactive", 0)
            spec = vals.get("Pages speculative", 0); wired = vals.get("Pages wired down", 0)
            act  = vals.get("Pages active", 0); comp = vals.get("Pages occupied by compressor", 0)
            total = free + inact + spec + wired + act + comp
            if total > 0:
                avail_pct = (free + inact + spec) / total * 100
                used_pct  = 100 - avail_pct
                now = time.time()
                with _state_lock:
                    if _mem_min is None or used_pct < _mem_min: _mem_min = used_pct
                    if _mem_max is None or used_pct > _mem_max: _mem_max = used_pct
                    _mem_history.append((now, used_pct))
                    _prune_history(_mem_history, now)
                    _state["mem_used_pct"]  = used_pct
                    _state["mem_avail_pct"] = avail_pct
        except Exception as e:
            log.warning("vm_stat error: %s", e)

        try:
            sw = subprocess.check_output(["sysctl", "vm.swapusage"], text=True)
            mu = SWP_USED_RE.search(sw); mt = SWP_TOTAL_RE.search(sw)
            if mu and mt:
                used = float(mu.group(1)) / 1024; total = float(mt.group(1)) / 1024
                _state["swp_used_gb"] = used; _state["swp_total_gb"] = total
                if total > 0:
                    now = time.time()
                    with _state_lock:
                        _swp_history.append((now, used / total * 100))
                        _prune_history(_swp_history, now)
        except Exception as e:
            log.warning("sysctl error: %s", e)

        time.sleep(PM_INTERVAL)


# ── Data fetchers ─────────────────────────────────────────────────────────────

def get_cpu_usage():    return f"{psutil.cpu_percent(interval=None):.1f}%"
def get_ram_used_gb():
    m = psutil.virtual_memory()
    return f"{m.used/1024**3:.1f}/{m.total/1024**3:.0f}G"

def _mem_arrow():
    with _state_lock: snap = list(_mem_history)
    if len(snap) < MEM_DELTA_SAMPLES: return "→"
    d = snap[-1][1] - snap[-MEM_DELTA_SAMPLES][1]
    return "↑↑" if d>4 else "↑" if d>1 else "↓" if d<-1 else "→"

def _swp_arrow():
    with _state_lock: snap = list(_swp_history)
    if len(snap) < SWP_DELTA_SAMPLES: return ""
    total = _state.get("swp_total_gb", 1)
    if total == 0: return ""
    gb = (snap[-1][1] - snap[-SWP_DELTA_SAMPLES][1]) / 100 * total
    return " ↑↑" if gb>0.5 else " ↑" if gb>0.1 else " ↓" if gb<-0.1 else ""

def get_memory_pressure():
    with _state_lock:
        u = _state.get("mem_used_pct"); a = _state.get("mem_avail_pct")
        mn = _mem_min; mx = _mem_max
    if u is None: return "…", "#ffffff"
    c = PRESSURE_COLORS["Green"] if a>20 else PRESSURE_COLORS["Yellow"] if a>5 else PRESSURE_COLORS["Red"]
    mn = mn if mn is not None else u; mx = mx if mx is not None else u
    return f"{mn:.0f}% {u:.0f}%{_mem_arrow()} {mx:.0f}%", c

def get_mem_pct():
    with _state_lock: pct = _state.get("mem_used_pct")
    return f"{pct:.0f}%" if pct is not None else "…"

def get_mem_color():
    with _state_lock: a = _state.get("mem_avail_pct", 100)
    return PRESSURE_COLORS["Green"] if a>20 else PRESSURE_COLORS["Yellow"] if a>5 else PRESSURE_COLORS["Red"]

def get_ssd_usage():    return f"{psutil.disk_usage('/System/Volumes/Data').percent:.0f}%"

def get_cpu_freq_ghz():
    g = _state.get("cpu_ghz")
    if g: return f"{g:.2f} GHz"
    try:
        f = psutil.cpu_freq()
        return f"{f.current/1000:.2f} GHz" if f and f.current>0 else "N/A"
    except Exception:
        return "N/A"

def get_gpu_residency():
    p = _state.get("gpu_residency"); return f"{p:.1f}%" if p is not None else "…"

def get_cpu_power():
    m = _state.get("cpu_power_mw"); return f"{m:.0f} mW" if m is not None else "…"

def get_swap_used():
    with _state_lock: u = _state.get("swp_used_gb"); t = _state.get("swp_total_gb")
    return "…" if u is None else f"{u:.1f}/{t:.0f}G{_swp_arrow()}"

def get_thermal():
    t = _state.get("thermal", "…"); return t, THERMAL_COLORS.get(t, "#ffffff")

def get_efficiency():
    g = _state.get("gpu_residency"); m = _state.get("cpu_power_mw")
    return "…" if (g is None or m is None or m<10) else f"{g/(m/1000):.1f} %/W"


# ── External SSD temps (smartctl, 60 s cache) ────────────────────────────────

_SSD_DISKS    = {"SD1": "/dev/disk4", "SD2": "/dev/disk6"}
_SSD_TEMP_RE  = re.compile(r"^Temperature:\s+(\d+)\s+Celsius", re.MULTILINE)
_ssd_temp_cache: dict = {}   # key → (temp_str, expire_ts)
_SSD_INTERVAL = 60           # seconds between smartctl calls

def get_ssd_temp(key: str) -> str:
    """Return 'NN°C' for the given disk key, cached for _SSD_INTERVAL seconds."""
    now = time.time()
    cached = _ssd_temp_cache.get(key)
    if cached and now < cached[1]:
        return cached[0]
    disk = _SSD_DISKS.get(key)
    if not disk:
        return "N/A"
    try:
        out = subprocess.check_output(
            ["sudo", "smartctl", "-a", disk],
            text=True, timeout=10, stderr=subprocess.DEVNULL
        )
        m = _SSD_TEMP_RE.search(out)
        result = f"{m.group(1)}°C" if m else "N/A"
    except Exception as e:
        log.warning("smartctl %s error: %s", disk, e)
        result = "N/A"
    _ssd_temp_cache[key] = (result, now + _SSD_INTERVAL)
    return result


# ── PIL graph renderer ────────────────────────────────────────────────────────

def _render_graph(gw, gh, pad=26):
    """
    Render all graph lines into a PIL image and return it.
    Single image object replaces thousands of Tk canvas items.
    Draw order: delta → gpu → eff → tps → swp → mem (MEM topmost).
    """
    img = Image.new("RGB", (gw, gh), (10, 10, 15))
    draw = ImageDraw.Draw(img)
    plot_w = gw - pad

    with _state_lock:
        mem_snap = list(_mem_history)
        gpu_snap = list(_gpu_history)
        swp_snap = list(_swp_history)
        eff_snap = list(_eff_history)
        tps_snap = list(_tps_history)

    now = time.time()

    def ts_to_x(ts):
        age = now - ts
        return plot_w - int(age / GRAPH_WINDOW * plot_w)

    # Y-axis zoom: collect all visible values to find actual range
    cutoff = now - GRAPH_WINDOW
    all_vals = []
    for ts, v in mem_snap:
        if ts >= cutoff: all_vals.append(v)
    for ts, v in gpu_snap:
        if ts >= cutoff: all_vals.append(v)
    for ts, v in swp_snap:
        if ts >= cutoff: all_vals.append(v)
    for ts, v in eff_snap:
        if ts >= cutoff: all_vals.append(min(100, v / EFF_GRAPH_SCALE * 100))
    for ts, v in tps_snap:
        if ts >= cutoff: all_vals.append(min(100, v / TPS_GRAPH_SCALE * 100))
    if all_vals:
        y_lo = max(0.0,   min(all_vals) - 5.0)
        y_hi = min(100.0, max(all_vals) + 5.0)
        if y_hi - y_lo < 10.0:
            y_hi = min(100.0, y_lo + 10.0)
    else:
        y_lo, y_hi = 0.0, 100.0

    def val_to_y(val):
        norm = (val - y_lo) / (y_hi - y_lo) if y_hi > y_lo else 0.5
        norm = max(0.0, min(1.0, norm))
        return gh - 1 - int(norm * (gh - 2))

    # Grid lines at lo+25%, 50%, 75% of visible range
    for frac in [0.25, 0.5, 0.75]:
        pct_val = y_lo + frac * (y_hi - y_lo)
        y = val_to_y(pct_val)
        draw.line([(0, y), (plot_w, y)], fill=GRAPH_COLORS["grid"])
        draw.text((plot_w + 2, y - 5), f"{pct_val:.0f}%",
                  fill=GRAPH_COLORS["label"])

    def plot_line(snap, color_fn, scale=None, max_gap=None):
        if len(snap) < 2:
            return
        prev = None
        prev_ts = None
        for ts, raw in snap:
            val = min(100, (raw / scale) * 100) if scale else raw
            val = max(0, min(100, val))
            x = ts_to_x(ts); y = val_to_y(val)
            x = max(0, min(plot_w - 1, x))
            y = max(0, min(gh - 1, y))
            pt = (x, y)
            if prev is not None:
                gap_ok = (max_gap is None) or (ts - prev_ts <= max_gap)
                if gap_ok:
                    c = color_fn(raw) if callable(color_fn) else color_fn
                    draw.line([prev, pt], fill=c)
            prev = pt
            prev_ts = ts

    # MEM delta (grey) — background context line
    if len(mem_snap) >= MEM_DELTA_SAMPLES + 1:
        dlt = []
        for i in range(MEM_DELTA_SAMPLES, len(mem_snap)):
            d = mem_snap[i][1] - mem_snap[i - MEM_DELTA_SAMPLES][1]
            dlt.append((mem_snap[i][0], min(100, max(0, 50 + d * 5))))
        plot_line(dlt, GRAPH_COLORS["delta"])

    # GPU (teal) — draw before MEM so MEM line stays on top
    plot_line(gpu_snap, GRAPH_COLORS["gpu"])

    # EFF (light blue)
    plot_line(eff_snap, GRAPH_COLORS["eff"], scale=EFF_GRAPH_SCALE)

    # TPS (violet) — real workload throughput; break line between separate sessions
    plot_line(tps_snap, GRAPH_COLORS["tps"], scale=TPS_GRAPH_SCALE, max_gap=60)

    # SWP (orange-red) — draw before MEM
    plot_line(swp_snap, GRAPH_COLORS["swp"])

    # MEM (color by pressure) — topmost: most important line
    def mem_color(val):
        return GRAPH_COLORS["mem_red"] if val>95 else GRAPH_COLORS["mem_yellow"] if val>80 else GRAPH_COLORS["mem_green"]
    plot_line(mem_snap, mem_color)

    return img


# ── Flask web server ──────────────────────────────────────────────────────────

flask_app = Flask(__name__)

HTML_TEMPLATE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Mac Studio Monitor</title>
<style>
* { margin:0;padding:0;box-sizing:border-box; }
body { background:#08080f;color:#fff;font-family:'Courier New',monospace;padding:20px; }
h1 { color:#ff6eb4;text-align:center;font-size:1.1em;margin-bottom:16px;letter-spacing:2px; }
.divider { border:none;border-top:1px solid #ff6eb4;margin:10px 0 16px; }
.stats { display:grid;grid-template-columns:80px 1fr;gap:6px 12px;max-width:340px;margin:0 auto 20px; }
.label,.value { font-size:.95em;font-weight:bold; }
.value { text-align:right; }
.graph-wrap { max-width:700px;margin:0 auto; }
.graph-title { color:#ff6eb4;font-size:.75em;margin-bottom:6px; }
canvas { background:#0a0a0f;border:1px solid #ff6eb4;width:100%;height:160px;display:block; }
.legend { display:flex;gap:16px;margin-top:8px;font-size:.75em;flex-wrap:wrap; }
.legend span { display:flex;align-items:center;gap:6px; }
.dot { width:10px;height:10px;border-radius:50%;display:inline-block; }
.updated { text-align:center;color:#444;font-size:.7em;margin-top:16px; }
</style></head><body>
<h1>◈ Mac Studio ◈</h1><hr class="divider">
<div class="stats">
  <span class="label" style="color:#ff6eb4">USE</span><span class="value" style="color:#ff6eb4" id="v-USE">…</span>
  <span class="label" style="color:#00bfff">RAM</span><span class="value" style="color:#00bfff" id="v-RAM">…</span>
  <span class="label" id="l-MEM" style="color:#fff">MEM</span><span class="value" id="v-MEM" style="color:#fff">…</span>
  <span class="label" style="color:#ff6633">SSD</span><span class="value" style="color:#ff6633" id="v-SSD">…</span>
  <span class="label" style="color:#c084fc">GHz</span><span class="value" style="color:#c084fc" id="v-GHz">…</span>
  <span class="label" style="color:#b4b4bc">GPU</span><span class="value" style="color:#b4b4bc" id="v-GPU">…</span>
  <span class="label" style="color:#ffd700">PWR</span><span class="value" style="color:#ffd700" id="v-PWR">…</span>
  <span class="label" style="color:#ff8c00">SWP</span><span class="value" style="color:#ff8c00" id="v-SWP">…</span>
  <span class="label" id="l-THM" style="color:#00e676">THM</span><span class="value" id="v-THM" style="color:#00e676">…</span>
  <span class="label" style="color:#88aaff">EFF</span><span class="value" style="color:#88aaff" id="v-EFF">…</span>
  <span class="label" id="l-G4" style="color:#e040fb">g4 t/s</span><span class="value" id="v-G4" style="color:#e040fb">…</span>
  <span class="label" id="l-FLS" style="color:#c060e0">fls t/s</span><span class="value" id="v-FLS" style="color:#c060e0">…</span>
</div>
<div class="graph-wrap">
  <div class="graph-title">MEM + GPU + SWP + MEM-Δ + EFF + TPS 10h</div>
  <canvas id="graph"></canvas>
  <div class="legend">
    <span><span class="dot" style="background:#00e676"></span>MEM</span>
    <span><span class="dot" style="background:#ff6400"></span>SWP</span>
    <span><span class="dot" style="background:#b4b4bc"></span>GPU</span>
    <span><span class="dot" style="background:#aaaaaa"></span>MEM Δ</span>
    <span><span class="dot" style="background:#5064b4"></span>EFF ÷500</span>
    <span><span class="dot" style="background:#e040fb"></span>TPS ÷125</span>
  </div>
</div>
<div class="updated" id="updated">Updated: …</div>
<script>
const WS=36000,PAD=30,ES=500,TS=125;
function drawGraph(mem,gpu,swp,eff,tps){
  const cv=document.getElementById('graph'),ctx=cv.getContext('2d');
  cv.width=cv.offsetWidth;cv.height=160;
  const W=cv.width,H=cv.height,now=Date.now()/1000;
  ctx.clearRect(0,0,W,H);
  // Y-axis zoom: collect all visible values
  const allV=[];
  function collectV(data,sc){
    if(!data)return;
    data.forEach(([t,v])=>{if(now-t<=WS)allV.push(sc?Math.min(100,(v/sc)*100):v);});
  }
  collectV(mem);collectV(gpu);collectV(swp);collectV(eff,ES);collectV(tps,TS);
  let yLo=0,yHi=100;
  if(allV.length){
    yLo=Math.max(0,Math.min(...allV)-5);
    yHi=Math.min(100,Math.max(...allV)+5);
    if(yHi-yLo<10)yHi=Math.min(100,yLo+10);
  }
  function vToY(sv){
    const norm=yHi>yLo?(sv-yLo)/(yHi-yLo):0.5;
    return H-(Math.max(0,Math.min(1,norm))*H);
  }
  [0.25,0.5,0.75].forEach(f=>{
    const pv=yLo+f*(yHi-yLo),y=vToY(pv);
    ctx.strokeStyle='#1a1a2a';ctx.setLineDash([2,4]);
    ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(W-PAD,y);ctx.stroke();
    ctx.setLineDash([]);ctx.fillStyle='#7777aa';ctx.font='10px Courier New';
    ctx.textAlign='right';ctx.fillText(pv.toFixed(0)+'%',W-2,y+4);
  });
  function pl(data,cf,sc,maxGap){
    if(!data||data.length<2)return;
    for(let i=1;i<data.length;i++){
      const[t0,v0]=data[i-1],[t1,v1]=data[i];
      if(maxGap&&(t1-t0)>maxGap)continue;
      const sv0=sc?Math.min(100,(v0/sc)*100):v0, sv1=sc?Math.min(100,(v1/sc)*100):v1;
      const x0=(W-PAD)-((now-t0)/WS)*(W-PAD),x1=(W-PAD)-((now-t1)/WS)*(W-PAD);
      const y0=vToY(sv0),y1=vToY(sv1);
      ctx.strokeStyle=typeof cf==='function'?cf(v1):cf;ctx.lineWidth=1;
      ctx.beginPath();ctx.moveTo(x0,y0);ctx.lineTo(x1,y1);ctx.stroke();
    }
  }
  if(mem&&mem.length>=7){
    const d=[];
    for(let i=6;i<mem.length;i++) d.push([mem[i][0],Math.min(100,Math.max(0,50+(mem[i][1]-mem[i-6][1])*5))]);
    pl(d,'#aaaaaa');
  }
  ctx.globalAlpha=0.5; pl(gpu,'#b4b4bc'); ctx.globalAlpha=1.0;
  pl(eff,'#5064b4',ES);
  pl(tps,'#e040fb',TS,60);
  pl(swp,'#ff6400');
  pl(mem,v=>v>95?'#ff4444':v>80?'#ffd600':'#00e676');
}
function upd(d){
  ['USE','RAM','SSD','GHz','GPU','PWR','SWP','EFF'].forEach(k=>{
    const el=document.getElementById('v-'+k); if(el) el.textContent=d[k];
  });
  document.getElementById('v-MEM').textContent=d.MEM;
  document.getElementById('v-MEM').style.color=d.MEM_COLOR;
  document.getElementById('l-MEM').style.color=d.MEM_COLOR;
  document.getElementById('v-THM').textContent=d.THM;
  document.getElementById('v-THM').style.color=d.THM_COLOR;
  document.getElementById('l-THM').style.color=d.THM_COLOR;
  document.getElementById('v-G4').textContent=d.G4;
  document.getElementById('v-G4').style.color=d.G4_COLOR;
  document.getElementById('l-G4').style.color=d.G4_COLOR;
  document.getElementById('v-FLS').textContent=d.FLS;
  document.getElementById('v-FLS').style.color=d.FLS_COLOR;
  document.getElementById('l-FLS').style.color=d.FLS_COLOR;
  document.getElementById('updated').textContent='Updated: '+d.updated;
  drawGraph(d.mem_history,d.gpu_history,d.swp_history,d.eff_history,d.tps_history);
}
async function poll(){
  try{const r=await fetch('/api');if(r.ok)upd(await r.json());}catch(e){}
  setTimeout(poll,5000);
}
poll();
window.addEventListener('resize',()=>fetch('/api').then(r=>r.json()).then(d=>
  drawGraph(d.mem_history,d.gpu_history,d.swp_history,d.eff_history,d.tps_history)));
</script></body></html>"""

@flask_app.route("/")
def dashboard():
    mt, mc = get_memory_pressure(); tt, tc = get_thermal()
    with _state_lock:
        ms=list(_mem_history); gs=list(_gpu_history); ss=list(_swp_history)
        es=list(_eff_history); ts=list(_tps_history)
    return render_template_string(HTML_TEMPLATE,
        stats={"USE":get_cpu_usage(),"RAM":get_ram_used_gb(),"MEM":mt,"MEM_COLOR":mc,
               "SSD":get_ssd_usage(),"GHz":get_cpu_freq_ghz(),"GPU":get_gpu_residency(),
               "PWR":get_cpu_power(),"SWP":get_swap_used(),"THM":tt,"THM_COLOR":tc,
               "EFF":get_efficiency(),
               "G4":get_lms_model_display("g4"),   "G4_COLOR":get_lms_model_color("g4",   "G4"),
               "FLS":get_lms_model_display("flash"),"FLS_COLOR":get_lms_model_color("flash","FLS")},
        mem_history=ms,gpu_history=gs,swp_history=ss,eff_history=es,tps_history=ts,
        updated=time.strftime("%Y-%m-%d %H:%M:%S"))

@flask_app.route("/api")
def api():
    mt, mc = get_memory_pressure(); tt, tc = get_thermal()
    with _state_lock:
        ms=list(_mem_history); gs=list(_gpu_history); ss=list(_swp_history)
        es=list(_eff_history); ts=list(_tps_history)
    return jsonify({
        "USE":get_cpu_usage(),"RAM":get_ram_used_gb(),"MEM":mt,"MEM_COLOR":mc,
        "SSD":get_ssd_usage(),"GHz":get_cpu_freq_ghz(),"GPU":get_gpu_residency(),
        "PWR":get_cpu_power(),"SWP":get_swap_used(),"THM":tt,"THM_COLOR":tc,
        "EFF":get_efficiency(),
        "G4":get_lms_model_display("g4"),    "G4_COLOR":get_lms_model_color("g4",    "G4"),
        "FLS":get_lms_model_display("flash"), "FLS_COLOR":get_lms_model_color("flash", "FLS"),
        "mem_history":ms,"gpu_history":gs,"swp_history":ss,
        "eff_history":es,"tps_history":ts,
        "updated":time.strftime("%Y-%m-%d %H:%M:%S"),
    })

def _web_server():
    logging.getLogger('werkzeug').setLevel(logging.ERROR)
    flask_app.run(host="0.0.0.0", port=WEB_PORT, threaded=True, use_reloader=False)


# ── GUI ───────────────────────────────────────────────────────────────────────

class MonitorApp:
    def __init__(self, root):
        self.root       = root
        self._minimized = False
        self._startup   = True
        root.title("System Monitor")

        # ── Restore window state ──
        _ws = _load_window_state()
        _x = _ws.get("x"); _y = _ws.get("y")
        _mini_x = _ws.get("mini_x"); _mini_y = _ws.get("mini_y")
        _was_minimized = _ws.get("minimized", False)

        _mini_h = MINI_ROW_H * 6   # MEM + GPU + SWP + g4 + fls + restore arrow
        if _was_minimized and _mini_x is not None and _mini_y is not None:
            root.geometry(f"{MINI_WIDTH}x{_mini_h}+{_mini_x}+{_mini_y}")
        elif _x is not None and _y is not None:
            root.geometry(f"{WIN_WIDTH}x{WIN_HEIGHT}+{_x}+{_y}")
        else:
            root.geometry(f"{WIN_WIDTH}x{WIN_HEIGHT}")

        root.resizable(False, False)
        root.attributes("-topmost", True)
        root.attributes("-alpha", 0.70)
        root.configure(bg=BG_COLOR)
        root.bind("<Configure>", self._on_configure)
        root.bind("<m>", lambda e: self._toggle_minimize())

        self.canvas = tk.Canvas(root, width=WIN_WIDTH, height=WIN_HEIGHT,
                                highlightthickness=0, bd=0, bg=BG_COLOR)
        self.canvas.place(x=0, y=0)

        # Background image
        img_panel_w = WIN_WIDTH - STATS_WIDTH
        self.bg_photo = None
        try:
            img = Image.open(BG_IMAGE)
            crop_x = int(img.width * IMG_CROP_LEFT)
            img = img.crop((crop_x, 0, img.width, img.height))
            aspect = img.width / img.height
            sw = int(STATS_HEIGHT * aspect)
            img = img.resize((sw, STATS_HEIGHT), Image.LANCZOS)
            if sw > img_panel_w: img = img.crop((0, 0, img_panel_w, STATS_HEIGHT))
            self.bg_photo = ImageTk.PhotoImage(img)
            self.canvas.create_image(STATS_WIDTH, 0, anchor="nw", image=self.bg_photo)
        except Exception as e:
            log.warning("Background image error: %s", e)

        self.canvas.create_rectangle(0, 0, STATS_WIDTH, STATS_HEIGHT, fill=BG_COLOR, outline="")
        self.canvas.create_rectangle(4, 4, STATS_WIDTH-4, STATS_HEIGHT-4, fill="", outline=BORDER_COLOR, width=2)
        self.canvas.create_text(STATS_WIDTH//2, 18, text="◈ Mac Studio ◈",
            font=(FONT_FAMILY, TITLE_SIZE, "bold"), fill=BORDER_COLOR)
        self.canvas.create_line(10, 28, STATS_WIDTH-10, 28, fill=BORDER_COLOR, width=1)

        self._min_btn = tk.Label(root, text="▲", font=(FONT_FAMILY, 7, "bold"),
            fg=BORDER_COLOR, bg=BG_COLOR, cursor="hand2")
        self._min_btn.bind("<Button-1>", lambda e: self._toggle_minimize())
        self._min_btn.place(x=STATS_WIDTH-18, y=6)

        stats = [
            ("USE","USE"),("RAM","RAM"),("MEM","MEM"),("SSD","SSD"),
            ("GHz","GHz"),("GPU","GPU"),("PWR","PWR"),("SWP","SWP"),
            ("THM","THM"),("EFF","EFF"),("G4","g4 t/s"),("FLS","fls t/s"),
            ("SD1","SSD1"),("SD2","SSD2"),
        ]
        self.value_items = {}
        row_start_y = 38
        row_h = (STATS_HEIGHT - row_start_y - 22) // len(stats)
        for i, (key, prefix) in enumerate(stats):
            y = row_start_y + i * row_h + row_h // 2
            color = STAT_COLORS[key]
            self.canvas.create_text(12, y, text=prefix,
                font=(FONT_FAMILY, FONT_SIZE-1, "bold"), fill=color, anchor="w")
            item = self.canvas.create_text(STATS_WIDTH-6, y, text="…",
                font=(FONT_FAMILY, FONT_SIZE, "bold"), fill=color, anchor="e")
            self.value_items[key] = item

        # Graph area
        gx, gy = 4, STATS_HEIGHT + 10
        gw = WIN_WIDTH - 8
        gh = GRAPH_HEIGHT - 8
        self.graph_x = gx; self.graph_y = gy
        self.graph_w = gw; self.graph_h = gh

        self.canvas.create_rectangle(gx, gy, gx+gw, gy+gh,
            fill=BG_COLOR, outline=BORDER_COLOR, width=1)
        self.canvas.create_text(gx+4, gy-9, text="MEM+GPU+SWP+Δ+EFF+TPS 10h",
            font=(FONT_FAMILY, 7, "bold"), fill=BORDER_COLOR, anchor="nw")

        # Single canvas image item for PIL graph
        self._graph_img    = None
        self._graph_photo  = None
        self._graph_img_id = self.canvas.create_image(gx+1, gy+1, anchor="nw")

        # Mini strip — vertical stack
        _mini_h = MINI_ROW_H * 6
        self._mini_frame = tk.Frame(root, bg=BG_COLOR, width=MINI_WIDTH)
        self._mini_mem = tk.Label(self._mini_frame, text="MEM:…",
            font=(FONT_FAMILY, 9, "bold"), fg=PRESSURE_COLORS["Green"], bg=BG_COLOR, anchor="w")
        self._mini_gpu = tk.Label(self._mini_frame, text="GPU:…",
            font=(FONT_FAMILY, 9, "bold"), fg=STAT_COLORS["GPU"], bg=BG_COLOR, anchor="w")
        self._mini_swp = tk.Label(self._mini_frame, text="SWP:…",
            font=(FONT_FAMILY, 9, "bold"), fg=STAT_COLORS["SWP"], bg=BG_COLOR, anchor="w")
        self._mini_g4  = tk.Label(self._mini_frame, text="g4:…",
            font=(FONT_FAMILY, 9, "bold"), fg=STAT_COLORS["G4"],  bg=BG_COLOR, anchor="w")
        self._mini_fls = tk.Label(self._mini_frame, text="fls:…",
            font=(FONT_FAMILY, 9, "bold"), fg=STAT_COLORS["FLS"], bg=BG_COLOR, anchor="w")
        self._mini_rst = tk.Label(self._mini_frame, text="▼ expand",
            font=(FONT_FAMILY, 7, "bold"), fg=BORDER_COLOR, bg=BG_COLOR, cursor="hand2", anchor="w")
        self._mini_rst.bind("<Button-1>", lambda e: self._toggle_minimize())
        self._mini_frame.bind("<Button-1>", lambda e: self._toggle_minimize())
        self._mini_frame.configure(cursor="hand2")
        for w in [self._mini_mem, self._mini_gpu, self._mini_swp, self._mini_g4, self._mini_fls, self._mini_rst]:
            w.pack(side="top", fill="x", padx=4)
            w.bind("<Button-1>", lambda e: self._toggle_minimize())

        self._save_counter = 0

        if _was_minimized:
            self._minimized = True
            self._min_btn.place_forget()
            self.canvas.place_forget()
            _mini_h = MINI_ROW_H * 6
            self._mini_frame.place(x=0, y=0, width=MINI_WIDTH, height=_mini_h)

        root.after(3000, lambda: setattr(self, "_startup", False))
        self.update_stats()

    def _on_configure(self, event):
        if getattr(self, "_startup", True): return
        if event.widget == self.root and not self._minimized:
            if hasattr(self, '_save_pos_job'):
                self.root.after_cancel(self._save_pos_job)
            self._save_pos_job = self.root.after(1000, self._save_position)

    def _save_position(self):
        x = self.root.winfo_x(); y = self.root.winfo_y()
        if x > 0 or y > 0:
            _save_window_state(x, y, False)

    def _toggle_minimize(self):
        if self._minimized:
            self._mini_frame.place_forget()
            self.canvas.place(x=0, y=0)
            self._min_btn.place(x=STATS_WIDTH-18, y=6)
            self.root.geometry(f"{WIN_WIDTH}x{WIN_HEIGHT}")
            self._minimized = False
            _save_window_state(self.root.winfo_x(), self.root.winfo_y(), False)
        else:
            self._min_btn.place_forget()
            self.canvas.place_forget()
            _mini_h = MINI_ROW_H * 6
            self._mini_frame.place(x=0, y=0, width=MINI_WIDTH, height=_mini_h)
            self.root.geometry(f"{MINI_WIDTH}x{_mini_h}")
            self._minimized = True
            self.root.update_idletasks()
            _save_window_state(self.root.winfo_x(), self.root.winfo_y(), True)

    def draw_graph(self):
        if self._minimized:
            return
        # Render to PIL image and blit as single PhotoImage — no canvas line accumulation
        img = _render_graph(self.graph_w - 2, self.graph_h - 2)
        self._graph_img   = img
        self._graph_photo = ImageTk.PhotoImage(img)
        self.canvas.itemconfig(self._graph_img_id, image=self._graph_photo)

    def update_stats(self):
        pressure, mem_color = get_memory_pressure()
        mem_pct             = get_mem_pct()
        gui_mem_color       = get_mem_color()
        gpu_txt             = get_gpu_residency()
        swp_txt             = get_swap_used()
        thm_txt, thm_color  = get_thermal()

        if not self._minimized:
            self.canvas.itemconfig(self.value_items["USE"], text=get_cpu_usage())
            self.canvas.itemconfig(self.value_items["RAM"], text=get_ram_used_gb())
            self.canvas.itemconfig(self.value_items["SSD"], text=get_ssd_usage())
            self.canvas.itemconfig(self.value_items["GHz"], text=get_cpu_freq_ghz())
            self.canvas.itemconfig(self.value_items["GPU"], text=gpu_txt)
            self.canvas.itemconfig(self.value_items["PWR"], text=get_cpu_power())
            self.canvas.itemconfig(self.value_items["SWP"], text=swp_txt)
            self.canvas.itemconfig(self.value_items["MEM"], text=pressure, fill=mem_color)
            self.canvas.itemconfig(self.value_items["THM"], text=thm_txt, fill=thm_color)
            self.canvas.itemconfig(self.value_items["EFF"], text=get_efficiency())
            g4_color  = get_lms_model_color("g4",    "G4")
            fls_color = get_lms_model_color("flash",  "FLS")
            self.canvas.itemconfig(self.value_items["G4"],  text=get_lms_model_display("g4"),    fill=g4_color)
            self.canvas.itemconfig(self.value_items["FLS"], text=get_lms_model_display("flash"),  fill=fls_color)
            self.canvas.itemconfig(self.value_items["SD1"], text=get_ssd_temp("SD1"))
            self.canvas.itemconfig(self.value_items["SD2"], text=get_ssd_temp("SD2"))
            self.draw_graph()
        else:
            self._mini_mem.config(text=f"MEM:{mem_pct}", fg=gui_mem_color)
            self._mini_gpu.config(text=f"GPU:{gpu_txt}")
            self._mini_swp.config(text=f"SWP:{swp_txt}")
            self._mini_g4.config(text=f"g4:{get_lms_model_display('g4')}",
                                 fg=get_lms_model_color('g4', 'G4'))
            self._mini_fls.config(text=f"fls:{get_lms_model_display('flash')}",
                                  fg=get_lms_model_color('flash', 'FLS'))

        self._save_counter += 1
        if self._save_counter >= 24:
            _save_history()
            self._save_counter = 0

        self.root.after(UPDATE_MS, self.update_stats)


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _sigterm_handler)
    _load_history()
    threading.Thread(target=_data_loop,   daemon=True).start()
    threading.Thread(target=_web_server,  daemon=True).start()
    threading.Thread(target=_lms_log_stream,    daemon=True).start()
    threading.Thread(target=_lms_idle_watchdog, daemon=True).start()
    psutil.cpu_percent(interval=0.1)
    root = tk.Tk()
    MonitorApp(root)
    root.mainloop()
