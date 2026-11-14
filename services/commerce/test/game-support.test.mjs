import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Store, digest } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";

async function fixture(t, options = {}) {
  let now = 1900000000;
  const store = new Store(options.path || ":memory:", () => now);
  const config = {
    testing: true, publicURL: "https://example.test/account", prices: {},
    adminEmails: ["admin@example.test"], supportAdmins: ["support@example.test"],
    supportEmail: "contact@7agency.fr", mailFrom: "Playmelt <contact@7agency.fr>",
    ...options.config,
  };
  const mail = [];
  const app = await createApp({
    store, config, stripe: {}, mailer: { sendMail: async (value) => {
      mail.push(value);
      return options.sendMail ? options.sendMail(value) : { accepted: [config.supportEmail] };
    } },
  });
  let closed = false;
  const close = async () => {
    if (closed) return;
    closed = true;
    await app.close(); // createApp's onClose hook also closes this Store.
  };
  t.after(close);
  const user = (email) => store.consumeMagic(store.magic(email));
  const paired = (u) => {
    const request = store.device("Mac", digest("verifier"));
    store.approveDevice(request.userCode, u.user.id);
    return { ...u, session: store.exchangeDevice(request.deviceCode, "verifier").token };
  };
  const req = (u, method, path, payload, browser = false) => app.inject({
    method, url: "/account" + path, payload,
    headers: browser ? { cookie: "pm_session=" + u.session, origin: "https://example.test" }
      : u ? { authorization: "Bearer " + u.session } : {},
  });
  return { store, config, app, user, paired, req, mail, close, advance: (n) => now += n };
}
const body = (extra = {}) => ({
  clientId: randomUUID(), gameId: "steam-123", gameTitle: "A game", store: "Steam",
  category: "launch", message: "Le jeu ne démarre pas.", createdAt: 1899999999.5,
  diagnostics: { version: "2.2.0", macOS: "27.1", chip: "Apple M3 Max", memoryGB: 48,
    gpuName: "Apple M3 Max", renderer: "Wine + Metal", graphicsAPI: "DirectX 12", installed: true, launchBlocked: false },
  ...extra,
});
const route = "/v1/support/tickets";
const admin = (id, suffix) => "/v1/admin/support/" + id + "/" + suffix;

test("native support accepts an authenticated device without entitlement, and isolates accounts", async (t) => {
  const f = await fixture(t), a = f.paired(f.user("a@example.test")), b = f.paired(f.user("b@example.test"));
  assert.equal(f.store.entitlement(a.user.id), null);
  assert.equal((await f.req(null, "POST", route, body())).statusCode, 401);
  const browser = f.user("browser@example.test");
  assert.equal((await f.req(browser, "POST", route, body(), true)).statusCode, 403);
  assert.equal((await f.req(browser, "GET", route, undefined, true)).statusCode, 403);
  const payload = body(), response = await f.req(a, "POST", route, payload), ticket = response.json();
  assert.equal(response.statusCode, 201);
  assert.deepEqual(Object.keys(ticket).sort(), ["id", "status"]);
  assert.equal(ticket.status, "received");
  assert.deepEqual((await f.req(a, "GET", route)).json(), { tickets: [{ clientId: payload.clientId, ...ticket }] });
  assert.deepEqual((await f.req(b, "GET", route)).json(), { tickets: [] });
  assert.equal((await f.req(b, "POST", route, payload)).statusCode, 201);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM support_tickets").n, 2);
  assert.equal((await f.req(a, "GET", "/v1/support")).json()[0].id, ticket.id);
  assert.equal(f.mail.length, 2);
  assert.deepEqual(f.mail[0].to, { address: "contact@7agency.fr" });
  assert.equal(f.mail[0].html, undefined);
  assert.ok(!f.mail[0].text.includes("Apple M3 Max"));
  assert.equal(f.store.get("SELECT delivery FROM support_notifications WHERE ticket_id=?", ticket.id).delivery, "smtp_accepted");
});

test("concurrent retries use one account/clientId and never resend a notification", async (t) => {
  let release;
  const gate = new Promise((resolve) => release = resolve);
  const f = await fixture(t, { sendMail: async () => { await gate; return { accepted: ["contact@7agency.fr"] }; } });
  const a = f.paired(f.user("a@example.test")), payload = body();
  const requests = Array.from({ length: 8 }, () => f.req(a, "POST", route, payload));
  try {
    await new Promise((resolve) => setImmediate(resolve));
  } finally { release(); }
  const responses = await Promise.all(requests);
  assert.equal(responses.filter((r) => r.statusCode === 201).length, 1);
  assert.equal(responses.filter((r) => r.statusCode === 200).length, 7);
  assert.equal(new Set(responses.map((r) => r.json().id)).size, 1);
  assert.equal(f.mail.length, 1);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM game_support").n, 1);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM support_tickets").n, 1);
  const changed = await f.req(a, "POST", route, { ...payload, message: "Une autre description.", clientId: payload.clientId.toUpperCase() });
  assert.equal(changed.statusCode, 200);
  assert.equal(f.store.get("SELECT message FROM support_tickets").message, payload.message);
});

