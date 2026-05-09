// Custom Flutter bootstrap.
// We skip Flutter's default service worker and register our own
// (web/service_worker.js) so we can add runtime caching for
// shadow MVT tiles, map base tiles, and geocoding requests.

{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load();

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker
      .register('service_worker.js')
      .catch((e) => console.warn('[sunspot] SW registration failed', e));
  });
}
