import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";

const DAY = 86400;
const dayOf = (seconds) => new Date(seconds * 1000).toISOString().slice(0, 10);
const sources = [
  "github.com",
  "google.com",
  "bing.com",
  "linkedin.com",
  "instagram.com",
  "youtube.com",
  "steamcommunity.com",
  "reddit.com",
];
function sourceOf(value) {
  if (!value) return "direct";
  if (
    typeof value !== "string" ||
    value.length > 253 ||
    !/^[a-z0-9.-]+$/i.test(value)
  )
    return "other";
  const host = value.toLowerCase();
  return (
    sources.find((domain) => host === domain || host.endsWith("." + domain)) ||
    "other"
  );
}
export function browserAdmin(auth, config, fail) {
  return (req, reply) => {
    const user = auth(req, reply);
    if (!user) return null;
    if (
      user.device_id ||
      req.headers.authorization ||
      !req.cookies.pm_session ||
      !(config.adminEmails || []).includes(user.email)
    ) {
      fail(reply, 403, "staff_required");
      return null;
    }
    return user;
  };
}

function accountQuery(query = {}) {
  const page = Number(query.page ?? 1), pageSize = Number(query.pageSize ?? 50);
  const q = query.q ?? "", scope = query.scope ?? "all", access = query.access ?? "all", method = query.method ?? "all";
  if (!Number.isSafeInteger(page) || page < 1 || page > 100000 || ![25, 50, 100].includes(pageSize) ||
    typeof q !== "string" || q.length > 160 || /[\x00-\x1f\x7f]/.test(q) ||
    !["all", "customers", "internal"].includes(scope) ||
    !["all", "active", "trialing", "lifetime", "promotional", "none"].includes(access) ||
    !["all", "password", "google", "email_link"].includes(method)) return null;
  return { page, pageSize, q: q.trim(), scope, access, method };
}
const like = (value) => "%" + value.replace(/[\\%_]/g, "\\$&") + "%";
const activeJoin = `LEFT JOIN entitlements e ON e.id=(SELECT a.id FROM entitlements a
  LEFT JOIN blocked_payments b ON b.payment_intent=a.payment_intent
  WHERE a.user_id=u.id AND a.status IN ('active','trialing') AND (a.until IS NULL OR a.until>?)
  AND b.payment_intent IS NULL ORDER BY a.until IS NULL DESC,a.until DESC,a.id LIMIT 1)`;
const methods = (u) => ({ password: !!u.has_password, google: !!u.has_google, emailLinkObserved: !!u.has_email_link });
const accessOf = (u) => u.entitlement_id ? {
  plan: u.plan, phase: u.phase, until: u.until, owner: u.entitlement_id.startsWith("owner_"),
} : null;

/** Only bounded SQL pages leave the service; secrets and payment customer IDs never do. */
export function accounts(store, filters) {
  const where = [], values = [store.now()];
  if (filters.q) { where.push("(u.email LIKE ? ESCAPE '\\' OR u.id=?)"); values.push(like(filters.q), filters.q); }
  if (filters.scope !== "all") { where.push("u.is_internal=?"); values.push(filters.scope === "internal" ? 1 : 0); }
  if (filters.access === "none") where.push("e.id IS NULL");
  if (filters.access === "active") where.push("e.status='active'");
  if (filters.access === "trialing") where.push("e.status='trialing'");
  if (filters.access === "lifetime") where.push("e.plan='lifetime'");
  if (filters.access === "promotional") where.push("e.plan='promotional'");
  if (filters.method === "password") where.push("EXISTS(SELECT 1 FROM password_credentials p WHERE p.user_id=u.id)");
  if (filters.method === "google") where.push("EXISTS(SELECT 1 FROM oauth_identities o WHERE o.user_id=u.id AND o.provider='google')");
  if (filters.method === "email_link") where.push("EXISTS(SELECT 1 FROM magic_links m WHERE m.email=u.email AND m.confirmed IS NOT NULL)");
  const from = " FROM users u " + activeJoin + (where.length ? " WHERE " + where.join(" AND ") : "");
  const total = store.get("SELECT COUNT(*) AS n" + from, ...values).n;
  const rows = store.all(`SELECT u.id,u.email,u.created,u.is_internal,a.last_login,a.last_pair,
    e.id AS entitlement_id,e.plan,e.status AS phase,e.until,
    (SELECT COUNT(*) FROM devices d WHERE d.user_id=u.id AND d.revoked=0) AS devices,
    EXISTS(SELECT 1 FROM password_credentials p WHERE p.user_id=u.id) AS has_password,
    EXISTS(SELECT 1 FROM oauth_identities o WHERE o.user_id=u.id AND o.provider='google') AS has_google,
    EXISTS(SELECT 1 FROM magic_links m WHERE m.email=u.email AND m.confirmed IS NOT NULL) AS has_email_link
    FROM users u ${activeJoin} LEFT JOIN user_activity a ON a.user_id=u.id
    ${where.length ? "WHERE " + where.join(" AND ") : ""}
    ORDER BY u.created DESC,u.id LIMIT ? OFFSET ?`, ...values, filters.pageSize, (filters.page - 1) * filters.pageSize);
  return { items: rows.map((u) => ({ id: u.id, email: u.email, created: u.created,
    isInternal: u.is_internal === 1, last_login: u.last_login, last_pair: u.last_pair,
    devices: u.devices, registration: "account_created", methods: methods(u), access: accessOf(u) })),
    total, page: filters.page, pageSize: filters.pageSize, filters,
    provenance: "Stored accounts and observed authentication methods; no historical registration source is inferred" };
}

