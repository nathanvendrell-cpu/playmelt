"use strict";
(() => {
  if (navigator.doNotTrack === "1") return;
  const script = document.currentScript;
  const endpoint = script?.dataset.endpoint;
  if (!endpoint) return;
  const target = new URL(endpoint, location.href);
  if (target.origin !== location.origin) return;
  let referrer = "";
  try {
    const r = new URL(document.referrer);
    if (r.origin !== location.origin) referrer = r.hostname;
  } catch {}
  fetch(target.href, {
    method: "POST",
    credentials: "same-origin",
    keepalive: true,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ page: script.dataset.page || "site", referrer }),
  }).catch(() => {});
})();
