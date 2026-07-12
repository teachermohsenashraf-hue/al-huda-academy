// Service Worker لإشعارات الأكاديمية — يعمل حتى لو المتصفح مقفول تماماً
// + كاش حقيقي لهيكل التطبيق (App Shell) يسمح بفتحه بدون إنترنت
const CACHE_VERSION = 'v3';
const CACHE_NAME = 'huda-shell-' + CACHE_VERSION;
const SHELL_ASSETS = [
  '/',
  '/index.html',
  '/manifest.json',
  '/assets/logo.webp',
  '/assets/icon-192.png',
  '/assets/icon-512.png',
  '/assets/favicon-32.png',
];

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_ASSETS).catch(() => {}))
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    Promise.all([
      self.clients.claim(),
      caches.keys().then((keys) =>
        Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
      ),
    ])
  );
});

// استراتيجية: Network-first لصفحة التطبيق نفسها (عشان يوصل آخر تحديث دايماً وقت وجود إنترنت)
// مع تحديث الكاش تلقائياً بعد كل نجاح، وCache-first للأصول الثابتة (صور/أيقونات).
// لو مفيش إنترنت فعلاً، نرجع النسخة المخزّنة كآخر حل.
self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const isNavigation = req.mode === 'navigate' || (req.headers.get('accept') || '').includes('text/html');
  const isStaticAsset = /\/assets\//.test(req.url) || /\.(png|webp|jpg|jpeg|svg|ico)$/i.test(req.url);

  if (isNavigation) {
    event.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put('/index.html', copy));
          return res;
        })
        .catch(() => caches.match('/index.html').then((res) => res || caches.match(req)))
    );
    return;
  }

  if (isStaticAsset) {
    event.respondWith(
      caches.match(req).then(
        (cached) =>
          cached ||
          fetch(req).then((res) => {
            const copy = res.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(req, copy));
            return res;
          })
      )
    );
    return;
  }

  event.respondWith(fetch(req).catch(() => caches.match(req)));
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
