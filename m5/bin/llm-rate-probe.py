#!/usr/bin/env python3
"""llm-rate-probe.py - attribute instantaneous tok/s bursts to concurrency.

Compares the two rates the System Monitor derives from mlx-serve metrics:
  stream_tps  delta output_tokens.sum / delta decode_time_seconds.sum  (per stream)
  live_tps    delta generation_tokens_live / wall delta t              (box aggregate)

Prefill has its own gauge, so it cannot contaminate either of these.
"""
import argparse, csv, json, os, time, urllib.request


def fetch(url):
    with urllib.request.urlopen(url, timeout=3.0) as resp:
        return json.load(resp)


def numeric(value):
    if isinstance(value, dict):
        if "value" in value:
            return numeric(value["value"])
        total = 0
        for item in value.values():
            inner = numeric(item)
            if inner is not None:
                total += inner
        return total
    if isinstance(value, (int, float)):
        return value
    return None


def hsum(doc, key):
    return float(doc.get("histograms", {}).get(key, {}).get("sum", 0.0))


def gval(doc, key):
    value = numeric(doc.get("gauges", {}).get(key))
    return 0 if value is None else value


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:11234/metrics.json")
    ap.add_argument("--interval", type=float, default=0.5)
    ap.add_argument("--duration", type=float, default=180.0)
    ap.add_argument("--alert", type=float, default=130.0)
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    out_path = args.out or os.path.join(
        os.path.expanduser("~"), "Library", "Logs", "llm-rate-probe.csv")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    prev = None
    prev_t = None
    max_live = 0.0
    max_stream = 0.0
    peak_by_n = {}
    samples = 0
    bursts = 0

    with open(out_path, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["iso", "dt", "running", "waiting", "prefilling",
                         "batched", "live_tps", "stream_tps", "dgen",
                         "dout", "ddecode"])
        deadline = time.monotonic() + args.duration
        try:
            while time.monotonic() < deadline or args.duration <= 0:
                time.sleep(args.interval)
                doc = fetch(args.url)
                now = time.monotonic()
                running = int(gval(doc, "requests_running"))
                dt = round(now - prev_t, 3) if prev_t else 0.0
                live = None
                stream = None
                dgen, dout, ddec = 0, 0.0, 0.0

                if prev is not None and dt > 0:
                    dgen = gval(doc, "generation_tokens_live") - prev[0]
                    dout = hsum(doc, "output_tokens") - prev[1]
                    ddec = hsum(doc, "decode_time_seconds") - prev[2]
                    if dgen >= 0 and running > 0:
                        live = round(dgen / dt, 1)
                    if ddec > 0 and dout > 0:
                        stream = round(dout / ddec, 1)

                if live is not None:
                    samples += 1
                    if live > max_live:
                        max_live = live
                    if live >= args.alert:
                        bursts += 1
                        print("BURST live=%.1f stream=%s n=%d batched=%d waiting=%d"
                              % (live, stream, running,
                                 int(gval(doc, "batched_group_size")),
                                 int(gval(doc, "requests_waiting"))))
                    if live > peak_by_n.get(running, (0.0, None))[0]:
                        peak_by_n[running] = (live, stream)

                if stream is not None and stream > max_stream:
                    max_stream = stream

                writer.writerow([time.strftime("%Y-%m-%dT%H:%M:%S"), dt,
                                 running, int(gval(doc, "requests_waiting")),
                                 int(gval(doc, "requests_prefilling")),
                                 int(gval(doc, "batched_group_size")),
                                 live, stream, dgen, dout, round(ddec, 4)])
                fh.flush()
                prev = (gval(doc, "generation_tokens_live"),
                        hsum(doc, "output_tokens"),
                        hsum(doc, "decode_time_seconds"))
                prev_t = now
        except KeyboardInterrupt:
            pass

    print("samples=%d bursts=%d threshold=%.0f max_live=%.1f max_stream=%.1f"
          % (samples, bursts, args.alert, max_live, max_stream))
    for n in sorted(peak_by_n):
        live, stream = peak_by_n[n]
        print("  requests_running=%d  max_live=%.1f  stream_at_that_moment=%s"
              % (n, live, stream))
    print("csv: %s" % out_path)


if __name__ == "__main__":
    main()
