#!/usr/bin/env python3
"""
MacBook Pro System Monitor
Run: /opt/homebrew/bin/python3.13 mbp_monitor.py
Requirements: pip3 install psutil Pillow --break-system-packages
Background image: ~/.local/bin/TxtSysMonBkgd.webp
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
from PIL import Image, ImageDraw, ImageTk

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mbp_monitor")

# ── Config ───────────────────────────────────────────────────────────────────
UPDATE_MS        = 5000
PM_INTERVAL      = 15
BATTERY_INTERVAL = 60
WIN_WIDTH        = 320
STATS_HEIGHT     = 310
GRAPH_HEIGHT     = 80
WIN_HEIGHT       = STATS_HEIGHT + GRAPH_HEIGHT + 20
STATS_WIDTH      = 160
MINI_WIDTH       = 130   # vertical mini strip width
MINI_ROW_H       = 22    # height per stat row in mini strip
FONT_FAMILY      = "Courier"
FONT_SIZE        = 11
TITLE_SIZE       = 9
BORDER_COLOR     = "#ff6eb4"
BG_COLOR         = "#08080f"
BG_IMAGE         = os.path.expanduser("~/.local/bin/TxtSysMonBkgd.webp")
IMG_CROP_LEFT    = 0.37
HISTORY_FILE     = os.path.expanduser("~/.local/bin/mem_history.json")
STATE_FILE       = os.path.expanduser("~/.local/bin/monitor_state.json")
MAX_HISTORY      = 17280
GRAPH_WINDOW     = 86400    # 24h
EFF_GRAPH_SCALE  = 500.0    # 500 %/W = 100% of graph (Apple Silicon GPU/W peaks ~300-400)

MEM_DELTA_SAMPLES = 6
SWP_DELTA_SAMPLES = 12

# ── Precompiled regex ─────────────────────────────────────────────────────────
SWP_USED_RE  = re.compile(r"used\s*=\s*([\d.]+)M")
SWP_TOTAL_RE = re.compile(r"total\s*=\s*([\d.]+)M")
GPU_RE       = re.compile(r"GPU HW active residency:\s*([\d.]+)%")
CPU_PWR_RE   = re.compile(r"^CPU Power:\s*([\d.]+)\s*mW", re.MULTILINE)
CPU_FREQ_RE  = re.compile(r"(?:P0-Cluster HW active frequency|CPU 0 frequency):\s*([\d.]+)\s*MHz")
THERMAL_RE   = re.compile(r"Current pressure level:\s*(\w+)")
BAT_PCT_RE   = re.compile(r"(\d+)%")

# ── 508-compliant label colors (all ≥4.5:1 on #08080f) ───────────────────────
# GPU: #006666 was 2.94:1 (FAIL) → #00b4b4 (7.78:1)
# GHz: #00ced1 → #c084fc (purple, distinct from GPU teal)
# SSD: #ff4500 → #ff6633 (6.84:1)
# delta grey: #555555 was 2.68:1 (FAIL) → #aaaaaa (8.59:1)
# grid labels: #444466 was 2.15:1 (FAIL) → #7777aa (4.76:1)
STAT_COLORS = {
    "USE": "#ff6eb4",   # 7.74:1
    "RAM": "#00bfff",   # 9.41:1
    "MEM": "#ffffff",   # 18.6:1
    "SSD": "#ff6633",   # 6.84:1
    "GHz": "#c084fc",   # 8.21:1  purple — distinct from GPU teal
    "GPU": "#00b4b4",   # 7.78:1  (was #006666 — FAIL 2.94:1)
    "PWR": "#ffd700",   # 14.23:1
    "SWP": "#ff8c00",   # 8.56:1
    "BAT": "#00e676",   # 11.96:1
    "THM": "#00e676",   # 11.96:1
    "EFF": "#88aaff",   # 8.78:1
}

PRESSURE_COLORS = {"Green": "#00e676", "Yellow": "#ffd600", "Red": "#ff1744"}
THERMAL_COLORS  = {
    "Nominal": "#00e676", "Fair": "#ffd600",
    "Serious": "#ff8c00", "Critical": "#ff1744", "…": "#ffffff",
}

# ── Graph line colors as PIL RGB tuples (all ≥3:1 on #08080f) ────────────────
GRAPH_COLORS = {
    "mem_green":  (0,   230, 118),   # 11.96:1
    "mem_yellow": (255, 214,   0),   # 14.14:1
    "mem_red":    (255,  68,  68),   #  5.86:1
    "gpu":        (0,   180, 180),   #  7.78:1  (was 0,102,102 — FAIL 2.94:1)
    "swp":        (255, 100,   0),   #  7.08:1  distinct orange (not same as mem_red)
    "delta":      (170, 170, 170),   #  8.59:1  (was 85,85,85 — FAIL 2.68:1)
    "eff":        (80,  100, 180),   #  3.42:1  muted — context line, not primary
    "grid":       (26,   26,  42),   #  decorative — contrast not required
    "label":      (119, 119, 170),   #  4.76:1  (was 68,68,102 — FAIL 2.15:1)
}

# ── Shared state ─────────────────────────────────────────────────────────────
_state           = {}
_mem_min         = None
_mem_max         = None
_mem_history     = []
_gpu_history     = []
_swp_history     = []
_eff_history     = []
_state_lock      = threading.Lock()
_last_battery_ts = 0


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
                "history": _mem_history, "min": _mem_min, "max": _mem_max,
                "gpu_history": _gpu_history, "swp_history": _swp_history,
                "eff_history": _eff_history,
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


# ── Background data collection thread ────────────────────────────────────────

def _data_loop():
    global _mem_min, _mem_max, _last_battery_ts
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
            m = CPU_FREQ_RE.search(out)
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

        now = time.time()
        if now - _last_battery_ts > BATTERY_INTERVAL:
            try:
                bout = subprocess.check_output(["pmset", "-g", "batt"], text=True)
                m = BAT_PCT_RE.search(bout); pct = int(m.group(1)) if m else None
                st = "↑" if "charging" in bout.lower() and "discharging" not in bout.lower() \
                     else "↓" if "discharging" in bout.lower() else "~"
                with _state_lock:
                    _state["battery_text"] = f"{pct}%{st}" if pct is not None else "…"
            except Exception as e:
                log.warning("battery error: %s", e)
                with _state_lock:
                    _state["battery_text"] = "…"
            _last_battery_ts = now

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

def get_battery():
    with _state_lock: return _state.get("battery_text", "…")

def get_thermal():
    t = _state.get("thermal", "…"); return t, THERMAL_COLORS.get(t, "#ffffff")

def get_efficiency():
    g = _state.get("gpu_residency"); m = _state.get("cpu_power_mw")
    return "…" if (g is None or m is None or m<10) else f"{g/(m/1000):.1f} %/W"


# ── PIL graph renderer ────────────────────────────────────────────────────────

def _render_graph(gw, gh, pad=26):
    """Render all graph lines into a PIL image — single object, no Tcl accumulation.
    Draw order: delta → gpu → eff → swp → mem (MEM topmost).
    """
    img  = Image.new("RGB", (gw, gh), (10, 10, 15))
    draw = ImageDraw.Draw(img)
    plot_w = gw - pad

    with _state_lock:
        mem_snap = list(_mem_history)
        gpu_snap = list(_gpu_history)
        swp_snap = list(_swp_history)
        eff_snap = list(_eff_history)

    now = time.time()

    def ts_to_x(ts):
        return max(0, min(plot_w - 1, plot_w - int((now - ts) / GRAPH_WINDOW * plot_w)))

    def val_to_y(val):
        return max(0, min(gh - 1, gh - 1 - int(val / 100 * (gh - 2))))

    # Grid lines
    for pct in [25, 50, 75]:
        y = val_to_y(pct)
        draw.line([(0, y), (plot_w, y)], fill=GRAPH_COLORS["grid"])
        draw.text((plot_w + 2, y - 5), f"{pct}%", fill=GRAPH_COLORS["label"])

    def plot_line(snap, color_fn, scale=None):
        if len(snap) < 2: return
        prev = None
        for ts, raw in snap:
            val = min(100, max(0, (raw / scale) * 100)) if scale else max(0, min(100, raw))
            x = ts_to_x(ts); y = val_to_y(val)
            pt = (x, y)
            if prev is not None:
                c = color_fn(raw) if callable(color_fn) else color_fn
                draw.line([prev, pt], fill=c)
            prev = pt

    # MEM delta (grey) — background context line
    if len(mem_snap) >= MEM_DELTA_SAMPLES + 1:
        dlt = [(mem_snap[i][0], min(100, max(0, 50 + (mem_snap[i][1] - mem_snap[i-MEM_DELTA_SAMPLES][1]) * 5)))
               for i in range(MEM_DELTA_SAMPLES, len(mem_snap))]
        plot_line(dlt, GRAPH_COLORS["delta"])

    # GPU (teal) — draw before MEM so MEM stays on top
    plot_line(gpu_snap, GRAPH_COLORS["gpu"])

    # EFF (muted blue) — context line, not primary
    plot_line(eff_snap, GRAPH_COLORS["eff"], scale=EFF_GRAPH_SCALE)

    # SWP (orange) — draw before MEM
    plot_line(swp_snap, GRAPH_COLORS["swp"])

    # MEM (color by pressure) — topmost
    def mem_color(val):
        return GRAPH_COLORS["mem_red"] if val>95 else GRAPH_COLORS["mem_yellow"] if val>80 else GRAPH_COLORS["mem_green"]
    plot_line(mem_snap, mem_color)

    return img


# ── GUI ───────────────────────────────────────────────────────────────────────

class MonitorApp:
    def __init__(self, root):
        self.root       = root
        self._minimized = False
        self._startup   = True

        # Restore window state
        _ws = _load_window_state()
        _x = _ws.get("x"); _y = _ws.get("y")
        _mini_x = _ws.get("mini_x"); _mini_y = _ws.get("mini_y")
        _was_minimized = _ws.get("minimized", False)

        _mini_h = MINI_ROW_H * 5   # MEM + GPU + SWP + BAT + restore arrow
        if _was_minimized and _mini_x is not None and _mini_y is not None:
            root.geometry(f"{MINI_WIDTH}x{_mini_h}+{_mini_x}+{_mini_y}")
        elif _x is not None and _y is not None:
            root.geometry(f"{WIN_WIDTH}x{WIN_HEIGHT}+{_x}+{_y}")
        else:
            root.geometry(f"{WIN_WIDTH}x{WIN_HEIGHT}")

        root.title("MBP Monitor")
        root.resizable(False, False)
        root.attributes("-topmost", True)
        root.attributes("-alpha", 0.70)
        root.configure(bg=BG_COLOR)
        root.bind("<Configure>", self._on_configure)

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
        self.canvas.create_rectangle(4, 4, STATS_WIDTH-4, STATS_HEIGHT-4,
            fill="", outline=BORDER_COLOR, width=2)
        self.canvas.create_text(STATS_WIDTH//2, 18, text="◈ MacBook Pro ◈",
            font=(FONT_FAMILY, TITLE_SIZE, "bold"), fill=BORDER_COLOR)
        self.canvas.create_line(10, 28, STATS_WIDTH-10, 28, fill=BORDER_COLOR, width=1)

        self._min_btn = tk.Label(root, text="▲", font=(FONT_FAMILY, 7, "bold"),
            fg=BORDER_COLOR, bg=BG_COLOR, cursor="hand2")
        self._min_btn.bind("<Button-1>", lambda e: self._toggle_minimize())
        self._min_btn.place(x=STATS_WIDTH-18, y=6)

        stats = [
            ("USE","USE"),("RAM","RAM"),("MEM","MEM"),("SSD","SSD"),
            ("GHz","GHz"),("GPU","GPU"),("PWR","PWR"),("SWP","SWP"),
            ("BAT","BAT"),("THM","THM"),("EFF","EFF"),
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
        gx, gy = 4, STATS_HEIGHT + 14
        gw, gh = WIN_WIDTH - 8, GRAPH_HEIGHT - 8
        self.graph_x = gx; self.graph_y = gy
        self.graph_w = gw; self.graph_h = gh

        self.canvas.create_rectangle(gx, gy, gx+gw, gy+gh,
            fill=BG_COLOR, outline=BORDER_COLOR, width=1)
        self.canvas.create_text(gx+4, gy-9, text="MEM+GPU+SWP+Δ+EFF 24h",
            font=(FONT_FAMILY, 7, "bold"), fill=BORDER_COLOR, anchor="nw")

        # Single canvas image item for PIL graph — replaces all create_line calls
        self._graph_photo  = None
        self._graph_img_id = self.canvas.create_image(gx+1, gy+1, anchor="nw")

        # Mini strip — vertical stack
        _mini_h = MINI_ROW_H * 5
        self._mini_frame = tk.Frame(root, bg=BG_COLOR, width=MINI_WIDTH)
        self._mini_mem = tk.Label(self._mini_frame, text="MEM:…",
            font=(FONT_FAMILY, 9, "bold"), fg=PRESSURE_COLORS["Green"], bg=BG_COLOR, anchor="w")
        self._mini_gpu = tk.Label(self._mini_frame, text="GPU:…",
            font=(FONT_FAMILY, 9, "bold"), fg=STAT_COLORS["GPU"], bg=BG_COLOR, anchor="w")
        self._mini_swp = tk.Label(self._mini_frame, text="SWP:…",
            font=(FONT_FAMILY, 9, "bold"), fg=STAT_COLORS["SWP"], bg=BG_COLOR, anchor="w")
        self._mini_bat = tk.Label(self._mini_frame, text="BAT:…",
            font=(FONT_FAMILY, 9, "bold"), fg=STAT_COLORS["BAT"], bg=BG_COLOR, anchor="w")
        self._mini_rst = tk.Label(self._mini_frame, text="▼ expand",
            font=(FONT_FAMILY, 7, "bold"), fg=BORDER_COLOR, bg=BG_COLOR, cursor="hand2", anchor="w")
        self._mini_rst.bind("<Button-1>", lambda e: self._toggle_minimize())
        self._mini_frame.bind("<Button-1>", lambda e: self._toggle_minimize())
        self._mini_frame.configure(cursor="hand2")
        for w in [self._mini_mem, self._mini_gpu, self._mini_swp,
                  self._mini_bat, self._mini_rst]:
            w.pack(side="top", fill="x", padx=4)
            w.bind("<Button-1>", lambda e: self._toggle_minimize())

        self._save_counter = 0

        if _was_minimized:
            self._minimized = True
            self._min_btn.place_forget()
            self.canvas.place_forget()
            _mini_h = MINI_ROW_H * 5
            self._mini_frame.place(x=0, y=0, width=MINI_WIDTH, height=_mini_h)

        root.after(3000, lambda: setattr(self, "_startup", False))
        self.update_stats()

    # ── Minimize / restore ────────────────────────────────────────────────────

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
            _mini_h = MINI_ROW_H * 5
            self._mini_frame.place(x=0, y=0, width=MINI_WIDTH, height=_mini_h)
            self.root.geometry(f"{MINI_WIDTH}x{_mini_h}")
            self._minimized = True
            self.root.update_idletasks()
            _save_window_state(self.root.winfo_x(), self.root.winfo_y(), True)

    # ── Graph ─────────────────────────────────────────────────────────────────

    def draw_graph(self):
        if self._minimized:
            return
        img = _render_graph(self.graph_w - 2, self.graph_h - 2)
        self._graph_photo = ImageTk.PhotoImage(img)
        self.canvas.itemconfig(self._graph_img_id, image=self._graph_photo)

    # ── Stats update ──────────────────────────────────────────────────────────

    def update_stats(self):
        pressure, mem_color = get_memory_pressure()
        mem_pct             = get_mem_pct()
        gui_mem_color       = get_mem_color()
        gpu_txt             = get_gpu_residency()
        swp_txt             = get_swap_used()
        bat_txt             = get_battery()
        thm_txt, thm_color  = get_thermal()

        if not self._minimized:
            self.canvas.itemconfig(self.value_items["USE"], text=get_cpu_usage())
            self.canvas.itemconfig(self.value_items["RAM"], text=get_ram_used_gb())
            self.canvas.itemconfig(self.value_items["SSD"], text=get_ssd_usage())
            self.canvas.itemconfig(self.value_items["GHz"], text=get_cpu_freq_ghz())
            self.canvas.itemconfig(self.value_items["GPU"], text=gpu_txt)
            self.canvas.itemconfig(self.value_items["PWR"], text=get_cpu_power())
            self.canvas.itemconfig(self.value_items["SWP"], text=swp_txt)
            self.canvas.itemconfig(self.value_items["BAT"], text=bat_txt)
            self.canvas.itemconfig(self.value_items["MEM"], text=pressure, fill=mem_color)
            self.canvas.itemconfig(self.value_items["THM"], text=thm_txt, fill=thm_color)
            self.canvas.itemconfig(self.value_items["EFF"], text=get_efficiency())
            self.draw_graph()
        else:
            self._mini_mem.config(text=f"MEM:{mem_pct}", fg=gui_mem_color)
            self._mini_gpu.config(text=f"GPU:{gpu_txt}")
            self._mini_swp.config(text=f"SWP:{swp_txt}")
            self._mini_bat.config(text=f"BAT:{bat_txt}")

        self._save_counter += 1
        if self._save_counter >= 24:
            _save_history()
            self._save_counter = 0

        self.root.after(UPDATE_MS, self.update_stats)


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _sigterm_handler)
    _load_history()
    threading.Thread(target=_data_loop, daemon=True).start()
    psutil.cpu_percent(interval=0.1)
    root = tk.Tk()
    MonitorApp(root)
    root.mainloop()
