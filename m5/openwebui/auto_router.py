"""
title: Auto Router (Gemma ⇄ Flash-Next) — M5 Max 128 GB
author: ewagner (Pdl_Pwr)
version: 1.2
machine: Apple Silicon M5 Max, 128 GB unified memory
description: One "Auto" model routing quick requests to Gemma 4 26B-A4B and heavy
             requests to Qwen3.8-Flash-Next (88 GB GGUF) on an M5 Max Studio.
             Tuned for mmap/sparse weights + wired RAM ~74 GB; DO NOT port to
             other M-series Studios / generic Gemma 4 builds. See
             m5/docs/M5_MAX_AUTO_ROUTER_POLICY.md
requirements: httpx
"""
import json
import re
from typing import AsyncGenerator, Optional
import httpx
from pydantic import BaseModel, Field


class Pipe:
    class Valves(BaseModel):
        LMSTUDIO_URL: str = Field(
            default="http://localhost:1234/v1",
            description="LM Studio OpenAI-compatible base URL",
        )
        FAST_MODEL: str = Field(
            default="gemma-4-26b-a4b-it-qat",
            description="Quick model ID (as `lms ps` shows it)",
        )
        STRONG_MODEL: str = Field(default="flash-next", description="Heavy model ID")
        LENGTH_THRESHOLD: int = Field(
            default=1800,
            description="M5: last message longer than this (chars) -> strong",
        )
        SCORE_THRESHOLD: int = Field(
            default=3,
            description="Heuristic score that triggers Flash-Next",
        )
        KEYWORDS: str = Field(
            default=(
                "root cause, troubleshoot, traceback, stack trace, debug, refactor, optimize, "
                "architecture, design review, trade-off, tradeoff, harden, audit, compliance, "
                "threat model, benchmark, derive, prove, proof, algorithm, implement, "
                "complete script, production script, write a script, review this, review code, "
                "review config, review architecture, calculate dcf, calculate irr, "
                "calculate wacc, calculate tax, calculate drawdown, calculate retirement, "
                "forecast model, amortization, depreciation, vlan, acl, firewall, dns, sso, "
                "saml, tls, certificate"
            ),
            description="Comma-separated phrases that score toward the strong model",
        )
        IMAGES_TO_FAST: bool = Field(
            default=True,
            description="Send messages with images to the fast model (vision)",
        )
        LONG_CHAT_TURNS: int = Field(
            default=0,
            description="M5: turns -> strong (0 = off; long chats are follow-ups)",
        )
        USE_CLASSIFIER: bool = Field(
            default=False,
            description="If nothing matched, ask Gemma SIMPLE/COMPLEX (+~0.5 s)",
        )
        STRONG_REASONING_EFFORT: str = Field(
            default="medium",
            description="Flash-Next depth: low | medium | xhigh (blank = not sent)",
        )
        STRONG_MAX_TOKENS: int = Field(default=16384, description="Strong output budget")
        FAST_MAX_TOKENS: int = Field(default=2048, description="Fast output budget")
        SHOW_ROUTE: bool = Field(
            default=True, description="Show which model answered and why"
        )
        STRONG_PARAMS: str = Field(
            default='{"temperature": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0.0}',
            description="JSON sampling params for the strong model",
        )
        FAST_PARAMS: str = Field(
            default='{"temperature": 1.0, "top_p": 0.95, "top_k": 64}',
            description="JSON sampling params for the fast model",
        )

    def __init__(self):
        self.valves = self.Valves()

    def pipes(self):
        return [{"id": "auto", "name": "Auto (Gemma ⇄ Flash)"}]

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

    async def _classify(self, text: str) -> Optional[bool]:
        prompt = (
            "Classify the user's request. Reply with exactly one word: SIMPLE if it is a quick "
            "fact, short answer, casual chat or light rewrite; COMPLEX if it needs multi-step "
            "reasoning, analysis, code, planning or careful accuracy.\n\nRequest:\n" + text[:2000]
        )
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(15.0, read=None)) as c:
                r = await c.post(
                    f"{self.valves.LMSTUDIO_URL.rstrip('/')}/chat/completions",
                    json={
                        "model": self.valves.FAST_MODEL,
                        "temperature": 0,
                        "max_tokens": 8,
                        "messages": [{"role": "user", "content": prompt}],
                    },
                )
                if r.status_code != 200:
                    return None
                data = r.json()
        except Exception:
            return None
        out = str(
            (data.get("choices") or [{}])[0].get("message", {}).get("content") or ""
        ).upper()
        if "COMPLEX" in out:
            return True
        if "SIMPLE" in out:
            return False
        return None

    async def route(self, messages) -> tuple:
        """Returns (use_strong: bool, reason: str). Strips /<model> prefixes."""
        users = [m for m in messages if m.get("role") == "user"]
        if not users:
            return False, "no user message"

        last = users[-1]
        text, has_img = self._text_and_images(last.get("content"))
        stripped = text.lstrip()

        m = re.match(r"^/(flash|gemma|strong|fast)\b\s*", stripped, re.I)
        if m:
            self._set_text(last, stripped[m.end():])
            use_strong = m.group(1).lower() in ("flash", "strong")
            return use_strong, f"forced with /{m.group(1).lower()}"

        if has_img and self.valves.IMAGES_TO_FAST:
            return False, "image attached"

        text = stripped
        low = text.lower().strip()
        if not low:
            return False, "empty"

        last_idx = max(i for i, msg in enumerate(messages) if msg.get("role") == "user")
        prev_text = ""
        for msg in reversed(messages[:last_idx]):
            if msg.get("role") == "assistant":
                prev_text = self._text_and_images(msg.get("content"))[0]
                break
        if len(low) <= 80 and re.match(
            r"^(continue|go on|keep going|do it|yes|please do|run|next|more|same|finish|output)\b",
            low,
        ):
            if len(prev_text) > 1200:
                return True, "continuation of complex answer"
            return False, "short continuation"

        score, reasons = 0, []
        strong_re = re.compile(
            r"\b(root cause|troubleshoot|debug|traceback|stack trace|architecture|design review|"
            r"harden|audit|compliance|threat model|benchmark|optimize|refactor|implement|derive|"
            r"prove|proof|algorithm|complete script|production script|write a script|review "
            r"(this|code|script|config|architecture)|vlan|acl|firewall|dns|sso|saml|tls|"
            r"certificate)\b",
            re.I,
        )
        if "```" in text:
            if len(text) > 400 or re.search(
                r"\b(code|script|function|class|regex|json|yaml|bash|zsh|python|shell|error|"
                r"traceback|stack trace|debug|fix|refactor|review|optimize|implement|config|log)\b",
                low,
            ):
                score += 3
                reasons.append("code block/code task")
            else:
                score += 1
                reasons.append("small code block")
        if len(text) > self.valves.LENGTH_THRESHOLD:
            score += 2
            reasons.append(f"long message ({len(text)} chars)")
        if strong_re.search(text):
            score += 3
            reasons.append("complex task")
        for kw in [k.strip().lower() for k in self.valves.KEYWORDS.split(",") if k.strip()]:
            if kw and kw in low:
                score += 2
                reasons.append(f'keyword "{kw}"')
                break
        trivial_re = re.compile(
            r"\b(translate|paraphrase|rewrite|summarize|tl;dr|brief|short|what is|who is|"
            r"definition of|list|convert|format|spelling|grammar|fix typo|fix grammar)\b",
            re.I,
        )
        if len(text) < 220 and trivial_re.search(text) and score < 3:
            return False, "simple short request"
        if self.valves.LONG_CHAT_TURNS and len(users) > self.valves.LONG_CHAT_TURNS:
            if len(text) > 220 or strong_re.search(text):
                score += 2
                reasons.append("long conversation + substantial turn")

        if score >= self.valves.SCORE_THRESHOLD:
            return True, "; ".join(dict.fromkeys(reasons))
        if self.valves.USE_CLASSIFIER and 60 <= len(text) <= 2200:
            verdict = await self._classify(text)
            if verdict:
                return True, "classifier: complex"
            if verdict is not None:
                return False, "classifier: simple"
        return False, "default (quick)"

    async def pipe(self, body: dict, __event_emitter__=None) -> AsyncGenerator:
        messages = [dict(m) for m in body.get("messages", [])]
        use_strong, reason = await self.route(messages)
        model = self.valves.STRONG_MODEL if use_strong else self.valves.FAST_MODEL
        label = "Flash-Next" if use_strong else "Gemma"
        if __event_emitter__ and self.valves.SHOW_ROUTE:
            await __event_emitter__(
                {"type": "status", "data": {"description": f"→ {label} ({reason})", "done": True}}
            )
        try:
            params = json.loads(
                self.valves.STRONG_PARAMS if use_strong else self.valves.FAST_PARAMS
            )
        except json.JSONDecodeError:
            params = {}
        max_tokens = int(
            body.get("max_tokens")
            or (self.valves.STRONG_MAX_TOKENS if use_strong else self.valves.FAST_MAX_TOKENS)
        )
        payload = {
            "model": model,
            "messages": messages,
            "stream": bool(body.get("stream", True)),
            "max_tokens": max_tokens,
            **params,
        }
        effort = self.valves.STRONG_REASONING_EFFORT.strip().lower()
        if use_strong and effort:
            payload["reasoning_effort"] = effort
            payload["chat_template_kwargs"] = {"reasoning_effort": effort}

        url = f"{self.valves.LMSTUDIO_URL.rstrip('/')}/chat/completions"
        if not payload["stream"]:
            async with httpx.AsyncClient(timeout=httpx.Timeout(15.0, read=None)) as c:
                r = await c.post(url, json=payload)
                if r.status_code != 200 and effort:
                    clean = {
                        k: v
                        for k, v in payload.items()
                        if k not in ("reasoning_effort", "chat_template_kwargs")
                    }
                    r = await c.post(url, json=clean)
                if r.status_code != 200:
                    return f"**Router error {r.status_code} from {model}:** {r.text[:400]}"
                msg = r.json()["choices"][0]["message"]
                think = msg.get("reasoning_content") or msg.get("reasoning")
                return (f"<think>{think}</think>\n" if think else "") + (msg.get("content") or "")
        return self._stream(url, payload, model)

    async def _stream(self, url, payload, model):
        in_think = False
        async with httpx.AsyncClient(timeout=httpx.Timeout(15.0, read=None)) as c:
            async with c.stream("POST", url, json=payload) as r:
                if r.status_code == 400 and (
                    "reasoning_effort" in payload or "chat_template_kwargs" in payload
                ):
                    payload = {
                        k: v
                        for k, v in payload.items()
                        if k not in ("reasoning_effort", "chat_template_kwargs")
                    }
                    async for chunk in self._stream(url, payload, model):
                        yield chunk
                    return
                if r.status_code != 200:
                    err = (await r.aread()).decode("utf-8", "ignore")[:400]
                    yield f"**Router error {r.status_code} from {model}:** {err}\n\n(Is it loaded? `lms ps`)"
                    return
                async for line in r.aiter_lines():
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        delta = (json.loads(data).get("choices") or [{}])[0].get("delta") or {}
                    except (json.JSONDecodeError, IndexError):
                        continue
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
        if in_think:
            yield "</think>\n"
