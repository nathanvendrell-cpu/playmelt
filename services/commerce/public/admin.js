"use strict";
const base = document.querySelector("meta[name=api-base]").content;
const $ = (id) => document.getElementById(id),
  count = (n) => n === null || n === undefined ? "—" : new Intl.NumberFormat("fr-FR").format(n),
  money = (n) =>
    new Intl.NumberFormat("fr-FR", {
      style: "currency",
      currency: "EUR",
    }).format(n / 100),
  date = (n) =>
    n
      ? new Date(n * 1000).toLocaleString("fr-FR", {
          dateStyle: "short",
          timeStyle: "short",
        })
      : "—";
let period = 30,
  accountPage = 1,
  registrationPage = 1,
  accountRequest = 0,
  detailRequest = 0,
  activeClientID = null,
  clientTab = "account",
  lastAccountTrigger = null,
  registrationRequest = 0,
  currentData = null,
  busy = false;
function node(tag, text, className) {
  const n = document.createElement(tag);
  if (text !== undefined) n.textContent = text;
  if (className) n.className = className;
  return n;
}
async function api(path, body) {
  const r = await fetch(base + "/v1/" + path, {
    method: body ? "POST" : "GET",
    credentials: "same-origin",
    headers: body ? { "Content-Type": "application/json" } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  let data;
  try {
    data = await r.json();
  } catch {
    throw Error("Le service n’a pas renvoyé de réponse valide.");
  }
  const errors = {
    already_has_lifetime: "Ce client possède déjà un accès à vie. Aucun droit supplémentaire n’a été créé.",
    invalid_lifetime_access: "Saisissez un motif de 3 à 300 caractères et confirmez le bénéficiaire.",
    lifetime_grant_not_found: "Cet accès à vie n’est pas révocable depuis cette fiche.",
    lifetime_already_revoked: "Cet accès à vie a déjà été révoqué. Actualisez la fiche.",
    already_has_access: "Ce client a déjà un accès actif. Aucun accès n’a été ajouté ou prolongé.",
    customer_required: "Les accès promotionnels sont réservés aux comptes clients.",
    payment_review_required: "Un paiement est signalé sur ce compte. Vérifiez sa situation avant toute attribution.",
    idempotency_conflict: "Cette demande a déjà été utilisée avec d’autres paramètres. Actualisez la fiche.",
    promotion_already_revoked: "Cet accès promotionnel a déjà été révoqué. Actualisez la fiche.",
    invalid_promotion: "Choisissez 7, 30 ou 90 jours, un motif de 3 à 300 caractères et confirmez l’action.",
    promotion_not_found: "Cet accès promotionnel n’est pas disponible pour ce client.",
  };
  if (!r.ok)
    throw Error(
      errors[data.error] || (r.status === 401
        ? "Reconnectez-vous depuis « Mon compte »."
        : r.status === 403
          ? "Cet espace est réservé aux administrateurs autorisés."
          : r.status === 400
            ? "Vérifiez la recherche et les filtres demandés."
            : r.status === 404
              ? "Ce compte n’est plus disponible. Actualisez la liste."
              : r.status === 429
                ? "Trop de demandes rapprochées. Réessayez dans un instant."
                : "Le service est momentanément indisponible."),
    );
  return data;
}
function failure(e) {
  $("admin-status").textContent = e.message;
}
function empty(tbody, cols, text) {
  const tr = node("tr"),
    td = node("td", text, "empty-row");
  td.colSpan = cols;
  tr.append(td);
  tbody.replaceChildren(tr);
}
function row(values, labels = []) {
  const tr = node("tr");
  values.forEach((v, index) => {
    const cell = node("td");
    if (v instanceof Node) cell.append(v);
    else cell.textContent = String(v);
    if (labels[index]) cell.dataset.label = labels[index];
    tr.append(cell);
  });
  return tr;
}
const badge = (label, active) => node("span", label, "record-status" + (active ? " is-active" : ""));
function renderOverview(data) {
  currentData = data;
  const t = data.totals;
  const customerWindow = Number.isFinite(data.customerMetricsStarted)
    ? data.customerMetricsStarted > data.period.since
      ? "Depuis le " + date(data.customerMetricsStarted)
      : "Site et application · sur la période"
    : "Historique client indisponible";
  $("kpis").replaceChildren();
  for (const [label, value, detail] of [
    [
      "Comptes clients",
      count(t.accounts),
      count(t.newAccounts) + " créations sur la période",
    ],
    [
      "Accès clients actifs",
      count(t.activeLicences),
      count(t.activeTrials) + " essais en cours",
    ],
    ["Encaissements bruts", money(t.receiptsCents), "EUR · sur la période"],
    [
      "Demandes de téléchargement clients",
      count(t.siteDownloadRequests),
      customerWindow,
    ],
  ]) {
    const card = node("article", undefined, "kpi");
    card.append(
      node("p", label, "kpi-label"),
      node("strong", value),
      node("small", detail),
    );
    $("kpis").append(card);
  }
  $("collection-start").textContent =
    "Comptes internes exclus des chiffres clients. " +
    (Number.isFinite(data.customerMetricsStarted)
      ? "Connexions et demandes clients mesurées depuis le " + date(data.customerMetricsStarted) + ". Historique antérieur inconnu. "
      : "Historique des connexions et demandes clients indisponible. ") +
    "Visites mesurées depuis le " + date(data.collectionStarted) + ". Une demande de téléchargement ne confirme pas une installation.";
  $("visitor-summary").textContent = count(t.pageViews) + " pages vues sur la période · visiteurs uniques non mesurés.";
  $("visitors-note").textContent =
    "Visites anonymes agrégées, pas des personnes uniques. Les usages internes ne peuvent pas être isolés dans cet historique.";
  document.querySelector(".github-panel > .fine").textContent =
    "Téléchargements publics des DMG · cumul des versions publiées, usages internes éventuels compris.";
  $("daily-values").replaceChildren(
    ...data.series.map((s) =>
      row([
        s.date,
        ...[s.pageViews, s.logins, s.accounts, s.downloads].map((n) =>
          n === null ? "—" : count(n),
        ),
        s.receiptsCents === null ? "—" : money(s.receiptsCents),
      ]),
    ),
  );
  const sourceNames = { direct: "Accès direct", other: "Autres sites" };
  $("visit-sources").replaceChildren();
  const max = Math.max(1, ...data.sources.map((s) => s.count));
  for (const s of data.sources) {
    const item = node("div", undefined, "source-row"),
      parts = s.source.split("."),
      page = parts.shift(),
      origin = parts.join(".");
    item.append(
      node(
        "span",
        (sourceNames[origin] || origin) +
          " · " +
          (page === "account" ? "compte" : "site"),
      ),
      node("strong", count(s.count)),
    );
    const track = node("div", undefined, "source-track"),
      fill = node("i");
    fill.style.width = (s.count / max) * 100 + "%";
    track.append(fill);
    item.append(track);
    $("visit-sources").append(item);
  }
  if (!data.sources.length)
    $("visit-sources").append(
      node("p", "Aucune visite mesurée sur la période.", "fine"),
    );
  $("reserve-note").textContent =
    "Réserve comptable encore ouverte : " +
    money(t.pendingReserveCents) +
    (t.flaggedPayments
      ? " · " + count(t.flaggedPayments) + " paiement(s) signalé(s) à vérifier."
      : ".");
  const pr = $("payments-rows");
  if (!data.payments.length)
    empty(pr, 5, "Aucun encaissement enregistré sur cette période.");
  else
    pr.replaceChildren(
      ...data.payments.map((p) =>
        row([
          p.email,
          money(p.amountCents),
          date(p.received),
          date(p.reservedUntil),
          badge(p.flagged
            ? "À vérifier dans Stripe"
            : p.reservedUntil > data.asOf
              ? "Réserve ouverte"
              : "Réserve échue", false),
        ], ["Compte", "Encaissement brut", "Date", "Réserve jusqu’au", "État"]),
      ),
    );
  $("updated").textContent =
    "Mis à jour à " +
    new Date(data.asOf * 1000).toLocaleTimeString("fr-FR", {
      hour: "2-digit",
      minute: "2-digit",
    });
  drawChart();
}
const chartViews = {
  activity: {
    title: "Activité",
    series: [
      { key: "pageViews", name: "Pages vues", color: "#e16437" },
      { key: "logins", name: "Connexions clients", color: "#3c637b" },
      { key: "accounts", name: "Créations de comptes clients", color: "#8c9f8a" },
    ],
  },
  downloads: {
    title: "Téléchargements",
    series: [
      {
        key: "downloads",
        name: "Demandes clients depuis le site et l’application",
        color: "#e16437",
      },
    ],
  },
  receipts: {
    title: "Encaissements bruts",
    series: [
      {
        key: "receiptsCents",
        name: "Encaissements bruts en EUR",
        color: "#e16437",
      },
    ],
    currency: true,
  },
};
let chartView = chartViews.activity;
function renderChartLegend() {
  $("chart-title").textContent = chartView.title;
  $("chart-legend").replaceChildren(
    ...chartView.series.map((s) => {
      const n = node("span", s.name);
      n.style.setProperty("--series", s.color);
      return n;
    }),
  );
}
renderChartLegend();
$("chart-view").onchange = (e) => {
  chartView = chartViews[e.target.value] || chartViews.activity;
  renderChartLegend();
  drawChart();
};
function drawChart(focusIndex) {
  if (!currentData) return;
  const chartSeries = chartView.series;
  const chartNumber = chartView.currency ? (n) => money(n) : count;
  const canvas = $("activity-chart"),
    rect = canvas.getBoundingClientRect(),
    dpr = Math.min(devicePixelRatio || 1, 2),
    w = rect.width,
    h = rect.height;
  if (!w || !h) return;
  canvas.width = w * dpr;
  canvas.height = h * dpr;
  const ctx = canvas.getContext("2d");
  ctx.scale(dpr, dpr);
  const left = chartView.currency ? 70 : 37,
    right = 12,
    top = 24,
    bottom = 29,
    plotW = w - left - right,
    plotH = h - top - bottom,
    rows = currentData.series;
  const available = rows.some((r) => chartSeries.some((s) => r[s.key] > 0));
  $("chart-empty").hidden = available;
  let max = Math.max(
    1,
    ...rows.flatMap((r) => chartSeries.map((s) => r[s.key] || 0)),
  );
  const power = Math.pow(10, Math.floor(Math.log10(max))),
    step = Math.max(1, Math.ceil(max / 4 / power) * power);
  max = step * 4;
  ctx.font = "11px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.textBaseline = "middle";
  for (let tick = 0; tick <= 4; tick++) {
    const y = top + plotH - (tick / 4) * plotH;
    ctx.strokeStyle = "#e9edef";
    ctx.beginPath();
    ctx.moveTo(left, y);
    ctx.lineTo(w - right, y);
    ctx.stroke();
    ctx.fillStyle = "#7d8991";
    ctx.textAlign = "right";
    ctx.fillText(chartNumber(tick * step), left - 9, y);
  }
  const x = (i) =>
      left + (rows.length === 1 ? 0.5 : i / (rows.length - 1)) * plotW,
    y = (v) => top + plotH - (v / max) * plotH;
  const firstMeasured = rows.findIndex((r) => chartSeries.some((s) => r[s.key] !== null));
  if (firstMeasured > 0) {
    const boundary = x(firstMeasured);
    ctx.fillStyle = "#f2f4f580";
    ctx.fillRect(left, top, boundary - left, plotH);
    if (boundary - left > 90) {
      ctx.fillStyle = "#8b969d";
      ctx.textAlign = "left";
      ctx.fillText("Sans mesure", left + 10, top + 15);
    }
  }
  ctx.textAlign = "center";
  for (const i of [
    ...new Set([0, Math.floor((rows.length - 1) / 2), rows.length - 1]),
  ]) {
    ctx.textAlign =
      i === 0 ? "left" : i === rows.length - 1 ? "right" : "center";
    const d = new Date(rows[i].date + "T12:00:00Z");
    ctx.fillText(
      d.toLocaleDateString("fr-FR", {
        day: "numeric",
        month: "short",
        timeZone: "UTC",
      }),
      x(i),
      h - 10,
    );
  }
  for (const [seriesIndex, s] of chartSeries.entries()) {
    const segments = [];
    let segment = [];
    rows.forEach((r, i) => {
      if (r[s.key] === null) {
        if (segment.length) segments.push(segment);
        segment = [];
      } else segment.push({ x: x(i), y: y(r[s.key]), index: i });
    });
    if (segment.length) segments.push(segment);
    if (seriesIndex === 0) {
      const fill = ctx.createLinearGradient(0, top, 0, top + plotH);
      fill.addColorStop(0, s.color + "2e");
      fill.addColorStop(1, s.color + "02");
      ctx.fillStyle = fill;
      for (const points of segments) {
        if (points.length < 2) continue;
        ctx.beginPath();
        ctx.moveTo(points[0].x, top + plotH);
        points.forEach((p) => ctx.lineTo(p.x, p.y));
        ctx.lineTo(points.at(-1).x, top + plotH);
        ctx.closePath();
        ctx.fill();
      }
    }
    ctx.strokeStyle = s.color;
    ctx.lineWidth = seriesIndex === 0 ? 2.5 : 1.8;
    ctx.lineJoin = "round";
    ctx.lineCap = "round";
    for (const points of segments) {
      ctx.strokeStyle = s.color;
      ctx.lineWidth = seriesIndex === 0 ? 2.5 : 1.8;
      ctx.beginPath();
      points.forEach((p, i) => i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y));
      ctx.stroke();
      const point = focusIndex === undefined ? points.at(-1) : points.find((p) => p.index === Math.max(0, Math.min(rows.length - 1, focusIndex)));
      if (point) {
        ctx.fillStyle = s.color;
        ctx.strokeStyle = "#fff";
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.arc(point.x, point.y, focusIndex === undefined ? 3.2 : 4.2, 0, Math.PI * 2);
        ctx.fill();
        ctx.stroke();
      }
    }
  }
  if (focusIndex !== undefined) {
    const i = Math.max(0, Math.min(rows.length - 1, focusIndex)),
      r = rows[i];
    canvas.dataset.focus = String(i);
    ctx.strokeStyle = "#bcc7ce";
    ctx.setLineDash([3, 4]);
    ctx.beginPath();
    ctx.moveTo(x(i), top);
    ctx.lineTo(x(i), top + plotH);
    ctx.stroke();
    ctx.setLineDash([]);
    const tip = $("chart-tooltip");
    tip.textContent =
      r.date +
      " (UTC)\n" +
      chartSeries
        .map(
          (s) =>
            s.name +
            " : " +
            (r[s.key] === null ? "sans mesure" : chartNumber(r[s.key])),
        )
        .join("\n");
    tip.hidden = false;
  } else $("chart-tooltip").hidden = true;
}
$("activity-chart").addEventListener("pointermove", (e) => {
  const r = e.currentTarget.getBoundingClientRect();
  const left = chartView.currency ? 70 : 37;
  if (currentData)
    drawChart(
      Math.round(
        ((e.clientX - r.left - left) / Math.max(1, r.width - left - 12)) *
          (currentData.series.length - 1),
      ),
    );
});
$("activity-chart").addEventListener("pointerleave", () => drawChart());
$("activity-chart").addEventListener("blur", () => drawChart());
$("activity-chart").addEventListener("keydown", (e) => {
  if (
    !currentData ||
    !["ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)
  )
    return;
  e.preventDefault();
  const i = Number(e.currentTarget.dataset.focus || 0);
  drawChart(
    e.key === "Home"
      ? 0
      : e.key === "End"
        ? currentData.series.length - 1
        : i + (e.key === "ArrowRight" ? 1 : -1),
  );
});
new ResizeObserver(() => drawChart()).observe($("activity-chart"));
async function loadAccounts() {
  const request = ++accountRequest;
  $("accounts-pane").setAttribute("aria-busy", "true");
  $("previous-accounts").disabled = $("next-accounts").disabled = true;
  const query = new URLSearchParams({ page: accountPage, pageSize: $("account-page-size").value,
    q: $("account-search").value.trim(), scope: $("account-scope").value,
    access: $("account-access").value, method: $("account-method").value });
  try {
    const a = await api("admin/accounts?" + query);
    if (request !== accountRequest) return;
    $("account-count").textContent = count(a.total) + " compte(s) correspondant(s) · page " + a.page + "/" + Math.max(1, Math.ceil(a.total / a.pageSize));
    $("previous-accounts").disabled = a.page <= 1;
    $("next-accounts").disabled = a.page * a.pageSize >= a.total;
    const body = $("accounts-rows");
    if (!a.items.length) return empty(body, 5, "Aucun compte ne correspond à cette recherche.");
    body.replaceChildren(...a.items.map((u) => {
      const open = node("button", u.email + (u.isInternal ? " · Interne" : ""), "account-open");
      open.type = "button";
      open.setAttribute("aria-label", "Ouvrir la fiche de " + u.email);
      open.onclick = () => { lastAccountTrigger = open; loadAccountDetail(u.id).catch(failure); };
      return row([open, badge(accessLabel(u.access), !!u.access), date(u.created), date(u.last_login), u.devices],
        ["Compte", "Accès", "Créé le", "Dernière connexion", "Mac autorisés"]);
    }));
  } finally {
    if (request === accountRequest) $("accounts-pane").setAttribute("aria-busy", "false");
  }
}
function accessLabel(access) {
  return !access ? "Sans accès actif" : access.owner ? "Accès à vie" : access.plan === "promotional" ? "Accès promotionnel" : access.phase === "trialing" ? "Essai en cours" : access.plan === "lifetime" ? "À vie" : "Abonnement actif";
}
function methodLabel(methods) {
  const labels = [];
  if (methods.password) labels.push("Mot de passe disponible");
  if (methods.google) labels.push("Google associé");
  if (methods.emailLinkObserved) labels.push("Lien e-mail confirmé");
  return labels.join(" · ") || "Méthode historique non conservée";
}
// Client workspace: all remote values are inserted with textContent.
function clientFact(label, value) {
  const item = node("div", undefined, "client-fact");
  item.append(node("dt", label), node("dd", value));
  return item;
}
function clientList(items, render) {
  const list = node("ul", undefined, "client-rows");
  for (const item of items) list.append(render(item));
  return list;
}
function clientTruncation(list, parent) {
  if (list.total > list.items.length) parent.append(node("p", list.items.length + " éléments récents affichés sur " + count(list.total) + ".", "fine"));
}
function clientDisclosure(title, content) {
  const details = node("details", undefined, "client-disclosure");
  details.append(node("summary", title), content);
  return details;
}
function closeClient() {
  detailRequest++;
  activeClientID = null;
  $("account-detail").hidden = true;
  $("accounts-list").hidden = false;
  lastAccountTrigger?.focus({ preventScroll: true });
}
const clientPlan = (value) => ({ monthly: "Mensuel", quarterly: "Trimestriel", semiannual: "Semestriel", annual: "Annuel", lifetime: "À vie", promotional: "Promotionnel" }[value] || value);
const clientPhase = (value) => ({ active: "Actif", trialing: "En essai", revoked: "Révoqué", expired: "Échu", canceled: "Annulé", past_due: "Paiement en attente", unpaid: "Impayé" }[value] || value);
function clientRights(u) {
  const content = node("div"), list = clientList(u.entitlements.items, (e) => {
    const item = node("li"), text = node("div"), until = e.plan === "lifetime" ? "Sans échéance" : e.until ? "Échéance " + date(e.until) : "Échéance non renseignée";
    text.append(node("strong", clientPlan(e.plan)), node("p", until + " · mis à jour le " + date(e.updated)));
    item.append(text, badge(e.blockedReason ? "Paiement à vérifier" : clientPhase(e.status), e.status === "active" && !e.blockedReason));
    return item;
  });
  content.append(list);
  clientTruncation(u.entitlements, content);
  return content;
}
function clientActionForm(u, kind, grant = null, close = null) {
  const form = node("form", undefined, "client-action-form"), requestId = crypto.randomUUID(),
    revoke = kind.startsWith("revoke-"), lifetime = kind.includes("lifetime"),
    heading = node("div", undefined, "client-form-heading"), reason = node("textarea"),
    reasonLabel = node("label", revoke ? "Motif de révocation" : "Motif d’attribution"),
    confirm = node("input"), consent = node("label", undefined, "client-confirm"),
    save = node("button", revoke ? "Confirmer la révocation" : lifetime ? "Confirmer l’accès à vie" : "Confirmer l’accès temporaire"),
    status = node("p", "", "client-form-status");
  const title = revoke ? lifetime ? "Révoquer l’accès à vie accordé" : "Révoquer cet accès temporaire" : lifetime ? "Attribuer un accès à vie" : "Attribuer un accès temporaire";
  heading.append(node("h3", title));
  if (close) { const cancel = node("button", "Annuler", "quiet"); cancel.type = "button"; cancel.onclick = close; heading.append(cancel); }
  reason.id = "client-reason-" + requestId; reason.required = true; reason.minLength = 3; reason.maxLength = 300; reason.rows = 2; reasonLabel.htmlFor = reason.id;
  reason.placeholder = "Ex. accès partenaire, geste commercial…";
  confirm.type = "checkbox"; confirm.required = true;
  consent.append(confirm, node("span", (revoke ? "Je révoque cet accès pour " : lifetime ? "J’accorde un accès à vie à " : "J’accorde cet accès temporaire à ") + u.email + "."));
  form.append(heading, node("p", lifetime ? revoke ? "Seul ce droit accordé est retiré. Les autres droits et la facturation sont conservés." : "Accès permanent, sans renouvellement. La facturation Stripe éventuelle reste inchangée." : revoke ? "Les autres droits du client sont conservés. Une autorisation déjà émise peut rester valide jusqu’à 15 minutes." : "Accès limité, sans abonnement ni renouvellement automatique.", "fine"));
  let duration;
  if (kind === "promotion") {
    duration = node("select"); duration.id = "client-duration-" + requestId;
    const label = node("label", "Durée"), preview = node("p", undefined, "client-expiry"); label.htmlFor = duration.id;
    for (const days of [7, 30, 90]) { const option = node("option", days + " jours"); option.value = days; duration.append(option); }
    const expiry = () => { preview.textContent = "Jusqu’au " + date(u.asOf + Number(duration.value) * 86400) + " environ. L’échéance exacte sera confirmée à l’attribution."; };
    duration.onchange = expiry; expiry();
    const field = node("div", undefined, "client-duration-field"); field.append(label, duration, preview); form.append(field);
  }
  form.append(reasonLabel, reason, consent, save, status);
  status.setAttribute("role", "status"); status.setAttribute("aria-live", "polite");
  form.onsubmit = async (event) => {
    event.preventDefault();
    const value = reason.value.trim();
    if (save.disabled) return;
    if (value.length < 3 || value.length > 300 || !confirm.checked) {
      status.textContent = "Ajoutez un motif de 3 à 300 caractères et confirmez le bénéficiaire.";
      status.dataset.error = "true";
      (value.length < 3 || value.length > 300 ? reason : confirm).focus();
      return;
    }
    const body = { reason: value, requestId, confirmed: true };
    if (duration) body.days = Number(duration.value);
    const endpoint = lifetime ? "lifetime" : "promotions";
    const path = "admin/accounts/" + encodeURIComponent(u.id) + "/" + endpoint + (revoke ? "/" + encodeURIComponent(grant.id || grant.promotionId) + "/revoke" : "");
    save.disabled = true; status.dataset.error = "false"; status.textContent = "Enregistrement…";
    let saved = false;
    try {
      const result = await api(path, body); saved = true;
      const message = revoke ? "Accès révoqué. Les autres droits du client sont conservés." : lifetime ? "Accès à vie attribué à " + u.email + ". Facturation inchangée." : "Accès temporaire attribué jusqu’au " + date(result.until) + ".";
      status.textContent = message;
      if (activeClientID === u.id) await loadAccountDetail(u.id, true);
      await loadAccounts();
      $("admin-status").textContent = message;
    } catch (error) {
      const message = saved ? "Action enregistrée. L’actualisation de la fiche a échoué : " + error.message : error.message;
      status.textContent = message; status.dataset.error = "true";
      $("admin-status").textContent = message;
    } finally { save.disabled = false; }
  };
  return form;
}
function clientAccess(u) {
  const section = node("section", undefined, "client-access"), summary = node("div", undefined, "client-access-summary"),
    actions = node("div", undefined, "client-access-actions"), drawer = node("div", undefined, "client-action-drawer"),
    lifetime = node("button", "Attribuer à vie"), promotion = node("button", "Accès temporaire", "secondary"),
    capability = u.lifetimeAccess, canLifetime = capability?.available === true && capability.canGrant === true,
    canPromotion = !u.isInternal && !u.access;
  drawer.hidden = true;
  drawer.id = "client-action-" + u.id;
  drawer.setAttribute("role", "region"); drawer.setAttribute("aria-label", "Attribution d’accès");
  lifetime.setAttribute("aria-controls", drawer.id); promotion.setAttribute("aria-controls", drawer.id);
  summary.append(node("span", "Droit actif", "client-eyebrow"), node("strong", accessLabel(u.access)),
    node("p", u.access?.plan === "lifetime" ? "Sans échéance" : u.access?.until ? "Jusqu’au " + date(u.access.until) : u.access ? "Échéance non renseignée" : "Aucun droit d’utilisation actif", "client-access-until"));
  lifetime.type = promotion.type = "button";
  lifetime.disabled = !canLifetime; promotion.disabled = !canPromotion;
  lifetime.setAttribute("aria-expanded", "false"); promotion.setAttribute("aria-expanded", "false");
  const blocked = capability?.blockedReason || (canLifetime ? "" : "L’attribution à vie n’est pas disponible pour ce compte.");
  if (blocked) lifetime.title = blocked;
  if (!canPromotion) promotion.title = u.isInternal ? "Compte interne" : "Un accès est déjà actif";
  let actionButton = null;
  const collapse = () => { drawer.hidden = true; lifetime.setAttribute("aria-expanded", "false"); promotion.setAttribute("aria-expanded", "false"); actionButton?.focus({ preventScroll: true }); };
  const choose = (button, kind) => {
    if (button.disabled) return;
    const wasOpen = button.getAttribute("aria-expanded") === "true"; collapse();
    if (wasOpen) return;
    actionButton = button;
    drawer.replaceChildren(clientActionForm(u, kind, null, collapse)); drawer.hidden = false;
    button.setAttribute("aria-expanded", "true"); drawer.querySelector("textarea")?.focus({ preventScroll: true });
  };
  lifetime.onclick = () => choose(lifetime, "lifetime"); promotion.onclick = () => choose(promotion, "promotion");
  actions.append(lifetime, promotion);
  section.append(summary, actions);
  if (blocked && u.access?.plan !== "lifetime") section.append(node("p", blocked, "client-access-note"));
  const wrapper = node("div"); wrapper.append(section, drawer);
  return wrapper;
}
function renderClientDetail(u) {
  const wrapper = node("div", undefined, "client-workspace"), toolbar = node("div", undefined, "client-toolbar"),
    back = node("button", "← Tous les clients", "quiet"), head = node("div", undefined, "client-profile-head"),
    avatar = node("div", (u.email || "?").slice(0, 1).toUpperCase(), "client-monogram"), identity = node("div", undefined, "client-identity"),
    tabs = node("div", undefined, "client-detail-tabs"), panels = node("div", undefined, "client-panels");
  back.type = "button"; back.onclick = closeClient;
  toolbar.append(back, node("span", "Fiche client", "client-breadcrumb"));
  avatar.setAttribute("aria-hidden", "true");
  identity.append(node("span", u.isInternal ? "COMPTE INTERNE" : "CLIENT PLAYMELT", "client-eyebrow"), node("h2", u.email), node("p", methodLabel(u.methods), "client-identity-meta"));
  head.append(avatar, identity, badge(u.access ? "Accès actif" : "Sans accès", !!u.access));
  wrapper.append(toolbar, head, clientAccess(u), tabs, panels);
  tabs.setAttribute("role", "tablist"); tabs.setAttribute("aria-label", "Détails du client");
  const choices = [];
  const addTab = (key, label, panel) => {
    const button = node("button", label); button.type = "button"; button.id = "client-tab-" + key;
    panel.id = "client-panel-" + key; panel.className = "client-tabpanel"; panel.setAttribute("role", "tabpanel"); panel.setAttribute("aria-labelledby", button.id);
    button.setAttribute("role", "tab"); button.setAttribute("aria-controls", panel.id);
    tabs.append(button); panels.append(panel); choices.push({ key, button, panel });
    button.onclick = () => { clientTab = key; select(); };
    button.onkeydown = (event) => {
      if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
      event.preventDefault(); const i = choices.findIndex((x) => x.key === key);
      const target = event.key === "Home" ? 0 : event.key === "End" ? choices.length - 1 : (i + (event.key === "ArrowRight" ? 1 : -1) + choices.length) % choices.length;
      choices[target].button.click(); choices[target].button.focus();
    };
  };
  const account = node("div"), facts = node("dl", undefined, "client-facts");
  for (const [label, value] of [["Inscription", date(u.created)], ["Dernière connexion", date(u.lastLogin)], ["Connexion", methodLabel(u.methods)], ["Dernier Mac associé", date(u.lastPair)],
    ["Téléchargements demandés", count(u.downloadRequests.total)], ["Dernière demande", date(u.downloadRequests.lastRequested)]]) facts.append(clientFact(label, value));
  account.append(facts);
  if (u.entitlements.total) account.append(clientDisclosure("Droits enregistrés · " + count(u.entitlements.total), clientRights(u)));
  const grantActions = node("div");
  for (const grant of u.lifetimeAccess?.revocableGrants || []) grantActions.append(clientDisclosure("Révoquer l’accès à vie accordé le " + date(grant.created), clientActionForm(u, "revoke-lifetime", grant)));
  for (const grant of u.revocablePromotions || []) grantActions.append(clientDisclosure("Révoquer l’accès temporaire · échéance " + date(grant.until), clientActionForm(u, "revoke-promotion", grant)));
  if (grantActions.childElementCount) account.append(grantActions);
  const technical = node("div", undefined, "client-details-note");
  technical.append(node("p", "Identifiant : " + u.id), node("p", u.billingLinked ? "Compte de facturation associé. L’état d’annulation et les règlements restent à vérifier dans Stripe." : "Aucun compte de facturation associé."));
  if (u.trial) technical.append(node("p", "Essai enregistré : " + date(u.trial.started) + " → " + date(u.trial.until)));
  technical.append(node("p", "Les méthodes de connexion reflètent les données conservées. La source de l’inscription historique peut être inconnue."));
  if (u.ownerCodes.total) technical.append(node("p", count(u.ownerCodes.total) + " code(s) propriétaire enregistré(s). Aucun code secret n’est exposé."));
  account.append(clientDisclosure("Informations du compte", technical));
  addTab("account", "Compte", account);
  if (u.devices.total) {
    const panel = node("div"), list = clientList(u.devices.items, (d) => { const item = node("li"), text = node("div"); text.append(node("strong", d.label), node("p", "Associé le " + date(d.created))); item.append(text, badge(d.revoked ? "Révoqué" : "Autorisé", !d.revoked)); return item; });
    panel.append(list); clientTruncation(u.devices, panel); addTab("devices", "Appareils · " + count(u.devices.total), panel);
  }
  const events = [...(u.promotionAudit?.items || []).map((a) => ({ ...a, lifetime: false })), ...(u.lifetimeAccess?.audit?.items || []).map((a) => ({ ...a, lifetime: true }))].sort((a, b) => b.created - a.created);
  if (events.length) {
    const panel = node("div"), list = clientList(events, (a) => { const item = node("li"), text = node("div"); text.append(node("strong", a.action === "grant" ? a.lifetime ? "Accès à vie attribué" : "Accès temporaire · " + a.days + " jours" : a.lifetime ? "Accès à vie révoqué" : "Accès temporaire révoqué"), node("p", a.reason), node("small", a.actor + " · " + date(a.created))); item.append(text); return item; });
    panel.append(list); clientTruncation({ total: (u.promotionAudit?.total || 0) + (u.lifetimeAccess?.audit?.total || 0), items: events }, panel); addTab("history", "Historique · " + count((u.promotionAudit?.total || 0) + (u.lifetimeAccess?.audit?.total || 0)), panel);
  }
  if (u.payments.total) {
    const panel = node("div"); panel.append(clientList(u.payments.items, (p) => { const item = node("li"); item.append(node("strong", p.currency?.toLowerCase() === "eur" ? money(p.amountCents) : (p.amountCents / 100) + " " + p.currency), node("span", date(p.received))); return item; }));
    clientTruncation(u.payments, panel); addTab("payments", "Paiements · " + count(u.payments.total), panel);
  }
  if (u.support.total) {
    const panel = node("div"); panel.append(clientList(u.support.items, (s) => { const item = node("li"), text = node("div"); text.append(node("strong", s.category), node("p", date(s.created))); item.append(text, badge(supportStatusNames[s.status] || s.status, false)); return item; }));
    clientTruncation(u.support, panel); addTab("support", "Support · " + count(u.support.total), panel);
  }
  function select() {
    if (!choices.some((x) => x.key === clientTab)) clientTab = "account";
    for (const item of choices) { const active = item.key === clientTab; item.panel.hidden = !active; item.button.tabIndex = active ? 0 : -1; item.button.setAttribute("aria-selected", String(active)); }
  }
  select(); return wrapper;
}
async function loadAccountDetail(id, preserveTab = false) {
  const request = ++detailRequest, detail = $("account-detail");
  if (!preserveTab || activeClientID !== id) clientTab = "account";
  activeClientID = id; detail.hidden = false; $("accounts-list").hidden = true;
  detail.setAttribute("aria-busy", "true");
  const loading = node("div", undefined, "client-loading"), back = node("button", "← Tous les clients", "quiet"); back.type = "button"; back.onclick = closeClient;
  loading.append(back, node("p", "Chargement du client…")); detail.replaceChildren(loading);
  try {
    const u = await api("admin/accounts/" + encodeURIComponent(id));
    if (request !== detailRequest) return;
    detail.replaceChildren(renderClientDetail(u));
    detail.focus({ preventScroll: true });
    if (!preserveTab) detail.scrollIntoView({ block: "start", behavior: "auto" });
  } catch (error) {
    if (request === detailRequest) loading.append(node("p", error.message, "client-load-error"));
    throw error;
  } finally {
    if (request === detailRequest) detail.setAttribute("aria-busy", "false");
  }
}
// Registration queue.
async function loadRegistrations() {
  const request = ++registrationRequest;
  $("registrations-pane").setAttribute("aria-busy", "true");
  $("previous-registrations").disabled = $("next-registrations").disabled = true;
  try {
    const query = new URLSearchParams({ page: registrationPage, q: $("registration-search").value.trim() });
    const r = await api("admin/registrations?" + query);
    if (request !== registrationRequest) return;
    $("registration-count").textContent = count(r.total) + " adresse(s) en attente · page " + r.page + "/" + Math.max(1, Math.ceil(r.total / r.pageSize));
    $("previous-registrations").disabled = r.page <= 1;
    $("next-registrations").disabled = r.page * r.pageSize >= r.total;
    const body = $("registrations-rows");
    if (!r.items.length) return empty(body, 4, "Aucune vérification encore valide ne correspond à cette recherche.");
    body.replaceChildren(...r.items.map((u) => row([u.email, u.passwordRequested ? "Vérification avec mot de passe demandé" : "Vérification par lien e-mail", count(u.pendingLinks), date(u.expires)], ["E-mail", "Demande", "Liens valides", "Dernière expiration"])));
  } finally {
    if (request === registrationRequest) $("registrations-pane").setAttribute("aria-busy", "false");
  }
}
async function loadGitHub() {
  const g = await api("admin/github");
  $("github-total").textContent = g.available ? count(g.total) : "—";
  $("github-state").textContent = !g.available
    ? "Indisponible"
    : g.stale
      ? "Dernier relevé conservé"
      : "Relevé à " +
        new Date(g.observed * 1000).toLocaleTimeString("fr-FR", {
          hour: "2-digit",
          minute: "2-digit",
        });
  $("github-assets").replaceChildren();
  for (const a of g.assets || []) {
    const r = node("div", undefined, "asset-row");
    r.append(node("span", a.name), node("strong", count(a.downloads)));
    $("github-assets").append(r);
  }
  if (g.available && !g.assets.length)
    $("github-assets").append(
      node("p", "Aucun DMG publié sur GitHub.", "fine"),
    );
  if (g.truncated)
    $("github-assets").append(
      node("p", "Relevé limité aux 300 versions les plus récentes.", "fine"),
    );
}
const supportStatusNames = {
  open: "Ouvert", received: "Reçu", investigating: "En cours d’analyse",
  fixed: "Correctif apporté", verified: "Vérifié manuellement", closed: "Clôturé",
};
const supportDeliveryNames = {
  pending: "En attente d’envoi", sending: "Envoi en cours",
  smtp_accepted: "Acceptée par le relais SMTP ; réception non confirmée",
  unconfirmed: "Acceptation SMTP non confirmée", failed: "Échec d’envoi",
};
let selectedSupportId = null;
function showSupport(t) {
  selectedSupportId = t.id;
  document.querySelectorAll("#support-list > button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.ticket === t.id)));
  const detail = $("support-detail");
  detail.replaceChildren(node("h3", t.email));
  if (t.game) {
    detail.append(node("h4", t.game.gameTitle), node("p",
      t.game.store + " · " + t.game.gameId + " · " + t.category +
      "\nSignalement enregistré le " + date(t.created), "fine"));
  }
  detail.append(node("p", t.message, "support-message"));
  if (t.game) {
    const diagnostics = Object.entries(t.game.diagnostics || {});
    if (diagnostics.length) {
      const box = node("details"), values = node("dl", undefined, "support-diagnostics");
      box.append(node("summary", "Informations techniques transmises"));
      for (const [key, value] of diagnostics) values.append(node("dt", key), node("dd", typeof value === "boolean" ? value ? "Oui" : "Non" : String(value)));
      box.append(values);
      detail.append(box);
    }
    const form = node("form", undefined, "support-state-form"),
      label = node("label", "Statut du signalement"), select = node("select"),
      save = node("button", "Enregistrer le statut");
    select.id = "support-state";
    label.htmlFor = select.id;
    for (const status of ["received", "investigating", "fixed", "verified", "closed"]) {
      const option = node("option", supportStatusNames[status]);
      option.value = status;
      option.selected = status === t.status;
      select.append(option);
    }
    form.append(label, select, node("p", "Chaque changement est attribué à votre compte et conservé. Le statut « Vérifié » demande votre contrôle effectif.", "fine"), save);
    form.onsubmit = async (e) => {
      e.preventDefault();
      save.disabled = true;
      try {
        await api("admin/support/" + encodeURIComponent(t.id) + "/status", { status: select.value });
        await loadSupport(t.id);
      } catch (error) { failure(error); }
      finally { save.disabled = false; }
    };
    detail.append(form);
    const notification = t.game.notification;
    if (notification) {
      detail.append(node("p", "Notification interne : " +
        (supportDeliveryNames[notification.delivery] || notification.delivery) +
        ". Tentatives : " + notification.attempts + "/3 · " + date(notification.updated), "fine"));
      if (notification.delivery !== "smtp_accepted" && notification.attempts < 3) {
        const retry = node("button", "Réessayer la notification", "secondary");
        retry.disabled = notification.delivery === "sending" && notification.updated > Date.now() / 1000 - 120;
        retry.onclick = async () => {
          retry.disabled = true;
          try {
            await api("admin/support/" + encodeURIComponent(t.id) + "/notification/retry", {});
            await loadSupport(t.id);
          } catch (error) { failure(error); }
          finally { retry.disabled = false; }
        };
        detail.append(retry);
      }
    }
    if (t.game.audit.length) {
      const history = node("details"), list = node("ol", undefined, "support-history");
      history.append(node("summary", "Historique des statuts"));
      for (const entry of t.game.audit) list.append(node("li",
        date(entry.created) + " · " + entry.actor + "\n" +
        (supportStatusNames[entry.previousStatus] || entry.previousStatus) + " → " + (supportStatusNames[entry.status] || entry.status)));
      history.append(list);
      detail.append(history);
    }
  }
  if (t.replies?.length) {
    const history = node("details"), list = node("ol", undefined, "support-history");
    history.append(node("summary", "Réponses enregistrées (" + t.replies.length + ")"));
    for (const reply of t.replies) list.append(node("li", date(reply.created) + " · " +
      (supportDeliveryNames[reply.delivery] || reply.delivery) + "\n" + reply.body));
    history.append(list);
    detail.append(history);
  }
  const form = node("form"), label = node("label", "Votre réponse"),
    input = node("textarea"), send = node("button", "Enregistrer et envoyer");
  input.id = "support-reply";
  input.required = true;
  input.maxLength = 5000;
  label.htmlFor = input.id;
  form.append(label, input, send);
  form.onsubmit = async (e) => {
    e.preventDefault();
    send.disabled = true;
    try {
      const r = await api("admin/support/" + encodeURIComponent(t.id) + "/reply", { message: input.value });
      await loadSupport(t.id);
      $("support-detail").append(node("p", r.delivery === "smtp_accepted"
        ? "Réponse enregistrée et acceptée par le relais mail. La réception reste à confirmer."
        : "Réponse enregistrée ; envoi non confirmé.", "fine"));
    } catch (error) { failure(error); }
    finally { send.disabled = false; }
  };
  detail.append(form);
}
async function loadSupport(selectedId = selectedSupportId) {
  const tickets = await api("admin/support");
  $("support-list").replaceChildren();
  if (!tickets.length)
    $("support-list").append(node("p", "Aucune demande reçue.", "fine"));
  for (const t of tickets) {
    const b = node(
      "button",
      t.email + "\n" + (t.game ? t.game.gameTitle + " · " : "") +
        t.category + " · " + date(t.created) + "\n" + (supportStatusNames[t.status] || t.status),
    );
    b.dataset.ticket = t.id;
    b.setAttribute("aria-pressed", String(t.id === selectedId));
    b.onclick = () => {
      showSupport(t);
      if (matchMedia("(max-width: 600px)").matches) $("support-detail").scrollIntoView({ block: "start" });
    };
    $("support-list").append(b);
    if (t.id === selectedId) showSupport(t);
  }
}
document.querySelectorAll("[data-pane]").forEach((button, index, tabs) => {
  const choose = () => {
    tabs.forEach((b) => {
      const active = b === button;
      b.setAttribute("aria-selected", String(active));
      b.tabIndex = active ? 0 : -1;
      $(b.dataset.pane + "-pane").hidden = !active;
    });
    if (button.dataset.pane === "support") loadSupport().catch(failure);
    if (button.dataset.pane === "registrations") loadRegistrations().catch(failure);
  };
  button.onclick = choose;
  button.onkeydown = (e) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)) return;
    e.preventDefault();
    const next =
      e.key === "Home"
        ? 0
        : e.key === "End"
          ? tabs.length - 1
          : (index + (e.key === "ArrowRight" ? 1 : -1) + tabs.length) %
            tabs.length;
    tabs[next].click();
    tabs[next].focus();
  };
});
async function refresh() {
  if (busy) return;
  busy = true;
  $("refresh").disabled = true;
  $("admin-status").textContent = "";
  try {
    const d = await api("admin/overview?days=" + period);
    renderOverview(d);
    $("admin-content").hidden = false;
    drawChart();
    await Promise.all([loadAccounts(), loadGitHub(), ...(activeClientID ? [loadAccountDetail(activeClientID, true)] : [])]);
  } catch (e) {
    failure(e);
  } finally {
    busy = false;
    $("refresh").disabled = false;
  }
}
document.querySelectorAll("[data-days]").forEach(
  (b) =>
    (b.onclick = () => {
      period = Number(b.dataset.days);
      document
        .querySelectorAll("[data-days]")
        .forEach((p) => p.setAttribute("aria-pressed", String(p === b)));
      refresh();
    }),
);
$("refresh").onclick = refresh;
$("account-filters").onsubmit = (e) => {
  e.preventDefault();
  accountPage = 1;
  $("admin-status").textContent = "";
  loadAccounts().catch(failure);
};
$("reset-accounts").onclick = () => {
  $("account-filters").reset();
  accountPage = 1;
  loadAccounts().catch(failure);
};
$("registration-filters").onsubmit = (e) => {
  e.preventDefault();
  registrationPage = 1;
  loadRegistrations().catch(failure);
};
$("previous-registrations").onclick = () => {
  registrationPage = Math.max(1, registrationPage - 1);
  loadRegistrations().catch(failure);
};
$("next-registrations").onclick = () => {
  registrationPage++;
  loadRegistrations().catch(failure);
};
$("previous-accounts").onclick = () => {
  accountPage = Math.max(1, accountPage - 1);
  loadAccounts().catch(failure);
};
$("next-accounts").onclick = () => {
  accountPage++;
  loadAccounts().catch(failure);
};
refresh();
