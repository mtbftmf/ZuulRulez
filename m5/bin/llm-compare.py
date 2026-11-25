#!/usr/bin/env python3
"""
llm-compare.py — answer-quality comparison of two setups of the same model (engine, quant, settings),
judged blind. Python 3 stdlib only.

  run     send every prompt to one server and save the answers as ~/llm-compare/<label>.json
  report  build a blind side-by-side page from two saved runs: per prompt you pick the better
          answer (or "same") without knowing which setup wrote it, then press Reveal
  grade   run the self-grading tasks (m5/tests/graded-tasks.json) and score them pass/fail with no
          judging: code runs against hidden tests, tool calls and JSON are compared to the expected
          value, answers and formats are checked by rule. Saves ~/llm-compare/<label>.graded.json
  grade-diff  compare two graded runs task by task and per category

  ~/bin/llm-compare.py run --label mlx  --url http://127.0.0.1:11234/v1
  ~/bin/llm-compare.py run --label other --url http://127.0.0.1:11236/v1 --model flash-next-test
  ~/bin/llm-compare.py report mlx gguf          # writes ~/llm-compare/mlx-vs-gguf.html; open it
  ~/bin/llm-compare.py run --label nomtp --url http://127.0.0.1:11234/v1 --only 2,3,7 --extra '{"enable_mtp": false}'
  ~/bin/llm-compare.py grade --label mlx-26.11.2 --url http://127.0.0.1:11234/v1 --runs 3
  ~/bin/llm-compare.py grade --label gemma --url http://127.0.0.1:11235/v1 --model gemma-4-26b-a4b-it-qat
  ~/bin/llm-compare.py grade-diff mlx-26.11.2 splash-1.7.1

Graded code runs the model's Python in a child process: on macOS inside sandbox-exec (no network,
writes only to its own temp folder), with CPU, file-size and wall-clock limits, isolated Python (-I),
and an empty environment. Skip code tasks with --no-code.

Prompts: m5/tests/quality-prompts.md (each "### " heading starts a prompt; "> Check:" lines are
judging notes, not sent). Settings match Auto's Flash route: thinking on, medium effort,
temperature 1.0, top_p 0.95, top_k 20, max_tokens 8192. The kwargs are ignored by LM Studio, whose
rewritten GGUF template defaults to medium, so both setups think at medium. Reasoning is not shown
in the report, only the answers; speed and token counts stay hidden until Reveal.
Results stay in ~/llm-compare (never commit them: answers may contain personal context).
"""
import argparse, html, json, os, random, re, shutil, statistics, subprocess, sys, tempfile, time, urllib.error, urllib.request

HERE = os.path.dirname(os.path.realpath(__file__))
DEFAULT_PROMPTS = os.path.join(HERE, "..", "tests", "quality-prompts.md")
DEFAULT_TASKS = os.path.join(HERE, "..", "tests", "graded-tasks.json")
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
    try:
        extra = json.loads(a.extra) if a.extra else {}
    except json.JSONDecodeError as e:
        sys.exit(f"--extra is not valid JSON: {e}")
    if not isinstance(extra, dict):
        sys.exit("--extra must be a JSON object, e.g. '{\"enable_mtp\": false}'")
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
                "messages": [{"role": "user", "content": p["prompt"]}], **extra}
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
                       "max_tokens": a.max_tokens, "extra": extra, "date": time.strftime("%Y-%m-%d %H:%M"),
                       "results": results}, f, indent=1)
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


# ---------------------------------------------------------------- grade: self-scoring tasks

def chat(url, body, timeout):
    """POST one chat completion; return (message, finish_reason, completion_tokens, seconds) or raise."""
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        m = json.load(r)
    ch = (m.get("choices") or [{}])[0]
    return ch.get("message") or {}, ch.get("finish_reason"), (m.get("usage") or {}).get("completion_tokens"), time.time() - t0


def visible(msg):
    """Answer text with any inline <think> block removed."""
    return THINK_RE.sub("", msg.get("content") or "").strip()


