#!/usr/bin/env bash
# gemma-serve.sh — run the model server in the foreground. Started at boot by the LaunchDaemon
# com.gemma.llm (runs as the build account, restarts on exit). Engine and settings: ~/.config/gemma.env.
#   ENGINE=llamacpp  llama.cpp llama-server, GGUF (Q4_0) + vision projector, model id gemma-4-26b-a4b-it-qat
#   ENGINE=mlx       mlx-vlm server, MLX 4-bit QAT build, model id = its Hugging Face repo
# Both listen on 127.0.0.1:$PORT only, serve the OpenAI API at /v1, never download at start-up,
# and cap memory: context $CTX shared by at most $NP simultaneous requests.
# Run by hand to watch it: ~/bin/gemma-down.sh first, then ~/ZuulRulez/gemma/bin/gemma-serve.sh
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=gemma-env.sh
source "$HERE/gemma-env.sh"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
echo "$(date '+%F %T') gemma-serve: engine $ENGINE, model $MODEL_ID, ctx $CTX, parallel $NP, port $PORT"

case "$ENGINE" in
  llamacpp)
    exec llama-server \
      -hf "$GGUF_REPO:$GGUF_QUANT" --offline \
      --alias "$MODEL_ID" \
      --host 127.0.0.1 --port "$PORT" \
      -c "$CTX" -np "$NP" --kv-unified \
      -ngl all --jinja --no-webui --metrics
    ;;
  mlx)
    export HF_HUB_OFFLINE=1
    exec "$MLX_VENV/bin/mlx_vlm.server" \
      --model "$MLX_REPO" \
      --host 127.0.0.1 --port "$PORT" \
      --max-kv-size "$CTX" --max-num-seqs "$NP"
    ;;
esac
