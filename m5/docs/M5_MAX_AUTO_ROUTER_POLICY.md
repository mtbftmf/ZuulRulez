# M5 Max Auto Router Policy

This policy applies only to the M5 Max 128 GB Studio ZuulRulez host.

Do not treat this policy as a generic Gemma 4 local LLM template for other
M-series Studios using a houdini account for friends and family hosting.

## Repo scope

- GitHub project: ZuulRulez
- Repo: https://github.com/mtbftmf/ZuulRulez
- Default branch: MacLLM
- Monitor branch: M-ProcessorSystemMonitor
- Monitor worktree: ~/ZuulRulez-monitor
- MacLLM work: ~/ZuulRulez
- Commit author: Pdl_Pwr, using the per-repo GitHub noreply email configured in git
- GitHub CLI authentication is HTTPS/browser sign-in configured
- Never run git checkout in ~/ZuulRulez
- ~/bin scripts are links into ~/ZuulRulez/m5/bin
- flash-up.sh runs from ~/ZuulRulez/m5/bin at login
- ./install.sh performs a dry run
- ./install.sh --apply relinks m5/bin into ~/bin

## Change protocol

- Read README.md and CHANGELOG.md before changing anything.
- Each change gets one commit and one CHANGELOG line.
- CHANGELOG lines must include date, what changed, why, and measured result.
- If an AI chat is linked to GitHub, it may push.
- Otherwise it should produce files or a git bundle plus the commit commands.
- Never commit model files, Open WebUI data, exports, backups, tokens, API keys,
  passwords, AWS credentials, LAN IPs, personal email addresses, or hard-coded
  /Users/<name> paths.
- Machine-specific values belong in ~/.config/*.env.
- Commit only env.example or a non-secret template.

## M5 Max Auto Router defaults

- Fast model: Gemma 4 26B-A4B QAT, LM Studio `localhost:1234` (LMSTUDIO_URL).
- Strong model: Flash-Next, mlx-serve `127.0.0.1:11234` (STRONG_URL) since v1.4.0; the LM Studio
  GGUF is the rollback (STRONG_URL empty, EFFORT_MODE marker).
- Default route is Gemma.
- Flash-Next is for explicit /flash or /strong requests, or clearly complex work.
- Explicit overrides:
  - /gemma or /fast forces Gemma.
  - /flash or /strong forces Flash-Next.
  - /deep forces Flash-Next at xhigh (reasoning_effort xhigh; [effort:xhigh] marker in marker mode).
  - /route <text> reports the route and token cap without running it.
- Images go to Gemma by default. Flash-Next has vision (mlx-serve loads its vision tower), so /flash
  and /deep accept images (STRONG_HAS_VISION, on by default since v1.3.4).
- LENGTH_THRESHOLD should be 1800 or higher for this machine.
- LONG_CHAT_TURNS should be off by default, or at most 25 with complexity scoring.
- Small code fences must not force Flash-Next by themselves.
- Router version: v1.4.1. Do not deploy v1.2 (d01095e): it drops the deep route and caps.
- Effort (EFFORT_MODE kwargs, default): every Flash request carries
  chat_template_kwargs {enable_thinking: true, reasoning_effort: medium}, xhigh for /deep,
  DEEP_PHRASES or DEEP_SCORE. mlx-serve turns thinking OFF when a request omits it, and
  thinking-off Flash answers worse, so any other path to Flash (personas) must send it too.
- EFFORT_MODE marker (GGUF rollback): template default medium, [effort:xhigh] marker for deep routes.
- [effort:low] buys no measurable speed; xhigh is a nudge, not a guarantee (Oct 18-19 probes).
- Token caps when the request has none: STRONG_MAX_TOKENS 8192 (Flash medium),
  DEEP_MAX_TOKENS 24576 (Flash xhigh), FAST_MAX_TOKENS 0 (Gemma, no cap).
  A max_tokens already in the request wins. These caps are the real time limit.
- Context guard (v1.3.3): FAST_CTX must match Gemma's loaded context (32768). Requests
  estimated over FAST_CTX - FAST_CTX_RESERVE go to Flash (images included, v1.3.4); /gemma requests are trimmed
  (oldest messages first) instead.
- Exact reimbursement, retirement, tax, DCF, IRR, WACC, drawdown, depreciation,
  and line-item arithmetic must be computed in code.

## M5 memory behavior

- Flash-Next is expensive to route on this machine.
- Wired RAM: ~18 GB idle; with mlx-serve Flash generating, peak ~100 GB (Oct 24, MTP on,
  Gemma idle). The GGUF peaked near 76 GB.
- Flash-Next loads at 128K and Gemma at 32K; the 4 parallel slots of each share its context.
  A full 128K prompt takes ~2 min to read (867 tok/s at 100K). Repeated long prefixes are cheap (prefix cache: 12.9 s -> 0.05 s TTFT at 11.9K).
- Monitor with lms ps (Gemma), curl 127.0.0.1:11234/health (Flash), memory_pressure, and sysctl vm.swapusage.
- Use caffeinate only during deliberate long generation sessions.
- Do not bake aggressive Metal wired-limit values into generic builds.
