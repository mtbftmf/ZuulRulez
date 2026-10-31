#!/bin/bash
#
# macos-service-toggle.sh
#
# ==============================================================================
# BEFORE YOU RUN THIS: this list was built for one specific machine's usage
# profile (an LLM-hosting Mac Studio with iCloud/Messages/Siri/Apple
# Intelligence/games unused). It is a STARTING TEMPLATE, not a safe default
# for every Mac. Running it as-is on a machine with a different usage
# profile can disable features you actually rely on.
#
# Read through SERVICE_DATA below — it's grouped into commented sections by
# feature (Siri, iCloud, Messages, Apple Intelligence, etc.). For each
# section, decide whether you use that feature on THIS machine, and delete
# or comment out (leading #) the lines in any section you use before running
# `on`. If you were handed a companion checklist document alongside this
# script, work through that first — it turns this into a short list of
# yes/no questions instead of requiring you to know what each label does.
#
# Never disable anything you're not sure about just because it's in this
# list — when in doubt, leave it out and test later once you know more.
# ==============================================================================
#
# Disables/re-enables non-essential macOS background services that macOS
# updates tend to reset. Idempotent, tracks its own state so "off" only
# restores what this script actually changed, and separates the sudo
# (system domain) path from the per-user (gui/user domain) path so it
# works correctly whether invoked with or without sudo.
#
# Usage:
#   sudo ./macos-service-toggle.sh on                              # disable services
#   sudo ./macos-service-toggle.sh off                             # restore everything this script changed
#   sudo ./macos-service-toggle.sh status                          # read-only: compare recorded state to live launchctl state
#   sudo ./macos-service-toggle.sh on --dry-run                    # show what would happen, change nothing
#   sudo ./macos-service-toggle.sh on --yes                        # skip the high-risk confirmation prompt
#   sudo ./macos-service-toggle.sh on --gpu-limit-mb=57344         # raise GPU wired memory limit
#   sudo ./macos-service-toggle.sh on --model-dir=/path/to/models  # exclude dir from Spotlight indexing
#
# Notes:
#   - System-domain services need sudo. GUI/user-domain agents must run as
#     the actual logged-in user, not root, so the script re-execs those
#     calls via `sudo -u <real user>` even when the script itself is root.
#   - Some system-domain services may require SIP to be disabled to be
#     unloadable; you'll see [X] for those and can leave them as-is.
#   - --gpu-limit-mb and --model-dir are independent of the service list:
#     each is only applied if you pass it, and "off" reverses only what
#     was actually recorded, so adding services later doesn't touch these.
#   - Neither of these installs a daemon; they're one-shot sysctl/mdutil
#     calls, so a bad service change and a bad GPU limit are decoupled —
#     "off" cleanly reverses one without needing the other.
#   - PROTECTED_SERVICES below is a hard safety net: those services are
#     refused (logged as [BLOCKED]) even if they end up back in SERVICE_DATA
#     by accident. Editing the service list can't override this list.
#   - --gpu-limit-mb warns and asks to confirm if the requested value would
#     leave less than 6GB of headroom for the OS + apps on this machine.

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run with sudo (needed for system-domain launchctl"
    echo "calls and for writing state to /usr/local/var). Re-run as:"
    echo "  sudo $0 $*"
    exit 1
fi

STATE_DIR="/usr/local/var/macos-service-toggle"
STATE_FILE="$STATE_DIR/disabled.state"
EXTRAS_STATE_FILE="$STATE_DIR/extras.state"
LOG_FILE="$STATE_DIR/toggle.log"

DRY_RUN=0
ASSUME_YES=0
GPU_LIMIT_MB=""
MODEL_DIR=""

# ------------------------------------------------------------------------------
# SERVICE DATA BLOCK
# Format: service_id|description
#
# DO NOT run this list as-is on a machine you haven't audited. Every group
# below corresponds to a real macOS feature. If you use that feature on THIS
# machine, delete or comment out (leading #) the lines in that group before
# running `on`. See the accompanying checklist document for a walkthrough —
# it maps each group to a plain-English "do you use this?" question.
#
# Lines starting with # are ignored, so you can comment a group out instead
# of deleting it if you want to keep the option visible for later.
# ------------------------------------------------------------------------------
SERVICE_DATA=$(cat <<'EOF'
# --- Siri, Spotlight Suggestions, predictive/proactive features ---
# Skip this whole group if you use "Hey Siri," Siri Shortcuts, Spotlight web
# suggestions, or rely on location/app-based proactive suggestions.
com.apple.siri.morphunassetsupdaterd|Siri speech recognition daemon
com.apple.siri.voiceShortcutHandler|Siri TTS voice downloads
com.apple.duetexpertd|Siri predictions/suggestions
com.apple.assistantd|Siri assistant framework
com.apple.siriactionsd|Siri actions/shortcuts
com.apple.siriknowledged|Siri knowledge base
com.apple.knowledge-agent|Siri/Spotlight knowledge agent
com.apple.suggestd|Spotlight Suggestions
com.apple.coreduetd|Siri prediction/context daemon
com.apple.contextstored|Context store (Siri predictions backend)
com.apple.recentsd|Recent items/contacts suggestions
com.apple.proactived|Proactive Siri suggestions
com.apple.peopled|People/contacts suggestions daemon
com.apple.contentlinkingd|Content linking (Siri/Spotlight cross-referencing)
com.apple.audioanalyticsd|"Hey Siri" audio detection analysis
com.apple.followupd|Siri follow-up reminders
com.apple.spotlightknowledged|Spotlight web/knowledge suggestions updater
com.apple.routined|Significant Locations / predictive routines

# --- iCloud (Photos, Contacts/Calendar sync, iCloud Drive, Find My) ---
# Skip this group if you use ANY iCloud sync feature on this machine.
com.apple.cloudd|CloudKit daemon
com.apple.bird|iCloud Drive sync
com.apple.itunescloudd|iTunes/Music cloud sync
com.apple.amsengagementd|Apple Media Services engagement
com.apple.amsaccountsd|Apple Media Services accounts
com.apple.amsondevicestoraged|Apple Media on-device storage sync
com.apple.appleaccountd|Apple ID account daemon
com.apple.appleaccounttransparencyd|Apple ID transparency reporting
com.apple.swcd|iCloud shared web credentials
com.apple.swtransparencyd|iCloud shared web credentials transparency
com.apple.findmylocateagent|Find My location agent
com.apple.privatecloudcomputed|Apple Intelligence Private Cloud Compute

# --- Apple Intelligence (Writing Tools, Image Playground, Genmoji) ---
com.apple.intelligenceplatformd|Apple Intelligence platform daemon
com.apple.intelligencecontextd|Apple Intelligence context service
com.apple.generativeexperiencesd|Apple Intelligence generative features

# --- macOS 27 "Golden Gate" Siri AI (redesigned conversational Siri) ---
# Verified live against an actual Golden Gate system via
# `sudo -u <user> launchctl list | grep -iE "siri|intelligen|generativ|privatecloud|assistant"`
# rather than guessed — Golden Gate's Siri AI has a much larger process
# footprint than legacy Siri. Two grep matches from that command are
# DELIBERATELY excluded below; do not add them without a specific reason:
#   com.apple.unmountassistant.useragent - NOT Siri/AI at all. This is the
#     "safely eject this drive" warning system. Grep matched "assistant."
#   com.apple.intelligentroutingd - observed running on a machine with zero
#     Apple Intelligence involvement; almost certainly network path/
#     multipath routing optimization, coincidentally named. Same class of
#     false match as com.apple.mediaanalysi vs. mediaanalysisd earlier in
#     this project. Left out rather than risk disabling real networking.
com.apple.assistant_service|Siri assistant service (Golden Gate)
com.apple.intelligencetasksd|Apple Intelligence task engine
com.apple.SiriTTSTrainingAgent|Siri voice training agent
com.apple.callintelligenced|Call-related AI features (e.g. Live Translation/Call Screening)
com.apple.AddressBook.AssistantService|Contacts-related Siri/AI assistant service
com.apple.siri.context.service|Siri context service
com.apple.intelligenceflowd|Apple Intelligence flow runtime
com.apple.siriappintentsd|Siri App Intents runtime
com.apple.assistant_cdmd|Continuous "Hey Siri" dialog manager
com.apple.GenerativeFunctions.agentstored|Generative Functions agent store
com.apple.siriinferenced|On-device Siri AI inference engine
com.apple.visualintelligenced|Visual Intelligence (camera/photo AI lookup)
com.apple.sirittsd|Siri text-to-speech synthesis
com.apple.knowledgeconstructiond|Siri AI knowledge construction (Golden Gate)

# NOTE: several Golden Gate Siri AI surfaces run as ExtensionKit .appex/.xpc
# extensions (SiriAUSP, SiriSetupSettingsIntents, SAExtensionOrchestrator,
# AppleIntelligenceReportingSELFIngestor/ProcessingService,
# SiriSuggestionsBookkeepingService) rather than classic LaunchAgents.
# Confirmed via launchctl list across system/gui/user domains: none of them
# have an addressable launchd label. There is no `launchctl disable` lever
# for these — they can't be reached this way. The only control surface is
# the OS-level Siri/Apple Intelligence toggle in System Settings. Don't
# waste time hunting for a label; it doesn't exist.

# --- Messages / FaceTime / Business Chat ---
# Skip this group if you send/receive iMessages or take FaceTime calls here.
com.apple.CommCenter|Cellular/telephony service center
com.apple.avconferenced|FaceTime conferencing
com.apple.callservicesd|Phone/FaceTime call services
com.apple.identityservicesd|Messages/iMessage identity services
com.apple.imagent|Messages iMessage agent
com.apple.businessservicesd|Business Chat (Messages)
com.apple.coretelephony|CallKit / phone calls on Mac
com.apple.groupsessions|SharePlay / FaceTime SharePlay

# --- Continuity / Handoff / AirDrop between your own devices ---
# IMPORTANT: com.apple.rapportd is deliberately NOT in this list. Disabling
# it silently breaks inbound AirDrop and Universal Control mouse/keyboard
# sharing while leaving outbound AirDrop working — an easy thing to miss
# until you actually need the feature. Do not add it back without testing
# both directions of AirDrop and Universal Control afterward.
#
# com.apple.ecosystemd is lower-risk than rapportd even if you use
# Continuity — it's telemetry/analytics adjacent to the feature, not the
# transport layer itself (its sibling, com.apple.ecosystemanalyticsd, is
# in the Telemetry group below). Test Handoff/Universal Clipboard after
# disabling rather than assuming, same as anything else in this group.
com.apple.ecosystemd|Continuity ecosystem analytics (not the AirDrop/Handoff transport itself)

# --- HomeKit / Home app ---
com.apple.homed|Home app / HomeKit

# --- Family Sharing ---
com.apple.familycircled|Family Sharing daemon

# --- Health / Fitness ---
com.apple.healthd|Fitness tracking

# --- Games ---
# Skip if you use a game controller (Xbox/PlayStation/MFi) on this machine.
com.apple.gamemode|Game Mode (macOS Sonoma+)
com.apple.gamepolicyd|Game policy daemon

# --- Apple content apps you may not use (Podcasts, Books, TV, Music store) ---
com.apple.podcastsd|Podcast sync
com.apple.tvstoreagent|TV app data
com.apple.musicstoreagent|Music/iTunes store agent
com.apple.iBooksX|Book store agent
com.apple.music.subscription|Music subscription agent
com.apple.musicd|Music daemon
com.apple.commerce|App Store purchase/commerce background agent
com.apple.promotedcontentd|App Store promoted content delivery

# --- Misc apps/features you may not use ---
com.apple.educationd|Classroom/MDM education features
com.apple.AEServer|Remote Apple Events -- also in HIGH_RISK, confirmed at runtime
com.apple.weatherd|Weather daemon
com.apple.journald|Journal app
com.apple.freeform.agent|Freeform app sync
com.apple.remindd|Reminders sync
com.apple.notes.storaged|Notes sync
com.apple.printd|AirPrint
com.apple.translated|Translate app
com.apple.safariLaunchAgent|Safari Push Notifications
com.apple.PencilUIService|Handwriting recognition
com.apple.RealityComposer|Reality Composer / AR
com.apple.mediaanalysisd|Media analysis (Photos/Spotlight indexing)

# --- Telemetry / analytics / diagnostics ---
# Generally safe to disable regardless of use case, since these are
# one-directional reporting to Apple, not features you interact with.
com.apple.analyticsd|Analytics/diagnostics reporting -- also in HIGH_RISK, confirmed at runtime
com.apple.mobileassetd|Mobile asset downloads (fonts, dictionaries, some update assets) -- also in HIGH_RISK
com.apple.analyticsagent|Per-user analytics agent
com.apple.ecosystemanalyticsd|Ecosystem analytics
com.apple.geoanalyticsd|Location analytics
com.apple.cloudtelemetryservice|Cloud telemetry service
com.apple.usagetrackingagent|Usage tracking
com.apple.triald|Apple internal A/B-test/experiment framework
com.apple.triald_system|Apple internal A/B-test/experiment framework (system)

# --- Local network / caching ---
# Only matters on networks with a local Apple content-caching server
# (common in schools/enterprises); harmless to disable on a typical
# home or small-office network.
com.apple.AssetCacheLocatorService|Local content-caching server discovery
EOF
)

# Services that must never be disabled by this script, regardless of what
# ends up in SERVICE_DATA. This is a hard safety net independent of the
# editable list — the airportd mix-up (added back by accident more than
# once) is exactly the failure mode this exists to prevent.
# com.apple.watchdogd is the system watchdog (hang detection / recovery), not
# Apple Watch pairing as an earlier version of this list said. com.apple.rapportd
# carries inbound AirDrop and Universal Control. Both are protected here.
PROTECTED_SERVICES="
com.openssh.sshd
com.apple.MobileFileIntegrity
com.apple.containermanagerd.system
com.apple.audio.AudioComponentRegistrar
com.apple.XProtect.daemon.scan
com.apple.XprotectFramework.PluginService
com.apple.systemstatusd
com.apple.iconservices.iconservicesagent
com.apple.airportd
com.apple.accessoryd
com.apple.remotemanagementd
com.apple.backupd
com.apple.backupd-helper
com.apple.watchdogd
com.apple.rapportd
"

is_protected() {
    local service=$1
    for p in $PROTECTED_SERVICES; do
        [ "$service" = "$p" ] && return 0
        # sshd's real label has a per-host UUID suffix; match by prefix too
        case "$service" in "$p"*) return 0 ;; esac
    done
    return 1
}

