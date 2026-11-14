import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import Stripe from "stripe";
import { Store, digest } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";
import { plans, processEvent } from "../src/billing.mjs";
import { confirmContract } from "../src/contracts.mjs";

const NOW = 1900000000, DAY = 86400;
const keys = generateKeyPairSync("ed25519");
async function fixture(t) {
  let now = NOW, retrievalFailure = false;
  const store = new Store(":memory:", () => now), sdk = new Stripe("sk_test_fixture_only");
  const html = "<!doctype html><html><body>Conditions de recette.</body></html>";
  const config = { testing: true, publicURL: "https://example.test/account", live: false,
    signingKey: keys.privateKey, prices: Object.fromEntries(Object.keys(plans).map((p) => [p, "price_" + p])),
    termsVersion: "fixture-v1", termsHTML: html, termsSHA256: digest(html), termsURL: "https://example.test/terms",
    webhookSecret: "whsec_fixture_only", mailFrom: "test@example.test", supportEmail: "test@example.test" };
  const calls = [], mail = [];
  const sub = { id: "sub_one", customer: "cus_one", status: "active", current_period_end: NOW + 30 * DAY,
    items: { has_more: false, data: [{ price: { id: "price_monthly" }, quantity: 1 }] },
    latest_invoice: { id: "in_one", customer: "cus_one", subscription: "sub_one", paid: true, status: "paid", payment_intent: "pi_one", amount_paid: 1999, currency: "eur" } };
  const session = { id: "cs_one", customer: "cus_one", status: "complete", client_reference_id: null,
    mode: "subscription", subscription: "sub_one", currency: "eur", amount_total: 0 };
  const stripe = { webhooks: sdk.webhooks,
    subscriptions: { retrieve: async (id, options) => {
      calls.push({ id, options });
      if (retrievalFailure) throw Error("fixture unavailable");
      return structuredClone(sub);
    } },
    checkout: { sessions: { retrieve: async () => structuredClone(session) } },
    charges: { retrieve: async () => ({ payment_intent: "pi_one" }) },
  };
  const app = await createApp({ store, stripe, config, mailer: { sendMail: async (message) => { mail.push(message); return { accepted: [message.to.address] }; } } });
  t.after(() => app.close());
  const user = store.consumeMagic(store.magic("customer@example.test")), other = store.consumeMagic(store.magic("other@example.test"));
  store.run("UPDATE users SET stripe_customer=? WHERE id=?", "cus_one", user.user.id);
  session.client_reference_id = user.user.id;
  sub.metadata = { playmelt_user: user.user.id };
  const device = store.device("Mac QA", digest("verifier"));
  store.approveDevice(device.userCode, user.user.id);
  const paired = store.exchangeDevice(device.deviceCode, "verifier");
  // Keep authentication valid across the licence boundary being tested.
  store.run("UPDATE sessions SET expires=? WHERE hash=?", NOW + 90 * DAY, digest(paired.token));
  const event = (type, object, extra = {}) => ({ id: "evt_" + randomUUID(), livemode: false, type, data: { object }, ...extra });
  const apply = (type, object = { id: sub.id }, extra) => processEvent(store, stripe, event(type, object, extra), config);
  const launch = () => app.inject({ method: "POST", url: "/account/v1/launch-ticket", headers: { authorization: "Bearer " + paired.token } });
  const webhook = (value, secret = config.webhookSecret, timestamp) => {
    const payload = JSON.stringify(value);
    return app.inject({ method: "POST", url: "/account/v1/stripe/webhook", payload,
      headers: { "content-type": "application/json", "stripe-signature": sdk.webhooks.generateTestHeaderString({ payload, secret, ...(timestamp ? { timestamp } : {}) }) } });
  };
  const contract = (plan = "monthly") => store.run("INSERT INTO checkout_contracts(checkout_id,user_id,plan,terms_sha256,accepted,updated) VALUES(?,?,?,?,?,?)", session.id, user.user.id, plan, config.termsSHA256, NOW, NOW);
  return { store, app, stripe, sdk, config, user, other, sub, session, calls, mail, event, apply, launch, webhook, contract,
    advance: (n) => now += n, failRetrieval: (value) => retrievalFailure = value };
}