def match(expect, got, tol=1e-6):
    """True if got matches expect. Dicts match key by key, lists in order; {"ci": s} is a case-insensitive,
    whitespace-trimmed string; numbers compare with tolerance; booleans must be booleans."""
    if isinstance(expect, dict) and set(expect) == {"ci"}:
        return isinstance(got, str) and got.strip().lower() == expect["ci"].lower()
    if isinstance(expect, bool) or isinstance(got, bool):
        return expect is got
    if isinstance(expect, (int, float)):
        if isinstance(got, str):
            try:
                got = float(got.replace(",", ""))
            except ValueError:
                return False
        return isinstance(got, (int, float)) and abs(got - expect) <= tol
    if isinstance(expect, str):
        return isinstance(got, str) and got.strip() == expect
    if isinstance(expect, list):
        return isinstance(got, list) and len(got) == len(expect) and all(match(e, g, tol) for e, g in zip(expect, got))
    if isinstance(expect, dict):
        return isinstance(got, dict) and all(k in got and match(v, got[k], tol) for k, v in expect.items())
    return expect == got


def exact_keys(expect, got):
    """Every dict in got has exactly the keys of the matching dict in expect."""
    if isinstance(expect, dict) and set(expect) != {"ci"}:
        return isinstance(got, dict) and set(got) == set(expect) and all(exact_keys(v, got[k]) for k, v in expect.items())
    if isinstance(expect, list):
        return isinstance(got, list) and all(exact_keys(e, g) for e, g in zip(expect, got))
    return True


def strip_fence(text):
    m = re.search(r"```(?:json)?\s*\n(.*?)```", text, re.S)
    return (m.group(1) if m else text).strip()


SANDBOX_PROFILE = """(version 1)
(allow default)
(deny network*)
(deny file-write*)
(allow file-write* (subpath "{tmp}") (literal "/dev/null") (literal "/dev/stdout") (literal "/dev/stderr"))
"""


def run_python(code, tests, timeout=20):
    """Run code + tests in an isolated child Python. Returns (passed, detail)."""
    tmp = os.path.realpath(tempfile.mkdtemp(prefix="llmgrade-"))
    try:
        path = os.path.join(tmp, "t.py")
        with open(path, "w") as f:
            f.write(code + "\n\n# --- hidden tests ---\n" + tests + "\nprint('ALL TESTS PASSED')\n")
        cmd = [sys.executable, "-I", path]
        if shutil.which("sandbox-exec"):
            prof = os.path.join(tmp, "p.sb")
            with open(prof, "w") as f:
                f.write(SANDBOX_PROFILE.format(tmp=tmp))
            cmd = ["sandbox-exec", "-f", prof] + cmd

        def limits():
            import resource
            for lim, val in ((resource.RLIMIT_CPU, 15), (resource.RLIMIT_FSIZE, 10 << 20)):
                try:
                    resource.setrlimit(lim, (val, val))
                except (ValueError, OSError):
                    pass
        try:
            p = subprocess.run(cmd, cwd=tmp, env={"PATH": "/usr/bin:/bin", "HOME": tmp, "TMPDIR": tmp},
                               capture_output=True, text=True, timeout=timeout, preexec_fn=limits)
        except subprocess.TimeoutExpired:
            return False, f"timed out after {timeout}s"
        if p.returncode == 0 and "ALL TESTS PASSED" in p.stdout:
            return True, "tests passed"
        if p.returncode < 0:
            return False, "killed (CPU limit or signal %d)" % -p.returncode
        err = (p.stderr.strip().splitlines() or ["exit %d" % p.returncode])[-1]
        return False, err[:160]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def tool_calls(msg):
    """[(name, args_dict)] from OpenAI tool_calls, or from Qwen-style <tool_call>{json}</tool_call> in content."""
    out = []
    for tc in msg.get("tool_calls") or []:
        fn = tc.get("function") or {}
        args = fn.get("arguments") or {}
        if isinstance(args, str):
            try:
                args = json.loads(args) if args.strip() else {}
            except json.JSONDecodeError:
                args = {"__unparsed__": args}
        out.append((fn.get("name"), args))
    if not out:
        for blob in re.findall(r"<tool_call>\s*(\{.*?\})\s*</tool_call>", msg.get("content") or "", re.S):
            try:
                j = json.loads(blob)
                out.append((j.get("name"), j.get("arguments") or j.get("parameters") or {}))
            except json.JSONDecodeError:
                pass
    return out


