"""
title: Auto Router (Gemma ⇄ Flash-Next)
author: Pdl_Pwr
version: 1.4.1
description: One "Auto" model. Quick requests go to Gemma 4 26B-A4B (LM Studio), clearly complex
             ones to Qwen3.8-Flash-Next (medium effort; mlx-serve since v1.4.0).
             Prefixes: /flash or /strong, /gemma or /fast, /deep (Flash at xhigh effort),
             /route <text> (shows where <text> would go, without running it).
             v1.3: escalates to Flash at xhigh on its own for explicit "think hard"-style
             phrases (DEEP_PHRASES) or a very high complexity score (DEEP_SCORE).
             v1.3.3: conversations too big for Gemma's context go to Flash.
             v1.3.4: Flash-Next has vision (mmproj); /flash and /deep accept images.
             v1.4.0: Flash on its own server (STRONG_URL); effort sent as chat_template_kwargs.
             v1.4.1: prefixes work on messages with attachments.
requirements: httpx
"""

# v1.4.1 changes (Oct 24 2026)
# - Open WebUI puts an <attached_files>...</attached_files> block in front of the typed text when a
#   file or image is attached, so "/flash describe this" with an image never matched the prefix and
#   went to Gemma ("image attached"). Leading <attached_files> blocks are now set aside before the
#   prefix, length and keyword checks, and kept in the forwarded message.
#
# v1.4.0 changes (Oct 24 2026)
# - Flash-Next moved to mlx-serve (127.0.0.1:11234); Gemma stays on LM Studio. STRONG_URL is the
#   Flash server (empty = LMSTUDIO_URL, as before). Gemma and the classifier use LMSTUDIO_URL.
# - EFFORT_MODE "kwargs" (default): Flash requests carry
#   chat_template_kwargs {"enable_thinking": STRONG_THINKING, "reasoning_effort": STRONG_EFFORT or
#   DEEP_EFFORT}. mlx-serve turns thinking OFF unless a request turns it on, and thinking-off Flash
#   answered a two-step price question wrong (Oct 24). No [effort:...] marker is added in this mode.
# - EFFORT_MODE "marker": v1.3.4 behaviour for the LM Studio GGUF (rollback): template default,
#   [effort:xhigh] marker for deep routes, no kwargs.
# - /route and the status line show the effort; router errors name the server to check.

# v1.3.4 changes (Oct 24 2026)
# - STRONG_HAS_VISION now defaults to on: LM Studio loads Flash-Next with its vision projector
#   (mmproj-Qwen3.8-Flash-Next-F16.gguf, 862 MB) and it described a screenshot correctly.
#   Images still go to Gemma by default (faster); /flash and /deep with an image now go to Flash.
# - Context guard: an image in a conversation too big for Gemma now goes to Flash (128K) instead
#   of being trimmed, when STRONG_HAS_VISION is on. Only /gemma and /fast still trim.
#
# v1.3.3 changes (Oct 23 2026)
# - Context guard: Flash is loaded at 128K, Gemma at 32K. Before sending to Gemma, the whole request
#   (system prompt, history, images) is estimated in tokens. Over FAST_CTX - FAST_CTX_RESERVE:
#   - normally → Flash instead ("conversation ~N tokens, over Gemma's 32,768 context");
#   - when Gemma is required (image attached, or /gemma or /fast) → the oldest messages after the
#     system prompt are dropped until it fits, and the route note says how many.
#   Estimate = characters / CHARS_PER_TOKEN + IMAGE_TOKENS per image + 8 per message (cautious).
#   FAST_CTX = 0 turns the guard off.
#
# v1.3.2 changes (Oct 19 2026)
# - Per-route max_tokens caps: STRONG_MAX_TOKENS (Flash, medium), DEEP_MAX_TOKENS (Flash, xhigh),
#   FAST_MAX_TOKENS (Gemma); 0 = no cap. A max_tokens already in the request (chat Controls) wins.
#   Why: effort level does not bound reasoning length; uncapped xhigh requests ran 10+ min.
# - A reply cut off by the cap ends with a note saying so (a capped run may have no answer yet).
# - /route also shows the cap that would apply.
#
# v1.3 changes (Oct 14 2026)
# - DEEP_PHRASES: explicit asks for depth ("think carefully", "deep dive", ...) → Flash + [effort:xhigh].
# - DEEP_SCORE: messages scoring this high (several strong signals at once) → Flash + [effort:xhigh].
#   To turn automatic escalation off: DEEP_SCORE = 0 and DEEP_PHRASES = off (empty = built-in list).
#
# v1.2 changes (Oct 13 2026)
# - Routing is a score instead of first-match: several weak signals must add up before Flash is used.
# - Gemma is the default for chat, follow-ups, short snippets and simple lookups.
# - LONG_CHAT_TURNS default 0: a long conversation alone no longer forces Flash.
# - Code blocks count fully only when large or when the message asks to debug/fix/review/write code.
# - Narrower task keywords; bare topic words (dns, vlan, tls...) no longer route to Flash.
# - Short continuations ("continue", "yes", "go on") follow the previous answer's size.
# - reasoning_effort is no longer sent (LM Studio ignores it, and if it ever passed it through it
#   would override the template marker). /deep adds [effort:xhigh] to the system message instead.
# - /route dry run; images never go to Flash unless STRONG_HAS_VISION is on.

