import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Stripe from "stripe";
import { Store, digest } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";
import {
  retainTerms,
  confirmContract,
  sendContract,
} from "../src/contracts.mjs";

test("a verified Checkout retains accepted terms and retries its contractual email across restart without replacing the original document or fabricating delivery", async () => {
  const dir = mkdtempSync(join(tmpdir(), "playmelt-contract-"));
  const file = join(dir, "account.sqlite");
  let store, app;
  const sdk = new Stripe("sk_test_fixture_only"),
    sent = [];
  const config = {
    testing: true,
    publicURL: "https://example.test/account",
    live: false,
    webhookSecret: "whsec_contract_fixture",
    prices: { monthly: "price_monthly" },
    signingKey: generateKeyPairSync("ed25519").privateKey,
    termsVersion: "v1",
    termsHTML: '<html lang="fr"><body>Conditions acceptées v1</body></html>',
    mailFrom: "support@example.test",
    supportEmail: "support@example.test",
  };
  config.termsSHA256 = digest(config.termsHTML);
  config.termsURL = "https://example.test/terms";
  let failing = true;
  const mailer = {
    sendMail: async (message) => {
      if (failing) throw Error("temporary SMTP failure");
      sent.push(message);
      return { accepted: ["buyer@example.test"] };
    },
  };
  const session = {
    id: "cs_contract",
    customer: "cus_contract",
    client_reference_id: null,
    mode: "subscription",
    status: "complete",
    subscription: "sub_contract",
    amount_total: 0,
    currency: "eur",
  };
  const stripe = {
    webhooks: sdk.webhooks,
    checkout: {
      sessions: {
        create: async () => ({
          id: session.id,
          url: "https://checkout.stripe.com/c/pay/fixture",
          expires_at: Math.floor(Date.now() / 1000) + 3600,
        }),
        retrieve: async () => session,
      },
    },
    subscriptions: {
      retrieve: async () => ({
        id: "sub_contract",
        customer: session.customer,
        status: "trialing",
        default_payment_method: "pm_fixture",
        trial_start: 1700000000,
        trial_end: 1702592000,
        latest_invoice: null,
        items: { data: [{ price: { id: "price_monthly" } }] },
      }),
    },
  };
  const event = {
    id: "evt_contract",
    livemode: false,
    type: "checkout.session.completed",
    data: { object: { id: session.id } },
  };
  const payload = JSON.stringify(event);
  const webhook = () =>
    app.inject({
      method: "POST",
      url: "/account/v1/stripe/webhook",
      payload,
      headers: {
        "content-type": "application/json",
        "stripe-signature": sdk.webhooks.generateTestHeaderString({
          payload,
          secret: config.webhookSecret,
        }),
      },
    });
  try {
    store = new Store(file, () => 1700000010);
    app = await createApp({ store, stripe, config, mailer });
    const u = store.consumeMagic(store.magic("buyer@example.test"));
    session.client_reference_id = u.user.id;
    store.run(
      "UPDATE users SET stripe_customer=? WHERE id=?",
      session.customer,
      u.user.id,
    );
    const checkout = await app.inject({
      method: "POST",
      url: "/account/v1/checkout",
      payload: { plan: "monthly", acceptTerms: true, termsVersion: "v1" },
      headers: { authorization: "Bearer " + u.session },
    });
    assert.equal(checkout.statusCode, 200);
    assert.equal(
      store.get("SELECT terms_sha256 FROM checkout_contracts").terms_sha256,
      config.termsSHA256,
    );
    assert.equal((await webhook()).statusCode, 503);
    assert.equal(
      store.get("SELECT status FROM billing_events").status,
      "complete",
    );
    assert.equal(
      store.get("SELECT delivery FROM checkout_contracts").delivery,
      "failed",
    );
    assert.equal(sent.length, 0);
    await app.close();
    app = null;
    store = null;
    store = new Store(file, () => 1700000020);
    const changed = {
      ...config,
      termsVersion: "v2",
      termsHTML: "<html><body>New terms v2</body></html>",
    };
    changed.termsSHA256 = digest(changed.termsHTML);
    app = await createApp({ store, stripe, config: changed, mailer });
    failing = false;
    assert.equal((await webhook()).statusCode, 200);
    assert.equal(sent.length, 1);
    assert.equal(sent[0].to.address, "buyer@example.test");
    assert.equal(sent[0].attachments[0].content, config.termsHTML);
    assert.match(sent[0].text, /version v1/);
    assert.match(sent[0].text, /Essai actif/);
    assert.match(sent[0].text, /0,00/);
    assert.equal(
      store.get("SELECT delivery FROM checkout_contracts").delivery,
      "smtp_accepted",
    );
    assert.equal((await webhook()).statusCode, 200);
    assert.equal(sent.length, 1);
    assert.equal(store.get("SELECT COUNT(*) AS n FROM payment_reserves").n, 0);
  } finally {
    if (app) await app.close();
    else store?.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a wrong terms fingerprint or unconfirmed Checkout can never produce a contractual confirmation", async () => {
  const store = new Store(":memory:");
  try {
    assert.throws(() =>
      retainTerms(store, {
        termsHTML: "different",
        termsSHA256: "0".repeat(64),
        termsVersion: "v1",
      }),
    );
    const html = "<html>Terms</html>",
      sha = digest(html);
    retainTerms(store, {
      termsHTML: html,
      termsSHA256: sha,
      termsVersion: "v1",
    });
    const u = store.consumeMagic(store.magic("buyer@example.test")).user;
    store.run(
      "INSERT INTO checkout_contracts(checkout_id,user_id,plan,terms_sha256,accepted,updated) VALUES(?,?,?,?,?,?)",
      "cs_pending",
      u.id,
      "monthly",
      sha,
      store.now(),
      store.now(),
    );
    confirmContract(
      store,
      { id: "cs_pending", status: "open" },
      u,
      { status: "active" },
      { label: "1 mois" },
    );
    let sends = 0;
    await sendContract(
      store,
      {
        sendMail: async () => {
          sends++;
        },
      },
      {},
      "cs_pending",
    );
    assert.equal(sends, 0);
    assert.equal(
      store.get("SELECT confirmed FROM checkout_contracts").confirmed,
      null,
    );
  } finally {
    store.close();
  }
});
