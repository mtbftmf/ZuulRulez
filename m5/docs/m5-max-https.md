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
