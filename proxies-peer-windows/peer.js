/**
 * Proxies.sx Peer SDK for Windows (Node.js)
 * =========================================
 * A complete, production-grade bandwidth-sharing peer that runs on Windows
 * (also macOS/Linux). It implements the FULL Proxies.sx relay protocol:
 *   - Registers with the platform (keeps the same device identity across restarts)
 *   - Connects to the nearest relay over WebSocket (server-driven geo-routing)
 *   - Heartbeats every 30s
 *   - Opens TCP tunnels for customer traffic and forwards bytes both ways
 *   - Reports tunnel failures so customers fail fast
 *   - Opens several parallel WebSockets for higher throughput
 *
 * This is the same wire protocol as the canonical reference SDK (v1.3.1),
 * repackaged for Windows: it reads its settings from `config.json` instead of
 * environment variables, stores its identity next to the app, and prints
 * friendly activity logs.
 *
 * Run it with:  start.bat   (double-click)
 * or manually:  node peer.js
 */

'use strict';

// Node 18 prints "ExperimentalWarning: The Fetch API is an experimental feature"
// the first time fetch() is used. It is harmless, but it alarms users ("is it
// broken?"). Silence just that one notice; all other warnings still show.
const _origEmitWarning = process.emitWarning.bind(process);
process.emitWarning = (warning, ...args) => {
  const msg = typeof warning === 'string' ? warning : (warning && warning.message) || '';
  if (msg.includes('Fetch API is an experimental')) return;
  return _origEmitWarning(warning, ...args);
};

const WebSocket = require('ws');
const net = require('net');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const SDK_VERSION = '1.3.1';
// When packaged into a standalone .exe with `pkg`, __dirname points inside the
// virtual snapshot, so external files (config.json, state) must resolve next to
// the actual executable instead.
const APP_DIR = process.pkg ? path.dirname(process.execPath) : __dirname;

// ---------------------------------------------------------------------
// CONFIG - read config.json sitting next to this file. Environment
// variables override individual fields so advanced users / service
// wrappers can still inject values. config.json is the normal path.
// ---------------------------------------------------------------------
function loadConfig() {
  let fileCfg = {};
  const cfgPath = path.join(APP_DIR, 'config.json');
  try {
    fileCfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
  } catch (e) {
    if (fs.existsSync(cfgPath)) {
      console.error(`[CONFIG] config.json exists but is not valid JSON: ${e.message}`);
      process.exit(1);
    }
    // No config.json yet - fall back to env only (setup.bat creates the file).
  }
  const pick = (envKey, fileKey, dflt) =>
    process.env[envKey] !== undefined ? process.env[envKey]
      : fileCfg[fileKey] !== undefined ? fileCfg[fileKey]
      : dflt;

  return {
    apiKey: pick('API_KEY', 'apiKey', ''),
    apiBase: pick('API_BASE', 'apiBase', 'https://api.proxies.sx/v1'),
    relayUrl: pick('RELAY_URL', 'relayUrl', ''), // empty = let server pick nearest
    agentName: pick('AGENT_NAME', 'agentName', `windows-${crypto.randomBytes(3).toString('hex')}`),
    wallet: pick('WALLET', 'walletAddress', ''),
    country: pick('COUNTRY', 'country', 'US'),
    carrier: pick('CARRIER', 'carrier', 'unknown'),
    connectionMethod: pick('CONNECTION_METHOD', 'connectionMethod',
      process.platform === 'win32' ? 'windows' : 'agent'),
    wsConnections: Math.max(1, Math.min(8, parseInt(pick('WS_CONNECTIONS', 'wsConnections', 4), 10) || 4)),
    verbose: String(pick('VERBOSE', 'verbose', 'false')) === 'true',
  };
}

const cfg = loadConfig();

if (!cfg.apiKey || cfg.apiKey.startsWith('psx_REPLACE')) {
  console.error('');
  console.error('  ERROR: no API key set.');
  console.error('  Open config.json and set "apiKey" to your psx_ key from');
  console.error('  https://client.proxies.sx/account (API Keys section).');
  console.error('');
  process.exit(1);
}

const DEFAULT_RELAY = 'wss://relay.proxies.sx';
let activeRelay = cfg.relayUrl || DEFAULT_RELAY;
const RELAY_PINNED = !!cfg.relayUrl;          // an explicit relayUrl is a manual pin
const openSockets = new Set();
let lastRedirectAt = 0;

function ts() { return new Date().toISOString().replace('T', ' ').slice(0, 19); }
function log(...a) { console.log(`[${ts()}]`, ...a); }
function vlog(...a) { if (cfg.verbose) console.log(`[${ts()}]`, ...a); }
function isOurRelayUrl(u) {
  return typeof u === 'string' && /^wss:\/\/[a-z0-9.-]+\.proxies\.sx(?:\/|$)/i.test(u);
}

