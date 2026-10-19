// Service worker mínimo: permite instalar o app no celular.
// Estratégia "rede primeiro": o aluno sempre recebe a versão mais nova quando está online.
const CACHE = "pulse-medcards-v5";
const ARQUIVOS = ["./", "./index.html", "./manifest.json", "./config.js", "./icons/icon-192.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ARQUIVOS)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin) return; // dados do Supabase nunca são guardados
  e.respondWith(
    fetch(e.request)
      .then((r) => { const copia = r.clone(); caches.open(CACHE).then((c) => c.put(e.request, copia)); return r; })
      .catch(() => caches.match(e.request)),
  );
});
