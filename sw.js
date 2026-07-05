// Service Worker لإشعارات الأكاديمية — يعمل حتى لو المتصفح مقفول تماماً
self.addEventListener('install', (event) => {
  self.skipWaiting();
});
self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});
// معالج fetch أساسي — بعض المتصفحات تشترطه ضمن شروط اعتبار الموقع "قابلاً للتثبيت"
self.addEventListener('fetch', (event) => {
  event.respondWith(fetch(event.request).catch(() => caches.match(event.request)));
});

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch(e) { data = { title: 'أكاديمية الهدى', body: event.data ? event.data.text() : '' }; }
  const title = data.title || 'أكاديمية الهدى';
  const options = {
    body: data.body || '',
    icon: data.icon || '/assets/logo.webp',
    badge: data.badge || '/assets/logo.webp',
    dir: 'rtl',
    lang: 'ar',
    data: { url: data.url || '/index.html' },
    tag: data.tag || undefined,
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || '/index.html';
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if (client.url.includes(location.origin) && 'focus' in client) return client.focus();
      }
      if (clients.openWindow) return clients.openWindow(url);
    })
  );
});
