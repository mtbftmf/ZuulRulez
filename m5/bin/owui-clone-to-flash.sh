#!/usr/bin/env bash
# owui-clone-to-flash.sh — copy Open WebUI custom models (system prompts, params, tools,
# knowledge, avatars) built on existing base models onto Flash-Next.
#
# Usage:
#   export OWUI_TOKEN=sk-...            # Open WebUI: Settings → Account → API Keys (use an admin account)
#   ./owui-clone-to-flash.sh <source-base-id> [<source-base-id> ...]          # dry run (default)
#   DRY_RUN=0 ./owui-clone-to-flash.sh <source-base-id> [...]                 # apply
#
# Handles two cases:
#   1. Workspace custom models whose base_model_id is a source → new model "<id>-flash" on Flash.
#   2. Admin overrides of a source base model itself (system prompt set on the base model)
#      → same override applied to the Flash base model. If two sources both have one, the first listed wins.
# Workspace → Prompts (slash commands) are model-agnostic and need no cloning.
# Requires: curl, jq  (brew install jq)
set -euo pipefail

OWUI_URL="${OWUI_URL:-http://localhost:8080}"
: "${OWUI_TOKEN:?Set OWUI_TOKEN to an Open WebUI API key}"
TARGET_BASE="${TARGET_BASE:-flash-next}"   # Flash's model ID as Open WebUI shows it (include any connection prefix)
SUFFIX="${SUFFIX:-flash}"
DRY_RUN="${DRY_RUN:-1}"
APPLY_QWEN_SAMPLING="${APPLY_QWEN_SAMPLING:-1}"  # 1 = set Qwen's thinking-mode sampling on clones

[[ $# -gt 0 ]] || { sed -n '2,15p' "$0"; exit 1; }
command -v jq >/dev/null || { echo "jq missing: brew install jq" >&2; exit 1; }

SRCS_JSON=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
api() { curl -fsS -H "Authorization: Bearer $OWUI_TOKEN" -H "Content-Type: application/json" "$@"; }

[[ ( "$OWUI_TOKEN" == sk-* || "$OWUI_TOKEN" == eyJ* ) && "$OWUI_TOKEN" != *your-real-key* && "$OWUI_TOKEN" != "sk-..." ]] \
  || { echo "OWUI_TOKEN looks like a placeholder. Create one: Open WebUI → Settings → Account → API Keys" >&2; exit 1; }

LIST_PATH="${LIST_PATH:-/api/v1/models/list}"
backup="owui-models-backup-$(date +%Y%m%d-%H%M%S).json"
resp=$(curl -sSL -H "Authorization: Bearer $OWUI_TOKEN" "$OWUI_URL$LIST_PATH")

if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
  echo "error: $LIST_PATH did not return JSON (got: $(head -c 80 <<<"$resp" | tr '\n' ' ')...)" >&2
  echo "Check OWUI_URL ($OWUI_URL) and your Open WebUI version's API path." >&2; exit 1
fi
if jq -e 'type=="object" and has("detail")' >/dev/null <<<"$resp"; then
  echo "error: Open WebUI says: $(jq -r .detail <<<"$resp")" >&2; exit 1
fi
printf '%s\n' "$resp" > "$backup"

LIST='(if type=="array" then . else (.items // .data // []) end)'
count=$(jq "$LIST | length" "$backup")
total=$(jq 'if type=="object" then (.total // null) else null end' "$backup")
echo "Backup of current custom models: $backup ($count model(s))"
[[ "$total" != "null" && "$total" -gt "$count" ]] && \
  echo "warning: API reports $total models but returned $count (paginated); clones beyond page 1 will be missed." >&2

existing=$(jq -r "$LIST[].id" "$backup")

plan=$(jq -c --argjson srcs "$SRCS_JSON" --arg tgt "$TARGET_BASE" --arg sfx "$SUFFIX" \
           --argjson qs "$APPLY_QWEN_SAMPLING" "
  $LIST[]
  | (.base_model_id // null) as \$b
  | select( (\$b != null and any(\$srcs[]; . == \$b))
         or (\$b == null and (.id as \$i | any(\$srcs[]; . == \$i))) )
  | .id as \$src
  | (if \$b == null
       then .id = \$tgt | .name = \"Flash-Next\"
       else .id = (.id + \"-\" + \$sfx) | .name = (.name + \" (Flash)\") | .base_model_id = \$tgt
     end)
  | del(.created_at, .updated_at, .user_id, .user)
  | .params = ((.params // {}) + (if \$qs == 1 then
        {temperature:1.0, top_p:0.95, top_k:20, min_p:0.0, presence_penalty:0.0, repeat_penalty:1.0}
      else {} end))
  | {src: \$src, model: .}
" "$backup")

[[ -n "$plan" ]] || { echo "No custom models found on: $*"; echo "Check IDs in Admin → Settings → Models."; exit 0; }

made=0
while IFS= read -r row; do
  src=$(jq -r .src <<<"$row"); nid=$(jq -r .model.id <<<"$row")
  if grep -qxF -- "$nid" <<<"$existing"; then
    echo "skip  $src → $nid (already exists)"; continue
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "plan  $src → $nid"
  else
    jq -c .model <<<"$row" | api -X POST "$OWUI_URL/api/v1/models/create" -d @- >/dev/null
    echo "made  $src → $nid"; made=$((made+1))
  fi
  existing+=$'\n'"$nid"
done <<<"$plan"

[[ "$DRY_RUN" == 1 ]] && echo "Dry run only. Re-run with DRY_RUN=0 to create." || echo "Created $made model(s)."
