# M5 Max: local HTTPS for Open WebUI and the System Monitor

Applies ONLY to the M5 Max Studio. Set up 2026-10-25.

Browsers (Chrome with Google Advanced Protection in particular) warn on every visit to the plain
HTTP pages. Caddy terminates TLS in front of them with its own local certificate authority; the
HTTP ports keep working.

| Service | HTTPS | Backend |
| --- | --- | --- |
| Open WebUI | `https://STUDIO-HOSTNAME.local:8443`, `https://STUDIO-LAN-IP:8443` | `127.0.0.1:8080` |
| System Monitor | `https://STUDIO-HOSTNAME.local:9443`, `https://STUDIO-LAN-IP:9443` | `127.0.0.1:9090` |

`STUDIO-HOSTNAME` is `scutil --get LocalHostName`; `STUDIO-LAN-IP` is the Studio's Ethernet
address. Keep the real values in `/opt/homebrew/etc/Caddyfile` only (never commit them).

## Install (Studio)

```
brew install caddy
cp ~/ZuulRulez/m5/config/Caddyfile.example /opt/homebrew/etc/Caddyfile
```

Replace `STUDIO-HOSTNAME` and `STUDIO-LAN-IP` in `/opt/homebrew/etc/Caddyfile`, then:

```
caddy fmt --overwrite /opt/homebrew/etc/Caddyfile
caddy validate --config /opt/homebrew/etc/Caddyfile
brew services start caddy
```

- `auto_https disable_redirects` keeps Caddy off port 80.
- As a Homebrew service Caddy keeps its data in `/opt/homebrew/var/lib/caddy`; the CA root is
  `/opt/homebrew/var/lib/caddy/pki/authorities/local/root.crt`. Never copy `root.key` anywhere.
- Caddy's admin API listens on `127.0.0.1:2019` only.
- After editing the Caddyfile: `brew services restart caddy`.

## Trust the CA (once per device)

The System keychain covers every account on a Mac, guest accounts included.

