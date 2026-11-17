#!/usr/bin/env bash
# mlx-upgrade.sh — upgrade (or roll back) the pinned Homebrew mlx-serve and restart both model servers.
#
# Usage:
#   ~/bin/mlx-upgrade.sh --check      report only: installed, pinned, latest, rollback anchor, MLX_SERVE_* audit
#   ~/bin/mlx-upgrade.sh              upgrade to the tap's latest stable (skips if already current)
#   ~/bin/mlx-upgrade.sh 26.10.3      install a specific version (use this to roll back)
#   FORCE=1 ~/bin/mlx-upgrade.sh      reinstall even if already current
#
# Order (same as owui-upgrade.sh): stop both agents, change the binary, start them again.
#   1. brew update, then read the linked version and the tap's stable version.
#   2. Find the rollback anchor: the newest tap commit whose formula is the installed version.
#   3. Stop Flash and Gemma (bootout, then wait until launchctl print fails; m5-operations.md §2).
#   4. Unpin, install the target with HOMEBREW_NO_INSTALL_CLEANUP=1, so the old keg stays on disk as an
#      emergency fallback (a rollback by version still re-fetches: a bottle if the formula has one,
#      otherwise a source build; --check says which). If the install fails, the old binary starts again.
#   5. Start both with flash-up.sh (bootstrap, wait for the model IDs, warm, verify). Open WebUI untouched.
#   6. Prove the restart by changed PIDs, re-pin (always, via an EXIT trap), print the next checks.
# A version other than the tap's stable is installed from the anchor commit's formula: the tap file is
# checked out at that commit, reinstalled, and restored to HEAD (also via the EXIT trap).
# Logs (mlx-serve --help before/after, every brew line): ~/Library/Logs/mlx-upgrade/.
# Overrides go in ~/.config/macllm.env (see env.example). Per run: NO_UPDATE=1 skips brew update (--check
# otherwise fast-forwards the tap), PIN_AFTER=0 leaves an unpinned formula unpinned.
set -euo pipefail
[[ -f "$HOME/.config/macllm.env" ]] && source "$HOME/.config/macllm.env"

# ---------- CONFIG ----------
FORMULA="${MLX_UPGRADE_FORMULA:-ddalcu/mlx-serve/mlx-serve}"   # full name: the tap also ships a cask
KEG_NAME="${FORMULA##*/}"
FLASH_LABEL="${MLX_LABEL:-com.$USER.mlx-serve}"
GEMMA_LABEL="${GEMMA_LABEL:-com.$USER.mlx-serve-gemma}"
AGENT_DIR="${MLX_UPGRADE_AGENT_DIR:-$HOME/Library/LaunchAgents}"
FLASH_UP="${MLX_UPGRADE_FLASH_UP:-$HOME/bin/flash-up.sh}"
REPO="${MLX_UPGRADE_REPO:-$HOME/ZuulRulez}"
STOP_WAIT="${MLX_UPGRADE_STOP_WAIT:-90}"      # seconds per agent; Flash can take ~1 min to unload
LOG_DIR="${MLX_UPGRADE_LOG_DIR:-$HOME/Library/Logs/mlx-upgrade}"
# ----------------------------

DOM="gui/$(id -u)"
LABELS=("$FLASH_LABEL" "$GEMMA_LABEL")
MODE="upgrade"; TARGET=""
case "${1:-}" in
  --check) MODE="check" ;;
  -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
  "") ;;
  -*) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  *) TARGET="$1" ;;
esac

die()   { echo "error: $*" >&2; exit 1; }
say()   { echo "→ $*"; }
tilde() { local s="$1" t='~'; echo "${s//"$HOME"/$t}"; }   # never print /Users/<name>
export HOMEBREW_NO_AUTO_UPDATE=1                     # only the explicit brew update below touches the tap
export HOMEBREW_NO_INSTALL_CLEANUP=1                 # keep the old keg for rollback
export HOMEBREW_NO_ENV_HINTS=1

command -v brew >/dev/null || die "brew not found"
command -v jq   >/dev/null || die "jq not found (brew install jq)"
if [[ -n "${MLX_UPGRADE_TAP_DIR:-}" ]]; then TAP_DIR="$MLX_UPGRADE_TAP_DIR"; else
  TAP_USER="${FORMULA%%/*}"; TAP_REPO="${FORMULA#*/}"; TAP_REPO="${TAP_REPO%%/*}"
  TAP_DIR="$(brew --repository)/Library/Taps/$TAP_USER/homebrew-$TAP_REPO"   # ddalcu/mlx-serve -> ddalcu/homebrew-mlx-serve
