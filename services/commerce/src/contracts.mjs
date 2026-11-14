import { digest } from "./store.mjs";

export function retainTerms(store, config) {
  if (!config.termsHTML) return;
  if (digest(config.termsHTML) !== config.termsSHA256)
    throw Error("Terms document does not match the accepted fingerprint");
  store.run(
    "INSERT OR IGNORE INTO terms_documents VALUES(?,?,?,?)",
    config.termsSHA256,
    config.termsVersion,
    config.termsHTML,
    store.now(),
  );
}

/** Called only after retrieving a complete Checkout and its actual entitlement. */
export function confirmContract(store, session, user, entitlement, plan) {
  const contract = store.get(
    "SELECT * FROM checkout_contracts WHERE checkout_id=? AND user_id=?",
    session.id,
    user.id,
  );
  if (
    !contract ||
    !entitlement ||
    entitlement.user_id !== user.id ||
    !["active", "trialing"].includes(entitlement.status) ||
    (entitlement.until !== null && (!Number.isSafeInteger(entitlement.until) || entitlement.until <= store.now())) ||
    (entitlement.payment_intent && store.get("SELECT payment_intent FROM blocked_payments WHERE payment_intent=?", entitlement.payment_intent)) ||
    session.status !== "complete"
  )
    return;
  if (contract.plan !== entitlement.plan) throw Error("Contract plan mismatch");
  if (
    !Number.isSafeInteger(session.amount_total) ||
    session.amount_total < 0 ||
    session.currency !== "eur"
  )
    throw Error("Contract amount missing from verified Checkout");
  const summary = {
    reference: session.id,
    plan: contract.plan,
    label: plan.label,
    paidNowCents: session.amount_total,
    currency: "EUR",
    recurringCents: plan.months ? plan.cents : null,
    periodMonths: plan.months || null,
    phase: entitlement.status,
    until: entitlement.until,
  };
  store.run(
    "UPDATE checkout_contracts SET confirmed=?,summary=?,updated=? WHERE checkout_id=? AND confirmed IS NULL",
    store.now(),
    JSON.stringify(summary),
    store.now(),
    session.id,
  );
}

const escaped = (text) =>
  String(text).replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const euros = (cents) =>
  new Intl.NumberFormat("fr-FR", { style: "currency", currency: "EUR" }).format(
    cents / 100,
  );
const date = (seconds) =>
  new Intl.DateTimeFormat("fr-FR", {
    dateStyle: "long",
    timeStyle: "short",
    timeZone: "Europe/Paris",
  }).format(new Date(seconds * 1000));
const sending = new WeakMap();

/** An SMTP failure keeps the durable outbox pending for Stripe's next retry. */
export function sendContract(store, mailer, config, checkoutID) {
  const previous = sending.get(store) || Promise.resolve();
  const task = previous
    .catch(() => {})
    .then(async () => {
      const row = store.get(
        "SELECT c.*,u.email,d.html,d.version FROM checkout_contracts c JOIN users u ON u.id=c.user_id JOIN terms_documents d ON d.sha256=c.terms_sha256 WHERE c.checkout_id=? AND c.confirmed IS NOT NULL",
        checkoutID,
      );
      if (!row || row.delivery === "smtp_accepted") return;
      const claimed = store.run(
        "UPDATE checkout_contracts SET delivery='sending',attempts=attempts+1,updated=? WHERE checkout_id=? AND (delivery!='sending' OR updated<=?)",
        store.now(),
        checkoutID,
        store.now() - 120,
      );
      if (!claimed.changes)
        throw Error("Contract delivery already in progress");
      const s = JSON.parse(row.summary);
      const lines = [
        "Votre accès Playmelt est confirmé.",
        "Référence : " + s.reference,
        "Offre : " + s.label,
        "Montant de la commande à cette étape : " + euros(s.paidNowCents),
        s.phase === "trialing"
          ? "Essai actif jusqu’au " +
            date(s.until) +
            ". Carte enregistrée par Stripe. Aucun prix d’abonnement prélevé pendant l’essai."
          : "Accès actif" +
            (s.until ? " jusqu’au " + date(s.until) : " à vie") +
            ".",
        s.periodMonths
          ? "Tarif hors réduction : " +
            euros(s.recurringCents) +
            " tous les " +
            s.periodMonths +
            " mois. Les réductions et prochaines échéances exactes figurent dans votre portail Stripe."
          : "Paiement unique, sans renouvellement automatique.",
        "Conditions acceptées le " +
          date(row.accepted) +
          " (version " +
          row.version +
          "). Une copie intégrale est jointe à ce message.",
        "Gérer l’abonnement ou demander une assistance : " +
          config.publicURL +
          "/",
        "Droit de rétractation : 14 jours à compter de la conclusion du contrat. Une déclaration claire à " +
          config.supportEmail +
          " suffit. Le modèle facultatif figure dans les conditions jointes.",
        "7AGENCY — Nathan VENDRELL EI · SIRET 82157370600057",
        "2 rue du Docteur Rebatel, 69003 Lyon, France",
        "TVA non applicable, article 293 B du CGI.",
      ];
      try {
        const result = await mailer.sendMail({
          from: config.mailFrom,
          to: { address: row.email },
          replyTo: config.supportEmail,
          messageId:
            "<playmelt-contract-" +
            digest(checkoutID).slice(0, 32) +
            "@7agency.fr>",
          subject: "Playmelt — confirmation de votre accès",
          text: lines.join("\n\n"),
          html:
            '<!doctype html><html lang="fr"><meta charset="utf-8"><body style="margin:0;background:#f2f4f5;color:#20282c;font:15px/1.65 -apple-system,BlinkMacSystemFont,Arial,sans-serif"><main style="max-width:640px;margin:32px auto;background:#fff;border:1px solid #dce1e5;border-radius:24px;overflow:hidden"><div style="padding:28px 32px;border-top:4px solid #f2633b"><strong style="font-size:24px">playmelt</strong><h1 style="font-size:28px;line-height:1.2;margin:24px 0">Votre accès est confirmé.</h1>' +
            lines
              .slice(1)
              .map(
                (line) =>
                  '<p style="margin:0 0 18px">' + escaped(line) + "</p>",
              )
              .join("") +
            "</div></main></body></html>",
          attachments: [
            {
              filename: "Playmelt-conditions-" + row.version + ".html",
              content: row.html,
              contentType: "text/html; charset=utf-8",
            },
          ],
        });
        if (
          !Array.isArray(result?.accepted) ||
          !result.accepted.includes(row.email)
        )
          throw Error("SMTP did not confirm this recipient");
        store.run(
          "UPDATE checkout_contracts SET delivery='smtp_accepted',updated=? WHERE checkout_id=?",
          store.now(),
          checkoutID,
        );
      } catch (error) {
        store.run(
          "UPDATE checkout_contracts SET delivery='failed',updated=? WHERE checkout_id=?",
          store.now(),
          checkoutID,
        );
        throw error;
      }
    });
  sending.set(store, task);
  task
    .finally(() => {
      if (sending.get(store) === task) sending.delete(store);
    })
    .catch(() => {});
  return task;
}
