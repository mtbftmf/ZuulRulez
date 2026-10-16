#!/usr/bin/env bash
# owui-sync-flash.sh — copy settings from one reference Flash persona to all the other Flash personas.
#
# Set the reference up by hand once (e.g. turn Builtin Tools off on Flash-IT), then:
#   export OWUI_TOKEN=sk-...                       # Open WebUI → Settings → Account → API Keys (admin)
#   ~/bin/owui-sync-flash.sh                       # report: what differs from the reference, per persona
#   KEYS=capabilities ~/bin/owui-sync-flash.sh     # dry run: show what would be copied
#   KEYS=capabilities DRY_RUN=0 ~/bin/owui-sync-flash.sh   # apply
#
# KEYS = comma-separated top-level keys under "meta" to copy (take them from the report).
# PARAM_KEYS = same for "params" (e.g. function_calling). System prompts, names, avatars, tools and
# knowledge are never copied unless you name them. A backup of all models is written first.
# Requires: curl, jq
set -euo pipefail

OWUI_URL="${OWUI_URL:-http://localhost:8080}"
: "${OWUI_TOKEN:?Set OWUI_TOKEN to an Open WebUI API key}"
REF="${REF:-muse-it-flash}"          # reference persona ID (Flash-IT)
BASE="${BASE:-flash-next}"           # personas with this base model are targets
KEYS="${KEYS:-}"
PARAM_KEYS="${PARAM_KEYS:-}"
DRY_RUN="${DRY_RUN:-1}"

command -v jq >/dev/null || { echo "jq missing: brew install jq" >&2; exit 1; }
api() { curl -fsS -H "Authorization: Bearer $OWUI_TOKEN" -H "Content-Type: application/json" "$@"; }

resp=$(curl -sSL -H "Authorization: Bearer $OWUI_TOKEN" "$OWUI_URL/api/v1/models/list")
jq -e . >/dev/null 2>&1 <<<"$resp" || { echo "error: model list is not JSON: $(head -c 80 <<<"$resp")" >&2; exit 1; }
jq -e 'type=="object" and has("detail")' >/dev/null <<<"$resp" && { echo "error: $(jq -r .detail <<<"$resp")" >&2; exit 1; }
LIST='(if type=="array" then . else (.items // .data // []) end)'

backup="$HOME/owui-models-backup-$(date +%Y%m%d-%H%M%S).json"
printf '%s\n' "$resp" > "$backup"

ref=$(jq -c --arg r "$REF" "$LIST[] | select(.id==\$r)" <<<"$resp")
[[ -n "$ref" ]] || { echo "error: reference '$REF' not found. IDs: $(jq -r "$LIST[].id" <<<"$resp" | tr '\n' ' ')" >&2; exit 1; }

targets=$(jq -c --arg r "$REF" --arg b "$BASE" \
  "$LIST[] | select(.id != \$r and (.base_model_id == \$b or (.id == \$b and .base_model_id == null)))" <<<"$resp")
[[ -n "$targets" ]] || { echo "No other personas on base '$BASE'."; exit 0; }
echo "Backup: $backup"
echo "Reference: $REF ($(jq -r .name <<<"$ref"))"

# Leaf-level differences between two objects, as dotted paths (skips per-persona fields).
DIFF='def leaves: [paths(type != "object")] ;
      ($a | leaves) + ($b | leaves) | unique[]
      | . as $p | select(($a | getpath($p)) != ($b | getpath($p)))
      | map(tostring) | join(".")'
SKIP='^(meta\.(description|profile_image_url|tags|suggestion_prompts|toolIds|knowledge|filterIds|actionIds)|params\.system)'

if [[ -z "$KEYS$PARAM_KEYS" ]]; then
  echo
  echo "Settings that differ from the reference (per-persona fields hidden):"
  while IFS= read -r t; do
    d=$(jq -rn --argjson a "$(jq -c '{meta, params}' <<<"$ref")" --argjson b "$(jq -c '{meta, params}' <<<"$t")" "$DIFF" \
        | grep -Ev "$SKIP" || true)
    echo "  $(jq -r '.id' <<<"$t"):"
    if [[ -n "$d" ]]; then sed 's/^/      /' <<<"$d" | head -40; else echo "      (same)"; fi
  done <<<"$targets"
  echo
  echo "Copy with:  KEYS=<meta keys> [PARAM_KEYS=<params keys>] $0   (top-level names, e.g. KEYS=capabilities)"
  exit 0
fi

keys_json=$(tr ',' '\n' <<<"$KEYS" | sed '/^$/d' | jq -R . | jq -sc .)
pkeys_json=$(tr ',' '\n' <<<"$PARAM_KEYS" | sed '/^$/d' | jq -R . | jq -sc .)

n=0
while IFS= read -r t; do
  id=$(jq -r .id <<<"$t")
  new=$(jq -c --argjson ref "$ref" --argjson k "$keys_json" --argjson pk "$pkeys_json" '
      .meta = ((.meta // {}) + ($ref.meta // {} | with_entries(select(.key as $x | $k | index($x)))))
    | .params = ((.params // {}) + ($ref.params // {} | with_entries(select(.key as $x | $pk | index($x)))))
    | del(.created_at, .updated_at, .user, .user_id)' <<<"$t")
  if [[ "$new" == "$(jq -c 'del(.created_at, .updated_at, .user, .user_id)' <<<"$t")" ]]; then
    echo "same  $id"; continue
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "plan  $id"
  else
    api -X POST "$OWUI_URL/api/v1/models/model/update?id=$id" -d "$new" >/dev/null
    echo "done  $id"; n=$((n+1))
  fi
done <<<"$targets"

[[ "$DRY_RUN" == 1 ]] && echo "Dry run. Re-run with DRY_RUN=0 to apply." || echo "Updated $n persona(s). Restore: $backup"