export function accountDetail(store, id) {
  const u = store.get(`SELECT u.id,u.email,u.created,u.is_internal,u.stripe_customer IS NOT NULL AS billing_linked,
    a.last_login,a.last_pair,e.id AS entitlement_id,e.plan,e.status AS phase,e.until,
    EXISTS(SELECT 1 FROM password_credentials p WHERE p.user_id=u.id) AS has_password,
    EXISTS(SELECT 1 FROM oauth_identities o WHERE o.user_id=u.id AND o.provider='google') AS has_google,
    EXISTS(SELECT 1 FROM magic_links m WHERE m.email=u.email AND m.confirmed IS NOT NULL) AS has_email_link
    FROM users u ${activeJoin} LEFT JOIN user_activity a ON a.user_id=u.id WHERE u.id=?`, store.now(), id);
  if (!u) return null;
  const list = (table, order, fields, limit) => ({
    total: store.get(`SELECT COUNT(*) AS n FROM ${table} WHERE user_id=?`, id).n,
    items: store.all(`SELECT ${fields} FROM ${table} WHERE user_id=? ORDER BY ${order} LIMIT ?`, id, limit),
  });
  const codes = store.all("SELECT created,expires,used FROM owner_codes WHERE email=? ORDER BY created DESC LIMIT 20", u.email)
    .map((c) => ({ created: c.created, expires: c.expires, used: c.used, state: c.used ? "redeemed" : c.expires > store.now() ? "available" : "expired" }));
  return { asOf: store.now(), id: u.id, email: u.email, created: u.created, isInternal: u.is_internal === 1,
    registration: "account_created", methods: methods(u), billingLinked: !!u.billing_linked,
    lastLogin: u.last_login, lastPair: u.last_pair, access: accessOf(u),
    entitlements: { total: store.get("SELECT COUNT(*) AS n FROM entitlements WHERE user_id=?", id).n,
      items: store.all(`SELECT e.plan,e.status,e.until,e.updated,b.reason AS blockedReason,
        CASE WHEN e.plan='promotional' AND e.id LIKE 'promo_%' THEN e.id ELSE NULL END AS promotionId
        FROM entitlements e LEFT JOIN blocked_payments b ON b.payment_intent=e.payment_intent
        WHERE e.user_id=? ORDER BY e.updated DESC,e.id LIMIT 20`, id) },
    devices: list("devices", "created DESC,id", "id,label,created,revoked", 20),
    support: list("support_tickets", "created DESC,id", "id,category,status,created", 10),
    payments: list("payment_reserves", "received DESC,id", "amount AS amountCents,currency,received,reserved_until AS reservedUntil", 10),
    ownerCodes: { total: store.get("SELECT COUNT(*) AS n FROM owner_codes WHERE email=?", u.email).n, items: codes },
    trial: store.get("SELECT started,until FROM trials WHERE user_id=?", id) || null,
    downloadRequests: store.get("SELECT COUNT(*) AS total,MAX(created) AS lastRequested FROM download_links WHERE user_id=?", id),
    promotionAudit: { total: store.get("SELECT COUNT(*) AS n FROM admin_access_audit WHERE user_id=?", id).n,
      items: store.all(`SELECT a.action,a.duration_days AS days,a.until,a.reason,a.created,u.email AS actor
        FROM admin_access_audit a JOIN users u ON u.id=a.actor_id WHERE a.user_id=? ORDER BY a.created DESC,a.id LIMIT 30`, id) },
    revocablePromotions: store.all(`SELECT e.id AS promotionId,e.until FROM entitlements e WHERE e.user_id=? AND e.plan='promotional' AND e.status='active'
      AND EXISTS(SELECT 1 FROM admin_access_audit a WHERE a.entitlement_id=e.id AND a.user_id=e.user_id AND a.action='grant') ORDER BY e.updated DESC,e.id LIMIT 20`, id),
    lifetimeAccess: lifetimeAccessDetail(store, u),
    provenance: "Account creation is stored; historical email verification time, registration source and billing cancellation schedule are not stored. Owner codes are lifetime grants, never promotional discounts. No code, token or credential is exposed." };
}

