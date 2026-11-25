/* Domain transition worker for https://berumrah.id/sw.js only.
 * Keep same script URL so installed old workers can update.
 * No cache/storage deletion, imported scripts, or forced client navigation.
 * Existing app autoUpdate listeners may reload upon activation.
 */
self.addEventListener('install', (event) => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  const url = new URL(request.url);

  if (
    request.method !== 'GET' ||
    request.mode !== 'navigate' ||
    url.origin !== 'https://berumrah.id' ||
    url.origin !== self.location.origin
  ) {
    return;
  }

  event.respondWith(Response.redirect(
    `https://berumrah.com${url.pathname}${url.search}${url.hash}`,
    302
  ));
});