# Services worth a second thought before disabling
HIGH_RISK="com.apple.coretelephony com.apple.mobileassetd com.apple.analyticsd com.apple.screensharing com.apple.AEServer"

usage() {
    echo "Usage: sudo $0 [on|off|status] [--dry-run] [--yes] [--gpu-limit-mb=N] [--model-dir=PATH]"
    echo "  on        Disable services (state is recorded)"
    echo "  off       Re-enable only the services this script disabled"
    echo "  status    Show current state vs. live launchctl state (read-only, no changes)"
    echo "  --dry-run       Show actions without making changes"
    echo "  --yes           Skip the high-risk / low-headroom confirmation prompts"
    echo "  --gpu-limit-mb  Set iogpu.wired_limit_mb (only with 'on'; reversed by 'off')"
    echo "  --model-dir     Exclude a directory from Spotlight indexing (only with 'on')"
    exit 1
}

log() {
    echo "$1"
    mkdir -p "$STATE_DIR" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE" 2>/dev/null
}

# Resolve the real logged-in user even when invoked via sudo, so GUI/user
# domain launchctl calls run in the correct session context instead of root's.
resolve_real_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        echo "$SUDO_USER"
    else
        stat -f%Su /dev/console
    fi
}

REAL_USER="$(resolve_real_user)"
REAL_UID="$(id -u "$REAL_USER" 2>/dev/null || echo 0)"

