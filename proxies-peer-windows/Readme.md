# Proxies.sx Peer for Windows

Earn by sharing your internet bandwidth. This is the official **Windows / Node.js**
peer for the Proxies.sx network. It connects your machine to the nearest relay and
forwards customer traffic through your connection. You get paid per GB served.

It speaks the exact same relay protocol as the Android app and the canonical
reference SDK (v1.3.1): server-driven nearest-relay routing, multi-socket
throughput, fast binary tunnels, and a stable device identity across restarts.

Works on Windows 10/11 (and Windows Server). Also runs unchanged on macOS/Linux.

---

## Quick start (3 steps, ~2 minutes)

1. **Install Node.js** (one time): download the **LTS** installer from
   <https://nodejs.org> and run it with the default options.

2. **Set up the peer**: double-click **`setup.bat`**. It installs the one
   dependency and creates your `config.json`. Then open `config.json` in
   Notepad and paste your API key:

   ```json
   {
     "apiKey": "psx_your_key_here",
     "agentName": "my-windows-rig",
     "country": "US"
   }
   ```

   Get your `psx_` API key at <https://client.proxies.sx/account> → **API Keys**
   → *Create key*.

3. **Start earning**: double-click **`start.bat`**. Leave the window open. You
   should see:

   ```
   [REGISTERED] device=... relay=wss://relay.proxies.sx sockets=4
   [CONNECTED]  device=... relay=wss://relay.proxies.sx
   [ACK] relay confirmed connection
   ```

That's it. Your device now shows up at <https://farmer.proxies.sx> under **Peers**.

---

## config.json reference

| Field | Required | Default | What it does |
|---|---|---|---|
| `apiKey` | **yes** | – | Your `psx_` API key from client.proxies.sx |
| `agentName` | no | random | Friendly name shown in your dashboard |
| `walletAddress` | no | – | Crypto payout wallet (can also be set in the portal) |
| `country` | no | `US` | Your ISO-2 country hint. The server still verifies the real IP. |
| `carrier` | no | `unknown` | Your ISP / carrier name (informational) |
| `wsConnections` | no | `4` | Parallel relay sockets (1–8). More = higher throughput. |
| `connectionMethod` | no | `windows` | Connection-type badge in the dashboard |
| `verbose` | no | `false` | Set `true` to log every tunnel open/close (for debugging) |

You can also override any field with an environment variable
(`API_KEY`, `AGENT_NAME`, `WALLET`, `COUNTRY`, `WS_CONNECTIONS`, `RELAY_URL`, …) —
useful when running as a service. Environment variables win over `config.json`.

---

## Run it 24/7 (auto-start on boot)

`start.bat` already auto-restarts the peer if it ever stops. To also start it
automatically when Windows boots, pick one:

### Option A — Task Scheduler (simplest)
1. Press `Win+R`, type `taskschd.msc`, Enter.
2. **Create Task** → General: name it `Proxies Peer`, tick **Run whether user is
   logged on or not**.
3. **Triggers** → New → *At startup*.
4. **Actions** → New → *Start a program* → Program: the full path to `start.bat`.
5. OK. It now launches on every boot.

### Option B — Windows Service via NSSM (most robust)
1. Download NSSM from <https://nssm.cc/download> and unzip it.
2. In an **Administrator** Command Prompt:
   ```cmd
   nssm install ProxiesPeer "C:\Windows\System32\cmd.exe" "/c C:\path\to\windows-peer-sdk\start.bat"
   nssm start ProxiesPeer
   ```
3. It now runs as a background service, even before login. Stop with
   `nssm stop ProxiesPeer`.

---

## Optional: build a standalone .exe (no Node.js needed to run)

If you want a single portable file you can drop on any Windows box:

1. Double-click **`build-exe.bat`** (needs Node.js to build, not to run).
2. It produces `build\proxies-peer.exe`.
3. Copy `proxies-peer.exe` **and** your `config.json` into the same folder and
   double-click the exe.

