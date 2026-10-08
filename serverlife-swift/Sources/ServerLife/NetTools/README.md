# NetTools — network tools and SSH keys

Port of `src/main/nettools.js` and `src/renderer/js/nettools.js` (whole), the
main.js `net:*` handlers, `src/renderer/js/keys.js`, `src/main/sshkeys.js` and
the main.js `keys:*` / `knownhosts:*` handlers. GUIDE.md "Network tools" and
"Keys and known hosts" are the spec.

## Action ids

| id | what | args |
|---|---|---|
| `nettools` | the Network tools panel (⌘⇧T) | `connId` (or `ctx.connId`) preselects **Run on**; `tool` (`ping`, `curl`, `traceroute`, `dns`, `ports`, `telnet`, `tls`, `http`, `whois`, `serial`, `teleport`, `local`); `host` String — a target, run at once; `preset` JSON — a saved request record |
| `webapi-ping` | the panel on **Teleport cluster** for a proxy, run at once (for `cluster-info` / a profile's Cluster info button) | `proxy` String (else `ctx.host.proxy`) |
| `keys` | the SSH keys dialog (⌘⇧K) | — |
| `forget-host-key` | look up and forget known_hosts entries | `ctx.host` (`name.cluster` for Teleport nodes, else hostname / direct hostname / alias, as sidebar.js did) or `hostname` String; neither → asks |

A second `nettools` / `webapi-ping` with arguments closes the open panel and
opens a fresh one (each `openNetTools` call was a fresh modal: Run on back to
this machine unless `connId` is given); with no arguments it brings the open
one forward.

## Files

| File | What |
|---|---|
| `NetCore.swift` | `NetCheck` (checkHost, hostFromInput, splitHostPort, parsePorts, telnetTarget, ipVersion), `NetTool` (the tool list, `remote`, `needs`, `missing`), `HostCaps`, `NetInstall` (TOOL_PACKAGES, installHint), `PortStateInfo` (open / refused / no answer / unknown name / error / unknown), `NetText` (safeName, shortUrl, bodyExt, pingNote, pretty JSON), `ntNumber` (JS `Number()` semantics) |
| `NetLocal.swift` | from this machine: `ping`, `traceroute`, `whois` (argv only), `lookup` (dnssd `DNSServiceQueryRecord`: A/AAAA/CNAME/MX/TXT/NS/SRV + PTR), `portCheck`, `telnetProbe`, `cleanBanner`, `guessService`, `localInfo` (getifaddrs, resolv.conf); result structs with `.json` in the original's shape |
| `NetSocket.swift` | non-blocking POSIX connect with Node's error codes; the port probe; the telnet probe (negotiation answered with Devices' `Telnet.parse`) |
| `NetTLS.swift` | TLS certificate via Network.framework + SecTrust (verified?, protocol, cipher, ALPN, subject, issuer, validity, days left, SANs, serial, SHA-256, and the chain); HTTP check via URLSession with redirects followed by hand (chain, timing, size, headers, 2 KB preview); `HTTPFetch` |
| `NetCurl.swift` | `CurlOptions`, `NetCurl.args` (one argv for preview, copy and run), `command`, `checkUrl`, `request` (runs `/usr/bin/curl`, splits header blocks into hops), `CurlExample` |
| `NetRemote.swift` | `NTConnections` (connected sessions via `ConnectionManager`), `NetRemote`: `net:hostTools` (+hints), `hostPorts`, `hostPing`, `hostTrace`, `hostCurl` (SOCKS through the session), `hostFacts`, host refs for saved/recent records — over `Connection.hostTools/probePorts/hostPing/hostTrace/withSocks` (Connections/ConnNetProbes.swift) |
| `_NetStoreStandIn.swift` | forwarders to Data/'s `netRequests` / `netRuns` store methods (see below) |
| `NetToolsModel.swift` | the panel's state and `dispatch` (every tool, here and on a host), examples, saved/recent strips, telnet/serial hand-off |
| `NetToolsView.swift`, `NetResults.swift`, `NTUI.swift` | the panel, each result's layout, shared pieces (flow layout, badges, KV grid, disclosure, `NTAsk` sheets over the panel) |
| `SSHKeys.swift` | `listKeys` (fingerprint, type, bits, passphrase from the key's header, mtime, mode/permission check), `agentKeys`, `isEncrypted`, `addToAgent` (pty, askpass disabled, every prompt answered), `generate`, `installScript`/`install`, `knownHostEntries`, `forgetHost`, `teleportIdentity`, `agentOnly` grouping. `SSHKeys.sshDir` is overridable (tests use a temp dir) |
| `KeysDialog.swift` | the SSH keys sheet, Install public key, Generate SSH key, passphrase prompt, Forget host key |

## Uses from other owners

- Connections: `ConnectionManager.shared.connections/require`, `Connection.exec`, `.connect`,
  `.hostTools/.hostFacts/.probePorts/.hostPing/.hostTrace/.withSocks`.
- Teleport service: `Inventory.shared.profiles` (suggested target / examples), `.sshHosts`
  (which ssh_config hosts name a key), `WebAPIPing.ping` + `badges/sections/licenseWarnings`.
- Devices service: `DeviceSessions.shared.listPorts()`, `Telnet.parse/nawsFrame/errorText`.
- Actions performed: `open-on-connection` (telnet from a host), `telnet-open` / `serial-open`
  (consoles; host = a device descriptor with the original's option names — `host`/`hostname`,
  `port`, `newline`, `localEcho`; `path`, `baudRate`, `dataBits`, `parity`, `stopBits`, `rtscts`,
  `xon`, `xoff`), `edit-profile` (args `profile` JSON, type `serial`, for Save…).

## Stand-ins / not done

- **Saved requests and recent runs**: `NetSaved` (`_NetStoreStandIn.swift`) forwards to Data/'s
  store.js port (`Store.listNetRequests/saveNetRequest/deleteNetRequest/addNetRun/listNetRuns/clearNetRuns`).
  `addNetRun` is ported as written: the original compares a three-part key with a two-part one, so a
  repeat run is never replaced — Recent is every run (as GUIDE.md says), capped at 25.
- HTTP check uses URLSession, which applies HSTS (an `http://` URL on a preloaded domain is
  fetched over https) and decompresses (size is the decoded body). Reason phrases come from the
  standard table, not the server's own text.
- TLS `authorizationError` is SecTrust's wording, not OpenSSL's code (`CERT_HAS_EXPIRED`).
- After a run of a saved request the original re-saved it with `name: undefined` and no `on`
  (renaming it to its URL, dropping its host, recreating it if deleted); this keeps name and host
  and skips a deleted record. The original's local port-check note always read "nothing open"
  (it tested `x.open`); this lists the open ports.
- The panel is a window of its own, so its status messages show in its own footer, not the main
  window's status bar.
- curl output is capped at 24 MB (ping/traceroute/whois at 4 MB) as the original's `maxBuffer`;
  the body is formatted off the main thread and only the first 512 KB is drawn (Copy body / Save
  output… have all of it).
- The HTTP check connects directly (no system proxy), as Node did.
- Save output… offers a target-shaped file name (`ping-<target>.txt`,
  `ports-from-<host>-to-<target>.json`, `response-<target>.json` …) — the original computed these
  but passed none.