def words(s):
    return re.findall(r"[\w'’-]+", s)


def grade_one(task, msg, no_code):
    """(verdict, detail): verdict is 'pass', 'fail' or 'skip'."""
    g, text = task["grade"], visible(msg)
    t = g["type"]
    if t == "python":
        if no_code:
            return "skip", "--no-code"
        blocks = re.findall(r"```(?:python|py)?\s*\n(.*?)```", text, re.S)
        if not blocks:
            return "fail", "no code block"
        ok, why = run_python(max(blocks, key=len), g["tests"])
        return ("pass" if ok else "fail"), why
    if t == "tool":
        calls = tool_calls(msg)
        if not calls:
            return "fail", "no tool call"
        name, args = calls[0]
        if name != g["name"]:
            return "fail", f"called {name}"
        bad = [k for k, v in g["args"].items() if k not in args or not match(v, args[k])]
        return ("fail", "wrong " + ", ".join(f"{k}={args.get(k)!r}" for k in bad)) if bad else ("pass", f"{name} ok")
    if t == "no_tool":
        if tool_calls(msg):
            return "fail", f"called {tool_calls(msg)[0][0]}"
        missing = [c for c in g.get("contains", []) if c not in text]
        return ("fail", "missing " + ", ".join(missing)) if missing else ("pass", "answered directly")
    if t == "json":
        raw = strip_fence(text)
        try:
            got = json.loads(raw)
        except json.JSONDecodeError as e:
            return "fail", f"not JSON ({e.msg})"
        if not match(g["expect"], got, g.get("tol", 1e-6)):
            return "fail", "values differ: " + raw[:120].replace("\n", " ")
        if g.get("exact_keys") and not exact_keys(g["expect"], got):
            return "fail", "extra or missing keys"
        return "pass", "matches"
    if t == "answer":
        lines = [m.strip() for m in re.findall(r"(?im)^\s*\**\s*ANSWER\s*\**\s*:\s*\**(.+?)\**\s*$", text)]
        if not lines:
            return "fail", "no 'ANSWER:' line"
        got = lines[-1].rstrip(".")
        ok = match(g["expect"], got, g.get("tol", 1e-6))
        return ("pass" if ok else "fail", f"ANSWER: {got[:60]}")
    if t == "format":
        body = text.strip()
        lines = [l for l in body.splitlines() if l.strip()]
        if "exact" in g and body.strip().rstrip(".").lower() != g["exact"]:
            return "fail", f"got {body[:40]!r}"
        if "lines" in g and len(lines) != g["lines"]:
            return "fail", f"{len(lines)} lines"
        if "bullets" in g:
            bl = [l for l in lines if re.match(r"\s*[-*•]\s+", l)]
            if len(bl) != g["bullets"]:
                return "fail", f"{len(bl)} bullets"
            if g.get("only_bullets") and len(bl) != len(lines):
                return "fail", "text besides the bullets"
            long = [len(words(re.sub(r"^\s*[-*•]\s+", "", l))) for l in bl if len(words(re.sub(r"^\s*[-*•]\s+", "", l))) > g.get("max_words_per_bullet", 10 ** 6)]
            if long:
                return "fail", f"bullet of {long[0]} words"
        if "max_words" in g and len(words(body)) > g["max_words"]:
            return "fail", f"{len(words(body))} words"
        if "not_regex" in g and re.search(g["not_regex"], body):
            return "fail", "banned text present"
        if "regex" in g and not re.search(g["regex"], body):
            return "fail", "expected text missing"
        for rx in g.get("all_regex", []):
            if not re.search(rx, body):
                return "fail", f"missing /{rx}/"
        return "pass", "format ok"
    return "fail", f"unknown grade type {t}"