confirm_high_risk() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    echo "The following high-risk services are in the list and can affect"
    echo "calls/FaceTime, screen sharing, remote Apple events, or update/diagnostic delivery:"
    for s in $HIGH_RISK; do
        echo "$SERVICE_DATA" | grep -q "^$s|" && echo "  - $s"
    done
    read -r -p "Continue? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# Check whether a service is actually registered in a given domain.
# launchctl print returns non-zero and prints "Could not find service" if not.
domain_has_service() {
    local domain=$1 as_root=$2
    if [ "$as_root" -eq 1 ]; then
        sudo launchctl print "$domain" >/dev/null 2>&1
    else
        sudo -u "$REAL_USER" launchctl print "$domain" >/dev/null 2>&1
    fi
}

# Find which domain a service is actually registered in.
# Prints "system", "gui/<uid>", or "user/<uid>" on stdout; empty if not found anywhere.
find_domain() {
    local service=$1
    if domain_has_service "system/$service" 1; then
        echo "system"
    elif domain_has_service "gui/$REAL_UID/$service" 0; then
        echo "gui/$REAL_UID"
    elif domain_has_service "user/$REAL_UID/$service" 0; then
        echo "user/$REAL_UID"
    fi
}

# Try a launchctl action against a specific domain string, returns 0/1
try_domain() {
    local action=$1 target=$2 as_root=$3
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [DRY-RUN] launchctl $action $target"
        return 0
    fi
    if [ "$as_root" -eq 1 ]; then
        sudo launchctl "$action" "$target" 2>/dev/null
    else
        sudo -u "$REAL_USER" launchctl "$action" "$target" 2>/dev/null
    fi
}