fi
SERVE_BIN="$(brew --prefix)/opt/$KEG_NAME/bin/mlx-serve"   # follows the re-link; never the bare name on PATH
TAP_FILE="Formula/$KEG_NAME.rb"
[[ -f "$TAP_DIR/$TAP_FILE" ]] || die "tap formula not found: $(tilde "$TAP_DIR/$TAP_FILE")"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$$.log"   # PID suffix: two runs in one second never share a log

linked_version() {   # version of the linked keg, e.g. 26.10.3; empty if not installed
  local opt; opt="$(brew --prefix)/opt/$KEG_NAME"
  [[ -L "$opt" ]] && basename "$(readlink "$opt")" || true
}
is_pinned()  { brew list --pinned 2>/dev/null | grep -qx "$KEG_NAME"; }
agent_pid()  { launchctl print "$DOM/$1" 2>/dev/null | awk '/^[[:space:]]*pid = / {print $3; exit}' || true; }
loaded()     { launchctl print "$DOM/$1" >/dev/null 2>&1; }

# anchor_for VERSION: newest tap commit whose formula mentions that exact version.
anchor_for() {
  local v="$1" c
  while read -r c; do
    # whole version only: 26.10.3 must not match 26.10.31 or 126.10.3
    if git -C "$TAP_DIR" show "$c:$TAP_FILE" 2>/dev/null | grep -qE "(^|[^0-9.])${v//./\\.}([^0-9]|\\.[^0-9]|$)"; then echo "$c"; return 0; fi
  done < <(git -C "$TAP_DIR" log --format=%H -- "$TAP_FILE")
  return 1
}

# source_reachable COMMIT: is the download the formula at COMMIT points to still there?
source_reachable() {
  local rb url tag code
  rb="$(git -C "$TAP_DIR" show "$1:$TAP_FILE")"
  url="$(grep -m1 -E '^[[:space:]]*url "' <<<"$rb" | sed -E 's/^[[:space:]]*url "([^"]+)".*/\1/')"
  tag="$(grep -m1 -oE 'tag:[[:space:]]*"[^"]+"' <<<"$rb" | sed -E 's/.*"([^"]+)"/\1/' || true)"
  [[ -n "$url" ]] || { echo "no url line"; return 1; }
  if [[ -n "$tag" || "$url" == *.git ]]; then
    git ls-remote --exit-code "$url" "refs/tags/${tag:-}" >/dev/null 2>&1 \
      && { echo "git tag ${tag:-?} present"; return 0; } || { echo "git tag ${tag:-?} NOT found at $url"; return 1; }
  fi
  code="$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 20 "$url" || true)"
  [[ "$code" == 200 ]] && { echo "download answers 200"; return 0; } || { echo "download answers ${code:-no response}: $url"; return 1; }
}

# install_kind COMMIT: bottle (download) or source build, for the formula at COMMIT.
install_kind() {
  if git -C "$TAP_DIR" show "$1:$TAP_FILE" 2>/dev/null | grep -qE '^[[:space:]]*bottle do'; then echo "bottle (download)"
  else echo "source build (compiles locally; slow, needs the Xcode tools)"; fi
}

capture_help() {   # capture_help VERSION: save --help, or a marker when the binary is missing
  if [[ -x "$SERVE_BIN" ]]; then "$SERVE_BIN" --help >"$LOG_DIR/help-$1.txt" 2>&1 || true
  else echo "NOT CAPTURED: $SERVE_BIN missing" >"$LOG_DIR/help-$1.txt"; fi
}

