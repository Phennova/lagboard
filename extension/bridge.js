// LagBoard — isolated-world relay between the page engine (inject.js) and the
// extension service worker (background.js), which talks to the Mac app.
(() => {
  let port = null;

  function connect() {
    try {
      port = chrome.runtime.connect({ name: 'lagboard' });
    } catch {
      return; // extension was reloaded; this content script is orphaned
    }
    port.onMessage.addListener((m) => {
      if (m && m.type === 'state') {
        window.postMessage({ __lagboard: 'state', state: m }, location.origin);
      }
    });
    port.onDisconnect.addListener(() => {
      void chrome.runtime.lastError;
      port = null;
      setTimeout(connect, 1000);
    });
  }
  connect();

  window.addEventListener('message', (e) => {
    if (e.source !== window || !e.data || e.data.__lagboard !== 'status') return;
    try {
      port && port.postMessage({ type: 'status', video: e.data.video, audio: e.data.audio, supported: e.data.supported });
    } catch {}
  });

  // Keeps the service worker (and its WebSocket) alive while a Meet tab is open.
  setInterval(() => {
    try {
      port && port.postMessage({ type: 'keepalive' });
    } catch {}
  }, 20000);
})();