# $1=action(disable/enable) $2=service $3=desc
# On success, prints the domain used via global LAST_DOMAIN
execute_action() {
    local action=$1 service=$2 desc=$3
    LAST_DOMAIN=""

    if [ "$action" = "disable" ] && is_protected "$service"; then
        log "    [BLOCKED] $service is on the protected list and will never be disabled by this script ($desc)"
        return 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        # Can't verify a domain we can't query safely without side effects
        # in dry-run against a live system; just show the intended target.
        LAST_DOMAIN="system (unverified, dry-run)"
        try_domain "$action" "system/$service" 1
        return 0
    fi

    local domain
    domain="$(find_domain "$service")"

    if [ -z "$domain" ]; then
        log "    [SKIP] $service not found in system, gui/$REAL_UID, or user/$REAL_UID — may not exist on this macOS version"
        return 1
    fi

    local as_root=0
    [ "$domain" = "system" ] && as_root=1

    if try_domain "$action" "$domain/$service" "$as_root"; then
        LAST_DOMAIN="$domain"
        log "    [OK] $action: $service ($desc) [domain: $domain, verified]"
        return 0
    fi

    log "    [X] Found $service in $domain but failed to $action it"
    return 1
}

set_gpu_limit() {
    local mb="$1"
    local prev already_recorded total_mb headroom_mb

    already_recorded="$(grep '^GPU_LIMIT_PREV_MB=' "$EXTRAS_STATE_FILE" 2>/dev/null | tail -1)"
    prev="$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"

    # Warn if the requested limit leaves thin headroom for the OS + apps.
    # GPU wired memory is non-pageable, so too little headroom causes gradual
    # swap growth under real load rather than an immediate, obvious failure.
    total_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
    if [ "$total_mb" -gt 0 ]; then
        headroom_mb=$(( total_mb - mb ))
        if [ "$headroom_mb" -lt 6144 ] && [ "$ASSUME_YES" -ne 1 ]; then
            echo "    WARNING: --gpu-limit-mb=$mb on a ${total_mb}MB system leaves only"
            echo "    ${headroom_mb}MB of headroom for the OS and apps. Under 6GB headroom"
            echo "    has previously caused gradually rising swap on this kind of setup"
            echo "    (not an immediate crash — watch 'memory_pressure' over hours, not"
            echo "    just at idle, if you proceed)."
            read -r -p "    Proceed with $mb anyway? [y/N] " reply
            [[ "$reply" =~ ^[Yy]$ ]] || { log "    Skipped GPU limit change (declined at low-headroom warning)"; return 1; }
        fi
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [DRY-RUN] sysctl iogpu.wired_limit_mb=$mb (current: $prev)"
        return 0
    fi

    if sudo sysctl "iogpu.wired_limit_mb=$mb" >/dev/null 2>&1; then
        # Only record the ORIGINAL value the first time; re-running 'on' with a
        # new limit must not overwrite it with an already-raised value, or
        # 'off' would restore to the wrong baseline.
        if [ -z "$already_recorded" ]; then
            echo "GPU_LIMIT_PREV_MB=$prev" >> "$EXTRAS_STATE_FILE"
        fi
        log "    [OK] iogpu.wired_limit_mb set to $mb (was $prev)"
        log "    NOTE: not persisted across reboot. To persist, add"
        log "          'iogpu.wired_limit_mb=$mb' to /etc/sysctl.conf yourself"
        log "          after confirming stability — this script won't do that automatically."
    else
        log "    [X] Failed to set iogpu.wired_limit_mb"
        return 1
    fi
}

