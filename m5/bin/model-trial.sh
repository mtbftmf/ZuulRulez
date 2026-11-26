#!/bin/bash
# model-trial.sh: try a candidate MLX model next to the running stack, then remove it.
#
#   ~/bin/model-trial.sh rarevector/Swift-1.5-Qwen3.8-27B-VectorCut-MLX-4bit
#
# Steps: download the repo into ~/llm-trial/<name> (its own folder, not the shared Hugging Face cache,
# so deleting it frees the space) -> stop Gemma (Flash + Gemma + a 15-25 GB candidate would pass the
# 112 GiB GPU limit) -> start a second mlx-serve on 127.0.0.1:11236 -> llm-bench -> llm-compare grade
# (base tier once, hard tier HARD_RUNS times) -> grade-diff against Flash's baselines -> stop the
# candidate, delete its folder, start Gemma again. Flash and Open WebUI stay up throughout; Auto's
# Gemma route is down while the trial runs.
#
# Settings (environment): TRIAL_PORT=11236  TRIAL_CTX=131072  HARD_RUNS=3  MTP=1 (0 = no --mtp)
#   KEEP=1 keeps the download for another run   STOP_GEMMA=0 leaves Gemma running (watch memory)
#   BASELINE=mlx-26.11.2 (grade-diff compares with BASELINE and BASELINE-hard)
# Remove a kept download:  ~/bin/model-trial.sh --remove <name>
# Log: ~/Library/Logs/model-trial/<name>-<time>.log
set -uo pipefail

PORT="${TRIAL_PORT:-11236}"; CTX="${TRIAL_CTX:-131072}"; HARD_RUNS="${HARD_RUNS:-3}"
MTP="${MTP:-1}"; KEEP="${KEEP:-0}"; STOP_GEMMA="${STOP_GEMMA:-1}"; BASELINE="${BASELINE:-mlx-26.11.2}"
TRIAL_DIR="${TRIAL_DIR:-$HOME/llm-trial}"; LOG_DIR="${TRIAL_LOG_DIR:-$HOME/Library/Logs/model-trial}"
BIN="${TRIAL_BIN:-$HOME/bin}"
SERVE_BIN="${SERVE_BIN:-$(brew --prefix 2>/dev/null)/opt/mlx-serve/bin/mlx-serve}"
HF_BIN="${HF_BIN:-$(command -v hf || command -v huggingface-cli || true)}"
GEMMA_URL="${GEMMA_URL:-http://127.0.0.1:11235}"

die() { echo "error: $*" >&2; exit 1; }
tilde() { local s="$1" t='~'; echo "${s//"$HOME"/$t}"; }

if [[ "${1:-}" == "--remove" ]]; then
  [[ -n "${2:-}" && "$2" != */* ]] || die "usage: $(basename "$0") --remove <name>"
  [[ -d "$TRIAL_DIR/$2" ]] || die "nothing at $(tilde "$TRIAL_DIR/$2")"
  du -sh "$TRIAL_DIR/$2"; rm -rf "${TRIAL_DIR:?}/$2" && echo "removed $(tilde "$TRIAL_DIR/$2")"; exit 0
fi
REPO="${1:-}"
[[ "$REPO" == */* && "$REPO" != *" "* ]] || die "usage: $(basename "$0") owner/repo   (or --remove <name>)"
NAME="${REPO##*/}"; DIR="$TRIAL_DIR/$NAME"; URL="http://127.0.0.1:$PORT"
mkdir -p "$LOG_DIR" "$TRIAL_DIR"
LOG="$LOG_DIR/$NAME-$(date +%Y%m%d-%H%M%S).log"; SERVE_LOG="${LOG%.log}.serve.log"
exec > >(tee -a "$LOG") 2>&1

[[ -x "$SERVE_BIN" ]] || die "mlx-serve not found at $SERVE_BIN"
[[ -n "$HF_BIN" ]] || die "hf CLI not found (brew install huggingface-cli, or pip install -U huggingface_hub)"
command -v python3 >/dev/null || die "python3 not found"
if curl -fsS -m 3 "$URL/v1/models" >/dev/null 2>&1; then die "something already answers on $URL; set TRIAL_PORT"; fi
free_gb=$(df -g "$TRIAL_DIR" 2>/dev/null | awk 'NR==2{print $4}')
[[ -z "$free_gb" || "$free_gb" -ge 40 ]] || die "only ${free_gb} GB free on the trial disk; need about 40"