test("only allowlisted diagnostics persist, without client addresses, paths, logs or tokens", async (t) => {
  const f = await fixture(t), a = f.paired(f.user("a@example.test")), payload = body();
  const valid = payload.diagnostics;
  payload.diagnostics = { ...valid, log: "private log", path: "/Users/private", token: "secret", serialNumber: "private", nested: { secret: true } };
  payload.email = "intruder@example.test\r\nBcc: victim@example.test";
  payload.to = ["intruder@example.test"];
  const response = await f.req(a, "POST", route, payload);
  assert.equal(response.statusCode, 201);
  assert.deepEqual(JSON.parse(f.store.get("SELECT diagnostics FROM game_support").diagnostics), valid);
  assert.equal(f.mail.length, 1);
  assert.deepEqual(f.mail[0].to, { address: "contact@7agency.fr" });
  assert.ok(!JSON.stringify(f.mail[0]).includes("intruder"));
});

test("invalid native fields and diagnostic types cannot create a ticket", async (t) => {
  const f = await fixture(t), a = f.paired(f.user("a@example.test"));
  for (const value of [
    { clientId: "not-a-uuid" }, { gameId: 123 }, { gameTitle: "x".repeat(201) },
    { store: [] }, { category: "licence" }, { message: "1234" },
    { message: "x".repeat(4001) }, { createdAt: "1900000000" }, { createdAt: -1 },
    { diagnostics: [] }, { diagnostics: { version: 22 } },
    { diagnostics: { memoryGB: "48" } }, { diagnostics: { memoryGB: 9000 } },
    { diagnostics: { installed: 1 } }, { diagnostics: { launchBlocked: "false" } },
    { diagnostics: { renderer: "x".repeat(81) } }, { diagnostics: { gpuName: "/Users/private" } },
    { diagnostics: { macOS: "27\nBcc: victim@example.test" } },
  ]) assert.equal((await f.req(a, "POST", route, body(value))).statusCode, 400, JSON.stringify(value));
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM support_tickets").n, 0);
  assert.equal(f.mail.length, 0);
});

test("browser staff alone changes game status with durable actor audit, never automatic verification", async (t) => {
  const f = await fixture(t), a = f.paired(f.user("a@example.test")), owner = f.user("admin@example.test"), support = f.user("support@example.test");
  const ticket = (await f.req(a, "POST", route, body())).json();
  assert.equal((await f.req(a, "GET", "/v1/admin/support")).statusCode, 403);
  for (const u of [a, f.paired(owner)]) {
    assert.equal((await f.req(u, "POST", admin(ticket.id, "status"), { status: "verified" })).statusCode, 403);
    assert.equal((await f.req(u, "POST", admin(ticket.id, "notification/retry"), {})).statusCode, 403);
  }
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM support_status_audit").n, 0);
  assert.equal((await f.req(owner, "POST", admin(ticket.id, "status"), { status: "resolved" }, true)).statusCode, 400);
  assert.equal((await f.req(owner, "POST", admin("missing", "status"), { status: "fixed" }, true)).statusCode, 404);
  for (const status of ["investigating", "fixed", "verified", "closed", "received"]) {
    const response = await f.req(owner, "POST", admin(ticket.id, "status"), { status }, true);
    assert.equal(response.statusCode, 200);
    assert.equal(response.json().status, status);
    f.advance(1);
  }
  await f.req(owner, "POST", admin(ticket.id, "status"), { status: "received" }, true);
  const listed = (await f.req(support, "GET", "/v1/admin/support", undefined, true)).json()[0];
  assert.equal(listed.id, ticket.id);
  assert.equal(listed.game.gameTitle, "A game");
  assert.equal(listed.game.audit.length, 5);
  assert.equal(listed.game.audit[0].previousStatus, "received");
  assert.ok(listed.game.audit.every((entry) => entry.actor === owner.user.email));
  assert.equal(listed.game.notification.delivery, "smtp_accepted");
  assert.equal(listed.game.notificationAttempts.length, 1);
});