---

## "It says CONNECTED but I'm not earning yet" — this is normal

Seeing `[REGISTERED]`, `[CONNECTED]` and `[ACK] relay confirmed connection` means
your peer is **working correctly and online**. Earning does not start the instant
you connect — your device goes through a short pipeline:

```
CONNECTED  ->  VERIFIED        ->  LISTED          ->  EARNING
(you're     (a quality probe    (made available    (customer traffic
 online)     grades your IP)     to customers)       flows, you get paid)
```

The single most important thing: **keep the peer running continuously.** The
quality probe can only grade a device that stays online — if you open it for a
minute and close it, it never gets verified, so it never earns. Use `start.bat`
(it auto-restarts) and ideally set it to run on boot (see "Run it 24/7" above).
Check your device and earnings at <https://farmer.proxies.sx>.

> The `ExperimentalWarning: The Fetch API is an experimental feature` line you may
> have seen on older builds is harmless Node noise and is now silenced. It never
> meant anything was broken.

## How you get paid

- You earn **per GB** of customer traffic your device serves. The live rate
  depends on your IP type (mobile > residential > datacenter) and is set by the
  platform — it is printed as `[RATE] current earnings: $X/GB` on first
  registration, and shown in your dashboard.
- Earnings and payout status: <https://farmer.proxies.sx>.
- Withdrawals go to your **registered wallet** only. Minimum payout applies
  (see the portal).

> Tip: a residential or mobile connection earns more than a datacenter/VPS IP.
> The network classifies your IP automatically — you don't set the tier.

---

## Verify your peer is actually serving traffic

Set `"verbose": true` in `config.json`, restart, then from any machine run a
request through your own device (replace `YOURUSER`, `DEVICEID`, `YOURPAK`):

```cmd
curl -v -x "http://psx_YOURUSER-peer-us-pin-device-DEVICEID:pak_YOURPAK@gw.proxies.sx:7000" https://api.ipify.org/?format=json
```

In your peer window you should see, in order:
```
[TUNNEL_CONNECT] <id> api.ipify.org:443
[TCP_OPEN_OK]    <id>
```
If those appear, your peer is forwarding real traffic correctly.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Node.js is not installed` | Install the LTS from nodejs.org, re-run `setup.bat` |
| `ERROR: no API key set` | Edit `config.json`, set `apiKey` to your `psx_` key |
| `register failed: HTTP 401` | API key is wrong/revoked — make a new one in the portal |
| `register failed: HTTP 400 ... walletAddress` | Remove `walletAddress` or set a valid wallet |
| Device shows **offline** right after restart | Normal for a few seconds; it reuses the same identity via `.sx-peer-state.json`. Don't delete that file. |
| `CONNECTED` + `ACK` but **$0 earnings** | Working as intended — keep it running. It must stay online to get verified, listed, then earn (see "It says CONNECTED but I'm not earning yet" above). |
| `ExperimentalWarning: The Fetch API ...` | Harmless Node notice, now silenced in the latest build. Never meant anything was broken. |
| Window closes instantly | Run `setup.bat` first; then launch via `start.bat` |
| Behind strict firewall/CGNAT and no tunnels open | Your network may block outbound; try a different connection |

Need help? Open a ticket at <https://client.proxies.sx> or message support.

---

## Files in this folder

| File | Purpose |
|---|---|
| `peer.js` | The peer client (the whole protocol) |
| `config.json` | Your settings (created by `setup.bat`) |
| `config.example.json` | Template |
| `setup.bat` | One-time setup (install deps + create config) |
| `start.bat` | Run the peer, with auto-restart |
| `build-exe.bat` | Optional: build a standalone `.exe` |
| `.sx-peer-state.json` | Saved device identity (auto-created; keep it) |

MIT licensed. Fork it, rebrand it, ship it.
