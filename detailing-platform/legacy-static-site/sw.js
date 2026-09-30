/* Service worker для Dark Side Car's.
   Имя кэша содержит версию — при изменении сайта поднимите число,
   старые кэши удалятся сами при активации. */

var VERSION = "dsc-v1";
var SHELL = VERSION + "-shell";

var ASSETS = [
  "./",
  "./index.html",
  "./portfolio.html",
  "./manifest.webmanifest",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/maskable-192.png",
  "./icons/maskable-512.png",
  "./icons/apple-touch-icon.png",
  "./icons/favicon-64.png",
  "./icons/favicon.ico"
];

self.addEventListener("install", function (event) {
  event.waitUntil(
    caches.open(SHELL).then(function (cache) {
      /* addAll падает целиком, если хоть один файл недоступен — кладём по одному */
      return Promise.all(
        ASSETS.map(function (url) {
          return cache.add(new Request(url, { cache: "reload" })).catch(function () {});
        })
      );
    }).then(function () {
      return self.skipWaiting();
    })
  );
});

self.addEventListener("activate", function (event) {
  event.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(
        keys.map(function (k) {
          if (k.indexOf(VERSION) !== 0) return caches.delete(k);
        })
      );
    }).then(function () {
      return self.clients.claim();
    })
  );
});

self.addEventListener("fetch", function (event) {
  var req = event.request;

  /* Кэшируем только собственные GET-запросы. Карты, мессенджеры
     и внешние сервисы идут в сеть напрямую. */
  if (req.method !== "GET") return;

  var url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  /* Навигация: сначала сеть, при отказе — сохранённая оболочка */
  if (req.mode === "navigate") {
    event.respondWith(
      fetch(req)
        .then(function (res) {
          var copy = res.clone();
          caches.open(SHELL).then(function (c) { c.put(req, copy); });
          return res;
        })
        .catch(function () {
          return caches.match(req).then(function (hit) {
            return hit || caches.match("./index.html");
          });
        })
    );
    return;
  }

  /* Статика: сначала кэш, параллельно обновляем */
  event.respondWith(
    caches.match(req).then(function (hit) {
      var live = fetch(req)
        .then(function (res) {
          if (res && res.status === 200 && res.type === "basic") {
            var copy = res.clone();
            caches.open(SHELL).then(function (c) { c.put(req, copy); });
          }
          return res;
        })
        .catch(function () { return hit; });
      return hit || live;
    })
  );
});