restore_gpu_limit() {
    local prev
    prev="$(grep '^GPU_LIMIT_PREV_MB=' "$EXTRAS_STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2)"
    [ -z "$prev" ] && return 0

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [DRY-RUN] sysctl iogpu.wired_limit_mb=$prev"
        return 0
    fi
    if sudo sysctl "iogpu.wired_limit_mb=$prev" >/dev/null 2>&1; then
        log "    [OK] iogpu.wired_limit_mb restored to $prev"
    else
        log "    [X] Failed to restore iogpu.wired_limit_mb"
    fi
}

set_mdutil_exclude() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        log "    [X] --model-dir '$dir' does not exist, skipping"
        return 1
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [DRY-RUN] mdutil -i off '$dir'"
        return 0
    fi
    if sudo mdutil -i off "$dir" >/dev/null 2>&1; then
        if ! grep -qF "MDUTIL_DIR=$dir" "$EXTRAS_STATE_FILE" 2>/dev/null; then
            echo "MDUTIL_DIR=$dir" >> "$EXTRAS_STATE_FILE"
        fi
        log "    [OK] Spotlight indexing disabled for $dir"
    else
        log "    [X] Failed to disable Spotlight indexing for $dir"
        return 1
    fi
}

restore_mdutil() {
    [ -f "$EXTRAS_STATE_FILE" ] || return 0
    while IFS='=' read -r key dir; do
        [ "$key" = "MDUTIL_DIR" ] || continue
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "    [DRY-RUN] mdutil -i on '$dir'"
            continue
        fi
        if sudo mdutil -i on "$dir" >/dev/null 2>&1; then
            log "    [OK] Spotlight indexing re-enabled for $dir"
        else
            log "    [X] Failed to re-enable Spotlight indexing for $dir"
        fi
    done < "$EXTRAS_STATE_FILE"
}

