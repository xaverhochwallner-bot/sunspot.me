// Sunspot service worker.
// Strategies:
//   /shadow/tile/*     stale-while-revalidate, capped at 200 entries
//   *.cartocdn.com     cache-first (map base tiles), 500 entries
//   nominatim.org      network-first with cache fallback, 50 entries
//   same-origin        cache-first (app shell, assets, icons)
//   everything else    network passthrough (Sentry, analytics, API JSON)

const VERSION = 'v1';
const APP_SHELL_CACHE   = `sunspot-app-shell-${VERSION}`;
const SHADOW_TILE_CACHE = `sunspot-shadow-tiles-${VERSION}`;
const MAP_TILE_CACHE    = `sunspot-map-tiles-${VERSION}`;
const GEOCODE_CACHE     = `sunspot-geocode-${VERSION}`;

const SHADOW_TILE_MAX = 200;
const MAP_TILE_MAX    = 500;
const GEOCODE_MAX     = 50;

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keep = new Set([APP_SHELL_CACHE, SHADOW_TILE_CACHE, MAP_TILE_CACHE, GEOCODE_CACHE]);
    const names = await caches.keys();
    await Promise.all(names.filter(n => !keep.has(n)).map(n => caches.delete(n)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  if (url.pathname.includes('/shadow/tile/')) {
    event.respondWith(staleWhileRevalidate(req, SHADOW_TILE_CACHE, SHADOW_TILE_MAX));
    return;
  }

  if (url.hostname.endsWith('cartocdn.com')) {
    event.respondWith(cacheFirst(req, MAP_TILE_CACHE, MAP_TILE_MAX));
    return;
  }

  if (url.hostname === 'nominatim.openstreetmap.org') {
    event.respondWith(networkFirst(req, GEOCODE_CACHE, GEOCODE_MAX));
    return;
  }

  if (url.origin === self.location.origin) {
    event.respondWith(cacheFirst(req, APP_SHELL_CACHE, 0));
    return;
  }
});

async function cacheFirst(req, cacheName, maxEntries) {
  const cache  = await caches.open(cacheName);
  const cached = await cache.match(req);
  if (cached) return cached;
  try {
    const res = await fetch(req);
    if (res && res.ok) {
      cache.put(req, res.clone());
      if (maxEntries > 0) trimCache(cacheName, maxEntries);
    }
    return res;
  } catch {
    return cached || Response.error();
  }
}

async function staleWhileRevalidate(req, cacheName, maxEntries) {
  const cache  = await caches.open(cacheName);
  const cached = await cache.match(req);
  const fetchPromise = fetch(req).then(res => {
    if (res && res.ok) {
      cache.put(req, res.clone());
      if (maxEntries > 0) trimCache(cacheName, maxEntries);
    }
    return res;
  }).catch(() => cached);
  return cached || fetchPromise;
}

async function networkFirst(req, cacheName, maxEntries) {
  const cache = await caches.open(cacheName);
  try {
    const res = await fetch(req);
    if (res && res.ok) {
      cache.put(req, res.clone());
      if (maxEntries > 0) trimCache(cacheName, maxEntries);
    }
    return res;
  } catch {
    const cached = await cache.match(req);
    return cached || Response.error();
  }
}

async function trimCache(cacheName, maxEntries) {
  const cache = await caches.open(cacheName);
  const keys  = await cache.keys();
  if (keys.length <= maxEntries) return;
  const excess = keys.length - maxEntries;
  for (let i = 0; i < excess; i++) {
    await cache.delete(keys[i]);
  }
}
