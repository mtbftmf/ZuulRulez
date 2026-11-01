#!/usr/bin/env python3
"""gemma-monitor — read-only web dashboard for a headless Gemma 4 Studio.

Runs as the build account (LaunchDaemon com.gemma.monitor), standard library only.
Serves http://<host>.local:MON_PORT/ (default 9090) on the LAN:
  /            dashboard (refreshes every 5 s, 36-hour graph)
  /api/stats   JSON: memory, swap, CPU, GPU, power, thermals, model server, Open WebUI
  /health      {"ok": true}

Sources (no sudo needed here):
  vm_stat, sysctl, top                    memory, swap, pressure, CPU
  http://127.0.0.1:PORT/metrics          llama-server counters (the server runs with --metrics)
  http://127.0.0.1:OWUI_PORT/health      Open WebUI
  /usr/local/var/gemma-monitor/powermetrics.txt
                                          GPU residency, CPU/GPU/ANE power, thermal pressure,
                                          written every ~15 s by the root-only sampler
                                          (com.gemma.powermetrics, gemma/monitor/pm-sampler.sh)
Settings come from ~/.config/gemma.env (PORT, OWUI_PORT, MON_PORT); nothing host-specific is
hard-coded. History (one point a minute, 36 hours) survives restarts in
~/Library/Application Support/gemma-monitor/history.json.
"""

import json
import os
import re
import signal
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ── Settings ──────────────────────────────────────────────────────────────────