function promotionBody(body, grant) {
  const keys = grant ? ["days", "reason", "requestId", "confirmed"] : ["reason", "requestId", "confirmed"];
  if (!body || typeof body !== "object" || Array.isArray(body) || Object.keys(body).some((k) => !keys.includes(k)) ||
    keys.some((k) => !(k in body)) || body.confirmed !== true || typeof body.reason !== "string" ||
    body.reason.trim().length < 3 || body.reason.trim().length > 300 || /[\x00-\x1f\x7f]/.test(body.reason) ||
    typeof body.requestId !== "string" || !/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(body.requestId) ||
    (grant && ![7, 30, 90].includes(body.days))) return null;
  return { ...body, reason: body.reason.trim(), requestId: body.requestId.toLowerCase() };
}
const promotionError = (error, status = 409) => ({ error, status });
const promotionResult = (e, replayed = false) => ({ id: e.id, plan: e.plan, phase: e.status, until: e.until, replayed });
export function grantPromotion(store, actor, userID, body) {
  return store.transaction(() => {
    if (store.get("SELECT 1 FROM admin_lifetime_access_audit WHERE request_id=?", body.requestId)) return promotionError("idempotency_conflict");
    const previous = store.get("SELECT * FROM admin_access_audit WHERE request_id=?", body.requestId);
    if (previous) {
      if (previous.action !== "grant" || previous.actor_id !== actor.id || previous.user_id !== userID || previous.duration_days !== body.days || previous.reason !== body.reason)
        return promotionError("idempotency_conflict");
      return promotionResult(store.get("SELECT * FROM entitlements WHERE id=?", previous.entitlement_id), true);
    }
    const user = store.get("SELECT id,is_internal FROM users WHERE id=?", userID);
    if (!user) return promotionError("account_not_found", 404);
    if (user.is_internal) return promotionError("customer_required");
    if (store.entitlement(userID)) return promotionError("already_has_access");
    if (store.get(`SELECT EXISTS(SELECT 1 FROM entitlements e JOIN blocked_payments b ON b.payment_intent=e.payment_intent WHERE e.user_id=?)
      OR EXISTS(SELECT 1 FROM payment_reserves p JOIN blocked_payments b ON b.payment_intent=p.payment_intent WHERE p.user_id=?) AS blocked`, userID, userID).blocked)
      return promotionError("payment_review_required");
    const now = store.now(), until = now + body.days * DAY, id = "promo_" + randomUUID();
    store.run("INSERT INTO entitlements(id,user_id,plan,status,until,updated) VALUES(?,?,'promotional','active',?,?)", id, userID, until, now);
    store.run("INSERT INTO admin_access_audit(id,entitlement_id,user_id,actor_id,action,duration_days,until,reason,created,request_id) VALUES(?,?,?,?,'grant',?,?,?,?,?)",
      randomUUID(), id, userID, actor.id, body.days, until, body.reason, now, body.requestId);
    return promotionResult({ id, plan: "promotional", status: "active", until });
  });
}
export function revokePromotion(store, actor, userID, grantID, body) {
  return store.transaction(() => {
    if (store.get("SELECT 1 FROM admin_lifetime_access_audit WHERE request_id=?", body.requestId)) return promotionError("idempotency_conflict");
    const previous = store.get("SELECT * FROM admin_access_audit WHERE request_id=?", body.requestId);
    if (previous) {
      if (previous.action !== "revoke" || previous.actor_id !== actor.id || previous.user_id !== userID || previous.entitlement_id !== grantID || previous.reason !== body.reason)
        return promotionError("idempotency_conflict");
      return promotionResult(store.get("SELECT * FROM entitlements WHERE id=?", grantID), true);
    }
    const e = store.get(`SELECT e.* FROM entitlements e WHERE e.id=? AND e.user_id=? AND e.plan='promotional'
      AND EXISTS(SELECT 1 FROM admin_access_audit a WHERE a.entitlement_id=e.id AND a.user_id=e.user_id AND a.action='grant')`, grantID, userID);
    if (!e || !grantID.startsWith("promo_")) return promotionError("promotion_not_found", 404);
    if (e.status !== "active") return promotionError("promotion_already_revoked");
    const now = store.now();
    store.run("UPDATE entitlements SET status='revoked',updated=? WHERE id=? AND user_id=? AND plan='promotional'", now, grantID, userID);
    store.run("INSERT INTO admin_access_audit(id,entitlement_id,user_id,actor_id,action,duration_days,until,reason,created,request_id) VALUES(?,?,?,?,'revoke',NULL,?,?,?,?)",
      randomUUID(), grantID, userID, actor.id, e.until, body.reason, now, body.requestId);
    return promotionResult({ ...e, status: "revoked" });
  });
}