test("Basil/Clover invoice parents reconcile current pinned-API subscriptions instead of being silently ignored", async (t) => {
  const f = await fixture(t);
  const invoice = { id: "in_event", parent: { type: "subscription_details", subscription_details: { subscription: f.sub.id } } };
  assert.equal((await f.launch()).statusCode, 402);
  await f.apply("invoice.paid", invoice);
  assert.equal(f.calls.length, 1);
  assert.equal(f.calls[0].id, f.sub.id);
  assert.equal((await f.launch()).statusCode, 200);
  f.sub.status = "past_due";
  await f.apply("invoice.payment_failed", invoice);
  assert.equal((await f.launch()).statusCode, 402);
  await f.apply("invoice.paid", invoice); // Late success notification still retrieves current past_due.
  assert.equal((await f.launch()).statusCode, 402);
  assert.equal(f.store.entitlement(f.other.user.id), null);
});

test("a paid cancellation scheduled for period end keeps service until its exact paid expiry", async (t) => {
  const f = await fixture(t);
  f.sub.cancel_at_period_end = true;
  f.sub.cancel_at = f.sub.current_period_end;
  await f.apply("customer.subscription.updated");
  assert.equal((await f.launch()).statusCode, 200);
  f.advance(30 * DAY - 1);
  const last = await f.launch();
  assert.equal(last.statusCode, 200);
  assert.equal(last.json().expiresAt, f.sub.current_period_end);
  f.advance(1);
  assert.equal((await f.launch()).statusCode, 402);
});

test("effective cancellation revokes service even if a terminal snapshot no longer has a period", async (t) => {
  const f = await fixture(t);
  await f.apply("customer.subscription.updated");
  assert.equal((await f.launch()).statusCode, 200);
  f.sub.status = "canceled";
  delete f.sub.current_period_end;
  await f.apply("customer.subscription.deleted");
  assert.equal(f.store.get("SELECT status FROM entitlements WHERE id=?", f.sub.id).status, "canceled");
  assert.equal((await f.launch()).statusCode, 402);
});

test("unpaid, incomplete, expired, paused and collection-paused subscriptions never produce new launch tickets", async (t) => {
  for (const status of ["past_due", "unpaid", "incomplete", "incomplete_expired", "paused"]) {
    const f = await fixture(t);
    await f.apply("customer.subscription.updated");
    f.sub.status = status;
    await f.apply("customer.subscription.updated");
    assert.equal((await f.launch()).statusCode, 402, status);
  }
  const f = await fixture(t);
  f.sub.pause_collection = { behavior: "void" };
  await f.apply("customer.subscription.updated");
  assert.equal((await f.launch()).statusCode, 402);
});

test("a recognized price cannot hide extra items, pagination or a non-unit quantity", async (t) => {
  for (const mutate of [
    (s) => s.items.data.push({ price: { id: "price_other" }, quantity: 1 }),
    (s) => s.items.has_more = true,
    (s) => s.items.data[0].quantity = 2,
    (s) => s.items.data[0].quantity = 0,
  ]) {
    const f = await fixture(t);
    await f.apply("customer.subscription.updated");
    assert.equal((await f.launch()).statusCode, 200);
    mutate(f.sub);
    await f.apply("customer.subscription.updated");
    assert.equal((await f.launch()).statusCode, 402);
  }
});

test("a trial cannot start early or exceed the approved thirty days, and needs a collected method", async (t) => {
  for (const [start, end, method, expected] of [
    [NOW, NOW + 30 * DAY, null, 402],
    [NOW, NOW + 30 * DAY, "pm_card", 200],
    [NOW, NOW + 31 * DAY, "pm_card", 402],
    [NOW + DAY, NOW + 30 * DAY, "pm_card", 402],
  ]) {
    const f = await fixture(t);
    Object.assign(f.sub, { status: "trialing", trial_start: start, trial_end: end, default_payment_method: method, latest_invoice: null });
    await f.apply("customer.subscription.created");
    assert.equal((await f.launch()).statusCode, expected);
    if (expected === 200) {
      f.advance(30 * DAY);
      assert.equal((await f.launch()).statusCode, 402);
    }
  }
});

