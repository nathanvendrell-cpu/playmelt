import { DatabaseSync } from "node:sqlite";
import { createHash, randomBytes, randomUUID } from "node:crypto";
export const digest = (x) => createHash("sha256").update(x).digest("hex");
export const token = () => randomBytes(32).toString("base64url");
export class Store {
  constructor(path, now = () => Math.floor(Date.now() / 1000)) {
    this.now = now;
    this.db = new DatabaseSync(path);
    this.db
      .exec(`PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY,email TEXT NOT NULL UNIQUE,stripe_customer TEXT UNIQUE,created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS magic_links(hash TEXT PRIMARY KEY,email TEXT NOT NULL,expires INTEGER NOT NULL,used INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS sessions(hash TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),device_id TEXT,expires INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),label TEXT NOT NULL,revoked INTEGER NOT NULL DEFAULT 0,created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS device_requests(hash TEXT PRIMARY KEY,code TEXT UNIQUE NOT NULL,challenge TEXT NOT NULL,label TEXT NOT NULL,user_id TEXT REFERENCES users(id),expires INTEGER NOT NULL,used INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS entitlements(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),plan TEXT NOT NULL,status TEXT NOT NULL,until INTEGER,invoice TEXT,payment_intent TEXT,updated INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS admin_access_audit(id TEXT PRIMARY KEY,entitlement_id TEXT NOT NULL REFERENCES entitlements(id),user_id TEXT NOT NULL REFERENCES users(id),actor_id TEXT NOT NULL REFERENCES users(id),action TEXT NOT NULL CHECK(action IN ('grant','revoke')),duration_days INTEGER,until INTEGER NOT NULL,reason TEXT NOT NULL,created INTEGER NOT NULL,request_id TEXT NOT NULL UNIQUE);
      CREATE TABLE IF NOT EXISTS admin_lifetime_access_audit(id TEXT PRIMARY KEY,entitlement_id TEXT NOT NULL REFERENCES entitlements(id),user_id TEXT NOT NULL REFERENCES users(id),actor_id TEXT NOT NULL REFERENCES users(id),action TEXT NOT NULL CHECK(action IN ('grant','revoke')),reason TEXT NOT NULL,created INTEGER NOT NULL,request_id TEXT NOT NULL UNIQUE);
      CREATE TABLE IF NOT EXISTS trials(user_id TEXT PRIMARY KEY REFERENCES users(id),subscription_id TEXT NOT NULL,started INTEGER NOT NULL,until INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS billing_events(id TEXT PRIMARY KEY,status TEXT NOT NULL,updated INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS blocked_payments(payment_intent TEXT PRIMARY KEY,reason TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS checkout_requests(user_id TEXT PRIMARY KEY REFERENCES users(id),plan TEXT NOT NULL,checkout_id TEXT,url TEXT,expires INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS checkout_terms(request_id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),version TEXT NOT NULL,sha256 TEXT NOT NULL,accepted INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS support_tickets(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),category TEXT NOT NULL,message TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'open',created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS support_replies(id TEXT PRIMARY KEY,ticket_id TEXT NOT NULL REFERENCES support_tickets(id),body TEXT NOT NULL,created INTEGER NOT NULL,delivery TEXT NOT NULL DEFAULT 'pending');
      CREATE TABLE IF NOT EXISTS game_support(ticket_id TEXT PRIMARY KEY REFERENCES support_tickets(id),user_id TEXT NOT NULL REFERENCES users(id),client_id TEXT NOT NULL,game_id TEXT NOT NULL,game_title TEXT NOT NULL,store TEXT NOT NULL,client_created REAL NOT NULL,diagnostics TEXT NOT NULL,UNIQUE(user_id,client_id));
      CREATE TABLE IF NOT EXISTS support_status_audit(id TEXT PRIMARY KEY,ticket_id TEXT NOT NULL REFERENCES support_tickets(id),actor_id TEXT NOT NULL REFERENCES users(id),previous_status TEXT NOT NULL,status TEXT NOT NULL,created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS support_notifications(ticket_id TEXT PRIMARY KEY REFERENCES support_tickets(id),delivery TEXT NOT NULL DEFAULT 'pending',attempts INTEGER NOT NULL DEFAULT 0,updated INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS support_notification_attempts(id TEXT PRIMARY KEY,ticket_id TEXT NOT NULL REFERENCES support_tickets(id),attempt INTEGER NOT NULL,delivery TEXT NOT NULL,created INTEGER NOT NULL,updated INTEGER NOT NULL,UNIQUE(ticket_id,attempt));
      CREATE TABLE IF NOT EXISTS payment_reserves(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),payment_intent TEXT,amount INTEGER NOT NULL,currency TEXT NOT NULL,received INTEGER NOT NULL,reserved_until INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS service_state(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS activity_daily(day TEXT NOT NULL,kind TEXT NOT NULL,source TEXT NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(day,kind,source));
      CREATE TABLE IF NOT EXISTS user_activity(user_id TEXT PRIMARY KEY REFERENCES users(id),last_login INTEGER,last_pair INTEGER);
      CREATE TABLE IF NOT EXISTS owner_codes(hash TEXT PRIMARY KEY,email TEXT NOT NULL,expires INTEGER NOT NULL,created INTEGER NOT NULL,used_by TEXT REFERENCES users(id),used INTEGER);
      CREATE TABLE IF NOT EXISTS github_download_snapshots(day TEXT PRIMARY KEY,observed INTEGER NOT NULL,total INTEGER NOT NULL,assets TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS terms_documents(sha256 TEXT PRIMARY KEY,version TEXT NOT NULL,html TEXT NOT NULL,created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS checkout_contracts(checkout_id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),plan TEXT NOT NULL,terms_sha256 TEXT NOT NULL REFERENCES terms_documents(sha256),accepted INTEGER NOT NULL,confirmed INTEGER,summary TEXT,delivery TEXT NOT NULL DEFAULT 'pending',attempts INTEGER NOT NULL DEFAULT 0,updated INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS download_links(hash TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),artifact TEXT NOT NULL,source TEXT NOT NULL,created INTEGER NOT NULL,expires INTEGER NOT NULL,delivery TEXT NOT NULL DEFAULT 'pending',claimed INTEGER,transfer_hash TEXT UNIQUE,transfer_session TEXT,transfer_expires INTEGER,used INTEGER);
      CREATE INDEX IF NOT EXISTS download_links_user_created ON download_links(user_id,created);
      CREATE TABLE IF NOT EXISTS password_credentials(user_id TEXT PRIMARY KEY REFERENCES users(id),hash TEXT NOT NULL,updated INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS password_registrations(magic_hash TEXT PRIMARY KEY REFERENCES magic_links(hash),password_hash TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS password_resets(hash TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),expires INTEGER NOT NULL,used INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS login_throttles(identifier TEXT PRIMARY KEY,started INTEGER NOT NULL,failures INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS account_networks(user_id TEXT PRIMARY KEY REFERENCES users(id),ip_hash TEXT NOT NULL,masked TEXT NOT NULL,generation INTEGER NOT NULL CHECK(generation>0),updated INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS network_changes(user_id TEXT PRIMARY KEY REFERENCES users(id),hash TEXT NOT NULL UNIQUE,target_hash TEXT NOT NULL,target_masked TEXT NOT NULL,generation INTEGER NOT NULL,created INTEGER NOT NULL,expires INTEGER NOT NULL,used INTEGER NOT NULL DEFAULT 0,delivery TEXT NOT NULL DEFAULT 'pending');
      CREATE TABLE IF NOT EXISTS network_change_limits(user_id TEXT PRIMARY KEY REFERENCES users(id),window_started INTEGER NOT NULL,requests INTEGER NOT NULL,last_requested INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS oauth_identities(provider TEXT NOT NULL,subject TEXT NOT NULL,user_id TEXT NOT NULL REFERENCES users(id),created INTEGER NOT NULL,PRIMARY KEY(provider,subject),UNIQUE(provider,user_id));
      CREATE TABLE IF NOT EXISTS google_native_requests(hash TEXT PRIMARY KEY,challenge TEXT NOT NULL,state TEXT NOT NULL,expires INTEGER NOT NULL,started INTEGER);
      CREATE TABLE IF NOT EXISTS google_oauth_states(hash TEXT PRIMARY KEY,browser_hash TEXT NOT NULL,nonce_hash TEXT NOT NULL,verifier TEXT NOT NULL,expires INTEGER NOT NULL,intent TEXT NOT NULL,source TEXT NOT NULL,native_hash TEXT REFERENCES google_native_requests(hash));
      CREATE TABLE IF NOT EXISTS google_native_grants(hash TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),challenge TEXT NOT NULL,expires INTEGER NOT NULL);
    `);
    // Additive migration preserves accounts, devices and existing magic links.
    const magicColumns = this.all("PRAGMA table_info(magic_links)");
    for (const [name, fallback] of [["intent", ""], ["source", "site"]])
      if (!magicColumns.some((column) => column.name === name))
        this.db.exec(`ALTER TABLE magic_links ADD COLUMN ${name} TEXT NOT NULL DEFAULT '${fallback}'`);
    // used also marks rejected or invalidated links; only a committed
    // confirmation is evidence of email-link authentication. Old rows stay unknown.
    if (!magicColumns.some((column) => column.name === "confirmed"))
      this.db.exec("ALTER TABLE magic_links ADD COLUMN confirmed INTEGER");
    if (!this.all("PRAGMA table_info(users)").some((column) => column.name === "is_internal"))
      this.db.exec("ALTER TABLE users ADD COLUMN is_internal INTEGER NOT NULL DEFAULT 0 CHECK(is_internal IN (0,1))");
    // Keep management lists and their per-account lookups bounded as the
    // customer base grows. Apply after the additive is_internal migration.
    this.db.exec(`
      CREATE INDEX IF NOT EXISTS users_created_id ON users(created DESC,id);
      CREATE INDEX IF NOT EXISTS users_internal_created_id ON users(is_internal,created DESC,id);
      CREATE INDEX IF NOT EXISTS entitlements_user_status_until ON entitlements(user_id,status,until);
      CREATE INDEX IF NOT EXISTS devices_user_revoked_created ON devices(user_id,revoked,created DESC);
      CREATE INDEX IF NOT EXISTS owner_codes_email_created ON owner_codes(email,created DESC);
      CREATE INDEX IF NOT EXISTS support_tickets_user_created ON support_tickets(user_id,created DESC);
      CREATE INDEX IF NOT EXISTS payment_reserves_user_received ON payment_reserves(user_id,received DESC);
      CREATE INDEX IF NOT EXISTS magic_links_email_expires ON magic_links(email,expires);
      CREATE INDEX IF NOT EXISTS magic_links_email_confirmed ON magic_links(email,confirmed);
      CREATE INDEX IF NOT EXISTS oauth_identities_user_provider ON oauth_identities(user_id,provider);
      CREATE INDEX IF NOT EXISTS admin_access_audit_user_created ON admin_access_audit(user_id,created DESC);
      CREATE INDEX IF NOT EXISTS admin_access_audit_grant ON admin_access_audit(entitlement_id,created DESC);
      CREATE INDEX IF NOT EXISTS admin_lifetime_access_audit_user_created ON admin_lifetime_access_audit(user_id,created DESC);
      CREATE INDEX IF NOT EXISTS admin_lifetime_access_audit_grant ON admin_lifetime_access_audit(entitlement_id,created DESC);
    `);
    this.internalEmails = new Set();
    this.run(
      "INSERT OR IGNORE INTO service_state VALUES('collection_started',?)",
      String(this.now()),
    );
    this.run("INSERT OR IGNORE INTO service_state VALUES('customer_metrics_started',?)", String(this.now()));
  }
  setInternalEmails(emails) {
    this.internalEmails = new Set(emails);
    for (const email of this.internalEmails)
      this.run("UPDATE users SET is_internal=1 WHERE email=?", email);
  }
  recordLogin(userID) {
    const user = this.get("SELECT is_internal FROM users WHERE id=?", userID);
    if (!user) throw Error("Unknown account");
    if (!user.is_internal) {
      this.activity("login", "account");
      this.activity("customer_login", "account");
    }
    this.run("INSERT INTO user_activity(user_id,last_login) VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET last_login=excluded.last_login", userID, this.now());
  }
  close() {
    this.db.close();
  }
  run(sql, ...args) {
    return this.db.prepare(sql).run(...args);
  }
  get(sql, ...args) {
    return this.db.prepare(sql).get(...args);
  }
  all(sql, ...args) {
    return this.db.prepare(sql).all(...args);
  }
  transaction(fn) {
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const v = fn();
      this.db.exec("COMMIT");
      return v;
    } catch (e) {
      this.db.exec("ROLLBACK");
      throw e;
    }
  }
  magic(email, intent = "", source = "site") {
    if (!["", "download"].includes(intent) || !["site", "app"].includes(source))
      throw Error("Invalid authentication intent");
    const value = token();
    this.run(
      "INSERT INTO magic_links(hash,email,expires,intent,source) VALUES(?,?,?,?,?)",
      digest(value),
      email,
      this.now() + 900,
      intent,
      source,
    );
    return value;
  }
  consumeMagic(value) {
    return this.transaction(() => {
      const link = this.get(
        "SELECT * FROM magic_links WHERE hash=? AND used=0 AND expires>?",
        digest(value),
        this.now(),
      );
      if (!link) return null;
      this.run("UPDATE magic_links SET used=1,confirmed=? WHERE hash=?", this.now(), digest(value));
      const inserted = this.run(
        "INSERT OR IGNORE INTO users(id,email,created) VALUES(?,?,?)",
        randomUUID(),
        link.email,
        this.now(),
      );
      if (this.internalEmails.has(link.email)) this.run("UPDATE users SET is_internal=1 WHERE email=?", link.email);
      const user = this.get("SELECT * FROM users WHERE email=?", link.email);
      const registration = this.get("SELECT password_hash FROM password_registrations WHERE magic_hash=?", digest(value));
      if (registration && inserted.changes)
        this.run("INSERT OR IGNORE INTO password_credentials VALUES(?,?,?)", user.id, registration.password_hash, this.now());
      if (registration) this.run("UPDATE password_registrations SET password_hash='' WHERE magic_hash=?", digest(value));
      if (inserted.changes && !user.is_internal) this.activity("account_created", "account");
      this.recordLogin(user.id);
      return { user, session: this.session(user.id), intent: link.intent, source: link.source };
    });
  }
  downloadLink(userID, artifact, source) {
    return this.transaction(() => {
      const recent = this.get(
        "SELECT COUNT(*) AS n FROM download_links WHERE user_id=? AND created>?",
        userID, this.now() - 3600,
      );
      // Failed sends may be retried immediately; accepted/in-flight sends cool down.
      const cooling = this.get(
        "SELECT hash FROM download_links WHERE user_id=? AND created>? AND delivery IN ('pending','smtp_accepted')",
        userID, this.now() - 60,
      );
      if (recent.n >= 3 || cooling) return null;
      const value = token();
      this.run(
        "INSERT INTO download_links(hash,user_id,artifact,source,created,expires) VALUES(?,?,?,?,?,?)",
        digest(value), userID, artifact, source, this.now(), this.now() + 900,
      );
      return value;
    });
  }
  downloadDelivery(value, accepted) {
    this.run(
      "UPDATE download_links SET delivery=?,expires=CASE WHEN ? THEN expires ELSE ? END WHERE hash=? AND delivery='pending'",
      accepted ? "smtp_accepted" : "failed", Number(accepted), this.now(), digest(value),
    );
  }
  claimDownload(value, userID, artifact, session) {
    return this.transaction(() => {
      const transfer = token();
      const result = this.run(
        "UPDATE download_links SET claimed=?,transfer_hash=?,transfer_session=?,transfer_expires=? WHERE hash=? AND user_id=? AND artifact=? AND delivery='smtp_accepted' AND expires>? AND claimed IS NULL AND used IS NULL",
        this.now(), digest(transfer), digest(session), this.now() + 60,
        digest(value), userID, artifact, this.now(),
      );
      return result.changes ? transfer : null;
    });
  }
  consumeDownload(transfer, userID, artifact, session) {
    return this.transaction(() => {
      const row = this.get(
        "SELECT hash,source FROM download_links WHERE transfer_hash=? AND user_id=? AND artifact=? AND transfer_session=? AND transfer_expires>? AND expires>? AND used IS NULL",
        digest(transfer), userID, artifact, digest(session), this.now(), this.now(),
      );
      if (!row) return null;
      this.run("UPDATE download_links SET used=? WHERE hash=?", this.now(), row.hash);
      return row;
    });
  }
  session(userID, deviceID = null) {
    const value = token();
    this.run(
      "INSERT INTO sessions VALUES(?,?,?,?)",
      digest(value),
      userID,
      deviceID,
      this.now() + 30 * 86400,
    );
    return value;
  }
  authenticate(value) {
    if (typeof value !== "string" || value.length > 128) return null;
    return this.get(
      `SELECT u.*,s.device_id FROM sessions s JOIN users u ON u.id=s.user_id LEFT JOIN devices d ON d.id=s.device_id WHERE s.hash=? AND s.expires>? AND (s.device_id IS NULL OR d.revoked=0)`,
      digest(value),
      this.now(),
    );
  }
  device(label, challenge) {
    const value = token(),
      code = randomBytes(5).toString("hex").toUpperCase();
    this.run(
      "INSERT INTO device_requests(hash,code,challenge,label,expires) VALUES(?,?,?,?,?)",
      digest(value),
      code,
      challenge,
      label,
      this.now() + 600,
    );
    return { deviceCode: value, userCode: code, expiresIn: 600, interval: 5 };
  }
  approveDevice(code, userID) {
    return (
      this.run(
        "UPDATE device_requests SET user_id=? WHERE code=? AND user_id IS NULL AND used=0 AND expires>?",
        userID,
        code,
        this.now(),
      ).changes === 1
    );
  }
  exchangeDevice(value, verifier) {
    return this.transaction(() => {
      const r = this.get(
        "SELECT * FROM device_requests WHERE hash=? AND used=0 AND expires>?",
        digest(value),
        this.now(),
      );
      if (!r) return { error: "expired_token" };
      if (digest(verifier) !== r.challenge)
        return { error: "invalid_verifier" };
      if (!r.user_id) return { error: "authorization_pending" };
      this.run("UPDATE device_requests SET used=1 WHERE hash=?", digest(value));
      const id = randomUUID();
      this.run(
        "INSERT INTO devices(id,user_id,label,created) VALUES(?,?,?,?)",
        id,
        r.user_id,
        r.label,
        this.now(),
      );
      this.activity("device_paired", "app");
      this.run(
        "INSERT INTO user_activity(user_id,last_pair) VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET last_pair=excluded.last_pair",
        r.user_id,
        this.now(),
      );
      return { token: this.session(r.user_id, id), deviceID: id };
    });
  }
  activity(kind, source) {
    if (
      ![
        "page_view",
        "download",
        "account_created",
        "login",
        "device_paired",
        "customer_login",
        "customer_download",
      ].includes(kind)
    )
      throw Error("Invalid activity kind");
    if (
      typeof source !== "string" ||
      source.length > 253 ||
      !/^[a-z0-9._-]+$/.test(source)
    )
      throw Error("Invalid activity source");
    const day = new Date(this.now() * 1000).toISOString().slice(0, 10);
    this.run(
      "INSERT INTO activity_daily VALUES(?,?,?,1) ON CONFLICT(day,kind,source) DO UPDATE SET count=count+1",
      day,
      kind,
      source,
    );
  }
  issueOwnerCode(email) {
    const value =
      "PM-" +
      randomBytes(16).toString("hex").toUpperCase().match(/.{8}/g).join("-");
    this.transaction(() => {
      this.run(
        "UPDATE owner_codes SET expires=? WHERE email=? AND used_by IS NULL",
        this.now(),
        email,
      );
      this.run(
        "INSERT INTO owner_codes(hash,email,expires,created) VALUES(?,?,?,?)",
        digest(value),
        email,
        this.now() + 7 * 86400,
        this.now(),
      );
    });
    return value;
  }
  redeemOwnerCode(value, user) {
    const code = typeof value === "string" ? value.trim().toUpperCase() : "";
    if (!/^PM-(?:[A-F0-9]{8}-){3}[A-F0-9]{8}$/.test(code)) return false;
    return this.transaction(() => {
      const grant = this.get(
        "SELECT * FROM owner_codes WHERE hash=? AND email=?",
        digest(code),
        user.email,
      );
      if (!grant || (grant.used_by && grant.used_by !== user.id)) return false;
      if (grant.used_by === user.id)
        return !!this.get(
          "SELECT id FROM entitlements WHERE id=? AND status='active'",
          "owner_" + user.id,
        );
      if (grant.expires <= this.now()) return false;
      this.run(
        "INSERT INTO entitlements VALUES(?,?,?,'active',NULL,NULL,NULL,?) ON CONFLICT(id) DO UPDATE SET status='active',until=NULL,updated=excluded.updated",
        "owner_" + user.id,
        user.id,
        "lifetime",
        this.now(),
      );
      this.run(
        "UPDATE owner_codes SET used_by=?,used=? WHERE hash=?",
        user.id,
        this.now(),
        grant.hash,
      );
      return true;
    });
  }
  entitlement(userID) {
    const rows = this.all(
      `SELECT e.* FROM entitlements e LEFT JOIN blocked_payments b ON b.payment_intent=e.payment_intent WHERE user_id=? AND status IN ('active','trialing') AND (until IS NULL OR until>?) AND b.payment_intent IS NULL ORDER BY until IS NULL DESC,until DESC`,
      userID,
      this.now(),
    );
    return rows[0] || null;
  }
}