SERVE_PID=""; GEMMA_STOPPED=0
cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if [[ -n "$SERVE_PID" ]] && kill -0 "$SERVE_PID" 2>/dev/null; then
    echo "→ Stopping the trial server (pid $SERVE_PID)"
    kill "$SERVE_PID" 2>/dev/null
    for _ in $(seq 1 60); do kill -0 "$SERVE_PID" 2>/dev/null || break; sleep 1; done
    kill -9 "$SERVE_PID" 2>/dev/null || true
  fi
  if [[ "$KEEP" != 1 && -d "$DIR" ]]; then
    echo "→ Removing $(tilde "$DIR") ($(du -sh "$DIR" 2>/dev/null | cut -f1))"; rm -rf "${DIR:?}"
  elif [[ -d "$DIR" ]]; then
    echo "  kept $(tilde "$DIR"); remove later with: $(basename "$0") --remove $NAME"
  fi
  if [[ "$GEMMA_STOPPED" == 1 ]]; then
    echo "→ Starting Gemma again"
    OWUI_LABEL= "$BIN/flash-up.sh" | sed 's/^/  /'
  fi
  echo "log: $(tilde "$LOG")"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

echo "→ Downloading $REPO to $(tilde "$DIR") (resumes if interrupted)"
"$HF_BIN" download "$REPO" --local-dir "$DIR" >/dev/null || die "download failed"
du -sh "$DIR" | sed 's/^/  /'
[[ -f "$DIR/config.json" ]] || die "no config.json at the repo root; is this an MLX model folder?"

if [[ "$STOP_GEMMA" == 1 ]] && curl -fsS -m 3 "$GEMMA_URL/v1/models" >/dev/null 2>&1; then
  echo "→ Stopping Gemma for the trial (memory headroom)"
  STOP_MLX=0 STOP_OWUI=0 "$BIN/flash-down.sh" | sed 's/^/  /'
  GEMMA_STOPPED=1
fi

ARGS=(--model "$DIR" --host 127.0.0.1 --port "$PORT" --ctx-size "$CTX" --max-concurrent 1 --metrics)
[[ "$MTP" == 1 ]] && ARGS+=(--mtp)
echo "→ Starting mlx-serve on $URL: $(tilde "${ARGS[*]}")"
"$SERVE_BIN" "${ARGS[@]}" >"$SERVE_LOG" 2>&1 &
SERVE_PID=$!
printf "  waiting for the model to load "
ID=""
for _ in $(seq 1 300); do
  kill -0 "$SERVE_PID" 2>/dev/null || { echo; tail -20 "$SERVE_LOG"; die "mlx-serve exited during load (log above)"; }
  ID="$(curl -fsS -m 3 "$URL/v1/models" 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin)["data"];print(d[0]["id"] if d else "")' 2>/dev/null || true)"
  [[ -n "$ID" ]] && break
  printf "."; sleep 2
done
echo
[[ -n "$ID" ]] || die "no model listed on $URL after 10 minutes (see $(tilde "$SERVE_LOG"))"
echo "  serving \"$ID\" (pid $SERVE_PID)"
grep -iE 'mtp|draft' "$SERVE_LOG" | head -3 | sed 's/^/  log: /'
command -v vm_stat >/dev/null && vm_stat | awk '/Pages wired/{gsub("\\.","",$4); printf "  wired now: %.1f GB\n", $4*16384/1e9}'

LABEL="trial-$NAME"
echo "→ llm-bench"
python3 "$BIN/llm-bench.py" --model "$ID" --url "$URL/v1" --label "$LABEL" | grep -E 'run [0-9]|Share|llm-bench v2'
echo "→ grade, base tier (1 run)"
python3 "$BIN/llm-compare.py" grade --label "$LABEL" --url "$URL/v1" --model "$ID" | grep -E 'FAIL|passed|Saved'
echo "→ grade, hard tier ($HARD_RUNS runs)"
python3 "$BIN/llm-compare.py" grade --label "$LABEL-hard" --url "$URL/v1" --model "$ID" --tier hard --runs "$HARD_RUNS"
echo "→ against Flash"
python3 "$BIN/llm-compare.py" grade-diff "$BASELINE" "$LABEL" | tail -3
python3 "$BIN/llm-compare.py" grade-diff "$BASELINE-hard" "$LABEL-hard"
echo "✓ trial of $REPO done"