// Guard so N sockets closing on an expired token trigger ONE re-register.
let reregisterScheduled = false;
function scheduleReregister() {
  if (reregisterScheduled) return;
  reregisterScheduled = true;
  setTimeout(() => { reregisterScheduled = false; main().catch(() => {}); }, 5000);
}

// ---------------------------------------------------------------------
// 1. REGISTER - call /peer/agents/register, get a JWT + deviceId + relay
// ---------------------------------------------------------------------
async function register() {
  const res = await fetch(`${cfg.apiBase}/peer/agents/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      name: cfg.agentName,
      type: 'custom',
      connectionMethod: cfg.connectionMethod,
      sdkVersion: SDK_VERSION,
      // Only send walletAddress when set - an empty string fails validation.
      ...(cfg.wallet ? { walletAddress: cfg.wallet } : {}),
      apiKey: cfg.apiKey,
    }),
  });
  if (!res.ok) {
    throw new Error(`register failed: HTTP ${res.status} ${await res.text()}`);
  }
  return res.json(); // -> { token|jwt, refreshToken, deviceId, relay, earningsPerGB }
}

// ---------------------------------------------------------------------
// 1b. IDENTITY PERSISTENCE - reuse the SAME deviceId across restarts so a
// restart/update does not orphan the old device as "offline forever".
// ---------------------------------------------------------------------
const STATE_FILE = process.env.PEER_STATE_FILE || path.join(APP_DIR, '.sx-peer-state.json');
function loadState() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')); } catch { return null; }
}
function saveState(s) {
  try { fs.writeFileSync(STATE_FILE, JSON.stringify(s)); }
  catch (e) { console.error('[STATE] could not persist identity:', e.message); }
}
async function refreshSavedToken(deviceId, refreshToken) {
  try {
    const res = await fetch(`${cfg.apiBase}/peer/token/${deviceId}/refresh`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ refreshToken }),
    });
    if (!res.ok) return null;
    const j = await res.json();
    return j.token || j.jwt || null;
  } catch { return null; }
}

// ---------------------------------------------------------------------
// 2. CONNECT - open a WebSocket to the relay, carry the JWT in the
// Sec-WebSocket-Protocol header (never in the URL - URLs get logged).
// ---------------------------------------------------------------------
function connect(token, deviceId) {
  const url = activeRelay;
  const ws = new WebSocket(url, [`token.${token}`]);
  const tunnels = new Map();   // sessionId -> outbound TCP socket
  let heartbeatTimer = null;

  ws.on('open', () => {
    log(`[CONNECTED] device=${deviceId} relay=${url}`);
    openSockets.add(ws);
    send(ws, 'device_info', {
      country: cfg.country,
      carrier: cfg.carrier,
      currentIp: 'auto',           // 'auto' = let the server classify the IP
      protocol: 'binary-v1',       // opt in to the fast binary tunnel frames
      supportsRelayRedirect: true, // honor server-driven nearest-relay routing
      sdkVersion: SDK_VERSION,
    });
    heartbeatTimer = setInterval(() => send(ws, 'heartbeat', {}), 30_000);
  });

  ws.on('message', (raw) => {
    // Hot path: binary tunnel frames. [type 0x01 data | 0x03 close][sidLen][sid][payload]
    if (raw[0] === 0x01 || raw[0] === 0x03) {
      const sidLen = raw[1];
      const sessionId = raw.slice(2, 2 + sidLen).toString('utf-8');
      const payload = raw.slice(2 + sidLen);
      const sock = tunnels.get(sessionId);
      if (raw[0] === 0x01 && sock) sock.write(payload);
      else if (raw[0] === 0x03 && sock) { sock.end(); tunnels.delete(sessionId); }
      return;
    }

    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }

    switch (msg.type) {
      case 'connected':
        log('[ACK] relay confirmed connection');
        break;

      case 'heartbeat_ack':
        break;

      case 'relay_redirect': {
        const target = msg.payload && msg.payload.relay;
        if (RELAY_PINNED) break;                          // manual pin wins
        if (!isOurRelayUrl(target)) break;                // only *.proxies.sx wss
        if (target === activeRelay) break;
        if (Date.now() - lastRedirectAt < 60_000) break;  // anti-flap
        lastRedirectAt = Date.now();
        log(`[REDIRECT] ${activeRelay} -> ${target} (${(msg.payload && msg.payload.reason) || 'geo'})`);
        activeRelay = target;
        for (const s of Array.from(openSockets)) {
          try { s.close(4100, 'relay_redirect'); } catch {}
        }
        break;
      }

      // THE TUNNEL HANDLER - open a real TCP socket to the target and pipe bytes.
      case 'tunnel_connect': {
        const { sessionId, host, port } = msg.payload;
        vlog(`[TUNNEL_CONNECT] ${sessionId} ${host}:${port}`);
        const sock = net.connect(parseInt(port, 10), host);
        sock.setNoDelay(true);
        sock.setTimeout(30_000);
        sock._connectStartedAt = Date.now();

        sock.on('connect', () => {
          tunnels.set(sessionId, sock);
          vlog(`[TCP_OPEN_OK] ${sessionId}`);
          send(ws, 'tunnel_connected', { sessionId });
        });

        // For HTTPS (443) this is a plain TCP relay - TLS stays end-to-end
        // between the customer and the target. Do NOT terminate TLS here.
        sock.on('data', (data) => {
          if (ws.readyState !== WebSocket.OPEN) return;
          const sidBuf = Buffer.from(sessionId, 'utf-8');
          const frame = Buffer.alloc(2 + sidBuf.length + data.length);
          frame[0] = 0x01;
          frame[1] = sidBuf.length;
          sidBuf.copy(frame, 2);
          data.copy(frame, 2 + sidBuf.length);
          ws.send(frame);
        });

        sock.on('timeout', () => sock.destroy());

        sock.on('error', (err) => {
          vlog(`[TUNNEL_FAIL] ${sessionId} ${err.code || err.message}`);
          send(ws, 'tunnel_open_failed', {
            sessionId,
            reason: err.code === 'ECONNREFUSED' ? 'connection_refused'
                  : err.code === 'ENOTFOUND' ? 'dns_failed'
                  : err.code === 'ETIMEDOUT' ? 'timeout'
                  : 'unknown',
            detail: err.message,
            durationMs: Date.now() - sock._connectStartedAt,
          });
          tunnels.delete(sessionId);
        });

        sock.on('close', () => {
          send(ws, 'tunnel_closed', { sessionId });
          tunnels.delete(sessionId);
        });
        break;
      }

      case 'tunnel_close': {
        const { sessionId } = msg.payload;
        const sock = tunnels.get(sessionId);
        if (sock) { sock.end(); tunnels.delete(sessionId); }
        break;
      }

      case 'tunnel_data': { // legacy JSON+base64 path (pre binary-v1)
        const { sessionId, data } = msg.payload;
        const sock = tunnels.get(sessionId);
        if (sock) sock.write(Buffer.from(data, 'base64'));
        break;
      }

      case 'rotate_ip_request': {
        // Desktop peers can't toggle a carrier IP; report unsupported so the
        // gateway moves on instead of waiting.
        const { requestId } = msg.payload;
        send(ws, 'rotation_complete', {
          requestId, success: false, error: 'not_supported_on_desktop',
        });
        break;
      }

      default:
        // Unknown control messages are ignored, never fatal.
    }
  });

  ws.on('close', (code, reason) => {
    log(`[CLOSED] code=${code} reason=${reason || ''}`);
    if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null; }
    openSockets.delete(ws);
    for (const sock of tunnels.values()) sock.destroy();
    tunnels.clear();
    // 4001/4002 = auth failure -> full re-register (guarded). Anything else
    // (incl. 4100 redirect, network blip) -> reconnect just this socket.
    if (code === 4001 || code === 4002) {
      scheduleReregister();
    } else {
      setTimeout(() => connect(token, deviceId), 5000 + Math.random() * 2000);
    }
  });

  ws.on('error', (err) => console.error(`[${ts()}] [WS_ERR]`, err.message));
}

function send(ws, type, payload) {
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type, payload }));
}

// ---------------------------------------------------------------------
// MAIN
// ---------------------------------------------------------------------
async function main() {
  let token, deviceId, relay;
  const saved = loadState();
  if (saved && saved.deviceId && saved.refreshToken) {
    const t = await refreshSavedToken(saved.deviceId, saved.refreshToken);
    if (t) {
      token = t;
      deviceId = saved.deviceId;
      relay = saved.relay;
      log(`[RESUMED] device=${deviceId} (reused saved identity)`);
    }
  }
  if (!deviceId) {
    const r = await register();
    token = r.jwt || r.token;
    deviceId = r.deviceId;
    relay = r.relay;
    saveState({ deviceId, refreshToken: r.refreshToken, relay });
  }
  // Relay precedence: manual pin > server geo-assignment > built-in default.
  activeRelay = (RELAY_PINNED && cfg.relayUrl) || relay || activeRelay;
  log(`[REGISTERED] device=${deviceId} relay=${activeRelay} sockets=${cfg.wsConnections}`);
  log(`Sharing bandwidth as "${cfg.agentName}". Leave this window open. Press Ctrl+C to stop.`);
  for (let i = 0; i < cfg.wsConnections; i++) connect(token, deviceId);
}

process.on('SIGINT', () => { log('Stopping (Ctrl+C). Goodbye.'); process.exit(0); });

main().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
