import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import { Store, digest } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";
import { processEvent, plans } from "../src/billing.mjs";

const NOW = 1900000000;
const signingKey = generateKeyPairSync("ed25519").privateKey;
async function fixture(t) {
  const store = new Store(":memory:", () => NOW);
  let app;
  t.after(async () => { if (app) await app.close(); else store.close(); });
  const config = { testing: true, live: false, signingKey, publicURL: "https://example.test/account",
    prices: Object.fromEntries(Object.keys(plans).map(p => [p, "price_" + p])),
    termsVersion: "fixture-v1", termsHTML: "<html>Fixture terms</html>", termsURL: "https://example.test/terms" };
  config.termsSHA256 = digest(config.termsHTML);
  const user = store.consumeMagic(store.magic("buyer@example.test"));
  const other = store.consumeMagic(store.magic("other@example.test"));
  store.run("UPDATE users SET stripe_customer=? WHERE id=?", "cus_buyer", user.user.id);
  store.run("UPDATE users SET stripe_customer=? WHERE id=?", "cus_other", other.user.id);
  const session = { id: "cs_original", customer: "cus_buyer", client_reference_id: user.user.id,
    mode: "subscription", status: "complete", payment_status: "paid", subscription: "sub_original", amount_total: 1999, currency: "eur" };
  const sub = { id: "sub_original", customer: "cus_buyer", status: "active", current_period_end: NOW + 3600,
    metadata: { playmelt_user: user.user.id }, items: { has_more: false, data: [{ quantity: 1, price: { id: "price_monthly" } }] },
    latest_invoice: { id: "in_original", customer: "cus_buyer", subscription: "sub_original", paid: true, status: "paid",
      amount_paid: 1999, currency: "eur", payment_intent: "pi_original" } };
  let fail = false, creations = 0;
  const stripe = { checkout: { sessions: {
    retrieve: async () => { if (fail) throw Error("temporary retrieval failure"); return structuredClone(session); },
    create: async () => { creations++; return { id: "cs_repurchase_" + creations, url: "https://checkout.stripe.com/c/pay/repurchase_" + creations, expires_at: NOW + 3600 }; },
  } }, subscriptions: { retrieve: async () => structuredClone(sub) } };
  app = await createApp({ store, stripe, config, mailer: { sendMail: async () => { throw Error("no mail expected"); } } });
  const cache = (owner = user.user.id, checkout = session.id, plan = "monthly") =>
    store.run("INSERT INTO checkout_requests VALUES(?,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET checkout_id=excluded.checkout_id,url=excluded.url,expires=excluded.expires,plan=excluded.plan",
      owner, plan, checkout, "https://checkout.stripe.com/c/pay/" + checkout, NOW + 86400);
  const row = (owner = user.user.id) => store.get("SELECT * FROM checkout_requests WHERE user_id=?", owner);
  const contract = (owner = user.user.id, plan = "monthly") => store.run(
    "INSERT INTO checkout_contracts(checkout_id,user_id,plan,terms_sha256,accepted,updated) VALUES(?,?,?,?,?,?)",
    session.id, owner, plan, config.termsSHA256, NOW, NOW);
  const event = (type = "checkout.session.completed") => ({ id: "evt_" + randomUUID(), livemode: false, type, data: { object: { id: session.id } } });
  const apply = (e = event()) => processEvent(store, stripe, e, config);
  const checkout = () => app.inject({ method: "POST", url: "/account/v1/checkout", headers: { authorization: "Bearer " + user.session },
    payload: { plan: "monthly", acceptTerms: true, termsVersion: config.termsVersion } });
  cache(); contract();
  return { store, config, user, other, session, sub, cache, row, apply, event, checkout,
    fail: value => fail = value, creations: () => creations };
}

test("settled subscription expires only its cache and allows a new purchase after effective cancellation", async t => {
  const f = await fixture(t), e = f.event();
  await f.apply(e);
  assert.equal(f.row().expires, 0);
  assert.notEqual(f.store.get("SELECT confirmed FROM checkout_contracts WHERE checkout_id=?", f.session.id).confirmed, null);
  assert.equal((await f.checkout()).statusCode, 409); // Existing paid access remains authoritative.
  f.sub.status = "canceled";
  await processEvent(f.store, { subscriptions: { retrieve: async () => f.sub } },
    { id: "evt_cancel", livemode: false, type: "customer.subscription.deleted", data: { object: { id: f.sub.id } } }, f.config);
  const response = await f.checkout();
  assert.equal(response.statusCode, 200, response.body);
  assert.equal(response.json().url, "https://checkout.stripe.com/c/pay/repurchase_1");
  assert.equal(f.creations(), 1);
  assert.equal(f.row().checkout_id, "cs_repurchase_1");
  assert.deepEqual(await f.apply(e), { duplicate: true });
  assert.equal(f.row().checkout_id, "cs_repurchase_1");
  assert.ok(f.row().expires > NOW);
});

