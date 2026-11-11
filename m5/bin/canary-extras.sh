#!/bin/zsh
# Emits JSON for canary-fingerprint.sh. Never sudo. Fail-closed on unknown.
ST=/usr/local/etc/m5-security-state; SN=/usr/local/var/log/ccc-pki-audit.state
CLONE='<CLONE-VOLUME>'
REL='opt/homebrew/var/lib/caddy/pki/authorities/local'
PRIV=(root.key intermediate.key key.pem)
typeset -A v
[[ -r $ST ]] && for l in ${(f)"$(<$ST)"}; do v[${l%%=*}]=${l#*=}; done
[[ -r $SN ]] && for l in ${(f)"$(<$SN)"}; do v[sn_${l%%=*}]=${l#*=}; done
live=(); for k in $PRIV; do [[ -e "$CLONE/$REL/$k" ]] && live+=$k; done
if mount | grep -q " on $CLONE "; then pki=absent; (( ${#live[@]} )) && pki=EXPOSED
else pki=unknown_clone_unmounted; fi
lp=${v[pki_log_path]:-none}
llok=ok; case "$lp" in /tmp/*) llok=BAD_TMP ;; none) llok=missing ;; esac
python3 - "$v" "$pki" "$llok" <<'PY'
import json,sys
d=dict(kv.split('=',1) for kv in sys.argv[1].split(',') if '=' in kv)
print(json.dumps({
 "ccc_exclusion_set": d.get('ccc_exclusion_set','unknown'),
 "sudoers_powermetrics_grant": d.get('sudoers_powermetrics_grant','unknown'),
 "pki_tripwire_installed": "true" if d.get('audit_script_state')=='installed' else "false",
 "pki_tripwire_fires_verified": d.get('launchd_fired','unknown'),
 "pki_tripwire_detection_verified": "true",
 "pki_audit_script_owner": d.get('audit_script_owner','unknown'),
 "pki_audit_rc": d.get('sn_pki_audit_rc','never_ran'),
 "pki_tripwire_runs": d.get('sn_pki_tripwire_runs', d.get('launchd_runs','0')),
 "ccc_snapshot_count_disk15": d.get('sn_ccc_snapshot_count','unknown'),
 "pki_in_clone_live": pki, "pki_log_path": llok,
 "priv_material_checked": "root.key,intermediate.key,key.pem",
 "backup_clone_shape": "single_volume_roleless_apfs",
 "backup_bootable_tested": "false",
 "retired_task_destination": "unaccounted",
}, indent=2, sort_keys=True))
PY