import json
import re
from typing import AsyncGenerator, Optional

import httpx
from pydantic import BaseModel, Field

CONTINUATION_RE = re.compile(
    r"^(continue|go on|keep going|carry on|do it|yes|yep|ok(ay)?|please do|proceed|next|more|finish|"
    r"same|again|thanks|thank you)\b", re.I)
TRIVIAL_RE = re.compile(
    r"\b(translate|paraphrase|rewrite|reword|summari[sz]e|tl;?dr|what is|what's|who is|define|definition of|"
    r"convert|spelling|grammar|typo|synonym)\b", re.I)
CODE_INTENT_RE = re.compile(
    r"\b(debug|fix|error|traceback|stack trace|refactor|review|optimi[sz]e|implement|write|complete|"
    r"why does|doesn't work|does not work|fails?|failing|broken)\b", re.I)


LEAD_BLOCK_RE = re.compile(r"^\s*(?:<attached_files>.*?</attached_files>\s*)+", re.S)


def split_lead(text: str) -> tuple:
    """(leading Open WebUI <attached_files> block(s), the text the user typed)."""
    m = LEAD_BLOCK_RE.match(text or "")
    return (m.group(0), text[m.end():]) if m else ("", text or "")


DEFAULT_DEEP_PHRASES = ("think hard, think harder, think carefully, think deeply, think it through, deep dive, "
                    "in-depth, in depth, be thorough, rigorous, rigorously, "
                    "check your work, verify your reasoning, take your time, leave no stone unturned")


