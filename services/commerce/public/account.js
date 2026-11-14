"use strict";
const base = document.querySelector("meta[name=api-base]").content,
  $ = (id) => document.getElementById(id),
  status = $("status");
const messages = {
  sign_in_required: "Connectez-vous pour continuer.",
  expired_link: "Ce lien a expiré. Demandez-en un nouveau.",
  invalid_link: "Ce lien ne peut pas être utilisé.",
  too_many_requests: "Trop de tentatives. Réessayez dans quelques minutes.",
  checkout_pending:
    "Un paiement est déjà en cours. Reprenez-le ou attendez son expiration.",
  already_subscribed: "Votre accès est déjà actif.",
  terms_acceptance_required:
    "Lisez et acceptez les conditions de vente avant de continuer.",
  service_unavailable:
    "Service temporairement indisponible. Réessayez plus tard.",
};
async function api(path, data) {
  const r = await fetch(base + "/v1/" + path, {
    method: data ? "POST" : "GET",
    credentials: "same-origin",
    headers: data ? { "Content-Type": "application/json" } : {},
    body: data ? JSON.stringify(data) : undefined,
  });
  const body = await r.json();
  if (!r.ok) throw Error(body.error || "service_unavailable");
  return body;
}
function report(e) {
  status.textContent =
    messages[e.message] || "Cette action n’a pas pu être effectuée.";
}
function paragraph(text) {
  const p = document.createElement("p");
  p.textContent = text;
  return p;
}
function title(text, tag = "h2") {
  const h = document.createElement(tag);
  h.textContent = text;
  return h;
}
function button(text, action, secondary = false) {
  const b = document.createElement("button");
  b.type = "button";
  b.textContent = text;
  if (secondary) b.className = "secondary";
  b.onclick = async () => {
    b.disabled = true;
    try {
      await action();
    } catch (e) {
      report(e);
    } finally {
      b.disabled = false;
    }
  };
  return b;
}
function localLink(text, url) {
  const u = new URL(url, location.href);
  if (u.origin !== location.origin) throw Error("invalid_request");
  const a = document.createElement("a");
  a.textContent = text;
  a.href = u.href;
  return a;
}
async function showPlans(me, legal) {
  $("plans").hidden = !!me.entitlement;
  if (me.entitlement) return;
  const grid = $("plan-list");
  grid.replaceChildren();
  const label = document.createElement("label");
  label.className = "consent";
  const check = document.createElement("input");
  check.id = "accept-terms";
  check.type = "checkbox";
  const copy = document.createElement("span");
  copy.append(
    "J’ai lu et j’accepte les ",
    localLink("conditions de vente", legal.url),
    ".",
  );
  label.append(check, copy);
  $("plan-consent").replaceChildren(
    label,
    paragraph(
      "Le code promo se saisit sur la page sécurisée de Stripe. Aucun numéro de carte n’est conservé par Playmelt.",
    ),
  );
  const plans = await api("plans");
  const tabs = document.createElement("div");
  tabs.className = "plan-options";
  tabs.setAttribute("role", "tablist");
  tabs.setAttribute("aria-label", "Durée de l’accès");
  const summary = document.createElement("article");
  summary.className = "plan-summary";
  summary.id = "plan-detail";
  summary.setAttribute("role", "tabpanel");
  grid.append(tabs, summary);
  const choose = (index) => {
    const p = plans[index],
      trial = p.months && !me.trialUsed;
    check.checked = false;
    [...tabs.children].forEach((tab, i) => {
      tab.setAttribute("aria-selected", String(i === index));
      tab.tabIndex = i === index ? 0 : -1;
    });
    const price = document.createElement("strong");
    price.className = "chosen-price";
    price.textContent = new Intl.NumberFormat("fr-FR", {
      style: "currency",
      currency: "EUR",
    }).format(p.cents / 100);
    const detail = p.months
      ? trial
        ? "30 jours offerts. Carte demandée au départ. Premier débit à la fin de l’essai, puis renouvellement tous les " +
          p.months +
          " mois."
        : "Renouvellement tous les " + p.months + " mois."
      : "Paiement unique. Sans période d’essai ni renouvellement.";
    summary.setAttribute("aria-labelledby", "plan-tab-" + index);
    summary.replaceChildren(
      title(
        trial
          ? "30 jours pour essayer Playmelt"
          : p.months
            ? "Votre abonnement Playmelt"
            : "Votre accès à vie",
        "h3",
      ),
      price,
      paragraph(detail),
      button(
        trial ? "Commencer les 30 jours offerts" : "Continuer vers le paiement",
        async () => {
          if (!check.checked) {
            check.focus();
            throw Error("terms_acceptance_required");
          }
          const result = await api("checkout", {
            plan: p.id,
            acceptTerms: true,
            termsVersion: legal.version,
          });
          if (new URL(result.url).origin !== "https://checkout.stripe.com")
            throw Error("invalid_request");
          location.assign(result.url);
        },
      ),
    );
  };
  plans.forEach((p, index) => {
    const tab = document.createElement("button");
    tab.type = "button";
    tab.id = "plan-tab-" + index;
    tab.textContent = p.label;
    tab.setAttribute("role", "tab");
    tab.setAttribute("aria-controls", "plan-detail");
    tab.onclick = () => choose(index);
    tab.onkeydown = (e) => {
      let next;
      if (e.key === "ArrowRight") next = (index + 1) % plans.length;
      else if (e.key === "ArrowLeft")
        next = (index + plans.length - 1) % plans.length;
      else if (e.key === "Home") next = 0;
      else if (e.key === "End") next = plans.length - 1;
      else return;
      e.preventDefault();
      choose(next);
      tabs.children[next].focus();
    };
    tabs.append(tab);
  });
  choose(0);
}
async function showSupport() {
  $("support").hidden = false;
  const list = $("support-history");
  list.replaceChildren();
  for (const t of await api("support")) {
    const article = document.createElement("article");
    article.className = "ticket";
    article.append(
      title(t.category + " · " + t.id.slice(0, 8), "h3"),
      paragraph(t.message),
    );
    for (const reply of t.replies)
      article.append(paragraph("Playmelt : " + reply.body));
    list.append(article);
  }
}
async function reload() {
  let me;
  try {
    me = await api("me");
  } catch (e) {
    if (e.message === "sign_in_required") return;
    throw e;
  }
  const legal = await api("legal"),
    panel = $("account");
  panel.replaceChildren(title("Votre accès"), paragraph(me.email));
  if (me.entitlement) {
    const date = me.entitlement.until
      ? new Date(me.entitlement.until * 1000).toLocaleDateString("fr-FR")
      : null;
    panel.append(
      paragraph(
        date
          ? (me.entitlement.phase === "trialing"
              ? "Essai gratuit jusqu’au "
              : "Accès actif jusqu’au ") + date
          : "Accès à vie actif",
      ),
    );
  }
  panel.append(
    button(
      "Gérer ou résilier mon abonnement",
      async () => {
        const result = await api("billing/portal", {});
        if (new URL(result.url).origin !== "https://billing.stripe.com")
          throw Error("invalid_request");
        location.assign(result.url);
      },
      true,
    ),
  );
  if (me.devices.length) panel.append(title("Vos appareils", "h3"));
  for (const d of me.devices) {
    const row = document.createElement("div");
    row.className = "device-row";
    row.append(paragraph(d.label + (d.revoked ? " · accès retiré" : "")));
    if (!d.revoked)
      row.append(
        button(
          "Retirer l’accès",
          async () => {
            await api("devices/revoke", { id: d.id });
            await reload();
          },
          true,
        ),
      );
    panel.append(row);
  }
  panel.append(
    button(
      "Se déconnecter",
      async () => {
        await api("auth/logout", {});
        location.assign(base + "/");
      },
      true,
    ),
  );
  $("device").hidden = false;
  await Promise.all([showPlans(me, legal), showSupport()]);
}
$("login").onsubmit = async (e) => {
  e.preventDefault();
  const b = e.target.querySelector("button");
  b.disabled = true;
  try {
    await api("auth/email", { email: $("email").value });
    status.textContent =
      "Si cette adresse peut recevoir nos messages, un lien de connexion vient de lui être envoyé.";
  } catch (error) {
    report(error);
  } finally {
    b.disabled = false;
  }
};
$("device-form").onsubmit = async (e) => {
  e.preventDefault();
  try {
    await api("device/approve", { code: $("code").value });
    status.textContent = "Appareil autorisé. Revenez dans Playmelt.";
    await reload();
  } catch (error) {
    report(error);
  }
};
$("support-form").onsubmit = async (e) => {
  e.preventDefault();
  const b = e.target.querySelector("button");
  b.disabled = true;
  try {
    const t = await api("support", {
      category: $("support-category").value,
      message: $("support-message").value,
    });
    $("support-message").value = "";
    status.textContent = "Demande enregistrée : " + t.id.slice(0, 8) + ".";
    await showSupport();
  } catch (error) {
    report(error);
  } finally {
    b.disabled = false;
  }
};
const magic = new URLSearchParams(location.hash.slice(1)).get("token");
if (magic) {
  history.replaceState(null, "", location.pathname);
  $("account").replaceChildren(
    paragraph("Confirmez votre connexion à Playmelt."),
    button("Continuer", async () => {
      await api("auth/confirm", { token: magic });
      status.textContent = "Connexion réussie.";
      await reload();
    }),
  );
} else reload().catch(report);
