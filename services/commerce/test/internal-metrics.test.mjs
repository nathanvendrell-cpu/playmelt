import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Store } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";
import { overview, readGitHubDownloads } from "../src/admin.mjs";

const DAY = 86400;
const NOW = Date.UTC(2026, 10, 12, 12) / 1000;
const day = (seconds) => new Date(seconds * 1000).toISOString().slice(0, 10);
const user = (store, id, internal = false, created = NOW) => {
  store.run("INSERT INTO users(id,email,created,is_internal) VALUES(?,?,?,?)", id, id + "@example.test", created, internal ? 1 : 0);
  return store.get("SELECT * FROM users WHERE id=?", id);
};
function entitlement(store, id, account, status, until = null, payment = null) {
  store.run("INSERT INTO entitlements VALUES(?,?,?,?,?,NULL,?,?)", id, account.id, "monthly", status, until, payment, NOW);
}
function payment(store, id, account, amount, received = NOW, until = NOW + 10 * DAY) {
  store.run("INSERT INTO payment_reserves VALUES(?,?,?,?,?,?,?)", id, account.id, "pi_" + id, amount, "eur", received, until);
}
function activity(store, date, kind, count, source = "account") {
  store.run("INSERT INTO activity_daily VALUES(?,?,?,?) ON CONFLICT(day,kind,source) DO UPDATE SET count=excluded.count", day(date), kind, source, count);
}
const memory = (t) => {
  const store = new Store(":memory:", () => NOW);
  t.after(() => store.close());
  return store;
};

test("the internal owner's live account, session and lifetime grant remain usable while commercial KPI stay at zero", (t) => {
  const store = memory(t);
  store.setInternalEmails(["owner@example.test"]);
  const owner = store.consumeMagic(store.magic("owner@example.test"));
  assert.equal(store.redeemOwnerCode(store.issueOwnerCode(owner.user.email), owner.user), true);
  payment(store, "internal", owner.user, 9999);
  store.run("INSERT INTO support_tickets(id,user_id,category,message,created) VALUES(?,?,?,?,?)", "owner-help", owner.user.id, "licence", "Question de recette interne.", NOW);
  activity(store, NOW, "login", 100);
  activity(store, NOW, "download", 80, "site");
  activity(store, NOW, "account_created", 20);
  const before = store.entitlement(owner.user.id);
  const data = overview(store, 30);
  for (const key of ["accounts", "activeLicences", "activeTrials", "newAccounts", "logins", "siteDownloadRequests", "receiptsCents", "pendingReserveCents", "flaggedPayments", "openSupport"]) assert.equal(data.totals[key], 0, key);
  assert.deepEqual(data.payments, []);
  assert.equal(store.authenticate(owner.session).id, owner.user.id);
  assert.equal(store.authenticate(owner.session).is_internal, 1);
  assert.deepEqual(store.entitlement(owner.user.id), before);
  assert.equal(before.plan, "lifetime");
  assert.equal(store.get("SELECT COUNT(*) AS n FROM users").n, 1);
  assert.equal(store.get("SELECT COUNT(*) AS n FROM support_tickets").n, 1);
});

test("mixed customer and internal accounts reconcile paid access, trials, gross receipts, open reserves and support", (t) => {
  const store = memory(t),
    paid = user(store, "paid"), trial = user(store, "trial"),
    expired = user(store, "expired"), blocked = user(store, "blocked"),
    owner = user(store, "owner", true), staffTrial = user(store, "staff-trial", true);
  entitlement(store, "paid-access", paid, "active", NOW + DAY, "pi_paid");
  entitlement(store, "customer-trial", trial, "trialing", NOW + DAY);
  entitlement(store, "expired-access", expired, "active", NOW - 1);
  entitlement(store, "blocked-access", blocked, "active", null, "pi_blocked");
  entitlement(store, "owner-access", owner, "active");
  entitlement(store, "staff-trial-access", staffTrial, "trialing", NOW + DAY);
  payment(store, "paid", paid, 2000);
  payment(store, "blocked", blocked, 500);
  payment(store, "owner", owner, 9999);
  payment(store, "older", paid, 1000, NOW - 40 * DAY);
  store.run("INSERT INTO blocked_payments VALUES(?,?)", "pi_blocked", "disputed");
  for (const [id, account, status] of [["internal", owner, "open"], ["received", paid, "received"], ["fixed", trial, "fixed"], ["closed", paid, "closed"]]) {
    store.run("INSERT INTO support_tickets(id,user_id,category,message,status,created) VALUES(?,?,?,?,?,?)", id, account.id, "launch", "Un signalement de recette.", status, NOW);
  }
  const data = overview(store, 30);
  assert.equal(data.totals.accounts, 4);
  assert.equal(data.totals.newAccounts, 4);
  assert.equal(data.totals.activeLicences, 2);
  assert.equal(data.totals.activeTrials, 1);
  assert.equal(data.totals.receiptsCents, 2500);
  assert.equal(data.totals.pendingReserveCents, 3000);
  assert.equal(data.totals.flaggedPayments, 1);
  assert.equal(data.totals.openSupport, 2);
  assert.deepEqual(data.payments.map((p) => p.email).sort(), ["blocked@example.test", "paid@example.test"]);
  assert.equal(data.series.reduce((n, row) => n + (row.receiptsCents || 0), 0), data.totals.receiptsCents);
});

