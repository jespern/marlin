'use strict';
self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
// No offline transcript cache: the daemon remains the source of truth.
self.addEventListener('push', event => {
  let data = {};
  try { data = event.data?.json() || {}; } catch {}
  const sid = /^\d+$/.test(String(data.sid)) ? String(data.sid) : '';
  // Always show a notification for received pushes, as required by iOS.
  // Visibility suppression happens in the daemon before sending a push.
  event.waitUntil(self.registration.showNotification(data.title || 'Marlin needs you', {
    body: data.body || 'Open Marlin to see the update.',
    icon: '/icon-180.png', tag: 'marlin-' + sid,
    data: {url: '/?sid=' + sid},
  }));
});
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const url = new URL(event.notification.data?.url || '/', self.location.origin);
  if (url.origin !== self.location.origin) return;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({type: 'window', includeUncontrolled: true});
    for (const client of windows) {
      if (new URL(client.url).origin === url.origin) {
        await client.navigate(url.href);
        await client.focus();
        return;
      }
    }
    await self.clients.openWindow(url.href);
  })());
});