test("failed mail is retained without duplicate tickets; explicit staff retries are capped", async (t) => {
  const f = await fixture(t, { sendMail: async () => { throw Error("SMTP password must not be persisted"); } });
  const a = f.paired(f.user("a@example.test")), owner = f.user("admin@example.test"), payload = body();
  const response = await f.req(a, "POST", route, payload), ticket = response.json();
  assert.equal(response.statusCode, 201);
  assert.equal(ticket.status, "received");
  assert.equal((await f.req(a, "POST", route, payload)).statusCode, 200);
  assert.equal(f.mail.length, 1);
  for (let n = 0; n < 4; n++) {
    const retry = await f.req(owner, "POST", admin(ticket.id, "notification/retry"), {}, true);
    assert.equal(retry.statusCode, 200);
    assert.equal(retry.json().delivery, "failed");
  }
  assert.equal(f.mail.length, 3);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM support_tickets").n, 1);
  assert.equal(f.store.get("SELECT attempts FROM support_notifications").attempts, 3);
  assert.ok(f.store.all("SELECT * FROM support_notification_attempts").every((a) => a.delivery === "failed"));
  assert.ok(!JSON.stringify(f.store.all("SELECT * FROM support_notification_attempts")).includes("password"));
});

test("SMTP absence of acceptance and invalid configuration never claim delivery or add recipients", async (t) => {
  const f = await fixture(t, { sendMail: async () => ({ accepted: ["other@example.test"] }) });
  const a = f.paired(f.user("a@example.test"));
  assert.equal((await f.req(a, "POST", route, body())).statusCode, 201);
  assert.equal(f.store.get("SELECT delivery FROM support_notifications").delivery, "unconfirmed");
  f.config.supportEmail = "contact@7agency.fr, victim@example.test";
  assert.equal((await f.req(a, "POST", route, body())).statusCode, 201);
  assert.equal(f.mail.length, 1);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM support_notifications WHERE delivery='failed'").n, 1);
  f.config.supportEmail = "contact@7agency.fr\r\nBcc: victim@example.test";
  assert.equal((await f.req(a, "POST", route, body())).statusCode, 201);
  assert.equal(f.mail.length, 1);
});

test("game support, status audit and SMTP outcomes survive SQLite reopen and client retry", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "playmelt-game-support-"));
  let first, second;
  try {
    const path = join(dir, "support.sqlite");
    first = await fixture(t, { path });
    const a = first.paired(first.user("a@example.test")), owner = first.user("admin@example.test"), payload = body();
    const ticket = (await first.req(a, "POST", route, payload)).json();
    await first.req(owner, "POST", admin(ticket.id, "status"), { status: "investigating" }, true);
    await first.close();
    second = await fixture(t, { path });
    assert.deepEqual((await second.req(a, "GET", route)).json(), { tickets: [{ clientId: payload.clientId, id: ticket.id, status: "investigating" }] });
    const retry = await second.req(a, "POST", route, payload);
    assert.equal(retry.statusCode, 200);
    assert.equal(retry.json().id, ticket.id);
    assert.equal(second.mail.length, 0);
    const saved = (await second.req(owner, "GET", "/v1/admin/support", undefined, true)).json()[0];
    assert.equal(saved.game.audit.length, 1);
    assert.equal(saved.game.notification.delivery, "smtp_accepted");
    assert.equal(saved.game.notificationAttempts[0].delivery, "smtp_accepted");
  } finally {
    await first?.close();
    await second?.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a pending notification after process interruption is recovered only by staff without a new ticket", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "playmelt-support-recovery-"));
  let first, second;
  try {
    const path = join(dir, "support.sqlite");
    first = await fixture(t, { path, sendMail: async () => { throw Error("SMTP unavailable"); } });
    const a = first.paired(first.user("a@example.test")), owner = first.user("admin@example.test"), payload = body();
    const ticket = (await first.req(a, "POST", route, payload)).json();
    // Simulate interruption while SMTP was in flight, not a proven failure.
    first.store.run("UPDATE support_notifications SET delivery='sending',updated=? WHERE ticket_id=?", first.store.now() - 121, ticket.id);
    first.store.run("UPDATE support_notification_attempts SET delivery='sending',updated=? WHERE ticket_id=?", first.store.now() - 121, ticket.id);
    await first.close();
    second = await fixture(t, { path });
    assert.equal((await second.req(a, "POST", route, payload)).statusCode, 200);
    assert.equal(second.mail.length, 0);
    const retried = await second.req(owner, "POST", admin(ticket.id, "notification/retry"), {}, true);
    assert.equal(retried.json().delivery, "smtp_accepted");
    assert.equal(retried.json().attempts, 2);
    assert.equal(second.mail.length, 1);
    assert.equal(second.store.get("SELECT COUNT(*) AS n FROM support_tickets").n, 1);
    assert.deepEqual(second.store.all("SELECT delivery FROM support_notification_attempts ORDER BY attempt").map((r) => r.delivery), ["unconfirmed", "smtp_accepted"]);
    await second.req(owner, "POST", admin(ticket.id, "notification/retry"), {}, true);
    assert.equal(second.mail.length, 1);
  } finally {
    await first?.close();
    await second?.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
