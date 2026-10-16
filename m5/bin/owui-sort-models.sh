#!/usr/bin/env zsh
# owui-sort-models.sh — sort Open WebUI's model dropdown: "Auto" first, then everything A–Z by name.
# Run after adding, renaming or deleting a persona:   ~/bin/owui-sort-models.sh
# Prompts for your Open WebUI login unless OWUI_TOKEN is already set. Backs up the current
# model settings to ~/owui-model-config-backup.json before writing.
set -euo pipefail
OWUI_URL="${OWUI_URL:-http://localhost:8080}"
[[ -f "$HOME/.config/macllm.env" ]] && source "$HOME/.config/macllm.env"
: "${OWUI_EMAIL:?Set OWUI_EMAIL (your Open WebUI login) in ~/.config/macllm.env}"
command -v jq >/dev/null || { echo "jq missing: brew install jq" >&2; exit 1; }

if [[ -z "${OWUI_TOKEN:-}" ]]; then
  read -rs "PW?Open WebUI password for $OWUI_EMAIL: " && echo
  resp=$(curl -s "$OWUI_URL/api/v1/auths/signin" -H 'Content-Type: application/json' \
         -d "$(jq -nc --arg e "$OWUI_EMAIL" --arg p "$PW" '{email:$e,password:$p}')")
  unset PW
  OWUI_TOKEN=$(jq -r '.token // empty' <<<"$resp")
  [[ -n "$OWUI_TOKEN" ]] || { echo "sign-in failed: $(jq -r '.detail // .' <<<"$resp")" >&2; exit 1; }
fi
auth=(-H "Authorization: Bearer $OWUI_TOKEN")

cfg=$(curl -fsS "${auth[@]}" "$OWUI_URL/api/v1/configs/models")
jq -e 'type=="object"' >/dev/null <<<"$cfg" || { echo "unexpected config response" >&2; exit 1; }
print -r -- "$cfg" > ~/owui-model-config-backup.json

order=$(curl -fsS "${auth[@]}" "$OWUI_URL/api/models" | jq -c '[(.data // .)[] | {id, name}]
  | sort_by((if .name == "Auto" then "0" else "1" end) + (.name | ascii_downcase)) | map(.id)')
[[ $(jq length <<<"$order") -gt 0 ]] || { echo "no models returned; is LM Studio serving?" >&2; exit 1; }

n=$(jq -c --argjson o "$order" '.MODEL_ORDER_LIST = $o' <<<"$cfg" \
    | curl -fsS -X POST "${auth[@]}" -H 'Content-Type: application/json' -d @- "$OWUI_URL/api/v1/configs/models" \
    | jq '.MODEL_ORDER_LIST | length')
echo "Sorted $n models:"
curl -fsS "${auth[@]}" "$OWUI_URL/api/models" | jq -r --argjson o "$order" \
  '[(.data // .)[] | {id, name}] as $m | $o[] as $id | ($m[] | select(.id == $id) | "  " + .name)'
echo "Reload Open WebUI in the browser to see it."
