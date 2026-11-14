import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import Stripe from "stripe";
import { Store, digest, token } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";
import { processEvent, plans } from "../src/billing.mjs";
const keys = generateKeyPairSync("ed25519");
async function fixture(t) {
  let now = 1900000000;
  const store = new Store(":memory:", () => now),
    mail = [];
  const config = {
    testing: true,
    publicURL: "https://account.example/playmelt",
    live: false,
    webhookSecret: "whsec_fixture_only",
    prices: Object.fromEntries(
      Object.keys(plans).map((p) => [p, "price_" + p]),
    ),
    signingKey: keys.privateKey,
    mailFrom: "test@example.test",
    supportEmail: "support@example.test",
    supportAdmins: ["owner@example.test"],
    termsVersion: "2026-11-12",
    termsSHA256: "0".repeat(64),
    termsURL: "https://account.example/terms",
    privacyURL: "https://account.example/privacy",
  };
  const sdk = new Stripe("sk_test_fixture_only");
  const sub = {
    id: "sub_1",
    customer: "cus_1",
    status: "active",
    current_period_end: now + 3600,
    latest_invoice: {
      id: "in_1",
      paid: true,
      status: "paid",
      payment_intent: "pi_1",
    },
    items: { data: [{ price: { id: "price_monthly" } }] },
  };
  const calls = [];
  let failCheckout = false;
  const stripe = {
    webhooks: sdk.webhooks,
    customers: { create: async () => ({ id: "cus_1" }) },
    subscriptions: { retrieve: async () => structuredClone(sub) },
    checkout: {
      sessions: {
        create: async (params, options) => {
          calls.push({ params, options });
          if (failCheckout) {
            failCheckout = false;
            throw Error("network outcome unknown");
          }
          return {
            id: "cs_1",
            url: "https://checkout.stripe.com/c/pay/cs_1",
            expires_at: now + 86400,
          };
        },
        retrieve: async () => ({}),
      },
    },
    billingPortal: {
      sessions: {
        create: async () => ({
          url: "https://billing.stripe.com/p/session/123",
        }),
      },
    },
    charges: { retrieve: async () => ({ payment_intent: "pi_1" }) },
  };
  const app = await createApp({
    store,
    stripe,
    config,
    mailer: { sendMail: async (value) => { mail.push(value); return { accepted: [value.to.address] }; } },
  });
  t.after(() => app.close());
  const request = (method, path, payload, headers = {}) =>
    app.inject({ method, url: "/playmelt" + path, payload, headers });
  function user(email = "one@example.test") {
    const result = store.consumeMagic(store.magic(email));
    store.run(
      "UPDATE users SET stripe_customer=? WHERE id=?",
      "cus_1",
      result.user.id,
    );
    return result;
  }
  const event = (type, object, id = "evt_" + token()) => ({
    id,
    livemode: false,
    type,
    data: { object },
  });
  return {
    app,
    store,
    config,
    stripe,
    mail,
    request,
    user,
    sub,
    calls,
    event,
    advance: (secs) => (now += secs),
    failNextCheckout: () => (failCheckout = true),
  };
}
test("magic links are private, single-use, expiring and protected against cross-origin submission", async (t) => {
  const f = await fixture(t);
  assert.equal(
    (
      await f.request(
        "POST",
        "/v1/auth/email",
        { email: "person@example.test" },
        { origin: "https://evil.test" },
      )
    ).statusCode,
    403,
  );
  assert.equal(
    (
      await f.request(
        "POST",
        "/v1/auth/email",
        { email: "person@example.test" },
        { origin: "https://account.example" },
      )
    ).statusCode,
    200,
  );
  assert.equal(f.mail.length, 1);
  const secret = f.mail[0].text.match(/#token=([\w-]+)/)[1];
  assert.notEqual(f.store.get("SELECT hash FROM magic_links").hash, secret);
  const result = await f.request(
    "POST",
    "/v1/auth/confirm",
    { token: secret },
    { origin: "https://account.example" },
  );
  assert.equal(result.statusCode, 200);
  assert.match(result.headers["set-cookie"], /HttpOnly/);
  assert.match(result.headers["set-cookie"], /SameSite=Strict/i);
  assert.equal(
    (
      await f.request(
        "POST",
        "/v1/auth/confirm",
        { token: secret },
        { origin: "https://account.example" },
      )
    ).statusCode,
    400,
  );
  const expired = f.store.magic("expired@example.test");
  f.advance(901);
  assert.equal(f.store.consumeMagic(expired), null);
});
test("device pairing requires account approval and proof, cannot replay, and revocation invalidates access", async (t) => {
  const f = await fixture(t),
    u = f.user(),
    proof = token();
  const start = (
    await f.request("POST", "/v1/device/start", {
      challenge: digest(proof),
      label: "Mon Mac",
    })
  ).json();
  const exchange = (p) =>
    f.request("POST", "/v1/device/token", {
      deviceCode: start.deviceCode,
      verifier: p,
    });
  assert.equal((await exchange(proof)).statusCode, 428);
  assert.equal((await exchange(token())).statusCode, 400);
  assert.equal(
    (
      await f.request(
        "POST",
        "/v1/device/approve",
        { code: start.userCode },
        { authorization: "Bearer " + u.session },
      )
    ).statusCode,
    200,
  );
  const device = (await exchange(proof)).json();
  assert.ok(device.token);
  assert.equal((await exchange(proof)).statusCode, 400);
  assert.ok(f.store.authenticate(device.token));
  await f.request(
    "POST",
    "/v1/devices/revoke",
    { id: device.deviceID },
    { authorization: "Bearer " + u.session },
  );
  assert.equal(f.store.authenticate(device.token), undefined);
});
test("launch access requires a paid current entitlement and a registered device; ticket is signed and short-lived", async (t) => {
  const f = await fixture(t),
    u = f.user();
  assert.equal(
    (
      await f.request(
        "POST",
        "/v1/launch-ticket",
        {},
        { authorization: "Bearer " + u.session },
      )
    ).statusCode,
    403,
  );
  const p = token(),
    d = f.store.device("Mac", digest(p));
  f.store.approveDevice(d.userCode, u.user.id);
  const device = f.store.exchangeDevice(d.deviceCode, p),
    headers = { authorization: "Bearer " + device.token };
  assert.equal(
    (await f.request("POST", "/v1/launch-ticket", {}, headers)).statusCode,
    402,
  );
  await processEvent(
    f.store,
    f.stripe,
    f.event("invoice.paid", { subscription: "sub_1" }),
    f.config,
  );
  const result = (
      await f.request("POST", "/v1/launch-ticket", {}, headers)
    ).json(),
    [body, signature] = result.ticket.split(".");
  assert.ok(
    verify(
      null,
      Buffer.from(body),
      keys.publicKey,
      Buffer.from(signature, "base64url"),
    ),
  );
  const ticket = JSON.parse(Buffer.from(body, "base64url"));
  assert.equal(ticket.device, device.deviceID);
  assert.equal(ticket.exp - ticket.iat, 900);
  f.advance(3601);
  assert.equal(
    (await f.request("POST", "/v1/launch-ticket", {}, headers)).statusCode,
    402,
  );
});
test("Stripe webhooks verify signature and mode, deduplicate and reconcile current subscription state", async (t) => {
  const f = await fixture(t),
    u = f.user(),
    e = f.event("invoice.paid", { subscription: "sub_1" });
  assert.equal(
    (await f.request("POST", "/v1/stripe/webhook", e)).statusCode,
    400,
  );
  const raw = JSON.stringify(e),
    signature = f.stripe.webhooks.generateTestHeaderString({
      payload: raw,
      secret: f.config.webhookSecret,
    });
  assert.equal(
    (
      await f.request("POST", "/v1/stripe/webhook", raw, {
        "content-type": "application/json",
        "stripe-signature": signature,
      })
    ).statusCode,
    200,
  );
  assert.ok(f.store.entitlement(u.user.id));
  assert.equal(
    (await processEvent(f.store, f.stripe, e, f.config)).duplicate,
    true,
  );
  f.sub.status = "past_due";
  await processEvent(
    f.store,
    f.stripe,
    f.event("invoice.paid", { subscription: "sub_1" }),
    f.config,
  );
  assert.equal(f.store.entitlement(u.user.id), null);
  f.sub.status = "active";
  f.sub.latest_invoice.paid = false;
  await processEvent(
    f.store,
    f.stripe,
    f.event("customer.subscription.updated", { id: "sub_1" }),
    f.config,
  );
  assert.equal(f.store.entitlement(u.user.id), null);
  await assert.rejects(
    processEvent(
      f.store,
      f.stripe,
      { ...e, id: "evt_live", livemode: true },
      f.config,
    ),
    /mode/,
  );
});
test("refunds revoke access even when received before purchase event; old invoice cannot restore access", async (t) => {
  const f = await fixture(t),
    u = f.user();
  await processEvent(
    f.store,
    f.stripe,
    f.event("charge.refunded", { payment_intent: "pi_1" }),
    f.config,
  );
  await processEvent(
    f.store,
    f.stripe,
    f.event("invoice.paid", { subscription: "sub_1" }),
    f.config,
  );
  assert.equal(f.store.entitlement(u.user.id), null);
  f.sub.latest_invoice = {
    id: "in_2",
    paid: true,
    status: "paid",
    payment_intent: "pi_2",
  };
  await processEvent(
    f.store,
    f.stripe,
    f.event("invoice.paid", { subscription: "sub_1" }),
    f.config,
  );
  assert.ok(f.store.entitlement(u.user.id));
  f.sub.items.data[0].price.id = "price_other";
  await processEvent(
    f.store,
    f.stripe,
    f.event("customer.subscription.updated", { id: "sub_1" }),
    f.config,
  );
  assert.equal(f.store.entitlement(u.user.id), null);
});
test("checkout uses configured server price and keeps idempotency key after uncertain network outcome", async (t) => {
  const f = await fixture(t),
    u = f.user(),
    headers = { authorization: "Bearer " + u.session };
  f.failNextCheckout();
  assert.equal(
    (
      await f.request(
        "POST",
        "/v1/checkout",
        {
          plan: "monthly",
          amount: 1,
          acceptTerms: true,
          termsVersion: f.config.termsVersion,
        },
        headers,
      )
    ).statusCode,
    503,
  );
  assert.equal(
    (
      await f.request(
        "POST",
        "/v1/checkout",
        {
          plan: "monthly",
          amount: 1,
          acceptTerms: true,
          termsVersion: f.config.termsVersion,
        },
        headers,
      )
    ).statusCode,
    200,
  );
  assert.equal(f.calls.length, 2);
  assert.equal(
    f.calls[0].options.idempotencyKey,
    f.calls[1].options.idempotencyKey,
  );
  assert.deepEqual(f.calls[0].params.line_items, [
    { price: "price_monthly", quantity: 1 },
  ]);
  await f.request(
    "POST",
    "/v1/checkout",
    { plan: "monthly", acceptTerms: true, termsVersion: f.config.termsVersion },
    headers,
  );
  assert.equal(f.calls.length, 2);
  assert.equal(
    (
      await f.request(
        "POST",
        "/v1/checkout",
        {
          plan: "annual",
          acceptTerms: true,
          termsVersion: f.config.termsVersion,
        },
        headers,
      )
    ).statusCode,
    409,
  );
});
test("lifetime only grants access for exact paid price, account and quantity", async (t) => {
  const f = await fixture(t),
    u = f.user();
  const session = {
    id: "cs_life",
    customer: "cus_1",
    client_reference_id: u.user.id,
    mode: "payment",
    status: "complete",
    payment_status: "unpaid",
    currency: "eur",
    amount_subtotal: 39900,
    amount_total: 39900,
    payment_intent: "pi_life",
    line_items: { data: [{ price: { id: "price_lifetime" }, quantity: 1 }] },
  };
  f.stripe.checkout.sessions.retrieve = async () => structuredClone(session);
  const send = () =>
    processEvent(
      f.store,
      f.stripe,
      f.event("checkout.session.completed", { id: "cs_life" }),
      f.config,
    );
  await send();
  assert.equal(f.store.entitlement(u.user.id), null);
  session.payment_status = "paid";
  session.client_reference_id = "wrong";
  await send();
  assert.equal(f.store.entitlement(u.user.id), null);
  session.client_reference_id = u.user.id;
  await send();
  assert.equal(f.store.entitlement(u.user.id).plan, "lifetime");
});
test("card is required for trial, trial is server-bound and cannot restart on reinstall or a second subscription", async (t) => {
  const f = await fixture(t),
    u = f.user();
  f.sub.status = "trialing";
  f.sub.trial_start = 1900000000;
  f.sub.trial_end = 1900000000 + 30 * 86400;
  await processEvent(
    f.store,
    f.stripe,
    f.event("customer.subscription.created", { id: "sub_1" }),
    f.config,
  );
  assert.equal(f.store.entitlement(u.user.id), null);
  f.sub.default_payment_method = { id: "pm_card" };
  await processEvent(
    f.store,
    f.stripe,
    f.event("customer.subscription.updated", { id: "sub_1" }),
    f.config,
  );
  assert.equal(f.store.entitlement(u.user.id).status, "trialing");
  const same = f.store.consumeMagic(f.store.magic("one@example.test"));
  assert.equal(same.user.id, u.user.id);
  assert.ok(f.store.get("SELECT * FROM trials WHERE user_id=?", same.user.id));
  f.sub.status = "canceled";
  await processEvent(
    f.store,
    f.stripe,
    f.event("customer.subscription.deleted", { id: "sub_1" }),
    f.config,
  );
  assert.equal(f.store.entitlement(u.user.id), null);
  f.sub.id = "sub_2";
  f.sub.status = "trialing";
  await processEvent(
    f.store,
    f.stripe,
    f.event("customer.subscription.created", { id: "sub_2" }),
    f.config,
  );
  assert.equal(f.store.entitlement(u.user.id), null);
});
test("trial expiration blocks new launch tickets and Checkout requires a card with no immediate subscription charge", async (t) => {
  const f = await fixture(t),
    u = f.user(),
    headers = { authorization: "Bearer " + u.session };
  await f.request(
    "POST",
    "/v1/checkout",
    { plan: "monthly", acceptTerms: true, termsVersion: f.config.termsVersion },
    headers,
  );
  assert.equal(f.calls[0].params.payment_method_collection, "always");
  assert.deepEqual(f.calls[0].params.payment_method_types, ["card"]);
  assert.equal(f.calls[0].params.subscription_data.trial_period_days, 30);
  f.sub.status = "trialing";
  f.sub.default_payment_method = "pm_card";
  f.sub.trial_start = 1900000000;
  f.sub.trial_end = 1900000000 + 30 * 86400;
  await processEvent(
    f.store,
    f.stripe,
    f.event("customer.subscription.updated", { id: "sub_1" }),
    f.config,
  );
  assert.ok(f.store.entitlement(u.user.id));
  f.advance(30 * 86400 + 1);
  assert.equal(f.store.entitlement(u.user.id), null);
});
test("Checkout exposes Stripe promotion codes without accepting client-controlled prices or discounts", async (t) => {
  const f = await fixture(t),
    u = f.user();
  const response = await f.request(
    "POST",
    "/v1/checkout",
    {
      plan: "monthly",
      price: "price_fake",
      promotion_code: "FAKE",
      amount: 1,
      acceptTerms: true,
      termsVersion: f.config.termsVersion,
    },
    { authorization: "Bearer " + u.session },
  );
  assert.equal(response.statusCode, 200);
  assert.equal(f.calls[0].params.allow_promotion_codes, true);
  assert.deepEqual(f.calls[0].params.line_items, [
    { price: "price_monthly", quantity: 1 },
  ]);
  assert.equal(f.calls[0].params.discounts, undefined);
  assert.equal(f.calls[0].params.subscription_data.trial_period_days, 30);
});
test("a valid discounted lifetime purchase is granted, while wrong products, quantities and unpaid amounts are refused", async (t) => {
  const f = await fixture(t),
    u = f.user();
  const session = {
    id: "cs_discount",
    customer: "cus_1",
    client_reference_id: u.user.id,
    mode: "payment",
    status: "complete",
    payment_status: "paid",
    currency: "eur",
    amount_subtotal: 39900,
    amount_total: 31920,
    total_details: { amount_discount: 7980, amount_tax: 0 },
    payment_intent: "pi_discount",
    line_items: {
      data: [{ price: { id: "price_lifetime" }, quantity: 1 }],
      has_more: false,
    },
  };
  f.stripe.checkout.sessions.retrieve = async () => structuredClone(session);
  const send = () =>
    processEvent(
      f.store,
      f.stripe,
      f.event("checkout.session.completed", { id: session.id }),
      f.config,
    );
  session.line_items.data[0].price.id = "price_other";
  await send();
  assert.equal(f.store.entitlement(u.user.id), null);
  session.line_items.data[0].price.id = "price_lifetime";
  session.line_items.data[0].quantity = 2;
  await send();
  assert.equal(f.store.entitlement(u.user.id), null);
  session.line_items.data[0].quantity = 1;
  session.amount_total = 1;
  await send();
  assert.equal(f.store.entitlement(u.user.id), null);
  session.amount_total = 31920;
  session.payment_status = "unpaid";
  await send();
  assert.equal(f.store.entitlement(u.user.id), null);
  session.payment_status = "paid";
  await send();
  assert.equal(f.store.entitlement(u.user.id).plan, "lifetime");
});
test("a Stripe-validated fully discounted lifetime purchase needs no fabricated payment intent", async (t) => {
  const f = await fixture(t),
    u = f.user();
  const session = {
    id: "cs_gift",
    customer: "cus_1",
    client_reference_id: u.user.id,
    mode: "payment",
    status: "complete",
    payment_status: "no_payment_required",
    currency: "eur",
    amount_subtotal: 39900,
    amount_total: 0,
    total_details: { amount_discount: 39900, amount_tax: 0 },
    payment_intent: null,
    line_items: {
      data: [{ price: { id: "price_lifetime" }, quantity: 1 }],
      has_more: false,
    },
  };
  f.stripe.checkout.sessions.retrieve = async () => structuredClone(session);
  await processEvent(
    f.store,
    f.stripe,
    f.event("checkout.session.completed", { id: session.id }),
    f.config,
  );
  assert.equal(f.store.entitlement(u.user.id).plan, "lifetime");
});
test("simultaneous duplicate webhooks reconcile once and return an idempotent success", async (t) => {
  const f = await fixture(t);
  f.user();
  let calls = 0;
  const retrieve = f.stripe.subscriptions.retrieve;
  f.stripe.subscriptions.retrieve = async (...args) => {
    calls++;
    return retrieve(...args);
  };
  const event = f.event("customer.subscription.updated", { id: "sub_1" });
  const outcomes = await Promise.all([
    processEvent(f.store, f.stripe, event, f.config),
    processEvent(f.store, f.stripe, event, f.config),
  ]);
  assert.equal(calls, 1);
  assert.deepEqual(outcomes, [{ duplicate: false }, { duplicate: true }]);
});
test("paid receipts reserve the gross amount for at least fourteen days and duplicate events never reset the date", async (t) => {
  const f = await fixture(t),
    u = f.user();
  f.sub.latest_invoice.amount_paid = 1999;
  f.sub.latest_invoice.currency = "eur";
  const event = f.event("invoice.paid", { subscription: "sub_1" });
  await processEvent(f.store, f.stripe, event, f.config);
  const first = f.store.get("SELECT * FROM payment_reserves");
  assert.equal(first.user_id, u.user.id);
  assert.equal(first.amount, 1999);
  assert.equal(first.reserved_until - first.received, 14 * 86400);
  f.advance(3600);
  await processEvent(
    f.store,
    f.stripe,
    f.event("invoice.paid", { subscription: "sub_1" }),
    f.config,
  );
  assert.deepEqual(f.store.get("SELECT * FROM payment_reserves"), first);
});