def load_tasks(path):
    try:
        d = json.load(open(os.path.expanduser(path), encoding="utf-8"))
    except FileNotFoundError:
        sys.exit(f"tasks file not found: {path}")
    except json.JSONDecodeError as e:
        sys.exit(f"tasks file is not valid JSON: {e}")
    return d.get("tools", []), d["tasks"]


def cmd_grade(a):
    tools, tasks = load_tasks(a.tasks)
    try:
        extra = json.loads(a.extra) if a.extra else {}
    except json.JSONDecodeError as e:
        sys.exit(f"--extra is not valid JSON: {e}")
    if a.only:
        keep = {x.strip() for x in a.only.split(",")}
        tasks = [t for t in tasks if t["id"] in keep or t["cat"] in keep]
        if not tasks:
            sys.exit(f"--only {a.only}: no task id or category matched")
    os.makedirs(OUT_DIR, exist_ok=True)
    out_path = os.path.join(OUT_DIR, f"{a.label}.graded.json")
    url = a.url.rstrip("/") + "/chat/completions"
    sandbox = "sandbox-exec" if shutil.which("sandbox-exec") else "NOT sandboxed (no sandbox-exec)"
    print(f"{len(tasks)} tasks x {a.runs} run(s) → {url} (model {a.model}); code: "
          f"{'skipped' if a.no_code else sandbox}; saving to {out_path}")
    results = []
    for t in tasks:
        rec = {"id": t["id"], "cat": t["cat"], "title": t["title"], "runs": []}
        for n in range(a.runs):
            body = {"model": a.model, "max_tokens": a.max_tokens, "temperature": 1.0, "top_p": 0.95, "top_k": 20,
                    "chat_template_kwargs": {"enable_thinking": True, "reasoning_effort": a.effort},
                    "messages": [{"role": "user", "content": t["prompt"]}], **extra}
            if t["cat"] == "tools":
                body["tools"] = tools
            try:
                msg, finish, tok, dt = chat(url, body, a.timeout)
                verdict, why = grade_one(t, msg, a.no_code)
            except urllib.error.HTTPError as e:
                msg, finish, tok, dt = {}, "error", None, 0.0
                verdict, why = "fail", f"HTTP {e.code} {e.read().decode('utf-8', 'ignore')[:120]}"
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                sys.exit(f"{t['id']}: cannot reach {url}: {getattr(e, 'reason', e)}")
            if finish == "length" and verdict == "fail":
                why += f" (hit the {a.max_tokens}-token cap)"
            rec["runs"].append({"verdict": verdict, "why": why, "seconds": round(dt, 1), "tokens": tok,
                                "finish": finish, "answer": visible(msg)[:4000],
                                "tool_calls": [[nm, ag] for nm, ag in tool_calls(msg)]})
            mark = {"pass": "PASS", "fail": "FAIL", "skip": "skip"}[verdict]
            print(f"  {t['id']:10} {t['title'][:26]:26} {mark}  {dt:6.1f} s  {tok or 0:6} tok  {why}")
        results.append(rec)
        with open(out_path, "w") as f:
            json.dump({"label": a.label, "url": a.url, "model": a.model, "effort": a.effort, "runs": a.runs,
                       "max_tokens": a.max_tokens, "extra": extra, "code": "skipped" if a.no_code else sandbox,
                       "date": time.strftime("%Y-%m-%d %H:%M"), "results": results}, f, indent=1)
    print_summary(a.label, results)
    print(f"Saved {out_path}")


def tally(results):
    cats, secs = {}, []
    for r in results:
        c = cats.setdefault(r["cat"], [0, 0])
        for run in r["runs"]:
            if run["verdict"] == "skip":
                continue
            c[0] += run["verdict"] == "pass"
            c[1] += 1
            secs.append(run["seconds"])
    return cats, secs