| Device | How |
| --- | --- |
| A Mac (including the Studio) | Copy `root.crt` (scp or AirDrop), then `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain caddy-root.crt` **in a session with a screen** (local or Screen Sharing/ARD). Over SSH it fails with "authorization was denied since no user interaction was possible", and `caddy trust` fails the same way. Check: `security verify-cert -c caddy-root.crt` |
| Windows | Admin PowerShell: `certutil -addstore -f Root caddy-root.crt`, then quit Chrome/Edge completely |
| iPhone / iPad | AirDrop the file, install the profile, then Settings → General → About → Certificate Trust Settings → on |
| ChromeOS | Open `chrome://certificate-manager/localcerts/usercerts` (Local certificates → Installed by you), press **Import** under **Trusted Certificates** and pick `caddy-root.crt`. Do not use "Your certificates → Import and bind to user": that is for client certificates (a PKCS#12 file with a private key), not for a CA root. Check: the list shows `Caddy Local Authority - <year> ECC Root` with a fingerprint starting like the live root's |
| Android | Needs a screen lock. Settings → Security and privacy → More security settings → Install from device storage → CA certificate → Install anyway → pick `caddy-root.crt`. Check: View security certificates → User lists the Caddy root. Chrome uses it; most other apps ignore user-installed roots unless they opt in. Android shows a "network may be monitored" notice afterwards: that is normal for user-installed roots |
| Firefox (any OS) | Settings → Privacy & Security → Certificates → Import (own store) |

A device passes only on a chat message that is answered through the HTTPS link, not on `curl`: Open WebUI
chat is websocket-only and refuses an origin that is not in `CORS_ALLOW_ORIGIN`, so a reply proves the
origin and the certificate chain together. Compare the fingerprint of what you installed with
`openssl x509 -in root.crt -noout -fingerprint -sha256` on the Studio before trusting a copy: a stale root
with the same name looks identical in every device's list.

## Two networks: names only work on the Studio's network

The house has two subnets: Ethernet (the Studio) and a Wi-Fi network (MacBooks). Bonjour `.local`
names only resolve within one subnet, so from the Wi-Fi network `STUDIO-HOSTNAME.local` does not
resolve, while the Studio's IP is reachable through the router.

- The Studio's own Wi-Fi is **off** (`sudo networksetup -setairportpower en1 off`). With it on,
  the Studio announced both addresses and Wi-Fi clients picked the Wi-Fi one, which is not in the
  certificate.
- On Wi-Fi clients either use the IP links, or add a hosts entry so the name links work:
  `sudo sh -c 'printf "STUDIO-LAN-IP\tSTUDIO-HOSTNAME.local\n" >> /etc/hosts'`, then
  `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`. Windows:
  `C:\Windows\System32\drivers\etc\hosts`.
- Reserve the Studio's Ethernet address in the router's DHCP settings: the certificate and the
  hosts entries depend on it.
- Merging the two networks (old router in access-point mode) would make `.local` names work
  everywhere without hosts entries.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `ERR_CERT_AUTHORITY_INVALID` | This device does not trust the CA yet |
| `ERR_SSL_PROTOCOL_ERROR` / "sent an invalid response" | HTTPS sent to the plain HTTP port (8080 or 9090); use 8443 / 9443 |
| Name fails, IP works | Different subnet (Bonjour does not cross it): hosts entry or IP link |
| `curl -v https://STUDIO-HOSTNAME.local:8443` shows `SSL certificate verify ok` but the browser fails | The browser, not the setup: quit it fully and retry; Chrome's Secure DNS can also break `.local` names |

## Caddy PKI private material (added 2026-11-11)

This Caddy build writes its CA private keys as `root.key` and `intermediate.key`,
not `key.pem`. The staging warning in the handoff names `key.pem` as the private
file in the PKI directory; a detector written from that sentence checks a
filename that does not exist and reports clean on a copy holding the real CA key.
On this Studio the keys were found under the per-user data directory, not the
Homebrew one the first audit probed, and a full-volume clone copies both trees.

Private material must never reach backup media, and drift checking cannot see it:
the CA check in `m5-drift.sh` compares the SHA-256 of the keychain root against
the on-disk `root.crt` every 15 minutes with no sudo, and has no concept of a
private key at all. Carbon Copy Cloner APFS snapshots also retain deleted files,
so keys persist on a destination after the live files are removed.

Controls:

- Exclude the whole Caddy data directories from the boot-duplicate task's Ignore
  list (CCC UI; no CLI equivalent exists). They are regenerable runtime state, and
  excluding the whole directory also covers the leaf private keys under
  `certificates/local/`, which an entry for `pki` alone would miss:

      /opt/homebrew/var/lib/caddy
      /Users/<LOCAL-USERNAME>/Library/Application Support/Caddy
      /Users/<LOCAL-USERNAME>/Backups/caddy-pki-backup.zip.enc

  Type them exactly as listed, with your username in place of the placeholder; the
  gate's FAIL message prints the same three lines. An excluded clone restores
  without a CA, so a restored Studio needs `caddy trust` and an `m5-drift.sh
  snapshot` rebaseline. CCC writes the rules only when the task is saved in
  CCC writes the rules only when the task is saved in its window. The gate's
  `ccc_exclusion_set` asks CCC itself through
  `/usr/local/sbin/ccc-exclusion-verdict.py`, which opens the task store read-only
  and decodes each TASK `SETTINGS` binary plist with `plistlib` (`plutil -convert
  json` fails on the `<date>` values these carry). The rules are read from
  `rsync_filter.customFilterRules[].expressionString` and the boolean
  `rsync_filter.hasExclusions`. Tasks are enumerated by
  `sourceDisk.apfsVolumeGroupUUID`, never by searching the blob: `startupDiskUUID`
  holds the same value in every task created on this Mac, so a blob search counts
  tasks that clone other volumes. An earlier `sqlite3 instr()` search could not
  distinguish an exclusion from any other mention of a path and reported
  `named by 3 task rows` while one of the three sourced a RAID array.
  Every task cloning this volume is asked, because a sibling task with an empty
  Ignore list copies the CA key however the first task is configured. A failing
  probe prints `unreadable_or_unparsable`, never `not_set`, so a broken check
  cannot look like a missing rule. Offending task UUIDs go to
  `/usr/local/var/log/ccc-exclusion-offenders` and are named in the gate's FAIL.
  Re-run `m5-secops.sh refresh` after any change in the CCC window, and after any
  edit to the verdict tool re-run `m5-secops.sh install`: root executes only the
  root:wheel copy, never this file.

- Destination verification is a Terminal action, not a daemon action. The
  LaunchDaemon is denied `$CLONE/Users` and `$CLONE/opt/homebrew/var/lib/caddy`
  (EPERM) while root from a Terminal holding Full Disk Access opens both, so a
  `keys=0` from the daemon counts only directories it could read. Run
  `sudo ~/bin/caddy-pki-attest.sh` after every completed CCC run; it writes
  `/usr/local/var/log/caddy-pki-attest.state`. The gate accepts that attestation
  for the destination clean verdict only when it is under 14 days old, names the
  configured clone, and reports zero keys, zero encrypted archives and zero find
  errors. The hourly audit keeps the snapshot tripwire, which the daemon can read.

- Exposure ledger, 2026-11-23: task
  `EDFDF3A2-60C5-4645-AE5E-C75B5ED2F0F4` (`CCC Backup Task`, the original, not the
  hardened copy `2FEC566A`) had `hasExclusions: false` and completed a run on
  2026-11-05, eleven days after the CA root was created. Its destination `M5CCC`
  is not attached to this Mac, so those copies of `key.pem` cannot be deleted
  from here and are treated as exposed. **CA rotation is the only control that
  reaches them**; the exclusion added to the surviving task protects future runs
  and nothing already written.

- A restored clone restores an older Caddyfile. CCC preserves source mtimes, and
  `<CLONE-VOLUME>/opt/homebrew/etc/Caddyfile` predates the `studio.home.arpa`
  site, so a file-level restore from Recovery brings back a config without that
  listener and `https://studio.home.arpa` will not complete a trusted handshake
  until `/opt/homebrew/etc/Caddyfile` is restored separately. Because mtimes are
  preserved, a `find -newermt` comparison cannot detect this; compare content.
- `/usr/local/sbin/ccc-pki-audit.sh`, root:wheel 0755, hourly at :07. Root-executed
  code must not live on an admin-writable path, for the same reason the sudoers
  wrapper is pinned in `/usr/local/bin` and not `/opt/homebrew/bin`.
- `caddy-pki-attest.sh`, run from a Terminal with sudo, is the destination control;
  see the bullet above.
- `m5-secops.sh refresh | verify | gate | install | emit | merge`.
- Audit logs live under `/usr/local/var/log`, never `/tmp`, which macOS clears at
  boot and reaps after roughly three days.
- Adding the exclusion does not rotate the root, so no client re-trust and no
  `m5-drift.sh snapshot` rebaseline are required.

Reconstructing a runnable copy: the committed scripts carry one inert token,
<CLONE-VOLUME>, as the fallback default for CLONE, and nothing needs substituting
by hand. m5-secops.sh and caddy-pki-attest.sh resolve the clone path at run time by
sourcing ~/.config/m5-secops.env (0600, M5_CLONE_VOL, written by m5-ship.sh and
never committed), resolving the invoking human through SUDO_USER, the console owner
and dscl rather than $HOME because caddy-pki-attest.sh runs under sudo. The root
audit is deliberately different: install substitutes the resolved path into the
rendered script and aborts if the token would survive, so the daemon holds no
dependency on a user-writable config file. The task-UUID placeholder is gone
entirely: the exclusion verdict enumerates tasks by
sourceDisk.apfsVolumeGroupUUID, so no single task is pinned or trusted.
