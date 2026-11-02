// LagBoard — service worker. Holds the WebSocket to the LagBoard Mac app and fans
// effect state out to every Meet tab.
const WS_URL = 'ws://127.0.0.1:47823';

let ws = null;
let retryTimer = null;
let lastState = { type: 'state', active: [], intensity: 0.7 };
const ports = new Map(); // port -> {video, audio, supported}

function broadcast(msg) {
  for (const p of ports.keys()) {
    try { p.postMessage(msg); } catch {}
  }
}

function sendStatus() {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  let video = 0;
  let audio = 0;
  let supported = true;
  for (const s of ports.values()) {
    video += s.video || 0;
    audio += s.audio || 0;
    if (s.supported === false) supported = false;
  }
  ws.send(JSON.stringify({ type: 'status', tabs: ports.size, video, audio, supported }));
}

function scheduleReconnect() {
  if (retryTimer) return;
  retryTimer = setTimeout(() => {
    retryTimer = null;
    connect();
  }, 2000);
}

function connect() {
  if (ws && (ws.readyState === WebSocket.CONNECTING || ws.readyState === WebSocket.OPEN)) return;
  try {
    ws = new WebSocket(WS_URL);
  } catch {
    scheduleReconnect();
    return;
  }
  ws.onopen = () => sendStatus();
  ws.onmessage = (e) => {
    let m;
    try { m = JSON.parse(e.data); } catch { return; }
    if (m && m.type === 'state') {
      lastState = m;
      broadcast(m);
    }
  };
  ws.onclose = () => {
    ws = null;
    // App went away: make sure nobody is left frozen.
    lastState = { type: 'state', active: [], intensity: lastState.intensity };
    broadcast(lastState);
    scheduleReconnect();
  };
  ws.onerror = () => {};
}

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== 'lagboard') return;
  ports.set(port, {});
  port.postMessage(lastState);
  port.onMessage.addListener((m) => {
    if (m && m.type === 'status') {
      ports.set(port, m);
      sendStatus();
    }
    connect();
  });
  port.onDisconnect.addListener(() => {
    ports.delete(port);
    sendStatus();
  });
  connect();
  sendStatus();
});

setInterval(() => {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send('{"type":"ping"}');
}, 20000);

connect();