test("customer and subscription attribution mismatches cannot yield access or a contractual confirmation", async (t) => {
  for (const mutate of [
    (f) => f.sub.metadata.playmelt_user = f.other.user.id,
    (f) => f.sub.latest_invoice.customer = "cus_other",
    (f) => f.sub.latest_invoice.subscription = "sub_other",
  ]) {
    const f = await fixture(t);
    f.contract();
    mutate(f);
    await f.apply("checkout.session.completed", { id: f.session.id });
    assert.equal((await f.launch()).statusCode, 402);
    assert.equal(f.store.entitlement(f.other.user.id), null);
    assert.equal(f.store.get("SELECT confirmed FROM checkout_contracts").confirmed, null);
  }
  const f = await fixture(t);
  f.session.client_reference_id = f.other.user.id;
  await f.apply("checkout.session.completed", { id: f.session.id });
  assert.equal(f.calls.length, 0);
  assert.equal((await f.launch()).statusCode, 402);
});

test("refunds received before checkout never create a positive access confirmation; partial events remain fail closed", async (t) => {
  for (const refunded of [39900, 100]) {
    const f = await fixture(t);
    Object.assign(f.session, { mode: "payment", subscription: null, currency: "eur", payment_status: "paid", amount_subtotal: 39900, amount_total: 39900,
      total_details: { amount_discount: 0, amount_tax: 0 }, payment_intent: "pi_lifetime",
      line_items: { has_more: false, data: [{ price: { id: "price_lifetime" }, quantity: 1 }] } });
    f.contract("lifetime");
    await f.apply("charge.refunded", { id: "ch_lifetime", payment_intent: "pi_lifetime", amount: 39900, amount_refunded: refunded });
    assert.equal((await f.webhook(f.event("checkout.session.completed", { id: f.session.id }))).statusCode, 200);
    assert.equal((await f.launch()).statusCode, 402);
    assert.equal(f.store.get("SELECT confirmed FROM checkout_contracts").confirmed, null);
    assert.equal(f.mail.length, 0);
  }
});

test("successful discounted recurring payment is still access, while a failed invoice cannot masquerade as paid", async (t) => {
  const f = await fixture(t);
  f.sub.latest_invoice.amount_paid = 999;
  await f.apply("invoice.paid", { subscription: f.sub.id });
  assert.equal((await f.launch()).statusCode, 200);
  assert.equal(f.store.get("SELECT amount FROM payment_reserves").amount, 999);
  f.sub.latest_invoice.paid = false;
  await f.apply("invoice.payment_failed", { subscription: f.sub.id });
  assert.equal((await f.launch()).statusCode, 402);
});

test("signature, timestamp and live/test mode failures do not mutate entitlements", async (t) => {
  const f = await fixture(t), event = f.event("invoice.paid", { subscription: f.sub.id });
  assert.equal((await f.webhook(event, "whsec_other_fixture")).statusCode, 400);
  assert.equal((await f.webhook(event, f.config.webhookSecret, Math.floor(Date.now() / 1000) - 600)).statusCode, 400);
  assert.equal((await f.webhook({ ...event, livemode: true })).statusCode, 503);
  assert.equal((await f.launch()).statusCode, 402);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM billing_events").n, 0);
  assert.equal((await f.webhook(event)).statusCode, 200);
  assert.equal((await f.webhook(event)).statusCode, 200);
  assert.equal(f.calls.length, 1);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM payment_reserves").n, 1);
});

test("a transient Stripe retrieval failure is retryable with the same event without inventing paid access", async (t) => {
  const f = await fixture(t), event = f.event("invoice.paid", { subscription: f.sub.id });
  f.failRetrieval(true);
  await assert.rejects(processEvent(f.store, f.stripe, event, f.config));
  assert.equal((await f.launch()).statusCode, 402);
  assert.equal(f.store.get("SELECT status FROM billing_events WHERE id=?", event.id).status, "failed");
  f.failRetrieval(false);
  await processEvent(f.store, f.stripe, event, f.config);
  assert.equal((await f.launch()).statusCode, 200);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM payment_reserves").n, 1);
});

test("an expired or foreign entitlement cannot confirm another customer's retained contract", async (t) => {
  const f = await fixture(t);
  f.contract();
  for (const entitlement of [
    { user_id: f.user.user.id, status: "active", plan: "monthly", until: NOW },
    { user_id: f.other.user.id, status: "active", plan: "monthly", until: NOW + DAY },
  ]) confirmContract(f.store, f.session, f.user.user, entitlement, plans.monthly);
  assert.equal(f.store.get("SELECT confirmed FROM checkout_contracts").confirmed, null);
});