audit_env_vars() {   # MLX_SERVE_* settings that a release may have retired
  local f hits=0
  for f in "$AGENT_DIR/$FLASH_LABEL.plist" "$AGENT_DIR/$GEMMA_LABEL.plist" "$HOME/.config/macllm.env" \
           "$FLASH_UP" "$REPO"/m5/launchd/*.template "$REPO"/m5/launchd/system/*; do
    [[ -f "$f" ]] || continue
    if grep -n 'MLX_SERVE_' "$f" >/dev/null 2>&1; then
      grep -n 'MLX_SERVE_' "$f" | sed "s|^|  $(tilde "$f"):|"; hits=1
    fi
  done
  [[ $hits == 0 ]] && echo "  none set (plists, macllm.env, flash-up.sh, repo launchd templates)"
  return 0
}

# ---------- read state ----------
if [[ "${NO_UPDATE:-0}" != 1 ]]; then
  say "brew update"
  brew update --quiet >>"$LOG" 2>&1 || echo "  brew update failed (see log); using the tap as it is"
fi
INSTALLED="$(linked_version)"
[[ -n "$INSTALLED" ]] || die "$FORMULA is not installed (or not linked)"
STABLE="$(brew info --formula --json=v2 "$FORMULA" | jq -r '.formulae[0].versions.stable')"
[[ -n "$STABLE" && "$STABLE" != null ]] || die "could not read the tap's stable version"
TARGET="${TARGET:-$STABLE}"
WAS_PINNED=0; is_pinned && WAS_PINNED=1
ANCHOR="$(anchor_for "$INSTALLED" || true)"

echo "  installed $INSTALLED$([[ $WAS_PINNED == 1 ]] && echo ' (pinned)')  ->  target $TARGET  (tap stable $STABLE)"
if [[ -n "$ANCHOR" ]]; then
  echo "  rollback anchor for $INSTALLED: tap commit ${ANCHOR:0:10} ($(source_reachable "$ANCHOR" || true)); installs as $(install_kind "$ANCHOR")"
else
  echo "  rollback anchor for $INSTALLED: NOT FOUND in the tap history (rollback would need a manual formula)"
fi
if [[ "$TARGET" != "$STABLE" ]]; then
  TARGET_ANCHOR="$(anchor_for "$TARGET" || true)"
  [[ -n "$TARGET_ANCHOR" ]] || die "no tap commit has a formula for $TARGET"
  echo "  target $TARGET comes from tap commit ${TARGET_ANCHOR:0:10} ($(source_reachable "$TARGET_ANCHOR" || true)); installs as $(install_kind "$TARGET_ANCHOR")"
fi

if [[ "$MODE" == check ]]; then
  say "MLX_SERVE_* settings in use (a new release may have retired some):"
  audit_env_vars
  for l in "${LABELS[@]}"; do echo "  $l: $(loaded "$l" && echo "loaded, pid $(agent_pid "$l")" || echo "not loaded")"; done
  echo "  if a run is ever interrupted: brew pin $FORMULA; git -C $(tilde "$TAP_DIR") checkout -- $TAP_FILE"
  [[ "${NO_UPDATE:-0}" == 1 ]] || echo "  (this check ran brew update; NO_UPDATE=1 skips it)"
  if [[ "$INSTALLED" == "$TARGET" ]]; then echo "Already on $TARGET. Nothing changed."; else echo "Would install $TARGET. Nothing changed (--check)."; fi
  exit 0
fi

if [[ "$INSTALLED" == "$TARGET" && "${FORCE:-0}" != 1 ]]; then
  echo "Already on $TARGET. Nothing to do (FORCE=1 to reinstall)."; exit 0
fi
[[ -x "$FLASH_UP" ]] || die "$(tilde "$FLASH_UP") not found or not executable"
for l in "${LABELS[@]}"; do [[ -f "$AGENT_DIR/$l.plist" ]] || die "missing $(tilde "$AGENT_DIR/$l.plist")"; done

# ---------- from here on, always leave the tap clean and the formula pinned ----------
TAP_DIRTY=0
cleanup() {
  local rc=$?
  if [[ $TAP_DIRTY == 1 ]]; then git -C "$TAP_DIR" checkout -q HEAD -- "$TAP_FILE" && echo "  tap formula restored to HEAD"; fi
  if [[ $WAS_PINNED == 1 || "${PIN_AFTER:-1}" == 1 ]] && [[ -n "$(linked_version)" ]] && ! is_pinned; then
    brew pin "$FORMULA" >>"$LOG" 2>&1 && echo "  re-pinned $KEG_NAME at $(linked_version)"
  fi
  echo "  log: $(tilde "$LOG")"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP   # turn signals into an exit so the EXIT trap runs

capture_help "$INSTALLED"

OLD_PIDS=()   # indexed like LABELS (no associative arrays: macOS ships bash 3.2)
for i in "${!LABELS[@]}"; do OLD_PIDS[$i]="$(agent_pid "${LABELS[$i]}")"; done

say "Stopping Flash and Gemma (the models unload; up to ${STOP_WAIT}s each)"
for i in "${!LABELS[@]}"; do
  l="${LABELS[$i]}"
  if loaded "$l"; then
    launchctl bootout "$DOM/$l" || echo "  bootout $l returned $?"
    for _ in $(seq 1 $((STOP_WAIT * 2))); do loaded "$l" || break; sleep 0.5; done
    if loaded "$l"; then die "$l still loaded after ${STOP_WAIT}s; nothing was changed. Start again: OWUI_LABEL= $(tilde "$FLASH_UP")"; fi
    # bootout can drop the job from the domain before the process has exited and released its port
    if [[ -n "${OLD_PIDS[$i]:-}" ]]; then
      for _ in $(seq 1 $((STOP_WAIT * 2))); do kill -0 "${OLD_PIDS[$i]}" 2>/dev/null || break; sleep 0.5; done
      if kill -0 "${OLD_PIDS[$i]}" 2>/dev/null; then die "$l left launchd but pid ${OLD_PIDS[$i]} is still running after ${STOP_WAIT}s; nothing was changed. When it has exited: OWUI_LABEL= $(tilde "$FLASH_UP")"; fi
    fi
    echo "  $l stopped (was pid ${OLD_PIDS[$i]:-none})"
  else
    echo "  $l was not loaded"
  fi
done

restart_old() {
  echo "  starting the previous version again"
  OWUI_LABEL= "$FLASH_UP" >>"$LOG" 2>&1 && echo "  previous version is up" || echo "  flash-up failed too; see the log"
}

say "Installing $KEG_NAME $TARGET (old keg kept on disk)"
[[ $WAS_PINNED == 1 ]] && { brew unpin "$FORMULA" >>"$LOG" 2>&1 || true; }
if [[ "$TARGET" == "$STABLE" ]]; then
  if [[ "$INSTALLED" == "$TARGET" ]]; then CMD=(reinstall); else CMD=(upgrade); fi
else
  git -C "$TAP_DIR" checkout -q "$TARGET_ANCHOR" -- "$TAP_FILE"; TAP_DIRTY=1
  CMD=(reinstall)
fi
if ! brew "${CMD[@]}" --formula "$FORMULA" >>"$LOG" 2>&1; then
  echo "  brew ${CMD[*]} failed (last lines of the log):"; tail -5 "$LOG" | sed 's/^/    /'
  restart_old
  die "install of $TARGET failed; still on $(linked_version)"
fi
NEW="$(linked_version)"
[[ "$NEW" == "$TARGET" ]] || { restart_old; die "brew finished but $NEW is linked, not $TARGET"; }
echo "  now on $NEW"
capture_help "$NEW"

say "Starting Flash and Gemma with $(tilde "$FLASH_UP") (Open WebUI untouched)"
if ! OWUI_LABEL= "$FLASH_UP" 2>&1 | tee -a "$LOG" | sed 's/^/  /'; then
  echo
  echo "The servers did not come up on $NEW."
  echo "Logs:      ~/.mlx-serve/logs/mlx-serve-11234.log, ~/.mlx-serve/logs/mlx-serve-11235.log"
  echo "Flag diff: diff $(tilde "$LOG_DIR/help-$INSTALLED.txt") $(tilde "$LOG_DIR/help-$NEW.txt")"
  echo "Roll back: $(basename "$0") $INSTALLED   (re-fetches; see --check for bottle or source build)"
  echo "Emergency, unsupported, instant (old keg is still on disk):"
  echo "  ln -sfn $(brew --prefix)/Cellar/$KEG_NAME/$INSTALLED/bin/mlx-serve $(brew --prefix)/bin/mlx-serve && OWUI_LABEL= $(tilde "$FLASH_UP")"
  exit 1
fi

say "Restart proof (a new process must have a new PID)"
for i in "${!LABELS[@]}"; do
  l="${LABELS[$i]}"; p="$(agent_pid "$l")"
  if [[ -z "$p" ]]; then echo "  $l: NO PID"; exit 1; fi
  if [[ "$p" == "${OLD_PIDS[$i]:-}" ]]; then echo "  $l: pid $p UNCHANGED"; exit 1; fi
  echo "  $l: pid ${OLD_PIDS[$i]:-none} -> $p"
done

if grep -q '^NOT CAPTURED' "$LOG_DIR/help-$INSTALLED.txt" "$LOG_DIR/help-$NEW.txt"; then
  echo "  note: mlx-serve --help was not captured for one version, so flag changes were not compared"
elif ! diff -q "$LOG_DIR/help-$INSTALLED.txt" "$LOG_DIR/help-$NEW.txt" >/dev/null 2>&1; then
  echo "  note: mlx-serve --help changed; see: diff $(tilde "$LOG_DIR/help-$INSTALLED.txt") $(tilde "$LOG_DIR/help-$NEW.txt")"
fi
echo "✓ mlx-serve $INSTALLED -> $NEW, both servers up. Roll back with: $(basename "$0") $INSTALLED"
echo "  Next: llm-bench.py (solo, Flash and Gemma), llm-compare.py run --label mlx-$NEW, then the docs and owui-memories.py."