const lifetimePrefix = "admin_lifetime_";
const lifetimeBillingNotice = "Cet accès à vie ne résilie ni ne modifie aucun abonnement ou paiement existant.";
function lifetimeBlock(store, user) {
  if (user.is_internal) return { code: "customer_required", message: "Les comptes internes ne sont pas des bénéficiaires clients." };
  if (store.get(`SELECT EXISTS(SELECT 1 FROM entitlements e JOIN blocked_payments b ON b.payment_intent=e.payment_intent WHERE e.user_id=?)
    OR EXISTS(SELECT 1 FROM payment_reserves p JOIN blocked_payments b ON b.payment_intent=p.payment_intent WHERE p.user_id=?) AS blocked`, user.id, user.id).blocked)
    return { code: "payment_review_required", message: "Un paiement signalé doit être examiné avant toute attribution." };
  if (store.get("SELECT 1 FROM entitlements WHERE user_id=? AND plan='lifetime' AND status IN ('active','trialing') AND (until IS NULL OR until>?) LIMIT 1", user.id, store.now()))
    return { code: "already_has_lifetime", message: "Ce client dispose déjà d’un accès à vie actif." };
  return null;
}
function lifetimeAccessDetail(store, user) {
  const block = lifetimeBlock(store, user);
  return { available: true, canGrant: !block, ...(block ? { blockedReason: block.message } : {}),
    billingUnaffected: true, billingNotice: lifetimeBillingNotice,
    revocableGrants: store.all(`SELECT e.id,a.created FROM entitlements e JOIN admin_lifetime_access_audit a
      ON a.entitlement_id=e.id AND a.user_id=e.user_id AND a.action='grant'
      WHERE e.user_id=? AND e.plan='lifetime' AND e.until IS NULL AND e.status='active' AND e.invoice IS NULL AND e.payment_intent IS NULL AND e.id GLOB 'admin_lifetime_*'
      ORDER BY a.created DESC,e.id LIMIT 20`, user.id),
    audit: { total: store.get("SELECT COUNT(*) AS n FROM admin_lifetime_access_audit WHERE user_id=?", user.id).n,
      items: store.all(`SELECT a.action,a.reason,a.created,u.email AS actor FROM admin_lifetime_access_audit a
        JOIN users u ON u.id=a.actor_id WHERE a.user_id=? ORDER BY a.created DESC,a.id LIMIT 30`, user.id) } };
}
const lifetimeResult = (e, replayed = false) => ({ ...promotionResult(e, replayed), billingUnaffected: true, billingNotice: lifetimeBillingNotice });
export function grantLifetimeAccess(store, actor, userID, body) {
  return store.transaction(() => {
    if (store.get("SELECT 1 FROM admin_access_audit WHERE request_id=?", body.requestId)) return promotionError("idempotency_conflict");
    const previous = store.get("SELECT * FROM admin_lifetime_access_audit WHERE request_id=?", body.requestId);
    if (previous) {
      if (previous.action !== "grant" || previous.actor_id !== actor.id || previous.user_id !== userID || previous.reason !== body.reason)
        return promotionError("idempotency_conflict");
      return lifetimeResult(store.get("SELECT * FROM entitlements WHERE id=?", previous.entitlement_id), true);
    }
    const user = store.get("SELECT id,is_internal FROM users WHERE id=?", userID);
    if (!user) return promotionError("account_not_found", 404);
    const block = lifetimeBlock(store, user);
    if (block) return promotionError(block.code);
    const now = store.now(), id = lifetimePrefix + randomUUID();
    store.run("INSERT INTO entitlements(id,user_id,plan,status,until,updated) VALUES(?,?,'lifetime','active',NULL,?)", id, userID, now);
    store.run("INSERT INTO admin_lifetime_access_audit VALUES(?,?,?,?,'grant',?,?,?)",
      randomUUID(), id, userID, actor.id, body.reason, now, body.requestId);
    return lifetimeResult({ id, plan: "lifetime", status: "active", until: null });
  });
}
export function revokeLifetimeAccess(store, actor, userID, grantID, body) {
  return store.transaction(() => {
    if (store.get("SELECT 1 FROM admin_access_audit WHERE request_id=?", body.requestId)) return promotionError("idempotency_conflict");
    const previous = store.get("SELECT * FROM admin_lifetime_access_audit WHERE request_id=?", body.requestId);
    if (previous) {
      if (previous.action !== "revoke" || previous.actor_id !== actor.id || previous.user_id !== userID || previous.entitlement_id !== grantID || previous.reason !== body.reason)
        return promotionError("idempotency_conflict");
      return lifetimeResult(store.get("SELECT * FROM entitlements WHERE id=?", grantID), true);
    }
    const e = store.get(`SELECT e.* FROM entitlements e WHERE e.id=? AND e.user_id=? AND e.plan='lifetime' AND e.until IS NULL AND e.invoice IS NULL AND e.payment_intent IS NULL
      AND EXISTS(SELECT 1 FROM admin_lifetime_access_audit a WHERE a.entitlement_id=e.id AND a.user_id=e.user_id AND a.action='grant')`, grantID, userID);
    if (!e || !grantID.startsWith(lifetimePrefix)) return promotionError("lifetime_grant_not_found", 404);
    if (e.status !== "active") return promotionError("lifetime_already_revoked");
    const now = store.now();
    store.run("UPDATE entitlements SET status='revoked',updated=? WHERE id=? AND user_id=? AND plan='lifetime' AND until IS NULL", now, grantID, userID);
    store.run("INSERT INTO admin_lifetime_access_audit VALUES(?,?,?,?,'revoke',?,?,?)",
      randomUUID(), grantID, userID, actor.id, body.reason, now, body.requestId);
    return lifetimeResult({ ...e, status: "revoked" });
  });
}

