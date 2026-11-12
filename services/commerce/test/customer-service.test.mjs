import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Store } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";

async function fixture(t) {
  const store = new Store(":memory:");
  const config = {
    testing: true,
    publicURL: "https://example.test/account",
    live: false,
    prices: { monthly: "price_monthly" },
    signingKey: generateKeyPairSync("ed25519").privateKey,
    termsVersion: "2026-11-12",
    termsSHA256: "0".repeat(64),
    termsURL: "https://example.test/terms",
    supportAdmins: ["owner@example.test"],
  };
  const calls = [];
  const stripe = {
    checkout: {
      sessions: {
        create: async (params) => {
          calls.push(params);
          return {
            id: "cs_1",
            url: "https://checkout.stripe.com/c/pay/cs_1",
            expires_at: Date.now() / 1000 + 3600,
          };
        },
      },
    },
  };
  const app = await createApp({
    store,
    config,
    stripe,
    mailer: { sendMail: async () => ({ accepted: ["buyer@example.test"] }) },
  });
  t.after(() => app.close());
  const user = (email) => {
    const u = store.consumeMagic(store.magic(email));
    store.run(
      "UPDATE users SET stripe_customer=? WHERE id=?",
      "cus_" + randomUUID(),
      u.user.id,
    );
    return u;
  };
  const req = (user, method, path, payload) =>
    app.inject({
      method,
      url: "/account" + path,
      payload,
      headers: { authorization: "Bearer " + user.session },
    });
  return { app, store, config, calls, user, req };
}
test("a real checkbox acceptance with current terms is required and retained before creating Checkout", async (t) => {
  const f = await fixture(t),
    u = f.user("buyer@example.test");
  for (const body of [
    { plan: "monthly" },
    {
      plan: "monthly",
      acceptTerms: "true",
      termsVersion: f.config.termsVersion,
    },
    { plan: "monthly", acceptTerms: true, termsVersion: "old" },
  ])
    assert.equal(
      (await f.req(u, "POST", "/v1/checkout", body)).statusCode,
      400,
    );
  assert.equal(f.calls.length, 0);
  assert.equal(
    (
      await f.req(u, "POST", "/v1/checkout", {
        plan: "monthly",
        acceptTerms: true,
        termsVersion: f.config.termsVersion,
      })
    ).statusCode,
    200,
  );
  const consent = f.store.get("SELECT * FROM checkout_terms");
  assert.equal(consent.user_id, u.user.id);
  assert.equal(consent.version, f.config.termsVersion);
  assert.equal(consent.sha256, f.config.termsSHA256);
  assert.equal(f.calls[0].metadata.terms_sha256, f.config.termsSHA256);
});
test("support works without a paid licence and isolates customers and staff", async (t) => {
  const f = await fixture(t),
    a = f.user("buyer@example.test"),
    b = f.user("other@example.test"),
    owner = f.user("owner@example.test");
  const response = await f.req(a, "POST", "/v1/support", {
    category: "licence",
    message: "Je ne parviens pas à activer mon Mac.",
  });
  assert.equal(response.statusCode, 200);
  const ticket = response.json();
  assert.equal((await f.req(b, "GET", "/v1/support")).json().length, 0);
  assert.equal((await f.req(a, "GET", "/v1/support")).json()[0].id, ticket.id);
  assert.equal((await f.req(a, "GET", "/v1/admin/support")).statusCode, 403);
  assert.equal(
    (await f.req(owner, "GET", "/v1/admin/support")).json()[0].email,
    "buyer@example.test",
  );
  assert.equal(
    (
      await f.req(b, "POST", "/v1/admin/support/" + ticket.id + "/reply", {
        message: "intrusion",
      })
    ).statusCode,
    403,
  );
  const reply = await f.req(
    owner,
    "POST",
    "/v1/admin/support/" + ticket.id + "/reply",
    { message: "Nous avons reçu votre demande." },
  );
  assert.equal(reply.json().delivery, "smtp_accepted");
  assert.equal(
    (await f.req(a, "GET", "/v1/support")).json()[0].replies.length,
    1,
  );
});
test("account, trial and support survive a real SQLite close and reopen", () => {
  const directory = mkdtempSync(
      join(tmpdir(), "playmelt-commerce-persistence-"),
    ),
    file = join(directory, "account.sqlite");
  let store;
  try {
    store = new Store(file);
    const u = store.consumeMagic(store.magic("persistent@example.test"));
    store.run(
      "INSERT INTO trials VALUES(?,?,?,?)",
      u.user.id,
      "sub_trial",
      1000,
      2000,
    );
    store.run(
      "INSERT INTO support_tickets(id,user_id,category,message,created) VALUES(?,?,?,?,?)",
      "ticket",
      u.user.id,
      "paiement",
      "Vérification du paiement.",
      1000,
    );
    store.close();
    store = null;
    store = new Store(file);
    assert.equal(store.authenticate(u.session).id, u.user.id);
    assert.equal(
      store.get("SELECT subscription_id FROM trials WHERE user_id=?", u.user.id)
        .subscription_id,
      "sub_trial",
    );
    assert.equal(
      store.get("SELECT message FROM support_tickets WHERE id=?", "ticket")
        .message,
      "Vérification du paiement.",
    );
  } finally {
    store?.close();
    rmSync(directory, { recursive: true });
  }
});
