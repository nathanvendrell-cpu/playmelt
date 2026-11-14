import test from "node:test";
import assert from "node:assert/strict";
import { createApp } from "../src/app.mjs";
import { Store, digest } from "../src/store.mjs";
import { loadPortalConfiguration, validatePortalConfiguration } from "../src/portal-config.mjs";

const ORIGIN = "https://7agency.fr";
function settings(live = false) {
  return {
    live, testing: true, billingEnabled: false, prices: {},
    portalConfigurationID: live ? "bpc_fixtureLive" : "bpc_fixtureTest",
    publicURL: ORIGIN + "/Playmelt/" + (live ? "compte" : "compte-test"),
    termsURL: ORIGIN + "/Playmelt/legal/conditions-de-vente/",
    privacyURL: ORIGIN + "/Playmelt/legal/confidentialite/",
  };
}
function document(config = settings()) {
  return {
    id: config.portalConfigurationID, object: "billing_portal.configuration",
    active: true, is_default: false, livemode: config.live,
    name: "Playmelt — " + (config.live ? "Live" : "Test"),
    metadata: { playmelt_scope: "billing-portal" },
    default_return_url: config.publicURL.replace(/\/$/, "") + "/",
    business_profile: { headline: "Playmelt", terms_of_service_url: config.termsURL, privacy_policy_url: config.privacyURL },
    features: {
      subscription_cancel: { enabled: true, mode: "at_period_end", proration_behavior: "none" },
      payment_method_update: { enabled: true }, invoice_history: { enabled: true },
      subscription_update: { enabled: false }, customer_update: { enabled: false },
    },
    login_page: { enabled: false },
  };
}

test("dedicated test and live portals have exact independent targets and bounded capabilities", () => {
  for (const live of [false, true]) {
    const config = settings(live), portal = document(config);
    const verified = validatePortalConfiguration(portal, config);
    assert.deepEqual(verified, { id: portal.id, livemode: live, returnURL: config.publicURL + "/" });
    assert.ok(Object.isFrozen(verified));
    config.publicURL += "/";
    assert.equal(validatePortalConfiguration(portal, config).returnURL, config.publicURL);
  }
  const config = settings(), older = document(config);
  delete older.name; // The pinned API can identify the dedicated product through its headline.
  assert.equal(validatePortalConfiguration(older, config).id, config.portalConfigurationID);
  // Stripe automatically marks the first created configuration as the default.
  // It remains safe only when this exact dedicated ID and every capability match.
  const first = document(config);
  first.is_default = true;
  assert.equal(validatePortalConfiguration(first, config).id, config.portalConfigurationID);
  first.metadata.playmelt_scope = "another-product";
  assert.throws(() => validatePortalConfiguration(first, config), /portal configuration/);
});

const forbidden = [
  ["wrong object", (p) => { p.object = "customer"; }],
  ["different configuration", (p) => { p.id = "bpc_anotherProduct"; }],
  ["wrong mode", (p) => { p.livemode = true; }],
  ["non-boolean mode", (p) => { p.livemode = "false"; }],
  ["inactive", (p) => { p.active = false; }],
  ["invalid default flag", (p) => { p.is_default = null; }],
  ["other product name", (p) => { p.name = "Another product"; }],
  ["missing product identity", (p) => { delete p.name; delete p.business_profile.headline; }],
  ["missing scope", (p) => { delete p.metadata; }],
  ["other product scope", (p) => { p.metadata.playmelt_scope = "another-product"; }],
  ["external return", (p) => { p.default_return_url = "https://attacker.example/"; }],
  ["wrong account target", (p) => { p.default_return_url = ORIGIN + "/Playmelt/compte/"; }],
  ["return query", (p) => { p.default_return_url += "?next=another-product"; }],
  ["wrong terms", (p) => { p.business_profile.terms_of_service_url = ORIGIN + "/other/terms/"; }],
  ["wrong privacy", (p) => { p.business_profile.privacy_policy_url = "https://attacker.example/privacy"; }],
  ["no cancellation", (p) => { p.features.subscription_cancel.enabled = false; }],
  ["immediate cancellation", (p) => { p.features.subscription_cancel.mode = "immediately"; }],
  ["prorations", (p) => { p.features.subscription_cancel.proration_behavior = "create_prorations"; }],
  ["no card management", (p) => { p.features.payment_method_update.enabled = false; }],
  ["no history", (p) => { p.features.invoice_history.enabled = false; }],
  ["subscription editing", (p) => { p.features.subscription_update.enabled = true; }],
  ["customer editing", (p) => { p.features.customer_update.enabled = true; }],
  ["public login", (p) => { p.login_page.enabled = true; }],
];
test("wrong identity, mode, capabilities or targets are never accepted as the Playmelt portal", () => {
  for (const [name, mutate] of forbidden) {
    const config = settings(), portal = document(config);
    mutate(portal);
    assert.throws(() => validatePortalConfiguration(portal, config), /portal configuration/, name);
  }
  for (const mutate of [
    (c) => { c.portalConfigurationID = "bpc_"; },
    (c) => { c.portalConfigurationID = "bpc_bad/../../other"; },
    (c) => { c.live = undefined; },
    (c) => { c.publicURL = ORIGIN + "/Playmelt/compte"; },
    (c) => { c.publicURL = "https://7agency.fr.attacker.example/Playmelt/compte-test"; },
    (c) => { c.publicURL += "?next=another-product"; },
    (c) => { c.termsURL = ORIGIN + "/other/terms/"; },
    (c) => { c.privacyURL = ORIGIN + "/other/privacy/"; },
  ]) {
    const config = settings();
    mutate(config);
    assert.throws(() => validatePortalConfiguration(document(config), config));
  }
});