export function registrations(store, filters) {
  const values = [store.now()], extra = filters.q ? " AND m.email LIKE ? ESCAPE '\\'" : "";
  if (filters.q) values.push(like(filters.q));
  const from = `FROM magic_links m WHERE m.used=0 AND m.expires>? AND NOT EXISTS(SELECT 1 FROM users u WHERE u.email=m.email)${extra}`;
  return { total: store.get("SELECT COUNT(DISTINCT m.email) AS n " + from, ...values).n,
    page: filters.page, pageSize: filters.pageSize,
    items: store.all(`SELECT m.email,MAX(m.expires) AS expires,COUNT(*) AS pendingLinks,
      MAX(EXISTS(SELECT 1 FROM password_registrations p WHERE p.magic_hash=m.hash AND p.password_hash<>'')) AS passwordRequested
      ${from} GROUP BY m.email ORDER BY expires DESC,m.email LIMIT ? OFFSET ?`, ...values, filters.pageSize, (filters.page - 1) * filters.pageSize)
      .map((r) => ({ ...r, passwordRequested: !!r.passwordRequested })),
    provenance: "Unconsumed and unexpired verification links for emails without a stored account; delivery and human receipt are not confirmed. Expired requests are not counted." };
}
export function overview(store, days) {
  const now = store.now(),
    today = Math.floor(now / DAY) * DAY,
    since = today - (days - 1) * DAY;
  const started = Number(
    store.get("SELECT value FROM service_state WHERE key='collection_started'")
      .value,
  );
  const customerStartRow = store.get(
    "SELECT value FROM service_state WHERE key='customer_metrics_started'",
  );
  const candidate = customerStartRow && /^\d+$/.test(customerStartRow.value)
    ? Number(customerStartRow.value)
    : NaN;
  const customerStarted =
    Number.isSafeInteger(candidate) && candidate >= 0 && candidate <= now
      ? candidate
      : null;
  const daily = store.all(
    "SELECT * FROM activity_daily WHERE day>=? AND day<=? ORDER BY day",
    dayOf(since),
    dayOf(now),
  );
  const paymentFrom = " FROM payment_reserves r JOIN users u ON u.id=r.user_id LEFT JOIN blocked_payments b ON b.payment_intent=r.payment_intent WHERE u.is_internal=0 AND r.received>=? AND r.received<=?";
  const paymentTotals = store.get("SELECT COALESCE(SUM(r.amount),0) AS amount,COUNT(b.payment_intent) AS flagged" + paymentFrom, since, now);
  const receiptsByDay = new Map(store.all("SELECT date(r.received,'unixepoch') AS day,SUM(r.amount) AS amount" + paymentFrom + " GROUP BY day", since, now).map((r) => [r.day, r.amount]));
  const payments = store.all(
    "SELECT r.*,u.email,b.reason AS blocked_reason" + paymentFrom + " ORDER BY r.received DESC,r.id LIMIT 100",
    since,
    now,
  );
  // Account records retain attribution; old anonymous activity counters do not.
  const accountsByDay = new Map(
    store.all(
      "SELECT date(created,'unixepoch') AS day,COUNT(*) AS count FROM users WHERE is_internal=0 AND created>=? AND created<=? GROUP BY day",
      since,
      now,
    ).map((row) => [row.day, row.count]),
  );
  const series = Array.from({ length: days }, (_, i) => {
    const date = dayOf(since + i * DAY),
      covered = date >= dayOf(started),
      customerCovered = customerStarted !== null && date >= dayOf(customerStarted);
    const at = (kind, hasCoverage = covered) =>
      hasCoverage
        ? daily
            .filter((row) => row.day === date && row.kind === kind)
            .reduce((n, row) => n + row.count, 0)
        : null;
    return {
      date,
      pageViews: at("page_view"),
      downloads: at("customer_download", customerCovered),
      logins: at("customer_login", customerCovered),
      accounts: accountsByDay.get(date) || 0,
      receiptsCents: covered
        ? receiptsByDay.get(date) || 0
        : null,
    };
  });
  const totalKind = (kind) =>
    daily
      .filter((row) => row.kind === kind)
      .reduce((n, row) => n + row.count, 0);
  const customerTotal = (kind) =>
    customerStarted === null
      ? null
      : daily
          .filter((row) => row.kind === kind && row.day >= dayOf(customerStarted))
          .reduce((n, row) => n + row.count, 0);
  const counts = store.get("SELECT COUNT(*) AS accounts FROM users WHERE is_internal=0");
  const active = store.get(
    "SELECT COUNT(DISTINCT e.user_id) AS n FROM entitlements e JOIN users u ON u.id=e.user_id LEFT JOIN blocked_payments b ON b.payment_intent=e.payment_intent WHERE u.is_internal=0 AND e.status IN ('active','trialing') AND (e.until IS NULL OR e.until>?) AND b.payment_intent IS NULL",
    now,
  ).n;
  const trials = store.get(
    "SELECT COUNT(DISTINCT e.user_id) AS n FROM entitlements e JOIN users u ON u.id=e.user_id WHERE u.is_internal=0 AND e.status='trialing' AND e.until>? AND NOT EXISTS(SELECT 1 FROM entitlements a WHERE a.user_id=e.user_id AND a.status='active' AND (a.until IS NULL OR a.until>?))",
    now,
    now,
  ).n;
  const pendingReserve = store.get(
    "SELECT COALESCE(SUM(r.amount),0) AS amount FROM payment_reserves r JOIN users u ON u.id=r.user_id LEFT JOIN blocked_payments b ON b.payment_intent=r.payment_intent WHERE u.is_internal=0 AND r.reserved_until>? AND b.payment_intent IS NULL",
    now,
  ).amount;
  const visitors = new Map();
  for (const row of daily.filter((r) => r.kind === "page_view"))
    visitors.set(row.source, (visitors.get(row.source) || 0) + row.count);
  return {
    asOf: now,
    collectionStarted: started,
    customerMetricsStarted: customerStarted,
    period: { days, since, until: now, timezone: "UTC" },
    totals: {
      accounts: counts.accounts,
      activeLicences: active,
      activeTrials: trials,
      newAccounts: [...accountsByDay.values()].reduce((n, count) => n + count, 0),
      logins: customerTotal("customer_login"),
      pageViews: totalKind("page_view"),
      siteDownloadRequests: customerTotal("customer_download"),
      receiptsCents: paymentTotals.amount,
      pendingReserveCents: pendingReserve,
      flaggedPayments: paymentTotals.flagged,
      openSupport: store.get(
        "SELECT COUNT(*) AS n FROM support_tickets t JOIN users u ON u.id=t.user_id WHERE u.is_internal=0 AND t.status IN ('open','received','investigating','fixed')",
      ).n,
    },
    series,
    sources: [...visitors]
      .map(([source, count]) => ({ source, count }))
      .sort((a, b) => b.count - a.count),
    payments: payments.map((p) => ({
      id: p.id,
      email: p.email,
      amountCents: p.amount,
      currency: p.currency,
      received: p.received,
      reservedUntil: p.reserved_until,
      flagged: !!p.blocked_reason,
    })),
    provenance: {
      visits:
        "Anonymous first-party aggregates; internal visits cannot be identified or removed retrospectively",
      downloads:
        "customer_download only since customerMetricsStarted; internal accounts excluded at collection; requests, not completed downloads or installations",
      logins:
        "customer_login only since customerMetricsStarted; anonymous legacy login counters are not included",
      accounts:
        "Current non-internal account records and their creation timestamps; never the legacy mixed account_created counter",
      receipts:
        "Stripe-verified non-internal account receipts, gross EUR amounts; internal reserve does not delay Stripe payouts",
      github:
        "Public GitHub totals include all downloaders; internal downloads cannot be identified or removed retrospectively",
      history:
        "Customer login/download history is unknown before customerMetricsStarted, including part of its first day; null values remain gaps. Legacy anonymous counters remain stored without claiming they have been cleaned",
    },
  };
}

