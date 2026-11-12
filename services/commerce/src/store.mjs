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
      CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY,email TEXT NOT NULL UNIQUE,name TEXT NOT NULL DEFAULT '',stripe_customer TEXT UNIQUE,created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS magic_links(hash TEXT PRIMARY KEY,email TEXT NOT NULL,expires INTEGER NOT NULL,used INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS sessions(hash TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),device_id TEXT,expires INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),label TEXT NOT NULL,revoked INTEGER NOT NULL DEFAULT 0,created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS device_requests(hash TEXT PRIMARY KEY,code TEXT UNIQUE NOT NULL,challenge TEXT NOT NULL,label TEXT NOT NULL,user_id TEXT REFERENCES users(id),expires INTEGER NOT NULL,used INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS entitlements(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),plan TEXT NOT NULL,status TEXT NOT NULL,until INTEGER,invoice TEXT,payment_intent TEXT,updated INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS trials(user_id TEXT PRIMARY KEY REFERENCES users(id),subscription_id TEXT NOT NULL,started INTEGER NOT NULL,until INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS billing_events(id TEXT PRIMARY KEY,status TEXT NOT NULL,updated INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS blocked_payments(payment_intent TEXT PRIMARY KEY,reason TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS checkout_requests(user_id TEXT PRIMARY KEY REFERENCES users(id),plan TEXT NOT NULL,checkout_id TEXT,url TEXT,expires INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS checkout_terms(request_id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),version TEXT NOT NULL,sha256 TEXT NOT NULL,accepted INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS support_tickets(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),category TEXT NOT NULL,message TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'open',created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS support_replies(id TEXT PRIMARY KEY,ticket_id TEXT NOT NULL REFERENCES support_tickets(id),body TEXT NOT NULL,created INTEGER NOT NULL,delivery TEXT NOT NULL DEFAULT 'pending');
      CREATE TABLE IF NOT EXISTS payment_reserves(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),payment_intent TEXT,amount INTEGER NOT NULL,currency TEXT NOT NULL,received INTEGER NOT NULL,reserved_until INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS profile_progress(user_id TEXT PRIMARY KEY REFERENCES users(id),json TEXT NOT NULL,updated INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS benchmarks(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),json TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'private',created INTEGER NOT NULL);
    `);
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
  magic(email) {
    const value = token();
    this.run(
      "INSERT INTO magic_links(hash,email,expires) VALUES(?,?,?)",
      digest(value),
      email,
      this.now() + 900,
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
      this.run("UPDATE magic_links SET used=1 WHERE hash=?", digest(value));
      this.run(
        "INSERT OR IGNORE INTO users(id,email,created) VALUES(?,?,?)",
        randomUUID(),
        link.email,
        this.now(),
      );
      const user = this.get("SELECT * FROM users WHERE email=?", link.email);
      return { user, session: this.session(user.id) };
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
      return { token: this.session(r.user_id, id), deviceID: id };
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
