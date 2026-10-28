# gemma-env.sh — sourced (not run) by every gemma script and by the model-server daemon.
# Loads ~/.config/gemma.env, applies defaults, and derives MODEL_ID from ENGINE.
# Values already set in the environment (e.g. ENGINE=mlx on the command line) win over the file.
# shellcheck shell=bash disable=SC2034

_gemma_keep=(ENGINE GGUF_REPO GGUF_QUANT MLX_REPO CTX NP PORT OWUI_PORT)
for _v in "${_gemma_keep[@]}"; do [[ -n "${!_v:-}" ]] && eval "_cli_$_v=\"\${$_v}\""; done
GEMMA_ENV_FILE="${GEMMA_ENV_FILE:-$HOME/.config/gemma.env}"
# shellcheck disable=SC1090
[[ -f "$GEMMA_ENV_FILE" ]] && source "$GEMMA_ENV_FILE"
for _v in "${_gemma_keep[@]}"; do _c="_cli_$_v"; [[ -n "${!_c:-}" ]] && eval "$_v=\"\${$_c}\""; unset "$_c"; done
unset _v _c _gemma_keep

ENGINE="${ENGINE:-llamacpp}"
GGUF_REPO="${GGUF_REPO:-lmstudio-community/gemma-4-26B-A4B-it-QAT-GGUF}"
GGUF_QUANT="${GGUF_QUANT:-Q4_0}"
MLX_REPO="${MLX_REPO:-mlx-community/gemma-4-26B-A4B-it-qat-4bit}"
CTX="${CTX:-16384}"
NP="${NP:-2}"
PORT="${PORT:-1234}"
OWUI_PORT="${OWUI_PORT:-8080}"

LLM_LABEL="com.gemma.llm"
LLM_PLIST="/Library/LaunchDaemons/$LLM_LABEL.plist"
LLM_LOG="$HOME/Library/Logs/gemma-llm.log"
OWUI_LABEL_DEFAULT="com.openwebui.serve"
OWUI_PLIST_DEFAULT="/Library/LaunchDaemons/$OWUI_LABEL_DEFAULT.plist"
LLAMA_CACHE="${LLAMA_CACHE:-$HOME/models/llama.cpp}"
MLX_VENV="${MLX_VENV:-$HOME/mlx-venv}"
export LLAMA_CACHE

case "$ENGINE" in
  llamacpp) MODEL_ID="gemma-4-26b-a4b-it-qat" ;;   # set with --alias, matches the old LM Studio key
  mlx)      MODEL_ID="$MLX_REPO" ;;                 # mlx-vlm names models by their Hugging Face repo
  *) echo "error: ENGINE must be llamacpp or mlx (got '$ENGINE')" >&2; return 1 2>/dev/null || exit 1 ;;
esac