/** Fixed public repository only. No customer data or credentials leave this service. */
export async function readGitHubDownloads(store, fetcher = fetch) {
  const previous = store.get(
    "SELECT * FROM github_download_snapshots ORDER BY observed DESC LIMIT 1",
  );
  const saved = previous ? JSON.parse(previous.assets) : null;
  const previousAssets = Array.isArray(saved) ? saved : saved?.items || [];
  const previousTruncated = !!saved?.truncated;
  if (previous && store.now() - previous.observed < 300)
    return {
      available: true,
      cached: true,
      ...previous,
      assets: previousAssets,
      truncated: previousTruncated,
      history: store.all(
        "SELECT day,total,observed FROM github_download_snapshots ORDER BY day",
      ),
    };
  try {
    const assets = [];
    let more = false;
    for (let page = 1; page <= 3; page++) {
      const response = await fetcher(
        "https://api.github.com/repos/nathanvendrell-cpu/playmelt/releases?per_page=100&page=" +
          page,
        {
          headers: {
            Accept: "application/vnd.github+json",
            "User-Agent": "Playmelt-Admin",
            "X-GitHub-Api-Version": "2022-11-28",
          },
          signal: AbortSignal.timeout(8000),
          redirect: "error",
        },
      );
      if (!response.ok) throw Error("GitHub unavailable");
      const text = await response.text();
      if (text.length > 2 * 1024 * 1024)
        throw Error("GitHub response too large");
      const releases = JSON.parse(text);
      if (!Array.isArray(releases)) throw Error("Invalid releases");
      for (const release of releases.filter((r) => !r.draft))
        for (const asset of release.assets || []) {
          if (
            !/\.dmg$/i.test(asset.name || "") ||
            !Number.isSafeInteger(asset.download_count) ||
            asset.download_count < 0
          )
            continue;
          assets.push({
            id: asset.id,
            name: String(asset.name).slice(0, 160),
            version: String(release.tag_name).slice(0, 60),
            downloads: asset.download_count,
          });
        }
      more = /rel="next"/.test(response.headers.get("link") || "");
      if (!more) break;
    }
    const total = assets.reduce((n, a) => n + a.downloads, 0),
      observed = store.now(),
      day = dayOf(observed);
    store.run(
      "INSERT INTO github_download_snapshots VALUES(?,?,?,?) ON CONFLICT(day) DO UPDATE SET observed=excluded.observed,total=excluded.total,assets=excluded.assets",
      day,
      observed,
      total,
      JSON.stringify({ items: assets, truncated: more }),
    );
    return {
      available: true,
      observed,
      total,
      assets,
      truncated: more,
      history: store.all(
        "SELECT day,total,observed FROM github_download_snapshots ORDER BY day",
      ),
    };
  } catch {
    return previous
      ? {
          available: true,
          stale: true,
          observed: previous.observed,
          total: previous.total,
          assets: previousAssets,
          truncated: previousTruncated,
          history: store.all(
            "SELECT day,total,observed FROM github_download_snapshots ORDER BY day",
          ),
        }
      : {
          available: false,
          error: "github_unavailable",
          total: null,
          assets: [],
          history: [],
        };
  }
}