test("new customer accounts come from attributable creation dates even before anonymous collection, never the mixed legacy counter", (t) => {
  const store = memory(t);
  user(store, "recent", false, NOW - DAY);
  user(store, "owner", true, NOW - DAY);
  user(store, "historic", false, NOW - 60 * DAY);
  activity(store, NOW - DAY, "account_created", 999);
  const data = overview(store, 30), yesterday = data.series.find((r) => r.date === day(NOW - DAY));
  assert.equal(data.totals.accounts, 2);
  assert.equal(data.totals.newAccounts, 1);
  assert.equal(yesterday.accounts, 1);
  assert.equal(yesterday.logins, null);
  assert.equal(yesterday.downloads, null);
  assert.equal(data.series.reduce((n, row) => n + row.accounts, 0), 1);
  assert.equal(store.get("SELECT count FROM activity_daily WHERE kind='account_created'").count, 999);
});

test("legacy anonymous login/download totals remain untouched and unknown before the customer collection boundary", async (t) => {
  const store = memory(t), started = NOW - 2 * DAY;
  store.run("UPDATE service_state SET value=? WHERE key='collection_started'", String(NOW - 10 * DAY));
  store.run("UPDATE service_state SET value=? WHERE key='customer_metrics_started'", String(started));
  activity(store, NOW - 5 * DAY, "login", 999);
  activity(store, NOW - 5 * DAY, "download", 888, "site");
  activity(store, NOW - 5 * DAY, "page_view", 25, "site.direct");
  activity(store, NOW - 3 * DAY, "customer_login", 77);
  activity(store, NOW - DAY, "customer_login", 3);
  activity(store, NOW, "customer_login", 2);
  activity(store, NOW - DAY, "customer_download", 4, "site");
  activity(store, NOW, "customer_download", 2, "app");
  store.run("INSERT INTO github_download_snapshots VALUES(?,?,?,?)", day(NOW), NOW, 40, JSON.stringify([{ name: "Playmelt-2.1.0.dmg", downloads: 40 }]));
  const data = overview(store, 7);
  assert.equal(data.customerMetricsStarted, started);
  assert.equal(data.totals.logins, 5);
  assert.equal(data.totals.siteDownloadRequests, 6);
  assert.equal(data.totals.pageViews, 25);
  assert.equal(data.series.filter((r) => r.logins === null).length, 4);
  assert.equal(data.series.filter((r) => r.downloads === null).length, 4);
  assert.equal(data.series.reduce((n, row) => n + (row.logins || 0), 0), 5);
  assert.equal(data.series.reduce((n, row) => n + (row.downloads || 0), 0), 6);
  assert.equal(data.sources[0].count, 25);
  assert.equal(store.get("SELECT count FROM activity_daily WHERE kind='login'").count, 999);
  assert.equal(store.get("SELECT count FROM activity_daily WHERE kind='download'").count, 888);
  const github = await readGitHubDownloads(store, () => { throw Error("Network must not be used for this cached snapshot"); });
  assert.equal(github.total, 40);
  assert.match(data.provenance.github, /internal downloads cannot be identified/);
  assert.match(data.provenance.history, /unknown before/);
});