do_on() {
    log "Starting: disabling services (real user: $REAL_USER, uid: $REAL_UID)"
    [ "$DRY_RUN" -eq 1 ] && log "(dry run, no changes will be made)"
    confirm_high_risk || { echo "Aborted."; exit 1; }

    mkdir -p "$STATE_DIR"
    [ "$DRY_RUN" -eq 1 ] || : > "$STATE_FILE.new"

    while IFS='|' read -r service desc; do
        [ -z "$service" ] && continue
        case "$service" in \#*) continue ;; esac
        if execute_action "disable" "$service" "$desc"; then
            [ "$DRY_RUN" -eq 1 ] || echo "$service|$LAST_DOMAIN|$desc" >> "$STATE_FILE.new"
        fi
    done <<< "$SERVICE_DATA"

    if [ "$DRY_RUN" -eq 0 ]; then
        mv "$STATE_FILE.new" "$STATE_FILE"
        log "State written to $STATE_FILE"
    fi

    if [ -n "$GPU_LIMIT_MB" ]; then
        set_gpu_limit "$GPU_LIMIT_MB"
    fi
    if [ -n "$MODEL_DIR" ]; then
        set_mdutil_exclude "$MODEL_DIR"
    fi

    log "Done."
}

do_off() {
    if [ ! -f "$STATE_FILE" ]; then
        log "No state file at $STATE_FILE — nothing to restore (or 'on' was never run)."
        exit 0
    fi
    log "Restoring services recorded in $STATE_FILE"

    while IFS='|' read -r service domain desc; do
        [ -z "$service" ] && continue
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "    [DRY-RUN] launchctl enable $domain/$service"
            continue
        fi
        if [[ "$domain" == "system" ]]; then
            if launchctl enable "system/$service" 2>/dev/null; then
                log "    [OK] enable: $service ($desc) [domain: system]"
            else
                log "    [X] Failed to enable $service (system)"
            fi
        else
            if sudo -u "$REAL_USER" launchctl enable "$domain/$service" 2>/dev/null; then
                log "    [OK] enable: $service ($desc) [domain: $domain]"
            else
                log "    [X] Failed to enable $service ($domain)"
            fi
        fi
    done < "$STATE_FILE"

    [ "$DRY_RUN" -eq 1 ] || rm -f "$STATE_FILE"

    restore_gpu_limit
    restore_mdutil
    [ "$DRY_RUN" -eq 1 ] || rm -f "$EXTRAS_STATE_FILE"

    log "Done. Restored state cleared."
}