test("settled lifetime purchase expires its cache without deleting requests or contracts", async t => {
  const f = await fixture(t);
  Object.assign(f.session, { mode: "payment", subscription: null, amount_subtotal: 39900, amount_total: 39900,
    total_details: { amount_discount: 0, amount_tax: 0 }, payment_intent: "pi_lifetime",
    line_items: { has_more: false, data: [{ quantity: 1, price: { id: "price_lifetime" } }] } });
  f.store.run("UPDATE checkout_contracts SET plan='lifetime' WHERE checkout_id=?", f.session.id);
  f.cache(f.user.user.id, f.session.id, "lifetime");
  await f.apply();
  assert.equal(f.row().expires, 0);
  assert.equal(f.store.get("SELECT COUNT(*) n FROM checkout_requests").n, 1);
  assert.equal(f.store.get("SELECT COUNT(*) n FROM checkout_contracts").n, 1);
});

test("complete card-backed trial with no payment required can release its own cache", async t => {
  const f = await fixture(t);
  Object.assign(f.sub, { status: "trialing", trial_start: NOW, trial_end: NOW + 30 * 86400, default_payment_method: "pm_fixture", latest_invoice: null });
  Object.assign(f.session, { payment_status: "no_payment_required", amount_total: 0 });
  await f.apply();
  assert.equal(f.row().expires, 0);
  assert.equal(f.store.entitlement(f.user.user.id).status, "trialing");
});

test("unpaid, open, unrecognized-price, unrecognized-mode and wrong-account sessions preserve cached requests", async t => {
  for (const [label, mutate] of [
    ["unpaid Checkout", f => f.session.payment_status = "unpaid"],
    ["open Checkout", f => f.session.status = "open"],
    ["unpaid entitlement", f => f.sub.latest_invoice.paid = false],
    ["unrecognized price", f => f.sub.items.data[0].price.id = "price_unrelated"],
    ["unrecognized mode", f => f.session.mode = "setup"],
    ["wrong reference", f => f.session.client_reference_id = f.other.user.id],
    ["wrong customer", f => f.session.customer = "cus_other"],
    ["wrong subscription account", f => f.sub.metadata.playmelt_user = f.other.user.id],
  ]) {
    const f = await fixture(t), before = f.row();
    mutate(f); await f.apply();
    assert.deepEqual(f.row(), before, label);
  }
});

test("a prior confirmed contract cannot release a cache using a currently unpaid or blocked snapshot", async t => {
  for (const mutate of [
    f => { f.session.payment_status = "unpaid"; },
    f => { f.sub.latest_invoice.paid = false; },
    f => { f.store.run("INSERT INTO blocked_payments VALUES(?,?)", "pi_original", "refunded"); },
  ]) {
    const f = await fixture(t); await f.apply(); f.cache();
    const before = f.row(); mutate(f); await f.apply(); assert.deepEqual(f.row(), before);
  }
});

test("newer, pending and other-account cache rows survive delayed completion and duplicate event retries", async t => {
  for (const newer of ["cs_newer", "pending_creation"]) {
    const f = await fixture(t), event = f.event();
    f.cache(f.user.user.id, newer);
    f.cache(f.other.user.id, f.session.id);
    const buyer = f.row(), other = f.row(f.other.user.id);
    await f.apply(event); await f.apply(event); await f.apply();
    assert.deepEqual(f.row(), buyer);
    assert.deepEqual(f.row(f.other.user.id), other);
  }
});

test("transient retrieval failure preserves uncertainty; same-event retry expires the original cache once", async t => {
  const f = await fixture(t), event = f.event(), before = f.row();
  f.fail(true);
  await assert.rejects(f.apply(event), /temporary retrieval failure/);
  assert.deepEqual(f.row(), before);
  assert.equal(f.store.get("SELECT status FROM billing_events WHERE id=?", event.id).status, "failed");
  f.fail(false); await f.apply(event);
  assert.equal(f.row().expires, 0);
  assert.deepEqual(await f.apply(event), { duplicate: true });
  assert.equal(f.store.get("SELECT COUNT(*) n FROM payment_reserves").n, 1);
});

test("a missing retained contract cannot expire the Checkout cache", async t => {
  const f = await fixture(t), before = f.row();
  // Preserve the accepted document and request; simulate a missing contract without deleting data.
  f.store.run("UPDATE checkout_contracts SET checkout_id=? WHERE checkout_id=?", "cs_different", f.session.id);
  await f.apply();
  assert.deepEqual(f.row(), before);
});


test("an invalid lifetime price cannot reuse a prior confirmation to expire a pending cache", async t => {
  const f = await fixture(t);
  Object.assign(f.session, { mode: "payment", subscription: null, amount_subtotal: 39900, amount_total: 39900,
    total_details: { amount_discount: 0, amount_tax: 0 }, payment_intent: "pi_lifetime",
    line_items: { has_more: false, data: [{ quantity: 1, price: { id: "price_lifetime" } }] } });
  f.store.run("UPDATE checkout_contracts SET plan='lifetime' WHERE checkout_id=?", f.session.id);
  f.cache(f.user.user.id, f.session.id, "lifetime");
  await f.apply(); f.cache(f.user.user.id, f.session.id, "lifetime");
  const before = f.row();
  f.session.line_items.data[0].price.id = "price_outside_playmelt";
  await f.apply();
  assert.deepEqual(f.row(), before);
});