test("startup reads exactly the explicit configuration and refuses missing commercial or invalid remote configuration", async () => {
  const config = settings(), portal = document(config), calls = [];
  config.billingEnabled = true;
  const stripe = { billingPortal: { configurations: { retrieve: async (id) => { calls.push(id); return portal; } } } };
  assert.equal(await loadPortalConfiguration(stripe, config), portal);
  assert.deepEqual(calls, [config.portalConfigurationID]);
  portal.features.subscription_update.enabled = true;
  await assert.rejects(loadPortalConfiguration(stripe, config), /portal configuration/);
  portal.features.subscription_update.enabled = false;
  portal.livemode = true;
  await assert.rejects(loadPortalConfiguration(stripe, config), /portal configuration/);
  const absent = { ...config, portalConfigurationID: "" };
  const count = calls.length;
  await assert.rejects(loadPortalConfiguration(stripe, absent), /configuration is required/);
  assert.equal(await loadPortalConfiguration(stripe, { ...absent, billingEnabled: false }), null);
  assert.equal(calls.length, count);
  await assert.rejects(loadPortalConfiguration(stripe, { ...config, portalConfigurationID: "not-a-configuration" }));
  await assert.rejects(loadPortalConfiguration(stripe, { ...config, publicURL: ORIGIN + "/other" }));
  assert.equal(calls.length, count); // Invalid local IDs/targets never reach the SDK.
  const unavailable = { billingPortal: { configurations: { retrieve: async () => { throw Error("fixture unavailable"); } } } };
  await assert.rejects(loadPortalConfiguration(unavailable, config), /fixture unavailable/);
});

async function fixture(t, { configured = true } = {}) {
  const store = new Store(":memory:"), config = settings(), portal = document(config);
  if (!configured) config.portalConfigurationID = "";
  const calls = { retrieve: [], create: [] };
  let failReadback = false, returnedURL = "https://billing.stripe.com/p/session/fixture";
  const stripe = { billingPortal: {
    configurations: { retrieve: async (id) => {
      calls.retrieve.push(id);
      if (failReadback) throw Error("fixture readback unavailable");
      return structuredClone(portal);
    } },
    sessions: { create: async (params) => { calls.create.push(params); return { url: returnedURL }; } },
  } };
  let app;
  try { app = await createApp({ store, stripe, config, mailer: {} }); }
  catch (error) { store.close(); throw error; }
  t.after(() => app.close());
  const user = store.consumeMagic(store.magic("customer@example.test"));
  store.run("UPDATE users SET stripe_customer=? WHERE id=?", "cus_firstCustomer", user.user.id);
  const request = (u = user, payload = {}, extra = {}) => app.inject({
    method: "POST", url: "/Playmelt/compte-test/v1/billing/portal", payload,
    headers: Object.fromEntries(Object.entries({ origin: ORIGIN, ...(u ? { cookie: "pm_session=" + u.session } : {}), ...extra })
      .filter(([, value]) => value !== undefined)),
  });
  return { app, store, config, portal, calls, user, request,
    failReadback: () => { failReadback = true; }, returnURL: (value) => { returnedURL = value; } };
}

