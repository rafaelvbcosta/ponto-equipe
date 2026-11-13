// Service worker do Ponto Equipe: só recebe os lembretes (push). Não guarda páginas em cache.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Ponto Equipe', {
    body: d.body || '',
    icon: 'icon-192.png',
    tag: d.tag || 'ponto',
    renotify: true,
    data: { url: d.url || './#hoje' },
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || './', self.registration.scope).href;
  e.waitUntil((async () => {
    const list = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of list) {
      if (c.url.startsWith(self.registration.scope)) {
        try { c.postMessage({ go: new URL(url).hash.slice(1) || 'hoje' }); } catch (_) { /* ignore */ }
        return c.focus();
      }
    }
    return self.clients.openWindow(url);
  })());
});