do_status() {
    echo "Real user: $REAL_USER (uid: $REAL_UID)"
    echo

    if [ ! -f "$STATE_FILE" ]; then
        echo "No state file — 'on' has not been run, or 'off' cleared it."
    else
        echo "Services recorded as disabled by this script (verifying against live launchctl state):"
        # Read into an array first rather than looping with `< "$STATE_FILE"` directly —
        # that pattern previously produced spurious "not found" results for every
        # entry, most likely from stdin contention between the loop's redirect and
        # the launchctl/grep calls inside it. Reading to an array first removes any
        # possibility of that interaction, regardless of the exact mechanism.
        # NOTE: mapfile is bash 4+; macOS ships bash 3.2, so build the array manually.
        _status_lines=()
        while IFS= read -r _line || [ -n "$_line" ]; do
            _status_lines+=("$_line")
        done < "$STATE_FILE"
        for _line in "${_status_lines[@]}"; do
            IFS='|' read -r service domain desc <<< "$_line"
            [ -z "$service" ] && continue
            local disabled_output
            if [[ "$domain" == "system" ]]; then
                disabled_output="$(launchctl print-disabled system 2>/dev/null | grep -F "\"$service\"")"
            else
                disabled_output="$(sudo -u "$REAL_USER" launchctl print-disabled "$domain" 2>/dev/null | grep -F "\"$service\"")"
            fi
            if echo "$disabled_output" | grep -q "=> disabled"; then
                echo "  [still disabled]  $service ($desc) [domain: $domain]"
            elif [ -n "$disabled_output" ]; then
                echo "  [DRIFTED - now enabled]  $service ($desc) [domain: $domain]  <-- was disabled, isn't anymore"
            else
                echo "  [unknown/not found]  $service ($desc) [domain: $domain]"
            fi
        done
    fi

    echo
    if [ -f "$EXTRAS_STATE_FILE" ]; then
        echo "Extras state (GPU limit / Spotlight exclusion):"
        cat "$EXTRAS_STATE_FILE" | sed 's/^/  /'
        echo "  Current iogpu.wired_limit_mb: $(sysctl -n iogpu.wired_limit_mb 2>/dev/null)"
    else
        echo "No extras state recorded (GPU limit / Spotlight exclusion not set by this script, or already reverted)."
    fi

    echo
    echo "Protected services (never touched by this script, checked regardless of state file):"
    for p in $PROTECTED_SERVICES; do
        [ -z "$p" ] && continue
        echo "  $p"
    done
}

# ------------------------------------------------------------------------------
# Arg parsing
# ------------------------------------------------------------------------------
[ $# -eq 0 ] && usage
ACTION="$1"; shift
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --yes) ASSUME_YES=1 ;;
        --gpu-limit-mb=*) GPU_LIMIT_MB="${arg#*=}" ;;
        --model-dir=*) MODEL_DIR="${arg#*=}" ;;
        *) usage ;;
    esac
done

case "$ACTION" in
    on) do_on ;;
    off) do_off ;;
    status) do_status ;;
    *) usage ;;
esac
