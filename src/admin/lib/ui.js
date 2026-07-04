import { useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';

export const go = (h) => { location.hash = h; };

export function useLiveCollection(col, apply) {
  useEffect(() => {
    let ws, closed = false;
    (async () => {
      let token;
      try { token = (await API.refresh()).token; } catch (_) { return; } // degrade: no live updates
      if (closed) return;
      ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/api/realtime');
      ws.onopen = () => { ws.send(JSON.stringify({ action: 'auth', token })); ws.send(JSON.stringify({ action: 'subscribe', topic: col })); };
      ws.onmessage = (e) => { let m; try { m = JSON.parse(e.data); } catch (_) { return; } if (m.type === 'event') apply(m); };
    })();
    return () => { closed = true; if (ws) try { ws.close(); } catch (_) {} };
  }, [col]);
}