test("portal sessions use only the authenticated browser's customer, explicit dedicated configuration and exact return", async (t) => {
  const f = await fixture(t);
  const payload = { customer: "cus_attacker", configuration: "bpc_otherProduct", return_url: "https://attacker.example/",
    flow_data: { type: "subscription_update" } };
  const response = await f.request(f.user, payload);
  assert.equal(response.statusCode, 200);
  assert.deepEqual(f.calls.retrieve, [f.config.portalConfigurationID]);
  assert.deepEqual(f.calls.create, [{ customer: "cus_firstCustomer", configuration: f.config.portalConfigurationID, return_url: f.config.publicURL + "/" }]);
  const other = f.store.consumeMagic(f.store.magic("other@example.test"));
  f.store.run("UPDATE users SET stripe_customer=? WHERE id=?", "cus_secondCustomer", other.user.id);
  assert.equal((await f.request(other, payload)).statusCode, 200);
  assert.equal(f.calls.create[1].customer, "cus_secondCustomer");
  assert.equal(f.calls.retrieve.length, 2); // Read current policy again; no stale startup snapshot.
});

test("missing portal configuration refuses sessions without any Stripe call and preserves owner access", async (t) => {
  const f = await fixture(t, { configured: false });
  assert.equal((await f.request()).statusCode, 503);
  assert.deepEqual((await f.request()).json(), { error: "billing_portal_unavailable" });
  assert.deepEqual(f.calls, { retrieve: [], create: [] });
  const owner = f.store.consumeMagic(f.store.magic("owner@example.test"));
  assert.ok(f.store.redeemOwnerCode(f.store.issueOwnerCode(owner.user.email), owner.user));
  const me = await f.app.inject({ method: "GET", url: "/Playmelt/compte-test/v1/me", headers: { cookie: "pm_session=" + owner.session } });
  assert.equal(me.statusCode, 200);
  assert.equal(me.json().entitlement.plan, "lifetime");
});

test("remote policy drift or readback failure refuses a new portal session instead of using Stripe defaults", async (t) => {
  const f = await fixture(t);
  for (const [name, mutate] of forbidden) {
    Object.assign(f.portal, document(f.config));
    mutate(f.portal);
    const response = await f.request();
    assert.equal(response.statusCode, 503, name);
    assert.equal(response.json().error, "billing_portal_unavailable", name);
    assert.equal(f.calls.create.length, 0, name);
  }
  Object.assign(f.portal, document(f.config));
  f.failReadback();
  assert.equal((await f.request()).statusCode, 503);
  assert.equal(f.calls.create.length, 0);
});

test("anonymous, device, bearer-only and foreign-origin callers cannot obtain portal sessions", async (t) => {
  const f = await fixture(t);
  assert.equal((await f.request(null)).statusCode, 401);
  const started = f.store.device("Fixture Mac", digest("fixture-verifier"));
  f.store.approveDevice(started.userCode, f.user.user.id);
  const device = f.store.exchangeDevice(started.deviceCode, "fixture-verifier");
  assert.equal((await f.request({ session: device.token })).statusCode, 403);
  for (const session of [device.token, f.user.session]) {
    assert.equal((await f.request(null, {}, { authorization: "Bearer " + session })).statusCode, 403);
  }
  assert.equal((await f.request(f.user, {}, { origin: "https://attacker.example" })).statusCode, 403);
  assert.equal((await f.request(f.user, {}, { origin: undefined })).statusCode, 403);
  const noCustomer = f.store.consumeMagic(f.store.magic("no-customer@example.test"));
  assert.equal((await f.request(noCustomer)).statusCode, 400);
  assert.deepEqual(f.calls, { retrieve: [], create: [] });
});

test("an invalid returned portal URL never becomes an open redirect", async (t) => {
  const f = await fixture(t);
  f.returnURL("https://billing.stripe.com.attacker.example/session");
  const response = await f.request();
  assert.equal(response.statusCode, 503);
  assert.deepEqual(response.json(), { error: "service_unavailable" });
  assert.ok(!response.body.includes("attacker"));
});