class Pipe:
    class Valves(BaseModel):
        LMSTUDIO_URL: str = Field(default="http://localhost:1234/v1", description="LM Studio OpenAI-compatible base URL (Gemma)")
        STRONG_URL: str = Field(default="http://127.0.0.1:11234/v1", description="Flash-Next server base URL (empty = LMSTUDIO_URL)")
        EFFORT_MODE: str = Field(default="kwargs", description="kwargs: send chat_template_kwargs (mlx-serve); marker: [effort:xhigh] in the system message (LM Studio GGUF)")
        STRONG_THINKING: bool = Field(default=True, description="kwargs mode: enable_thinking for Flash (mlx-serve defaults it off)")
        STRONG_EFFORT: str = Field(default="medium", description="kwargs mode: reasoning_effort for Flash routes (low, medium, xhigh)")
        DEEP_EFFORT: str = Field(default="xhigh", description="kwargs mode: reasoning_effort for /deep, deep phrases and DEEP_SCORE")
        FAST_MODEL: str = Field(default="gemma-4-26b-a4b-it-qat", description="Quick model ID (as lms ps shows it)")
        STRONG_MODEL: str = Field(default="flash-next", description="Heavy model ID")
        SCORE_THRESHOLD: int = Field(default=3, description="Score at or above this → Flash")
        LENGTH_THRESHOLD: int = Field(default=1800, description="Last message longer than this (chars) adds 2; 3x longer adds 2 more")
        KEYWORDS: str = Field(
            default="root cause, troubleshoot, troubleshooting, traceback, stack trace, debug, refactor, optimize, "
                    "architecture, design review, trade-off, tradeoff, harden, hardening, audit, compliance, "
                    "threat model, derive, prove, proof, algorithm, implement, complete script, production script, "
                    "write a script, review this, review my, step by step, step-by-step, dcf, irr, wacc, "
                    "amortization, depreciation, roth conversion, monte carlo, network design, segmentation, isolation, "
                    "migration plan, disaster recovery, failover, redundancy, capacity planning",
            description="Comma-separated task phrases (whole-word match); one match adds 3",
        )
        IMAGES_TO_FAST: bool = Field(default=True, description="Messages with images go to the fast model (vision)")
        STRONG_HAS_VISION: bool = Field(default=True, description="Flash-Next can read images: /flash, /deep and oversized image chats go to Flash")
        LONG_CHAT_TURNS: int = Field(default=0, description="If > 0: conversations past this many turns add 1 for substantial messages")
        USE_CLASSIFIER: bool = Field(default=False, description="Ambiguous messages: ask the fast model SIMPLE/COMPLEX (+~0.5 s)")
        DEEP_PHRASES: Optional[str] = Field(
            default=None,
            description="Phrases (comma-separated) that send a message to Flash at xhigh. "
                        "Empty = built-in list; type off to disable",
        )
        DEEP_SCORE: int = Field(default=7, description="Score at or above this → Flash at xhigh (0 = off). Max score is 10-11")
        DEEP_MARKER: str = Field(default="[effort:xhigh]", description="marker mode: added to the system message for /deep")
        SHOW_ROUTE: bool = Field(default=True, description="Show which model answered, and why, above the reply")
        STRONG_PARAMS: str = Field(default='{"temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0.0}',
                                   description="JSON sampling params for the strong model")
        FAST_PARAMS: str = Field(default='{"temperature": 1.0, "top_p": 0.95, "top_k": 64}',
                                 description="JSON sampling params for the fast model")
        STRONG_MAX_TOKENS: int = Field(default=8192, description="max_tokens for Flash at medium effort (0 = no cap)")
        DEEP_MAX_TOKENS: int = Field(default=24576, description="max_tokens for Flash at xhigh: /deep, deep phrases, DEEP_SCORE (0 = no cap)")
        FAST_MAX_TOKENS: int = Field(default=0, description="max_tokens for Gemma (0 = no cap)")
        FAST_CTX: int = Field(default=32768, description="Gemma's loaded context (CONTEXT in lms ps). Bigger requests go to Flash (0 = no check)")
        FAST_CTX_RESERVE: int = Field(default=4096, description="Tokens kept free in Gemma's context for its reply")
        CHARS_PER_TOKEN: float = Field(default=3.0, description="Token estimate: characters per token (lower = more cautious)")
        IMAGE_TOKENS: int = Field(default=1100, description="Token estimate per attached image")

    def __init__(self):
        self.valves = self.Valves()

    def pipes(self):
        return [{"id": "auto", "name": "Auto (Gemma ⇄ Flash)"}]

    # ---------- helpers ----------
    @staticmethod
    def _text_and_images(content):
        if isinstance(content, str):
            return content, False
        text, has_img = [], False
        for part in content or []:
            if isinstance(part, dict):
                if part.get("type") == "text":
                    text.append(part.get("text", ""))
                elif part.get("type") in ("image_url", "image"):
                    has_img = True
        return "\n".join(text), has_img

    @staticmethod
    def _set_text(msg, new_text):
        if isinstance(msg.get("content"), str):
            msg["content"] = new_text
        else:
            for part in msg.get("content") or []:
                if isinstance(part, dict) and part.get("type") == "text":
                    part["text"] = new_text
                    break

    def _keywords(self, field: str = "KEYWORDS"):
        raw = getattr(self.valves, field) or ""
        if field == "DEEP_PHRASES":
            if raw.strip().lower() in ("off", "none", "-"):
                return []
            raw = raw.strip() or DEFAULT_DEEP_PHRASES
        kws = [k.strip().lower() for k in raw.split(",") if k.strip()]
        return [(k, re.compile(r"(?<![\w-])" + re.escape(k) + r"(?![\w-])", re.I)) for k in kws]

    def _add_marker(self, messages):
        marker = self.valves.DEEP_MARKER.strip()
        if not marker:
            return
        if messages and messages[0].get("role") == "system" and isinstance(messages[0].get("content"), str):
            if "[effort:" not in messages[0]["content"]:
                messages[0]["content"] = messages[0]["content"].rstrip() + "\n" + marker
        else:
            messages.insert(0, {"role": "system", "content": marker})

    async def _classify(self, text: str) -> Optional[bool]:
        prompt = ("Classify the user's request. Reply with exactly one word: SIMPLE if it is a quick fact, "
                  "short answer, casual chat or light rewrite; COMPLEX if it needs multi-step reasoning, "
                  "analysis, code, planning or careful accuracy.\n\nRequest:\n" + text[:2000])
        try:
            async with httpx.AsyncClient(timeout=15) as c:
                r = await c.post(f"{self.valves.LMSTUDIO_URL.rstrip('/')}/chat/completions",
                                 json={"model": self.valves.FAST_MODEL, "temperature": 0, "max_tokens": 8,
                                       "messages": [{"role": "user", "content": prompt}]})
                if r.status_code != 200:
                    return None
                out = str(((r.json().get("choices") or [{}])[0].get("message") or {}).get("content") or "").upper()
        except Exception:
            return None
        if "COMPLEX" in out:
            return True
        if "SIMPLE" in out:
            return False
        return None

    # ---------- context guard ----------
    def _estimate_tokens(self, messages) -> int:
        chars, imgs = 0, 0
        for msg in messages:
            content = msg.get("content")
            if isinstance(content, str):
                chars += len(content)
                continue
            for part in content or []:
                if isinstance(part, dict):
                    if part.get("type") == "text":
                        chars += len(part.get("text") or "")
                    elif part.get("type") in ("image_url", "image"):
                        imgs += 1
        per = self.valves.CHARS_PER_TOKEN if self.valves.CHARS_PER_TOKEN > 0 else 3.0
        return int(chars / per) + imgs * max(self.valves.IMAGE_TOKENS, 0) + 8 * len(messages)

    def _trim_to_fit(self, messages, limit: int) -> int:
        """Drop the oldest messages after the system prompt until the estimate fits; keeps the last message."""
        head = 0
        while head < len(messages) and messages[head].get("role") == "system":
            head += 1
        dropped = 0
        while len(messages) - head > 1 and self._estimate_tokens(messages) > limit:
            del messages[head]
            dropped += 1
        while len(messages) - head > 1 and messages[head].get("role") != "user":
            del messages[head]
            dropped += 1
        return dropped

    def _fit_fast(self, messages, reason: str, must_fast: bool) -> tuple:
        """Gemma route only. Returns (use_strong, reason); may trim messages in place."""
        ctx = self.valves.FAST_CTX
        if not ctx or ctx <= 0:
            return False, reason
        limit = max(ctx - max(self.valves.FAST_CTX_RESERVE, 0), 1024)
        est = self._estimate_tokens(messages)
        if est <= limit:
            return False, reason
        if not must_fast:
            return True, f"conversation ~{est:,} tokens, over Gemma's {ctx:,} context (was: {reason})"
        dropped = self._trim_to_fit(messages, limit)
        note = f"; dropped the {dropped} oldest message(s) to fit Gemma's {ctx:,} context" if dropped else ""
        left = self._estimate_tokens(messages)
        if left > limit:
            note += f"; still ~{left:,} tokens, may not fit"
        return False, reason + note

    # ---------- routing ----------
    async def route(self, messages) -> tuple:
        """Returns (use_strong, deep, reason, dry_run). Strips control prefixes from the last user message.
        A Gemma route that would overflow Gemma's context goes to Flash, or is trimmed when Gemma is required."""
        users = [m for m in messages if m.get("role") == "user"]
        text, has_img = self._text_and_images(users[-1].get("content")) if users else ("", False)
        forced_fast = bool(re.match(r"^(/route\b\s*)?/(gemma|fast)\b", split_lead(text)[1].lstrip(), re.I))
        use_strong, deep, reason, dry_run = await self._route(messages)
        if not use_strong:
            use_strong, reason = self._fit_fast(messages, reason, must_fast=forced_fast or (has_img and not self.valves.STRONG_HAS_VISION))
        return use_strong, deep, reason, dry_run

    async def _route(self, messages) -> tuple:
        users = [m for m in messages if m.get("role") == "user"]
        if not users:
            return False, False, "no user message", False
        last = users[-1]
        text, has_img = self._text_and_images(last.get("content"))
        lead, typed = split_lead(text)
        stripped = typed.lstrip()

        m = re.match(r"^/route\b\s*", stripped, re.I)
        if m:
            self._set_text(last, lead + stripped[m.end():])
            use_strong, deep, reason, _ = await self._route(messages)
            return use_strong, deep, reason, True

        m = re.match(r"^/(flash|strong|gemma|fast|deep)\b\s*", stripped, re.I)
        if m:
            cmd = m.group(1).lower()
            self._set_text(last, lead + stripped[m.end():])
            if cmd in ("gemma", "fast"):
                return False, False, f"forced with /{cmd}", False
            if has_img and not self.valves.STRONG_HAS_VISION:
                return False, False, f"/{cmd} ignored: image attached and STRONG_HAS_VISION is off", False
            return True, cmd == "deep", f"forced with /{cmd}", False

        if has_img and self.valves.IMAGES_TO_FAST:
            return False, False, "image attached", False

        low = stripped.lower().strip()
        if not low:
            return False, False, "empty message", False

        # Short continuation: follow the size of the previous answer.
        if len(low) <= 60 and CONTINUATION_RE.match(low):
            prev = next((msg for msg in reversed(messages) if msg.get("role") == "assistant"), None)
            prev_text = self._text_and_images(prev.get("content"))[0] if prev else ""
            if len(prev_text) > 1500:
                return True, False, "continuation of a long answer", False
            return False, False, "short continuation", False

        score, reasons = 0, []
        if "```" in stripped:
            if len(stripped) > 400 or CODE_INTENT_RE.search(stripped):
                score += 3
                reasons.append("code task")
            else:
                score += 1
                reasons.append("small code snippet")
        n = len(stripped)
        if n > self.valves.LENGTH_THRESHOLD:
            score += 2
            reasons.append(f"long message ({n} chars)")
            if n > 3 * self.valves.LENGTH_THRESHOLD:
                score += 2
                reasons.append("very long")
        for kw, rx in self._keywords():
            if rx.search(stripped):
                score += 3
                reasons.append(f'"{kw}"')
                break
        if self.valves.LONG_CHAT_TURNS and len(users) > self.valves.LONG_CHAT_TURNS and n > 220:
            score += 1
            reasons.append(f"long conversation ({len(users)} turns)")

        for kw, rx in self._keywords("DEEP_PHRASES"):
            if rx.search(stripped):
                return True, True, f'deep: asked for depth ("{kw}")' + (f"; score {score}" if score else ""), False
        if self.valves.DEEP_SCORE and score >= self.valves.DEEP_SCORE:
            return True, True, f"deep: score {score}: " + ", ".join(reasons), False

        if n < 220 and score < self.valves.SCORE_THRESHOLD and TRIVIAL_RE.search(stripped):
            return False, False, "simple short request", False
        if score >= self.valves.SCORE_THRESHOLD:
            return True, False, f"score {score}: " + ", ".join(reasons), False

        if self.valves.USE_CLASSIFIER and 60 <= n <= 2200:
            verdict = await self._classify(stripped)
            if verdict is not None:
                return verdict, False, "classifier: " + ("complex" if verdict else "simple"), False
        return False, False, f"score {score}" + (": " + ", ".join(reasons) if reasons else "") + " (quick)", False

    # ---------- forwarding ----------
    def _kwargs_mode(self) -> bool:
        return (self.valves.EFFORT_MODE or "kwargs").strip().lower() != "marker"

    def _effort(self, deep: bool) -> str:
        e = (self.valves.DEEP_EFFORT if deep else self.valves.STRONG_EFFORT) or ""
        e = e.strip().lower()
        return e if e in ("low", "medium", "xhigh") else ("xhigh" if deep else "medium")

    def _base_url(self, use_strong: bool) -> str:
        if use_strong and (self.valves.STRONG_URL or "").strip():
            return self.valves.STRONG_URL.strip().rstrip("/")
        return self.valves.LMSTUDIO_URL.rstrip("/")

    def _label(self, use_strong: bool, deep: bool) -> str:
        if not use_strong:
            return "Gemma"
        if self._kwargs_mode():
            return f"Flash-Next ({self._effort(deep)})" if self.valves.STRONG_THINKING else "Flash-Next (no thinking)"
        return "Flash-Next (xhigh)" if deep else "Flash-Next"

    def _hint(self, use_strong: bool) -> str:
        url = self._base_url(use_strong)
        if use_strong and url != self.valves.LMSTUDIO_URL.rstrip("/"):
            return f"(Is Flash's server up? `curl {url.rsplit('/v1', 1)[0]}/health`; log: ~/.mlx-serve/logs/)"
        return "(Is it loaded? `lms ps`)"

    def _cap(self, use_strong: bool, deep: bool, body: dict):
        """max_tokens for this route: request value first, then the route's valve; None = no cap."""
        try:
            if body.get("max_tokens"):
                return int(body["max_tokens"]), "chat setting"
        except (TypeError, ValueError):
            pass
        cap = (self.valves.DEEP_MAX_TOKENS if deep else self.valves.STRONG_MAX_TOKENS) if use_strong \
            else self.valves.FAST_MAX_TOKENS
        return (cap, "valve") if cap and cap > 0 else (None, None)

    @staticmethod
    def _cap_note(cap):
        return f"\n\n*(Stopped at the {cap:,}-token cap; the answer may be missing or incomplete.)*"

    async def pipe(self, body: dict, __event_emitter__=None):
        messages = [dict(m) for m in body.get("messages", [])]
        use_strong, deep, reason, dry_run = await self.route(messages)
        label = self._label(use_strong, deep)

        cap, cap_src = self._cap(use_strong, deep, body)
        cap_txt = f"cap {cap:,} tokens ({cap_src})" if cap else "no token cap"

        if dry_run:
            return f"**Route test:** this message would go to **{label}**: {reason}; {cap_txt}."

        model = self.valves.STRONG_MODEL if use_strong else self.valves.FAST_MODEL
        if deep and not self._kwargs_mode():
            self._add_marker(messages)

        if __event_emitter__ and self.valves.SHOW_ROUTE:
            await __event_emitter__({"type": "status",
                                     "data": {"description": f"→ {label} ({reason}; {cap_txt})", "done": True}})

        try:
            params = json.loads(self.valves.STRONG_PARAMS if use_strong else self.valves.FAST_PARAMS)
        except json.JSONDecodeError:
            params = {}
        payload = {"model": model, "messages": messages, "stream": bool(body.get("stream", True)), **params}
        if cap:
            payload["max_tokens"] = cap
        if use_strong and self._kwargs_mode():
            payload["chat_template_kwargs"] = {"enable_thinking": bool(self.valves.STRONG_THINKING),
                                               "reasoning_effort": self._effort(deep)}
        url = f"{self._base_url(use_strong)}/chat/completions"
        hint = self._hint(use_strong)

        if not payload["stream"]:
            async with httpx.AsyncClient(timeout=None) as c:
                try:
                    r = await c.post(url, json=payload)
                except httpx.HTTPError as e:
                    return f"**Router could not reach {model} at {url}:** {e}\n\n{hint}"
                if r.status_code != 200:
                    return f"**Router error {r.status_code} from {model}:** {r.text[:400]}\n\n{hint}"
                choice = (r.json().get("choices") or [{}])[0]
                msg = choice.get("message") or {}
                think = msg.get("reasoning_content") or msg.get("reasoning")
                note = self._cap_note(payload["max_tokens"]) \
                    if choice.get("finish_reason") == "length" and payload.get("max_tokens") else ""
                return (f"<think>{think}</think>\n" if think else "") + (msg.get("content") or "") + note

        return self._stream(url, payload, model, hint)

    async def _stream(self, url, payload, model, hint="(Is it loaded? `lms ps`)") -> AsyncGenerator:
        in_think = False
        finish = None
        try:
            async with httpx.AsyncClient(timeout=None) as c:
                async with c.stream("POST", url, json=payload) as r:
                    if r.status_code != 200:
                        err = (await r.aread()).decode("utf-8", "ignore")[:400]
                        yield f"**Router error {r.status_code} from {model}:** {err}\n\n{hint}"
                        return
                    async for line in r.aiter_lines():
                        if not line.startswith("data:"):
                            continue
                        data = line[5:].strip()
                        if data == "[DONE]":
                            break
                        try:
                            choice = (json.loads(data).get("choices") or [{}])[0]
                            delta = choice.get("delta") or {}
                        except (json.JSONDecodeError, IndexError, AttributeError):
                            continue
                        finish = choice.get("finish_reason") or finish
                        think = delta.get("reasoning_content") or delta.get("reasoning")
                        if think:
                            if not in_think:
                                in_think = True
                                yield "<think>"
                            yield think
                        content = delta.get("content")
                        if content:
                            if in_think:
                                in_think = False
                                yield "</think>\n"
                            yield content
        except httpx.HTTPError as e:
            if in_think:
                yield "</think>\n"
            yield f"**Router could not reach {model} at {url}:** {e}\n\n{hint}"
            return
        if in_think:
            yield "</think>\n"
        if finish == "length" and payload.get("max_tokens"):
            yield self._cap_note(payload["max_tokens"])
