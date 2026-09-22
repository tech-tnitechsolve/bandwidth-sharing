const net = require('net');
const http = require('http');
const { setGlobalDispatcher, ProxyAgent } = require('undici');
const { HttpsProxyAgent } = require('https-proxy-agent');
const WebSocket = require('ws');

const proxyHost = '127.0.0.1';
const proxyPort = 8080;
const proxyUrl = process.env.HTTP_PROXY || `http://${proxyHost}:${proxyPort}`;

console.log(`[PROXY-DISPATCHER] Kích hoạt Proxy Dispatcher (Buffer-Aware) qua: ${proxyUrl}`);

// 1. Ép toàn bộ native fetch qua Proxy
setGlobalDispatcher(new ProxyAgent(proxyUrl));

// 2. Ép toàn bộ WebSocket qua Proxy
const agent = new HttpsProxyAgent(proxyUrl);
const WS = WebSocket;

class ProxiedWebSocket extends WS {
  constructor(address, protocols, options) {
    let opts = {};
    let protos = undefined;

    if (typeof protocols === 'object' && !Array.isArray(protocols) && protocols !== null) {
      opts = Object.assign({}, protocols);
    } else {
      protos = protocols;
      if (typeof options === 'object' && options !== null) {
        opts = Object.assign({}, options);
      }
    }

    opts.agent = agent;
    super(address, protos, opts);
  }
}

for (const key of Object.getOwnPropertyNames(WS)) {
  if (!(key in ProxiedWebSocket)) {
    try { ProxiedWebSocket[key] = WS[key]; } catch (_) {}
  }
}

require.cache[require.resolve('ws')].exports = ProxiedWebSocket;

// 3. HOOK RAW TCP SOCKETS VỚI WRITE BUFFER (CHỐNG DROP GÓI TLS CLIENTHELLO)
const origCreateConnection = net.createConnection;

function createProxiedSocket(...args) {
  let normalized = {};
  if (typeof args[0] === 'object' && args[0] !== null) {
    normalized = Object.assign({}, args[0]);
  } else if (typeof args[0] === 'number') {
    normalized.port = args[0];
    if (typeof args[1] === 'string') {
      normalized.host = args[1];
    }
  }

  const targetHost = normalized.host || 'localhost';
  const targetPort = normalized.port;

  if (targetHost === '127.0.0.1' || targetHost === 'localhost' || targetHost === '::1') {
    return origCreateConnection.apply(net, args);
  }

  const duplex = new net.Socket();
  const writeBuffer = [];
  let realSocket = null;
  let isConnected = false;
  let isEnded = false;

  // Giữ lại các gói tin TLS gửi sớm vào hàng đợi
  duplex.write = function (chunk, encoding, cb) {
    if (isConnected && realSocket) {
      return realSocket.write(chunk, encoding, cb);
    } else {
      writeBuffer.push({ chunk, encoding, cb });
      return true;
    }
  };

  duplex.end = function (chunk, encoding, cb) {
    if (chunk) duplex.write(chunk, encoding);
    isEnded = true;
    if (isConnected && realSocket) {
      return realSocket.end(cb);
    }
  };

  duplex.destroy = function (err) {
    if (realSocket) realSocket.destroy(err);
    duplex.emit('close', !!err);
    return duplex;
  };

  const req = http.request({
    host: proxyHost,
    port: proxyPort,
    method: 'CONNECT',
    path: `${targetHost}:${targetPort}`,
    headers: {
      'Host': `${targetHost}:${targetPort}`,
      'Proxy-Connection': 'Keep-Alive'
    }
  });

  req.setTimeout(15000, () => {
    req.destroy(new Error('Proxy CONNECT Timeout'));
    duplex.emit('error', new Error('Proxy CONNECT Timeout'));
    duplex.destroy();
  });

  req.on('connect', (res, socket, head) => {
    if (res.statusCode === 200) {
      realSocket = socket;
      isConnected = true;

      socket.on('data', chunk => duplex.emit('data', chunk));
      socket.on('end', () => duplex.emit('end'));
      socket.on('close', hadError => duplex.emit('close', hadError));
      socket.on('error', err => duplex.emit('error', err));

      if (socket.setKeepAlive) duplex.setKeepAlive = socket.setKeepAlive.bind(socket);
      if (socket.setNoDelay) duplex.setNoDelay = socket.setNoDelay.bind(socket);
      socket.setTimeout(30000);

      // 1. Xả dữ liệu head (nếu có)
      if (head && head.length > 0) {
        duplex.emit('data', head);
      }

      // 2. XẢ TOÀN BỘ HÀNG ĐỢI TLS CLIENTHELLO VÀO SOCKET THỰC TẾ
      while (writeBuffer.length > 0) {
        const item = writeBuffer.shift();
        socket.write(item.chunk, item.encoding, item.cb);
      }

      if (isEnded) socket.end();

      duplex.emit('connect');
      duplex.emit('ready');

      const cb = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
      if (cb) cb();
    } else {
      const err = new Error(`Proxy CONNECT rejected: ${res.statusCode}`);
      duplex.emit('error', err);
      duplex.destroy(err);
    }
  });

  req.on('error', (err) => {
    duplex.emit('error', err);
    duplex.destroy(err);
  });

  req.end();
  return duplex;
}

net.createConnection = createProxiedSocket;
net.connect = createProxiedSocket;

// 4. Khởi chạy SDK
require('./reference-sdk.js');