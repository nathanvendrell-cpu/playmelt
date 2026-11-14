import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import { Store, digest } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";
import { overview, readGitHubDownloads } from "../src/admin.mjs";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

test("owner activation and aggregate counters survive a real SQLite close and reopen", () => {
  const dir = mkdtempSync(join(tmpdir(), "playmelt-owner-proof-")),
    path = join(dir, "account.sqlite");
  let store;
  try {
    store = new Store(path);
    const user = store.consumeMagic(store.magic("owner@example.test")).user,
      code = store.issueOwnerCode(user.email);
    store.activity("page_view", "site.direct");
    store.close();
    store = null;
    store = new Store(path);
    assert.equal(store.redeemOwnerCode(code, user), true);
    store.close();
    store = null;
    store = new Store(path);
    assert.equal(store.entitlement(user.id).plan, "lifetime");
    assert.equal(
      store.get("SELECT count FROM activity_daily WHERE kind='page_view'")
        .count,
      1,
    );
    assert.equal(store.get("SELECT hash FROM owner_codes").hash, digest(code));
  } finally {
    if (store) store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

async function fixture(t) {
  let now = 1900000000;
  const store = new Store(":memory:", () => now),
    keys = generateKeyPairSync("ed25519");
  const config = {
    testing: true,
    publicURL: "https://example.test/account",
    live: false,
    prices: {},
    signingKey: keys.privateKey,
    adminEmails: ["owner@example.test"],
    supportAdmins: ["owner@example.test"],
  };
  const app = await createApp({
    store,
    config,
    stripe: {},
    mailer: { sendMail: async (message) => ({ accepted: [message.to.address] }) },
  });
  t.after(() => app.close());
  const user = (email) => store.consumeMagic(store.magic(email));
  const req = (u, method, path, payload, extra = {}) =>
    app.inject({
      method,
      url: "/account" + path,
      payload,
      headers: {
        ...(u ? { cookie: "pm_session=" + u.session } : {}),
        origin: "https://example.test",
        ...extra,
      },
    });
  return { store, app, config, user, req, keys, advance: (n) => (now += n) };
}
test("admin data is unavailable to anonymous accounts, ordinary customers and paired device tokens", async (t) => {
  const f = await fixture(t),
    owner = f.user("owner@example.test"),
    buyer = f.user("buyer@example.test");
  assert.equal(
    (await f.req(null, "GET", "/v1/admin/overview")).statusCode,
    401,
  );
  assert.equal(
    (await f.req(buyer, "GET", "/v1/admin/overview")).statusCode,
    403,
  );
  assert.equal(
    (await f.req(owner, "GET", "/v1/admin/overview")).statusCode,
    200,
  );
  const d = f.store.device("Mac", digest("verifier"));
  f.store.approveDevice(d.userCode, owner.user.id);
  const paired = f.store.exchangeDevice(d.deviceCode, "verifier");
  assert.equal(
    (
      await f.req(null, "GET", "/v1/admin/overview", undefined, {
        authorization: "Bearer " + paired.token,
      })
    ).statusCode,
    403,
  );
  assert.equal((await f.req(null, "GET", "/admin")).statusCode, 303);
  assert.equal((await f.req(buyer, "GET", "/admin")).statusCode, 403);
  assert.match((await f.req(owner, "GET", "/admin")).body, /Administration/);
  assert.equal(
    (await f.req(owner, "GET", "/v1/admin/overview?days=999")).statusCode,
    400,
  );
});
test("public counters accept only first-party pages, keep aggregate low-cardinality sources and do not attribute a visit to a customer", async (t) => {
  const f = await fixture(t),
    u = f.user("owner@example.test");
  assert.equal(
    (
      await f.req(null, "POST", "/v1/metrics/pageview", {
        page: "site",
        referrer: "www.google.com",
      })
    ).statusCode,
    204,
  );
  assert.equal(
    (
      await f.req(u, "POST", "/v1/metrics/pageview", {
        page: "account",
        referrer: "a.random.example",
      })
    ).statusCode,
    204,
  );
  assert.equal(
    (
      await f.req(
        null,
        "POST",
        "/v1/metrics/pageview",
        { page: "site" },
        { origin: "https://evil.example" },
      )
    ).statusCode,
    403,
  );
  assert.equal(
    (
      await f.req(null, "POST", "/v1/metrics/pageview", {
        page: "customer/private-token",
      })
    ).statusCode,
    400,
  );
  assert.equal(
    (
      await f.req(
        null,
        "POST",
        "/v1/metrics/pageview",
        { page: "site" },
        { "user-agent": "example bot" },
      )
    ).statusCode,
    204,
  );
  const rows = f.store.all(
    "SELECT * FROM activity_daily WHERE kind='page_view'",
  );
  assert.deepEqual(rows.map((r) => r.source).sort(), [
    "account.other",
    "site.google.com",
  ]);
  assert.equal(
    rows.reduce((n, r) => n + r.count, 0),
    2,
  );
  assert.ok(rows.every((r) => !("user_id" in r)));
});
test("anonymous downloads fail without a redirect or a download counter", async (t) => {
  const f = await fixture(t);
  for (const method of ["HEAD", "GET"]) {
    const response = await f.req(null, method, "/v1/download?source=site");
    assert.equal(response.statusCode, 401);
    assert.equal(response.headers.location, undefined);
  }
  assert.equal(
    f.store.get(
      "SELECT SUM(count) AS n FROM activity_daily WHERE kind='download'",
    ).n,
    null,
  );
});
test("support membership never implicitly grants the general administration", async (t) => {
  const f = await fixture(t), owner = f.user("owner@example.test");
  delete f.config.adminEmails;
  assert.equal((await f.req(owner, "GET", "/v1/admin/overview")).statusCode, 403);
  assert.equal((await f.req(owner, "GET", "/admin")).statusCode, 403);
});
test("the isolated payment recipe accepts only its configured mailbox and never exposes a test notice in production pages", async (t) => {
  const f = await fixture(t);
  const production = await f.req(null, "GET", "/");
  assert.doesNotMatch(production.body, /ENVIRONMENT_NOTICE|Recette réservée/);
  f.config.testAccountEmail = "owner@example.test";
  const denied = await f.req(null, "POST", "/v1/auth/email", { email: "other@example.test" });
  assert.equal(denied.statusCode, 200);
  assert.equal(denied.json().requested, true);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM magic_links").n, 0);
  assert.equal((await f.req(null, "POST", "/v1/auth/email", { email: "owner@example.test" })).statusCode, 200);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM magic_links").n, 1);
  assert.match((await f.req(null, "GET", "/")).body, /Stripe en mode test/);
});
test("device credentials cannot enroll peers, revoke devices or manage billing, even when carried as a cookie", async (t) => {
  const f = await fixture(t), owner = f.user("owner@example.test");
  const request = f.store.device("Mac", digest("verifier"));
  f.store.approveDevice(request.userCode, owner.user.id);
  const paired = f.store.exchangeDevice(request.deviceCode, "verifier");
  const peer = f.store.device("Peer", digest("peer-verifier"));
  const routes = [
    ["/v1/device/approve", { code: peer.userCode }],
    ["/v1/devices/revoke", { id: paired.deviceID }],
    ["/v1/checkout", { plan: "monthly" }],
    ["/v1/billing/portal", {}],
  ];
  for (const cookie of [false, true]) {
    for (const [path, payload] of routes) {
      const r = await f.req(cookie ? { session: paired.token } : null, "POST", path, payload,
        cookie ? {} : { authorization: "Bearer " + paired.token });
      assert.equal(r.statusCode, 403, path);
      assert.equal(r.json().error, "browser_required", path);
    }
  }
  assert.equal(f.store.get("SELECT user_id FROM device_requests WHERE code=?", peer.userCode).user_id, null);
  assert.ok(f.store.authenticate(paired.token));
  assert.equal((await f.req(owner, "POST", "/v1/device/approve", { code: peer.userCode })).statusCode, 200);
});
test("dashboard totals reconcile with daily rows, preserve unknown history and include older still-open reserves", async (t) => {
  const f = await fixture(t),
    u = f.user("owner@example.test");
  f.store.activity("page_view", "site.direct");
  f.store.run(
    "INSERT INTO payment_reserves VALUES(?,?,?,?,?,?,?)",
    "in_1",
    u.user.id,
    "pi_1",
    1999,
    "eur",
    f.store.now(),
    f.store.now() + 14 * 86400,
  );
  const first = overview(f.store, 30);
  assert.equal(first.totals.newAccounts, 1);
  assert.equal(first.totals.logins, 1);
  assert.equal(first.totals.pageViews, 1);
  assert.equal(first.series.filter((r) => r.pageViews === null).length, 29);
  assert.equal(first.totals.receiptsCents, 1999);
  f.advance(8 * 86400);
  const recent = overview(f.store, 7);
  assert.equal(recent.totals.receiptsCents, 0);
  assert.equal(recent.totals.pendingReserveCents, 1999);
  assert.equal(
    recent.series.reduce((n, r) => n + (r.logins || 0), 0),
    recent.totals.logins,
  );
});
test("owner codes are hashed, account-bound, expiring and produce a signed lifetime ticket without a fabricated Stripe receipt", async (t) => {
  const f = await fixture(t),
    u = f.user("owner@example.test"),
    other = f.user("buyer@example.test"),
    code = f.store.issueOwnerCode(u.user.email);
  assert.ok(
    !JSON.stringify(f.store.all("SELECT * FROM owner_codes")).includes(code),
  );
  assert.equal(
    (await f.req(other, "POST", "/v1/redeem", { code })).statusCode,
    400,
  );
  assert.equal(
    (
      await f.req(
        u,
        "POST",
        "/v1/redeem",
        { code },
        { origin: "https://evil.example" },
      )
    ).statusCode,
    403,
  );
  assert.equal(
    (await f.req(u, "POST", "/v1/redeem", { code })).statusCode,
    200,
  );
  assert.equal(
    (await f.req(u, "POST", "/v1/redeem", { code })).statusCode,
    200,
  );
  assert.equal(f.store.entitlement(u.user.id).plan, "lifetime");
  assert.equal(f.store.entitlement(u.user.id).until, null);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM payment_reserves").n, 0);
  const device = f.store.device("Mac", digest("fixture"));
  f.store.approveDevice(device.userCode, u.user.id);
  const paired = f.store.exchangeDevice(device.deviceCode, "fixture");
  const ticket = await f.req(
    null,
    "POST",
    "/v1/launch-ticket",
    {},
    { authorization: "Bearer " + paired.token },
  );
  assert.equal(ticket.statusCode, 200);
  const [payload, signature] = ticket.json().ticket.split(".");
  assert.ok(
    verify(
      null,
      Buffer.from(payload),
      f.keys.publicKey,
      Buffer.from(signature, "base64url"),
    ),
  );
  assert.equal(JSON.parse(Buffer.from(payload, "base64url")).plan, "lifetime");
  assert.equal(
    (
      await f.req(
        null,
        "POST",
        "/v1/redeem",
        { code },
        { authorization: "Bearer " + paired.token },
      )
    ).statusCode,
    403,
  );
  const expired = f.store.issueOwnerCode(other.user.email);
  f.advance(7 * 86400);
  assert.equal(f.store.redeemOwnerCode(expired, other.user), false);
});
test("a fresh owner code invalidates the previous unused code without revoking a redeemed lifetime grant", async (t) => {
  const f = await fixture(t),
    u = f.user("owner@example.test"),
    old = f.store.issueOwnerCode(u.user.email),
    fresh = f.store.issueOwnerCode(u.user.email);
  assert.equal(f.store.redeemOwnerCode(old, u.user), false);
  assert.equal(f.store.redeemOwnerCode(fresh, u.user), true);
  f.store.issueOwnerCode(u.user.email);
  assert.ok(f.store.entitlement(u.user.id));
});
test("GitHub uses public aggregate downloads, caches without a background job and preserves the last real snapshot on failure", async (t) => {
  const f = await fixture(t);
  let calls = 0;
  const fetcher = async (url, options) => {
    calls++;
    assert.match(
      url,
      /^https:\/\/api.github.com\/repos\/nathanvendrell-cpu\/playmelt\/releases\?/,
    );
    assert.equal(options.headers.Authorization, undefined);
    return {
      ok: true,
      headers: new Headers(),
      text: async () =>
        JSON.stringify([
          {
            tag_name: "v2.1.0",
            assets: [
              { id: 1, name: "Playmelt-2.1.0.dmg", download_count: 17 },
              { id: 2, name: "source.zip", download_count: 800 },
            ],
          },
        ]),
    };
  };
  const a = await readGitHubDownloads(f.store, fetcher);
  assert.equal(a.total, 17);
  assert.equal(a.history.length, 1);
  assert.equal((await readGitHubDownloads(f.store, fetcher)).total, 17);
  assert.equal(calls, 1);
  f.advance(400);
  const stale = await readGitHubDownloads(f.store, async () => {
    throw Error("offline");
  });
  assert.equal(stale.stale, true);
  assert.equal(stale.total, 17);
});
test("a GitHub outage before the first measurement stays unknown, not zero", async (t) => {
  const f = await fixture(t);
  const r = await readGitHubDownloads(f.store, async () => {
    throw Error("offline");
  });
  assert.equal(r.available, false);
  assert.equal(r.total, null);
  assert.equal(
    f.store.all("SELECT * FROM github_download_snapshots").length,
    0,
  );
});
test("unverified billing cannot create Checkout or accept payment webhooks, while owner activation remains available", async (t) => {
  const f = await fixture(t),
    u = f.user("owner@example.test");
  f.config.billingEnabled = false;
  assert.equal(
    (await f.req(u, "POST", "/v1/checkout", { plan: "monthly" })).json().error,
    "billing_not_ready",
  );
  assert.equal(
    (await f.req(null, "POST", "/v1/stripe/webhook", {})).statusCode,
    503,
  );
  assert.equal(
    (await f.req(null, "GET", "/v1/billing/status")).json().enabled,
    false,
  );
  const code = f.store.issueOwnerCode(u.user.email);
  assert.equal(
    (await f.req(u, "POST", "/v1/redeem", { code })).statusCode,
    200,
  );
});