def _read_env(path):
    vals = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                vals[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return vals

_ENV = _read_env(os.path.expanduser("~/.config/gemma.env"))

def _setting(key, default):
    return os.environ.get(key) or _ENV.get(key) or default

LLM_PORT   = int(_setting("PORT", "1234"))
OWUI_PORT  = int(_setting("OWUI_PORT", "8080"))
MON_PORT   = int(_setting("MON_PORT", "9090"))
ENGINE     = _setting("ENGINE", "llamacpp")
PM_FILE    = _setting("MON_PM_FILE", "/usr/local/var/gemma-monitor/powermetrics.txt")
STATE_DIR  = os.path.expanduser("~/Library/Application Support/gemma-monitor")
HISTORY    = os.path.join(STATE_DIR, "history.json")

POLL_S      = 5        # stats and model-server poll
HIST_STEP   = 60       # one history point per minute
HIST_WINDOW = 36 * 3600
PM_STALE_S  = 90       # powermetrics file older than this: show "n/a"

# ── Helpers ───────────────────────────────────────────────────────────────────

def _run(cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""

def _sysctl(name):
    return _run(["sysctl", "-n", name]).strip()

def _get(url, timeout=3):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")

_PROM_RE = re.compile(r'^([A-Za-z_:][\w:]*)(?:\{[^}]*\})?\s+([-+0-9.eE]+|NaN|[+-]Inf)\s*$')

def parse_prometheus(text):
    """Prometheus text format → {name: float}; labels are dropped, last sample wins."""
    out = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        m = _PROM_RE.match(line.strip())
        if m:
            try:
                out[m.group(1)] = float(m.group(2))
            except ValueError:
                pass
    return out

def _first(d, *names):
    for n in names:
        if n in d:
            return d[n]
    return None

# ── Static host facts (read once) ─────────────────────────────────────────────

def host_facts():
    facts = {
        "host": _run(["scutil", "--get", "LocalHostName"]).strip() or socket.gethostname().split(".")[0],
        "chip": _sysctl("machdep.cpu.brand_string") or "Apple Silicon",
        "mem_total_gb": round(int(_sysctl("hw.memsize") or 0) / 2**30, 1),
        "cpu_cores": _sysctl("hw.ncpu"),
        "gpu_cores": "",
        "engine": ENGINE,
        "llm_port": LLM_PORT,
        "owui_port": OWUI_PORT,
        "ctx": _setting("CTX", ""),
    }
    m = re.search(r"Total Number of Cores:\s*(\d+)", _run(["system_profiler", "SPDisplaysDataType"], 20))
    if m:
        facts["gpu_cores"] = m.group(1)
    return facts

# ── Shared state ──────────────────────────────────────────────────────────────

_lock = threading.Lock()
_state = {}
_hist = {"t": [], "mem": [], "wired": [], "swap": [], "gpu": [], "pwr": [], "tps": []}
_acc = {}          # per-minute accumulators: key -> [sum, n]

def _acc_add(key, val):
    if val is None:
        return
    s = _acc.setdefault(key, [0.0, 0])
    s[0] += val
    s[1] += 1

def _acc_flush(now):
    with _lock:
        _hist["t"].append(int(now))
        for k in ("mem", "wired", "swap", "gpu", "pwr", "tps"):
            s = _acc.get(k)
            _hist[k].append(round(s[0] / s[1], 2) if s and s[1] else None)
        _acc.clear()
        cutoff = now - HIST_WINDOW
        while _hist["t"] and _hist["t"][0] < cutoff:
            for k in _hist:
                _hist[k].pop(0)

def load_history():
    try:
        with open(HISTORY) as f:
            data = json.load(f)
        if set(data) == set(_hist) and len({len(v) for v in data.values()}) == 1:
            cutoff = time.time() - HIST_WINDOW
            keep = [i for i, t in enumerate(data["t"]) if t >= cutoff]
            for k in _hist:
                _hist[k] = [data[k][i] for i in keep]
    except (OSError, ValueError, KeyError):
        pass

def save_history():
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = HISTORY + ".tmp"
        with _lock:
            data = json.dumps(_hist)
        with open(tmp, "w") as f:
            f.write(data)
        os.replace(tmp, HISTORY)
    except OSError:
        pass

# ── Pollers ───────────────────────────────────────────────────────────────────

def read_memory():
    out = _run(["vm_stat"])
    page = 16384
    m = re.search(r"page size of (\d+) bytes", out)
    if m:
        page = int(m.group(1))
    pages = {}
    for line in out.splitlines()[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            v = v.strip().rstrip(".")
            if v.isdigit():
                pages[k.strip()] = int(v)
    gb = lambda n: n * page / 2**30
    wired = gb(pages.get("Pages wired down", 0))
    used = gb(pages.get("Pages active", 0) + pages.get("Pages wired down", 0)
              + pages.get("Pages occupied by compressor", 0))
    comp = gb(pages.get("Pages occupied by compressor", 0))
    r = {"mem_used_gb": round(used, 2), "wired_gb": round(wired, 2), "compressed_gb": round(comp, 2)}
    swap = _sysctl("vm.swapusage")
    mu = re.search(r"used\s*=\s*([\d.]+)M", swap)
    mt = re.search(r"total\s*=\s*([\d.]+)M", swap)
    if mu and mt:
        r["swap_used_mb"] = float(mu.group(1))
        r["swap_total_mb"] = float(mt.group(1))
    lvl = _sysctl("kern.memorystatus_vm_pressure_level")       # 1 normal, 2 warning, 4 critical
    r["pressure"] = {"1": "Normal", "2": "Warning", "4": "Critical"}.get(lvl, "—")
    free = _sysctl("kern.memorystatus_level")                   # system-wide free %
    r["mem_free_pct"] = int(free) if free.isdigit() else None
    return r

def read_cpu():
    out = _run(["top", "-l", "2", "-n", "0", "-s", "1"], 10)
    lines = [l for l in out.splitlines() if l.startswith("CPU usage:")]
    r = {"load": [round(x, 2) for x in os.getloadavg()]}
    if lines:
        m = re.search(r"([\d.]+)% idle", lines[-1])
        if m:
            r["cpu_pct"] = round(100.0 - float(m.group(1)), 1)
    return r

_PM = {
    "gpu_pct": re.compile(r"GPU HW active residency:\s*([\d.]+)%"),
    "cpu_mw":  re.compile(r"^CPU Power:\s*([\d.]+)\s*mW", re.M),
    "gpu_mw":  re.compile(r"^GPU Power:\s*([\d.]+)\s*mW", re.M),
    "ane_mw":  re.compile(r"^ANE Power:\s*([\d.]+)\s*mW", re.M),
}
_THERMAL = re.compile(r"Current pressure level:\s*(\w+)")

def read_powermetrics():
    try:
        age = time.time() - os.path.getmtime(PM_FILE)
        with open(PM_FILE) as f:
            text = f.read()
    except OSError:
        return {"pm_status": "not installed"}
    if age > PM_STALE_S:
        return {"pm_status": f"stale ({int(age)} s)"}
    r = {"pm_status": "ok"}
    for k, rx in _PM.items():
        m = rx.search(text)
        r[k] = float(m.group(1)) if m else None
    m = _THERMAL.search(text)
    r["thermal"] = m.group(1) if m else None
    watts = [r[k] for k in ("cpu_mw", "gpu_mw", "ane_mw") if r.get(k) is not None]
    r["power_w"] = round(sum(watts) / 1000, 1) if watts else None
    return r

class LlamaPoller:
    """Turns llama-server's cumulative counters into per-interval rates."""

    def __init__(self):
        self.prev = None
        self.last_tps = None
        self.last_tps_at = 0
        self.last_prefill = None

    def poll(self):
        r = {"llm_up": True}
        try:
            _get(f"http://127.0.0.1:{LLM_PORT}/health")
        except urllib.error.HTTPError as e:            # 503 while the model is loading
            return {"llm_up": False, "llm_status": "Loading" if e.code == 503 else f"HTTP {e.code}"}
        except OSError:
            return {"llm_up": False, "llm_status": "Down"}
        if ENGINE != "llamacpp":
            r["llm_status"] = "Up (no metrics on this engine)"
            return r
        try:
            m = parse_prometheus(_get(f"http://127.0.0.1:{LLM_PORT}/metrics"))
        except OSError:
            r["llm_status"] = "Up (metrics unavailable)"
            return r
        tok = _first(m, "llamacpp:tokens_predicted_total")
        tok_s = _first(m, "llamacpp:tokens_predicted_seconds_total")
        pr = _first(m, "llamacpp:prompt_tokens_total")
        pr_s = _first(m, "llamacpp:prompt_seconds_total")
        busy = _first(m, "llamacpp:requests_processing")
        r["requests_processing"] = int(busy) if busy is not None else None
        r["requests_deferred"] = int(_first(m, "llamacpp:requests_deferred") or 0)
        kv = _first(m, "llamacpp:kv_cache_usage_ratio")            # older llama.cpp only
        r["kv_pct"] = round(kv * 100, 1) if kv is not None else None
        mx = _first(m, "llamacpp:n_tokens_max")                     # largest request so far
        r["tokens_max"] = int(mx) if mx is not None else None
        r["tokens_total"] = int(tok) if tok is not None else None
        r["metrics_known"] = tok is not None and tok_s is not None
        now = time.time()
        cur = (tok, tok_s, pr, pr_s)
        if self.prev and None not in cur and None not in self.prev:
            d_tok, d_tok_s = cur[0] - self.prev[0], cur[1] - self.prev[1]
            d_pr, d_pr_s = cur[2] - self.prev[2], cur[3] - self.prev[3]
            if d_tok > 0 and d_tok_s > 0:
                self.last_tps = d_tok / d_tok_s
                self.last_tps_at = now
            if d_pr > 0 and d_pr_s > 0:
                self.last_prefill = d_pr / d_pr_s
        self.prev = cur
        active = (busy or 0) > 0 or now - self.last_tps_at < 2 * POLL_S
        r["llm_status"] = "Active" if active else "Idle"
        r["tps_now"] = round(self.last_tps, 1) if active and self.last_tps else None
        r["tps_last"] = round(self.last_tps, 1) if self.last_tps else None
        r["tps_last_age_s"] = int(now - self.last_tps_at) if self.last_tps_at else None
        r["prefill_last"] = round(self.last_prefill, 1) if self.last_prefill else None
        return r

def read_owui():
    try:
        _get(f"http://127.0.0.1:{OWUI_PORT}/health")
        return {"owui_up": True}
    except OSError:
        return {"owui_up": False}

def poll_loop():
    llama = LlamaPoller()
    cpu_every, n = 3, 0
    next_flush = (int(time.time()) // HIST_STEP + 1) * HIST_STEP
    next_save = time.time() + 300
    while True:
        t0 = time.time()
        upd = {}
        for fn in (read_memory, read_powermetrics, llama.poll, read_owui):
            try:
                upd.update(fn())
            except Exception as e:                      # keep the dashboard alive whatever fails
                upd.setdefault("errors", []).append(f"{fn.__name__}: {e}")
        if n % cpu_every == 0:
            try:
                upd.update(read_cpu())
            except Exception:
                pass
        n += 1
        upd["updated"] = int(t0)
        with _lock:
            _state.update(upd)
            facts_mem = _state.get("mem_total_gb") or 0
        if facts_mem:
            _acc_add("mem", upd.get("mem_used_gb", 0) / facts_mem * 100)
        _acc_add("wired", upd.get("wired_gb"))
        if upd.get("swap_total_mb"):
            _acc_add("swap", upd["swap_used_mb"])
        _acc_add("gpu", upd.get("gpu_pct"))
        _acc_add("pwr", upd.get("power_w"))
        _acc_add("tps", upd.get("tps_now"))
        if t0 >= next_flush:
            _acc_flush(t0)
            next_flush += HIST_STEP
        if t0 >= next_save:
            save_history()
            next_save = t0 + 300
        time.sleep(max(0.5, POLL_S - (time.time() - t0)))

# ── Web ───────────────────────────────────────────────────────────────────────

PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Gemma Studio Monitor</title>
<style>
:root{--bg:#0b0d12;--card:#141821;--line:#262c38;--fg:#e4e8ee;--muted:#9aa4b2;
 --mem:#38bdf8;--wired:#2563eb;--gpu:#c3c9d2;--pwr:#facc15;--tps:#e879f9;--swap:#fb923c;
 --ok:#4ade80;--warn:#facc15;--crit:#f87171}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--fg);font:14px/1.45 ui-monospace,Menlo,monospace;padding:16px;max-width:1200px;margin:0 auto}
h1{font-size:17px;margin-bottom:2px}
#sub{color:var(--muted);font-size:12px;margin-bottom:14px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px;margin-bottom:12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px;min-width:0}
.card h2{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;margin-bottom:8px}
.row{display:flex;justify-content:space-between;gap:8px;margin:3px 0}
.k{color:var(--muted);white-space:nowrap;flex:none} .v{font-weight:700;text-align:right;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bar{height:6px;background:var(--line);border-radius:3px;margin:3px 0 8px;overflow:hidden}
.bar i{display:block;height:100%;width:0;transition:width .4s}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px;vertical-align:1px}
canvas{width:100%;height:200px;display:block}
.legend{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:12px;color:var(--muted);margin-bottom:6px}
.legend b{display:inline-block;width:10px;height:3px;vertical-align:3px;margin-right:5px}
footer{color:var(--muted);font-size:11px;margin-top:10px}
</style></head><body>
<h1 id="title">Gemma Studio</h1>
<div id="sub">loading…</div>
<div class="grid">
 <div class="card"><h2>Model server</h2>
  <div class="row"><span class="k">Status</span><span class="v" id="llm">—</span></div>
  <div class="row"><span class="k">Generating</span><span class="v" id="tps" style="color:var(--tps)">—</span></div>
  <div class="bar"><i id="tpsbar" style="background:var(--tps)"></i></div>
  <div class="row"><span class="k">Last</span><span class="v" id="tpslast">—</span></div>
  <div class="row"><span class="k">Prompt reading</span><span class="v" id="prefill">—</span></div>
  <div class="row"><span class="k">Busy / queued</span><span class="v" id="req">—</span></div>
  <div class="row"><span class="k" id="kvk">Largest request</span><span class="v" id="kv">—</span></div>
 </div>
 <div class="card"><h2>Memory</h2>
  <div class="row"><span class="k">Used</span><span class="v" id="mem" style="color:var(--mem)">—</span></div>
  <div class="bar"><i id="membar" style="background:var(--mem)"></i></div>
  <div class="row"><span class="k">Wired (model)</span><span class="v" id="wired">—</span></div>
  <div class="row"><span class="k">Compressed</span><span class="v" id="comp">—</span></div>
  <div class="row"><span class="k">Swap</span><span class="v" id="swap" style="color:var(--swap)">—</span></div>
  <div class="row"><span class="k">Pressure</span><span class="v" id="press">—</span></div>
 </div>
 <div class="card"><h2>Processor</h2>
  <div class="row"><span class="k">GPU active</span><span class="v" id="gpu">—</span></div>
  <div class="bar"><i id="gpubar" style="background:var(--gpu)"></i></div>
  <div class="row"><span class="k">CPU / load</span><span class="v" id="cpu">—</span></div>
  <div class="row"><span class="k">Power</span><span class="v" id="pwr" style="color:var(--pwr)">—</span></div>
  <div class="row"><span class="k">CPU / GPU / ANE</span><span class="v" id="pwrs">—</span></div>
  <div class="row"><span class="k">Thermal</span><span class="v" id="therm">—</span></div>
 </div>
 <div class="card"><h2>Services</h2>
  <div class="row"><span class="k">Open WebUI</span><span class="v" id="owui">—</span></div>
  <div class="row"><span class="k">Model server</span><span class="v" id="llmup">—</span></div>
  <div class="row"><span class="k">Power sampler</span><span class="v" id="pm">—</span></div>
  <div class="row"><span class="k">Engine</span><span class="v" id="eng">—</span></div>
  <div class="row"><span class="k">Monitor up</span><span class="v" id="monup">—</span></div>
 </div>
</div>
<div class="card"><h2>Last 36 hours (1-minute averages)</h2>
 <div class="legend"><span><b style="background:var(--mem)"></b>memory used %</span>
 <span><b style="background:var(--gpu)"></b>GPU %</span>
 <span><b style="background:var(--tps)"></b>tok/s (top = 80)</span>
 <span><b style="background:var(--pwr)"></b>power W (top = 80)</span>
 <span><b style="background:var(--swap)"></b>swap MB (top = 1024)</span></div>
 <canvas id="g"></canvas></div>
<footer>Read-only. Refreshes every 5 s. JSON at <a style="color:var(--muted)" href="/api/stats">/api/stats</a>.</footer>
<script>
const TPS_MAX=80, PWR_MAX=80, SWAP_MAX=1024, WIN=36*3600;
const $=id=>document.getElementById(id);
const f=(v,d=1,u='')=>v==null?'—':Number(v).toFixed(d)+u;
const col=s=>({Active:'var(--tps)',Idle:'var(--muted)',Down:'var(--crit)'}[s]||'var(--warn)');
const dot=(ok,t)=>'<span class="dot" style="background:'+(ok?'var(--ok)':'var(--crit)')+'"></span>'+t;
function bar(id,p){$(id).style.width=Math.max(0,Math.min(100,p||0))+'%'}
function draw(h){
 const c=$('g'),r=window.devicePixelRatio||1,W=c.clientWidth,H=200;
 c.width=W*r;c.height=H*r;const x=c.getContext('2d');x.scale(r,r);x.clearRect(0,0,W,H);
 const L=34,R=8,T=8,B=20,now=Date.now()/1000;
 const X=t=>L+(W-L-R)*(1-(now-t)/WIN), Y=p=>T+(H-T-B)*(1-Math.max(0,Math.min(1,p)));
 x.strokeStyle='#262c38';x.fillStyle='#9aa4b2';x.font='11px ui-monospace,Menlo,monospace';
 [0,.25,.5,.75,1].forEach(p=>{x.beginPath();x.moveTo(L,Y(p));x.lineTo(W-R,Y(p));x.stroke();x.fillText(Math.round(p*100)+'%',2,Y(p)+4)});
 for(let hr=0;hr<=36;hr+=6){const px=X(now-hr*3600);x.fillText(hr?'-'+hr+'h':'now',px-12,H-4)}
 const line=(key,scale,color,w)=>{x.strokeStyle=color;x.lineWidth=w;x.beginPath();let pen=false;
  h.t.forEach((t,i)=>{const v=h[key][i];if(v==null){pen=false;return}const px=X(t),py=Y(v/scale);
   pen?x.lineTo(px,py):x.moveTo(px,py);pen=true});x.stroke()};
 const css=n=>getComputedStyle(document.documentElement).getPropertyValue(n);
 line('gpu',100,css('--gpu'),1.2);line('pwr',PWR_MAX,css('--pwr'),1.2);line('swap',SWAP_MAX,css('--swap'),1.2);
 line('mem',100,css('--mem'),2);line('tps',TPS_MAX,css('--tps'),2);
}
async function tick(){
 try{
  const d=await (await fetch('/api/stats',{cache:'no-store'})).json(),s=d.state,h=d.facts;
  $('title').textContent=h.host+' — Gemma 4 server';
  $('sub').textContent=h.chip+' · '+h.cpu_cores+' CPU'+(h.gpu_cores?' / '+h.gpu_cores+' GPU cores':'')+' · '+h.mem_total_gb+' GB · updated '+new Date(s.updated*1000).toLocaleTimeString();
  $('llm').innerHTML='<span class="dot" style="background:'+col(s.llm_status)+'"></span>'+(s.llm_status||'—');
  $('tps').textContent=s.tps_now?f(s.tps_now,1,' tok/s'):'idle';bar('tpsbar',(s.tps_now||0)/TPS_MAX*100);
  $('tpslast').textContent=s.tps_last?f(s.tps_last,1,' tok/s')+(s.tps_last_age_s!=null?' · '+(s.tps_last_age_s<60?'just now':Math.round(s.tps_last_age_s/60)+' min ago'):''):'—';
  $('prefill').textContent=f(s.prefill_last,0,' tok/s');
  $('req').textContent=(s.requests_processing??'—')+' / '+(s.requests_deferred??'—');
  if(s.kv_pct!=null){$('kvk').textContent='Context in use';$('kv').textContent=f(s.kv_pct,0,'%')}
  else $('kv').textContent=s.tokens_max!=null?s.tokens_max.toLocaleString()+' tok'+(h.ctx?' of '+Number(h.ctx).toLocaleString():''):'—';
  const memPct=s.mem_used_gb/h.mem_total_gb*100;
  $('mem').textContent=f(s.mem_used_gb,1)+' / '+h.mem_total_gb+' GB';bar('membar',memPct);
  $('wired').textContent=f(s.wired_gb,1,' GB');$('comp').textContent=f(s.compressed_gb,1,' GB');
  $('swap').textContent=s.swap_total_mb?f(s.swap_used_mb,0)+' / '+f(s.swap_total_mb,0)+' MB':'none';
  const pc={Normal:'var(--ok)',Warning:'var(--warn)',Critical:'var(--crit)'}[s.pressure]||'var(--fg)';
  $('press').innerHTML='<span style="color:'+pc+'">'+(s.pressure||'—')+'</span>'+(s.mem_free_pct!=null?' · '+s.mem_free_pct+'% free':'');
  $('gpu').textContent=f(s.gpu_pct,0,'%');bar('gpubar',s.gpu_pct);
  $('cpu').textContent=f(s.cpu_pct,0,'%')+' / '+(s.load?s.load[0]:'—');
  $('pwr').textContent=f(s.power_w,1,' W');
  $('pwrs').textContent=[s.cpu_mw,s.gpu_mw,s.ane_mw].map(v=>v==null?'—':(v/1000).toFixed(1)).join(' / ')+' W';
  const tc={Nominal:'var(--ok)',Fair:'var(--warn)',Serious:'var(--swap)',Critical:'var(--crit)'}[s.thermal]||'var(--fg)';
  $('therm').innerHTML='<span style="color:'+tc+'">'+(s.thermal||'—')+'</span>';
  $('owui').innerHTML=dot(s.owui_up,s.owui_up?'up :'+h.owui_port:'down');
  $('llmup').innerHTML=dot(s.llm_up,s.llm_up?'up :'+h.llm_port:'down');
  $('pm').innerHTML=dot(s.pm_status==='ok',s.pm_status||'—');
  $('eng').textContent=h.engine;
  const up=d.monitor_uptime_s;$('monup').textContent=Math.floor(up/3600)+'h '+Math.floor(up%3600/60)+'m';
  last=d.history;draw(d.history);
 }catch(e){$('sub').textContent='monitor unreachable: '+e}
 setTimeout(tick,5000);
}
let last=null;window.addEventListener('resize',()=>{if(last)draw(last)});tick();
</script></body></html>"""

_FACTS = {}
_START = time.time()

class Handler(BaseHTTPRequestHandler):
    server_version = "gemma-monitor"

    def _send(self, code, body, ctype):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            self._send(200, PAGE, "text/html; charset=utf-8")
        elif path == "/api/stats":
            with _lock:
                body = json.dumps({"facts": _FACTS, "state": _state, "history": _hist,
                                   "monitor_uptime_s": int(time.time() - _START)})
            self._send(200, body, "application/json")
        elif path == "/health":
            self._send(200, json.dumps({"ok": True}), "application/json")
        else:
            self._send(404, "not found\n", "text/plain")

    do_HEAD = do_GET

    def log_message(self, *args):
        pass

def _load_facts():
    facts = host_facts()                      # system_profiler can take many seconds at boot
    with _lock:
        _FACTS.update(facts)
        _state["mem_total_gb"] = facts["mem_total_gb"]

def main():
    # Open the port first: host details are gathered in the background, so the page is up at once.
    _FACTS.update({"host": socket.gethostname().split(".")[0], "chip": "", "cpu_cores": "",
                   "gpu_cores": "", "mem_total_gb": round(int(_sysctl("hw.memsize") or 0) / 2**30, 1),
                   "engine": ENGINE, "llm_port": LLM_PORT, "owui_port": OWUI_PORT,
                   "ctx": _setting("CTX", "")})
    _state["mem_total_gb"] = _FACTS["mem_total_gb"]
    load_history()

    def stop(*_):
        save_history()
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    srv = ThreadingHTTPServer(("0.0.0.0", MON_PORT), Handler)
    threading.Thread(target=_load_facts, daemon=True).start()
    threading.Thread(target=poll_loop, daemon=True).start()
    srv.daemon_threads = True
    print(f"gemma-monitor on :{MON_PORT} (model server :{LLM_PORT}, Open WebUI :{OWUI_PORT})", flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()
