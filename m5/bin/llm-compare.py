#!/usr/bin/env python3
"""
llm-compare.py — answer-quality comparison of two setups of the same model (engine, quant, settings),
judged blind. Python 3 stdlib only.

  run     send every prompt to one server and save the answers as ~/llm-compare/<label>.json
  report  build a blind side-by-side page from two saved runs: per prompt you pick the better
          answer (or "same") without knowing which setup wrote it, then press Reveal

  ~/bin/llm-compare.py run --label mlx  --url http://127.0.0.1:11234/v1
  ~/bin/llm-compare.py run --label gguf --url http://localhost:1234/v1
  ~/bin/llm-compare.py report mlx gguf          # writes ~/llm-compare/mlx-vs-gguf.html; open it

Prompts: m5/tests/quality-prompts.md (each "### " heading starts a prompt; "> Check:" lines are
judging notes, not sent). Settings match Auto's Flash route: thinking on, medium effort,
temperature 1.0, top_p 0.95, top_k 20, max_tokens 8192. The kwargs are ignored by LM Studio, whose
rewritten GGUF template defaults to medium, so both setups think at medium. Reasoning is not shown
in the report, only the answers; speed and token counts stay hidden until Reveal.
Results stay in ~/llm-compare (never commit them: answers may contain personal context).
"""
import argparse, html, json, os, random, re, sys, time, urllib.error, urllib.request

HERE = os.path.dirname(os.path.realpath(__file__))
DEFAULT_PROMPTS = os.path.join(HERE, "..", "tests", "quality-prompts.md")
OUT_DIR = os.path.expanduser("~/llm-compare")
THINK_RE = re.compile(r"<think>.*?</think>\s*", re.S)


def load_prompts(path):
    try:
        text = open(os.path.expanduser(path), encoding="utf-8").read()
    except FileNotFoundError:
        sys.exit(f"prompts file not found: {path}")
    prompts, cur = [], None
    for line in text.splitlines():
        if line.startswith("### "):
            cur = {"title": line[4:].strip(), "lines": [], "check": []}
            prompts.append(cur)
        elif cur is not None:
            if line.startswith("> Check:"):
                cur["check"].append(line[len("> Check:"):].strip())
            else:
                cur["lines"].append(line)
    out = []
    for p in prompts:
        body = "\n".join(p["lines"]).strip()
        if body:
            out.append({"title": p["title"], "prompt": body, "check": " ".join(p["check"])})
    if not out:
        sys.exit(f"no prompts ('### ' headings) in {path}")
    return out


def cmd_run(a):
    prompts = load_prompts(a.prompts)
    if a.only:
        keep = {int(x) for x in a.only.split(",")}
        prompts = [p for i, p in enumerate(prompts, 1) if i in keep]
    os.makedirs(OUT_DIR, exist_ok=True)
    out_path = os.path.join(OUT_DIR, f"{a.label}.json")
    url = a.url.rstrip("/") + "/chat/completions"
    results = []
    print(f"{len(prompts)} prompts → {url} (model {a.model}), saving to {out_path}")
    for i, p in enumerate(prompts, 1):
        body = {"model": a.model, "max_tokens": a.max_tokens, "temperature": 1.0, "top_p": 0.95, "top_k": 20,
                "chat_template_kwargs": {"enable_thinking": True, "reasoning_effort": a.effort},
                "messages": [{"role": "user", "content": p["prompt"]}]}
        req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=a.timeout) as r:
                m = json.load(r)
        except urllib.error.HTTPError as e:
            sys.exit(f"prompt {i}: HTTP {e.code} {e.read().decode('utf-8', 'ignore')[:300]}")
        except (urllib.error.URLError, TimeoutError) as e:
            sys.exit(f"prompt {i}: cannot reach {url}: {getattr(e, 'reason', e)}")
        dt = time.time() - t0
        ch = (m.get("choices") or [{}])[0]
        msg = ch.get("message") or {}
        content = msg.get("content") or ""
        reasoning = msg.get("reasoning_content") or msg.get("reasoning") or ""
        inline = re.findall(r"<think>(.*?)</think>", content, re.S)
        if inline:
            reasoning += "".join(inline)
            content = THINK_RE.sub("", content)
        u = m.get("usage") or {}
        rec = {"title": p["title"], "prompt": p["prompt"], "check": p["check"], "answer": content.strip(),
               "reasoning_chars": len(reasoning), "completion_tokens": u.get("completion_tokens"),
               "seconds": round(dt, 1), "finish": ch.get("finish_reason")}
        results.append(rec)
        tok = rec["completion_tokens"] or 0
        print(f"  {p['title'][:44]:44} {dt:6.1f} s  {tok:6} tok  {tok / dt if dt else 0:5.1f} tok/s  "
              f"answer {len(rec['answer']):6,} chars  {rec['finish']}")
        with open(out_path, "w") as f:      # save after each prompt so an interrupted run keeps its answers
            json.dump({"label": a.label, "url": a.url, "model": a.model, "effort": a.effort,
                       "max_tokens": a.max_tokens, "date": time.strftime("%Y-%m-%d %H:%M"), "results": results}, f, indent=1)
    capped = sum(1 for r in results if r["finish"] == "length")
    print(f"Saved {out_path}" + (f"  ({capped} answer(s) hit the {a.max_tokens}-token cap)" if capped else ""))


PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Blind Answer Comparison</title>
<style>
:root{--bg:#fafaf9;--fg:#1c1917;--muted:#78716c;--card:#fff;--line:#e7e5e4;--acc:#2563eb;--pick:#dbeafe;--code:#f5f5f4}
@media (prefers-color-scheme:dark){:root{--bg:#171717;--fg:#e7e5e4;--muted:#a8a29e;--card:#1f1f1f;--line:#333;--acc:#60a5fa;--pick:#1e3a5f;--code:#262626}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 -apple-system,system-ui,sans-serif}
main{max-width:1400px;margin:0 auto;padding:16px}h1{font-size:22px;margin:8px 0}
.meta{color:var(--muted);font-size:13px}.q{border:1px solid var(--line);border-radius:10px;margin:22px 0;background:var(--card)}
.qh{padding:12px 16px;border-bottom:1px solid var(--line)}.qh h2{font-size:17px;margin:0 0 6px}
.prompt{white-space:pre-wrap;font-size:14px}.check{display:none;margin-top:8px;font-size:13px;color:var(--muted)}
.show-checks .check{display:block}.cols{display:grid;grid-template-columns:1fr 1fr}
@media (max-width:800px){.cols{grid-template-columns:1fr}}
.ans{padding:12px 16px;border-right:1px solid var(--line);min-width:0;overflow-x:auto}.ans:last-child{border-right:0}
.ans h3{font-size:14px;margin:0 0 8px;color:var(--muted)}.ans.picked{background:var(--pick)}
.who{display:none;font-weight:600;color:var(--acc)}.revealed .who{display:inline}
.stats{display:none;font-size:12px;color:var(--muted);margin-top:8px}.revealed .stats{display:block}
.pick{padding:10px 16px;border-top:1px solid var(--line);display:flex;gap:14px;flex-wrap:wrap}
button{font:inherit;padding:6px 12px;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--fg);cursor:pointer}
button.on{border-color:var(--acc);color:var(--acc);font-weight:600}
.bar{position:sticky;top:0;background:var(--bg);padding:10px 0;border-bottom:1px solid var(--line);display:flex;gap:10px;flex-wrap:wrap;align-items:center;z-index:2}
#tally{font-weight:600}table{border-collapse:collapse;margin:8px 0}td,th{border:1px solid var(--line);padding:4px 8px;vertical-align:top}
pre{background:var(--code);padding:8px;border-radius:6px;overflow-x:auto}code{background:var(--code);padding:0 3px;border-radius:3px}
.ans p{margin:6px 0}.ans ul,.ans ol{padding-left:22px;margin:6px 0}
</style></head><body><main>
<h1>Blind answer comparison</h1>
<p class="meta">__META__</p>
<div class="bar"><button id="checks">Show judging notes</button><button id="reveal">Reveal</button><span id="tally"></span></div>
<div id="qs"></div></main>
<script>
const DATA = __DATA__;
function esc(s){return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")}
function inline(s){return esc(s).replace(/`([^`]+)`/g,"<code>$1</code>").replace(/\\*\\*([^*]+)\\*\\*/g,"<b>$1</b>").replace(/(^|[^*])\\*([^*\\n]+)\\*/g,"$1<i>$2</i>")}
function md(src){
  const lines=src.split("\\n"); let out=[], i=0;
  while(i<lines.length){
    let l=lines[i];
    if(/^```/.test(l)){let b=[];i++;while(i<lines.length&&!/^```/.test(lines[i]))b.push(lines[i++]);i++;out.push("<pre>"+esc(b.join("\\n"))+"</pre>");continue}
    if(/^\\s*\\|.*\\|\\s*$/.test(l)&&i+1<lines.length&&/^\\s*\\|[\\s:|-]+\\|\\s*$/.test(lines[i+1])){
      const row=r=>r.trim().replace(/^\\||\\|$/g,"").split("|").map(c=>inline(c.trim()));
      let h=row(l);i+=2;let t="<table><tr>"+h.map(c=>"<th>"+c+"</th>").join("")+"</tr>";
      while(i<lines.length&&/^\\s*\\|.*\\|\\s*$/.test(lines[i]))t+="<tr>"+row(lines[i++]).map(c=>"<td>"+c+"</td>").join("")+"</tr>";
      out.push(t+"</table>");continue}
    let m=l.match(/^(#{1,6})\\s+(.*)/);if(m){out.push("<p><b>"+inline(m[2])+"</b></p>");i++;continue}
    if(/^\\s*([-*+]|\\d+[.)])\\s+/.test(l)){let ol=/^\\s*\\d/.test(l),items=[];
      while(i<lines.length&&/^\\s*([-*+]|\\d+[.)])\\s+/.test(lines[i]))items.push("<li>"+inline(lines[i++].replace(/^\\s*([-*+]|\\d+[.)])\\s+/,""))+"</li>");
      out.push((ol?"<ol>":"<ul>")+items.join("")+(ol?"</ol>":"</ul>"));continue}
    if(l.trim()===""){i++;continue}
    let p=[];while(i<lines.length&&lines[i].trim()!==""&&!/^(```|#{1,6}\\s|\\s*([-*+]|\\d+[.)])\\s)/.test(lines[i])&&!/^\\s*\\|.*\\|\\s*$/.test(lines[i]))p.push(lines[i++]);
    if(p.length)out.push("<p>"+inline(p.join(" "))+"</p>");else{out.push("<p>"+inline(l)+"</p>");i++}
  }
  return out.join("\\n")}
const picks={};
function stat(r){const tok=r.completion_tokens||0;return `${r.seconds} s · ${tok} tokens · ${r.seconds?(tok/r.seconds).toFixed(1):"?"} tok/s · reasoning ${r.reasoning_chars.toLocaleString()} chars · ${r.finish}`}
function render(){
  const qs=document.getElementById("qs");
  DATA.items.forEach((it,n)=>{
    const d=document.createElement("div");d.className="q";
    const sides=it.order.map((k,j)=>`<div class="ans" data-side="${k}"><h3>Answer ${j+1} <span class="who">— ${esc(DATA.labels[k])}</span></h3>${md(it[k].answer||"(empty)")}<div class="stats">${esc(stat(it[k]))}</div></div>`).join("");
    d.innerHTML=`<div class="qh"><h2>${esc(it.title)}</h2><div class="prompt">${esc(it.prompt)}</div>${it.check?`<div class="check">Judging note: ${esc(it.check)}</div>`:""}</div>
      <div class="cols">${sides}</div>
      <div class="pick"><button data-v="${it.order[0]}">Answer 1 better</button><button data-v="same">About the same</button><button data-v="${it.order[1]}">Answer 2 better</button></div>`;
    d.querySelectorAll(".pick button").forEach(b=>b.onclick=()=>{picks[n]=b.dataset.v;
      d.querySelectorAll(".pick button").forEach(x=>x.classList.toggle("on",x===b));
      d.querySelectorAll(".ans").forEach(x=>x.classList.toggle("picked",x.dataset.side===b.dataset.v));tally()});
    qs.appendChild(d)})}
function tally(){const n=Object.keys(picks).length;let s=`${n} of ${DATA.items.length} judged`;
  if(document.body.classList.contains("revealed")){const c={a:0,b:0,same:0};Object.values(picks).forEach(v=>c[v]++);
    s+=` — ${DATA.labels.a}: ${c.a} · ${DATA.labels.b}: ${c.b} · same: ${c.same}`}
  document.getElementById("tally").textContent=s}
document.getElementById("checks").onclick=()=>document.body.classList.toggle("show-checks");
document.getElementById("reveal").onclick=()=>{document.body.classList.add("revealed");tally()};
render();tally();
</script></body></html>"""


def cmd_report(a):
    runs = []
    for lab in (a.a, a.b):
        path = lab if lab.endswith(".json") else os.path.join(OUT_DIR, f"{lab}.json")
        try:
            runs.append(json.load(open(path)))
        except FileNotFoundError:
            sys.exit(f"no saved run: {path} (run it first)")
    ra, rb = runs
    by_title = {r["title"]: r for r in rb["results"]}
    items = []
    for r in ra["results"]:
        other = by_title.get(r["title"])
        if not other:
            print(f"skipped (only in {ra['label']}): {r['title']}")
            continue
        order = ["a", "b"]
        random.shuffle(order)
        items.append({"title": r["title"], "prompt": r["prompt"], "check": r.get("check", ""),
                      "a": r, "b": other, "order": order})
    if not items:
        sys.exit("the two runs have no prompts in common")
    data = {"labels": {"a": ra["label"], "b": rb["label"]}, "items": items}
    meta = (f"{len(items)} prompts · setups: {ra['label']} ({ra['date']}) and {rb['label']} ({rb['date']}), "
            f"shown in random order per prompt · effort {ra.get('effort')} / {rb.get('effort')}, "
            f"cap {ra.get('max_tokens')} tokens")
    page = PAGE.replace("__META__", html.escape(meta)).replace("__DATA__", json.dumps(data).replace("</", "<\\/"))
    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.expanduser(a.out) if a.out else os.path.join(OUT_DIR, f"{ra['label']}-vs-{rb['label']}.html")
    with open(out, "w", encoding="utf-8") as f:
        f.write(page)
    print(f"Wrote {out}\nOpen it: open '{out}'")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="send the prompts to one server and save the answers")
    r.add_argument("--label", required=True, help="name for this setup, e.g. mlx or gguf")
    r.add_argument("--url", required=True, help="OpenAI-compatible base URL, e.g. http://127.0.0.1:11234/v1")
    r.add_argument("--model", default="flash-next")
    r.add_argument("--prompts", default=DEFAULT_PROMPTS)
    r.add_argument("--effort", default="medium", help="reasoning_effort sent in chat_template_kwargs")
    r.add_argument("--max-tokens", type=int, default=8192)
    r.add_argument("--timeout", type=int, default=900, help="seconds per prompt")
    r.add_argument("--only", default="", help="comma-separated prompt numbers, e.g. 1,3")
    r.set_defaults(func=cmd_run)
    p = sub.add_parser("report", help="blind side-by-side page from two saved runs")
    p.add_argument("a"); p.add_argument("b")
    p.add_argument("--out", default="")
    p.set_defaults(func=cmd_report)
    a = ap.parse_args()
    a.func(a)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