export function registerAdmin(
  api,
  { store, config, auth, fail, base, prefix },
) {
  const staff = browserAdmin(auth, config, fail);
  api.post(
    "/v1/metrics/pageview",
    { config: { rateLimit: { max: 30, timeWindow: 60000 } } },
    async (req, reply) => {
      if (req.headers.origin !== base.origin)
        return fail(reply, 403, "origin_mismatch");
      if (!["site", "account"].includes(req.body?.page))
        return fail(reply, 400, "invalid_page");
      if (/bot|crawler|spider|headless/i.test(req.headers["user-agent"] || ""))
        return reply.code(204).send();
      if (store.authenticate(req.cookies.pm_session)?.is_internal)
        return reply.code(204).send();
      store.activity(
        "page_view",
        req.body.page + "." + sourceOf(req.body.referrer),
      );
      return reply.code(204).send();
    },
  );
  api.get("/v1/admin/overview", async (req, reply) => {
    if (!staff(req, reply)) return;
    const days = Number(req.query?.days || 30);
    if (![7, 30, 90].includes(days)) return fail(reply, 400, "invalid_period");
    return overview(store, days);
  });
  api.get("/v1/admin/accounts", async (req, reply) => {
    if (!staff(req, reply)) return;
    const filters = accountQuery(req.query);
    if (!filters) return fail(reply, 400, "invalid_filters");
    return accounts(store, filters);
  });
  api.get("/v1/admin/accounts/:id", async (req, reply) => {
    if (!staff(req, reply)) return;
    if (!/^[A-Za-z0-9_-]{1,100}$/.test(req.params.id)) return fail(reply, 400, "invalid_account");
    return accountDetail(store, req.params.id) || fail(reply, 404, "account_not_found");
  });
  api.get("/v1/admin/registrations", async (req, reply) => {
    if (!staff(req, reply)) return;
    const filters = accountQuery(req.query);
    if (!filters) return fail(reply, 400, "invalid_filters");
    return registrations(store, filters);
  });
  const mutationLimit = { config: { rateLimit: { max: 20, timeWindow: 60000 } } };
  api.post("/v1/admin/accounts/:id/promotions", mutationLimit, async (req, reply) => {
    const actor = staff(req, reply);
    if (!actor) return;
    const body = promotionBody(req.body, true);
    if (!body || !/^[A-Za-z0-9_-]{1,100}$/.test(req.params.id)) return fail(reply, 400, "invalid_promotion");
    const result = grantPromotion(store, actor, req.params.id, body);
    return result.error ? fail(reply, result.status, result.error) : reply.code(result.replayed ? 200 : 201).send(result);
  });
  api.post("/v1/admin/accounts/:id/promotions/:promotionId/revoke", mutationLimit, async (req, reply) => {
    const actor = staff(req, reply);
    if (!actor) return;
    const body = promotionBody(req.body, false);
    if (!body || !/^[A-Za-z0-9_-]{1,100}$/.test(req.params.id) || !/^promo_[a-f0-9-]{36}$/i.test(req.params.promotionId)) return fail(reply, 400, "invalid_promotion");
    const result = revokePromotion(store, actor, req.params.id, req.params.promotionId, body);
    return result.error ? fail(reply, result.status, result.error) : result;
  });
  api.post("/v1/admin/accounts/:id/lifetime", mutationLimit, async (req, reply) => {
    const actor = staff(req, reply);
    if (!actor) return;
    const body = promotionBody(req.body, false);
    if (!body || !/^[A-Za-z0-9_-]{1,100}$/.test(req.params.id)) return fail(reply, 400, "invalid_lifetime_access");
    const result = grantLifetimeAccess(store, actor, req.params.id, body);
    return result.error ? fail(reply, result.status, result.error) : reply.code(result.replayed ? 200 : 201).send(result);
  });
  api.post("/v1/admin/accounts/:id/lifetime/:grantId/revoke", mutationLimit, async (req, reply) => {
    const actor = staff(req, reply);
    if (!actor) return;
    const body = promotionBody(req.body, false);
    if (!body || !/^[A-Za-z0-9_-]{1,100}$/.test(req.params.id) || !/^admin_lifetime_[a-f0-9-]{36}$/i.test(req.params.grantId)) return fail(reply, 400, "invalid_lifetime_access");
    const result = revokeLifetimeAccess(store, actor, req.params.id, req.params.grantId, body);
    return result.error ? fail(reply, result.status, result.error) : result;
  });
  api.get("/v1/admin/github", async (req, reply) => {
    if (!staff(req, reply)) return;
    return readGitHubDownloads(store, config.githubFetch);
  });
  api.get("/admin", async (req, reply) => {
    const user = store.authenticate(req.cookies.pm_session);
    if (!user)
      return reply
        .code(303)
        .header("Location", prefix + "/")
        .send();
    if (
      user.device_id ||
      req.headers.authorization ||
      !(config.adminEmails || []).includes(user.email)
    )
      return fail(reply, 403, "staff_required");
    return reply
      .type("text/html")
      .send(
        readFileSync(
          new URL("../public/admin.html", import.meta.url),
          "utf8",
        ).replaceAll("%%BASE%%", prefix),
      );
  });
  for (const [file, mime] of [
    ["admin.js", "text/javascript"],
    ["admin.css", "text/css"],
    ["metrics.js", "text/javascript"],
  ])
    api.get("/" + file, async (req, reply) =>
      reply
        .type(mime)
        .send(readFileSync(new URL("../public/" + file, import.meta.url))),
    );
}
