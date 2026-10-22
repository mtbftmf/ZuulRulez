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

- Fast model: Gemma 4 26B-A4B QAT.
- Strong model: Flash-Next, 88 GB GGUF on 128 GB unified memory.
- Default route is Gemma.
- Flash-Next is for explicit /flash or /strong requests, or clearly complex work.
- Explicit overrides:
  - /gemma or /fast forces Gemma.
  - /flash or /strong forces Flash-Next.
- Images go to Gemma unless a vision-capable Flash-Next profile is loaded.
- LENGTH_THRESHOLD should be 1800 or higher for this machine.
- LONG_CHAT_TURNS should be off by default, or at most 25 with complexity scoring.
- Small code fences must not force Flash-Next by themselves.
- STRONG_REASONING_EFFORT default: medium.
- Use low for simple Flash-Next tasks.
- Use xhigh only for formal proofs, complex financial models, or deep architecture reviews.
- Default max_tokens when omitted: 2048 for fast model, 16384 for strong model.
- Exact reimbursement, retirement, tax, DCF, IRR, WACC, drawdown, depreciation,
  and line-item arithmetic must be computed in code.

## M5 memory behavior

- Flash-Next is expensive to route on this machine.
- Wired RAM is expected to stay near or below roughly 74 GB under normal use.
- Keep Flash-Next context normally 8k-16k unless intentionally analyzing long documents or logs.
- Monitor with lms ps, memory_pressure, and sysctl vm.swapusage.
- Use caffeinate only during deliberate long generation sessions.
- Do not bake aggressive Metal wired-limit values into generic builds.