test("a missing or future customer boundary yields unknown values, without falling back to old anonymous totals", (t) => {
  const store = memory(t);
  activity(store, NOW, "login", 5);
  activity(store, NOW, "download", 6, "site");
  activity(store, NOW, "customer_login", 2);
  store.run("DELETE FROM service_state WHERE key='customer_metrics_started'");
  for (const future of [false, true]) {
    if (future) store.run("INSERT INTO service_state VALUES('customer_metrics_started',?)", String(NOW + DAY));
    const data = overview(store, 7);
    assert.equal(data.customerMetricsStarted, null);
    assert.equal(data.totals.logins, null);
    assert.equal(data.totals.siteDownloadRequests, null);
    assert.ok(data.series.every((row) => row.logins === null && row.downloads === null));
  }
});

test("internal browser visits are excluded prospectively while anonymous visits remain anonymous and the owner stays in management", async (t) => {
  const store = new Store(":memory:", () => NOW);
  const app = await createApp({ store, stripe: {}, mailer: {}, config: {
    testing: true, publicURL: "https://example.test/account", prices: {},
    internalEmails: ["owner@example.test"], adminEmails: ["owner@example.test"],
  } });
  t.after(() => app.close());
  const owner = store.consumeMagic(store.magic("owner@example.test")), customer = store.consumeMagic(store.magic("customer@example.test"));
  assert.equal(store.redeemOwnerCode(store.issueOwnerCode(owner.user.email), owner.user), true);
  const req = (account, method, path, payload) => app.inject({
    method, url: "/account" + path, payload,
    headers: { origin: "https://example.test", ...(account ? { cookie: "pm_session=" + account.session } : {}) },
  });
  for (const page of ["account", "site"]) assert.equal((await req(owner, "POST", "/v1/metrics/pageview", { page })).statusCode, 204);
  assert.equal(store.get("SELECT COUNT(*) AS n FROM activity_daily WHERE kind='page_view'").n, 0);
  assert.equal((await req(customer, "POST", "/v1/metrics/pageview", { page: "site" })).statusCode, 204);
  assert.equal((await req(null, "POST", "/v1/metrics/pageview", { page: "site" })).statusCode, 204);
  const management = (await req(owner, "GET", "/v1/admin/accounts")).json();
  assert.equal(management.total, 2);
  assert.equal(management.items.find((u) => u.email === owner.user.email).isInternal, true);
  assert.equal(management.items.find((u) => u.email === customer.user.email).isInternal, false);
  const data = (await req(owner, "GET", "/v1/admin/overview")).json();
  assert.equal(data.totals.accounts, 1);
  assert.equal(data.totals.activeLicences, 0);
  assert.equal(data.totals.logins, 1);
  assert.equal(data.totals.pageViews, 2);
  assert.ok(store.all("SELECT * FROM activity_daily WHERE kind='page_view'").every((r) => !("user_id" in r)));
  assert.ok(store.authenticate(owner.session));
  assert.equal(store.entitlement(owner.user.id).plan, "lifetime");
});

test("marking an existing owner internal survives SQLite reopen without deleting sessions, grant, receipts or history", () => {
  const dir = mkdtempSync(join(tmpdir(), "playmelt-internal-metrics-")), path = join(dir, "metrics.sqlite");
  let store;
  try {
    store = new Store(path, () => NOW - 3 * DAY);
    const owner = store.consumeMagic(store.magic("owner@example.test"));
    store.redeemOwnerCode(store.issueOwnerCode(owner.user.email), owner.user);
    payment(store, "owner", owner.user, 9999, NOW - 3 * DAY);
    store.close();
    store = null;
    store = new Store(path, () => NOW);
    store.setInternalEmails([owner.user.email]);
    assert.equal(overview(store, 30).totals.accounts, 0);
    assert.equal(overview(store, 30).totals.receiptsCents, 0);
    store.close();
    store = null;
    store = new Store(path, () => NOW);
    assert.equal(overview(store, 30).totals.activeLicences, 0);
    assert.equal(store.authenticate(owner.session).is_internal, 1);
    assert.equal(store.entitlement(owner.user.id).plan, "lifetime");
    assert.equal(store.get("SELECT COUNT(*) AS n FROM payment_reserves").n, 1);
    assert.equal(store.get("SELECT SUM(count) AS n FROM activity_daily WHERE kind='login'").n, 1);
  } finally {
    store?.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