def print_summary(label, results):
    cats, secs = tally(results)
    p, n = sum(v[0] for v in cats.values()), sum(v[1] for v in cats.values())
    parts = "  ".join(f"{c} {v[0]}/{v[1]}" for c, v in cats.items() if v[1])
    med = statistics.median(secs) if secs else 0
    print(f"{label}: {p}/{n} passed ({100 * p / n if n else 0:.0f}%)  |  {parts}  |  "
          f"total {sum(secs) / 60:.1f} min, median {med:.1f} s per task")


def load_graded(lab):
    path = lab if lab.endswith(".json") else os.path.join(OUT_DIR, f"{lab}.graded.json")
    try:
        return json.load(open(path))
    except FileNotFoundError:
        sys.exit(f"no graded run: {path} (run grade first)")


def cmd_grade_diff(a):
    ra, rb = load_graded(a.a), load_graded(a.b)
    by = {r["id"]: r for r in rb["results"]}
    print(f"{'task':10} {'':26} {ra['label'][:14]:>14} {rb['label'][:14]:>14}")
    for r in ra["results"]:
        o = by.get(r["id"])
        if not o:
            continue
        def frac(x):
            runs = [u for u in x["runs"] if u["verdict"] != "skip"]
            return sum(u["verdict"] == "pass" for u in runs), len(runs)
        pa, pb = frac(r), frac(o)
        if not pa[1] or not pb[1]:
            print(f"{r['id']:10} {r['title'][:26]:26} {'skipped on one side':>29}")
            continue
        flag = "" if pa[0] * max(pb[1], 1) == pb[0] * max(pa[1], 1) else ("  <- " + (ra["label"] if pa[0] / max(pa[1], 1) > pb[0] / max(pb[1], 1) else rb["label"]) + " better")
        print(f"{r['id']:10} {r['title'][:26]:26} {pa[0]:>10}/{pa[1]:<3} {pb[0]:>10}/{pb[1]:<3}{flag}")
    ids = set(by) & {r["id"] for r in ra["results"]}
    print_summary(ra["label"], [r for r in ra["results"] if r["id"] in ids])
    print_summary(rb["label"], [r for r in rb["results"] if r["id"] in ids])
    if ra.get("runs", 1) == 1 or rb.get("runs", 1) == 1:
        print("Note: temperature 1.0 makes single runs noisy; a 1-task difference is not a finding. Use --runs 3.")


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
    r.add_argument("--extra", default="", help='JSON merged into each request, e.g. \'{"enable_mtp": false}\'')
    r.set_defaults(func=cmd_run)
    p = sub.add_parser("report", help="blind side-by-side page from two saved runs")
    p.add_argument("a"); p.add_argument("b")
    p.add_argument("--out", default="")
    p.set_defaults(func=cmd_report)
    g = sub.add_parser("grade", help="run the self-grading tasks against one server and score them")
    g.add_argument("--label", required=True)
    g.add_argument("--url", required=True)
    g.add_argument("--model", default="flash-next")
    g.add_argument("--tasks", default=DEFAULT_TASKS)
    g.add_argument("--effort", default="medium")
    g.add_argument("--max-tokens", type=int, default=8192)
    g.add_argument("--timeout", type=int, default=900, help="seconds per request")
    g.add_argument("--runs", type=int, default=1, help="repeat each task N times (temperature 1.0 is noisy)")
    g.add_argument("--only", default="", help="task ids or categories, e.g. code or tools-2,json")
    g.add_argument("--no-code", action="store_true", help="skip the code tasks (no model code is run)")
    g.add_argument("--extra", default="", help="JSON merged into each request")
    g.set_defaults(func=cmd_grade)
    d = sub.add_parser("grade-diff", help="compare two graded runs")
    d.add_argument("a"); d.add_argument("b")
    d.set_defaults(func=cmd_grade_diff)
    a = ap.parse_args()
    a.func(a)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
