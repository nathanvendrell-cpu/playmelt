export const plans = {
  monthly: { cents: 1999, months: 1, label: "1 mois" },
  quarterly: { cents: 5399, months: 3, label: "3 mois" },
  semiannual: { cents: 9599, months: 6, label: "6 mois" },
  annual: { cents: 16799, months: 12, label: "1 an" },
  lifetime: { cents: 39900, label: "À vie" },
};
const id = (x) => (typeof x === "string" ? x : x?.id);
function reservePayment(
  store,
  userID,
  reference,
  paymentIntent,
  amount,
  currency,
) {
  if (!Number.isSafeInteger(amount) || amount <= 0 || currency !== "eur")
    return;
  // Internal reserve from receipt, not a claim that Stripe payouts are delayed.
  store.run(
    "INSERT OR IGNORE INTO payment_reserves VALUES(?,?,?,?,?,?,?)",
    reference,
    userID,
    paymentIntent ?? null,
    amount,
    currency,
    store.now(),
    store.now() + 14 * 86400,
  );
}
function validLifetimePurchase(session, priceID) {
  const lines = session.line_items?.data;
  const subtotal = session.amount_subtotal,
    discount = session.total_details?.amount_discount ?? 0,
    tax = session.total_details?.amount_tax ?? 0,
    total = session.amount_total;
  return (
    session.status === "complete" &&
    session.currency === "eur" &&
    lines?.length === 1 &&
    !session.line_items.has_more &&
    id(lines[0].price) === priceID &&
    lines[0].quantity === 1 &&
    subtotal === plans.lifetime.cents &&
    Number.isSafeInteger(discount) &&
    discount >= 0 &&
    discount <= subtotal &&
    Number.isSafeInteger(tax) &&
    tax >= 0 &&
    Number.isSafeInteger(total) &&
    total === subtotal - discount + tax &&
    (total > 0
      ? session.payment_status === "paid" && !!id(session.payment_intent)
      : ["paid", "no_payment_required"].includes(session.payment_status))
  );
}
export async function reconcileSubscription(
  store,
  stripe,
  subscriptionID,
  prices,
) {
  const sub = await stripe.subscriptions.retrieve(subscriptionID, {
    expand: ["latest_invoice", "default_payment_method"],
  });
  const user = store.get(
    "SELECT * FROM users WHERE stripe_customer=?",
    id(sub.customer),
  );
  if (!user) return;
  const item = sub.items?.data?.find((x) =>
    Object.values(prices).includes(id(x.price)),
  );
  if (!item) {
    store.run(
      "UPDATE entitlements SET status='unrecognized_price',updated=? WHERE id=?",
      store.now(),
      sub.id,
    );
    return;
  }
  const plan = Object.keys(prices).find((x) => prices[x] === id(item.price));
  if (plan === "lifetime") throw Error("Lifetime cannot be a subscription");
  const invoice = sub.latest_invoice;
  const paid =
    invoice &&
    typeof invoice !== "string" &&
    invoice.paid === true &&
    invoice.status === "paid";
  if (paid && invoice.id)
    reservePayment(
      store,
      user.id,
      invoice.id,
      id(invoice.payment_intent),
      invoice.amount_paid,
      invoice.currency,
    );
  const trialStart = sub.trial_start,
    trialEnd = sub.trial_end;
  if (
    Number.isSafeInteger(trialStart) &&
    Number.isSafeInteger(trialEnd) &&
    trialEnd > trialStart
  )
    store.run(
      "INSERT OR IGNORE INTO trials VALUES(?,?,?,?)",
      user.id,
      sub.id,
      trialStart,
      trialEnd,
    );
  const trial = store.get("SELECT * FROM trials WHERE user_id=?", user.id);
  const trialActive =
    sub.status === "trialing" &&
    id(sub.default_payment_method) &&
    trial?.subscription_id === sub.id &&
    trialEnd === trial.until &&
    trialEnd > store.now() &&
    trialEnd - trialStart <= 31 * 86400;
  const until =
    sub.status === "trialing"
      ? trialEnd
      : (sub.current_period_end ?? item.current_period_end);
  if (!Number.isSafeInteger(until)) throw Error("Subscription period missing");
  const active = sub.status === "active" && paid && !sub.pause_collection;
  store.run(
    `INSERT INTO entitlements(id,user_id,plan,status,until,invoice,payment_intent,updated) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET status=excluded.status,until=excluded.until,invoice=excluded.invoice,payment_intent=excluded.payment_intent,plan=excluded.plan,updated=excluded.updated`,
    sub.id,
    user.id,
    plan,
    active
      ? "active"
      : trialActive
        ? "trialing"
        : ["active", "trialing"].includes(sub.status)
          ? "unpaid"
          : sub.status,
    until,
    id(invoice) ?? null,
    id(invoice?.payment_intent) ?? null,
    store.now(),
  );
}
const pending = new WeakMap();
export function processEvent(store, stripe, event, config) {
  // Reconcile serially: a slower, older retrieval must never overwrite a newer one.
  const previous = pending.get(store) || Promise.resolve();
  const next = previous
    .catch(() => {})
    .then(() => reconcileEvent(store, stripe, event, config));
  pending.set(store, next);
  next
    .finally(() => {
      if (pending.get(store) === next) pending.delete(store);
    })
    .catch(() => {});
  return next;
}
async function reconcileEvent(store, stripe, event, { prices, live }) {
  if (event.livemode !== live) throw Error("Wrong Stripe mode");
  const prior = store.get("SELECT * FROM billing_events WHERE id=?", event.id);
  if (prior?.status === "complete") return { duplicate: true };
  if (prior?.status === "processing" && prior.updated > store.now() - 120)
    throw Error("Event already processing");
  store.run(
    `INSERT INTO billing_events VALUES(?,'processing',?) ON CONFLICT(id) DO UPDATE SET status='processing',updated=excluded.updated`,
    event.id,
    store.now(),
  );
  try {
    const object = event.data.object;
    if (event.type.startsWith("customer.subscription."))
      await reconcileSubscription(store, stripe, object.id, prices);
    else if (event.type.startsWith("invoice.") && id(object.subscription))
      await reconcileSubscription(
        store,
        stripe,
        id(object.subscription),
        prices,
      );
    else if (
      [
        "checkout.session.completed",
        "checkout.session.async_payment_succeeded",
      ].includes(event.type)
    ) {
      const session = await stripe.checkout.sessions.retrieve(object.id, {
        expand: ["line_items"],
      });
      const user = store.get(
        "SELECT * FROM users WHERE stripe_customer=?",
        id(session.customer),
      );
      if (user && session.client_reference_id === user.id) {
        if (session.mode === "subscription" && id(session.subscription))
          await reconcileSubscription(
            store,
            stripe,
            id(session.subscription),
            prices,
          );
        if (
          session.mode === "payment" &&
          validLifetimePurchase(session, prices.lifetime)
        ) {
          store.run(
            `INSERT INTO entitlements VALUES(?,?,?,'active',NULL,NULL,?,?) ON CONFLICT(id) DO NOTHING`,
            session.id,
            user.id,
            "lifetime",
            id(session.payment_intent) ?? null,
            store.now(),
          );
          reservePayment(
            store,
            user.id,
            session.id,
            id(session.payment_intent),
            session.amount_total,
            session.currency,
          );
        }
      }
    } else if (
      ["charge.refunded", "charge.dispute.created"].includes(event.type)
    ) {
      const charge =
        event.type === "charge.refunded"
          ? object
          : await stripe.charges.retrieve(id(object.charge));
      if (id(charge.payment_intent))
        store.run(
          "INSERT OR IGNORE INTO blocked_payments VALUES(?,?)",
          id(charge.payment_intent),
          event.type,
        );
    }
    store.run(
      "UPDATE billing_events SET status='complete',updated=? WHERE id=?",
      store.now(),
      event.id,
    );
    return { duplicate: false };
  } catch (error) {
    store.run(
      "UPDATE billing_events SET status='failed',updated=? WHERE id=?",
      store.now(),
      event.id,
    );
    throw error;
  }
}
