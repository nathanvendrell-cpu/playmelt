import { randomUUID } from "node:crypto";
import { normalizeEmail } from "./email.mjs";

const categories = new Set([
  "launch", "crash", "graphics", "performance", "installation", "other",
]);
export const gameSupportStatuses = [
  "received", "investigating", "fixed", "verified", "closed",
];
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const object = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const text = (v, min, max) =>
  typeof v === "string" && v.trim().length >= min && v.length <= max &&
  !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(v);

function request(body) {
  if (!object(body) || typeof body.clientId !== "string" || !uuid.test(body.clientId) ||
      !text(body.gameId, 1, 200) || !text(body.gameTitle, 1, 200) ||
      !text(body.store, 1, 80) || !categories.has(body.category) ||
      !text(body.message, 5, 4000) ||
      typeof body.createdAt !== "number" || !Number.isFinite(body.createdAt) ||
      body.createdAt < 0 || body.createdAt > 253402300799 ||
      (body.diagnostics !== undefined && !object(body.diagnostics))) return null;
  const diagnostics = {};
  for (const [key, limit] of Object.entries({
    version: 80, macOS: 80, chip: 80, gpuName: 200, renderer: 80, graphicsAPI: 80,
  })) {
    const value = body.diagnostics?.[key];
    if (value === undefined) continue;
    // Diagnostic labels are single-line hardware/software names, never file paths.
    if (!text(value, 1, limit) || /[\r\n/\\:]/.test(value)) return null;
    diagnostics[key] = value.trim();
  }
  if (body.diagnostics?.memoryGB !== undefined) {
    const value = body.diagnostics.memoryGB;
    if (typeof value !== "number" || !Number.isFinite(value) || value <= 0 || value > 8192) return null;
    diagnostics.memoryGB = value;
  }
  for (const key of ["installed", "launchBlocked"]) {
    const value = body.diagnostics?.[key];
    if (value === undefined) continue;
    if (typeof value !== "boolean") return null;
    diagnostics[key] = value;
  }
  return {
    clientId: body.clientId.toLowerCase(), gameId: body.gameId.trim(),
    gameTitle: body.gameTitle.trim(), store: body.store.trim(),
    category: body.category, message: body.message.trim(),
    createdAt: body.createdAt, diagnostics,
  };
}

/** Durable, bounded outbox. Retries require an explicit staff action. */
export async function notifyGameSupport(store, mailer, config, ticketID) {
  const attempt = store.transaction(() => {
    const row = store.get("SELECT * FROM support_notifications WHERE ticket_id=?", ticketID);
    if (!row || row.delivery === "smtp_accepted" || row.attempts >= 3 ||
        (row.delivery === "sending" && row.updated > store.now() - 120)) return null;
    if (row.delivery === "sending") {
      // After interruption, the previous SMTP outcome is unknown, not failed.
      store.run("UPDATE support_notification_attempts SET delivery='unconfirmed',updated=? WHERE ticket_id=? AND attempt=? AND delivery='sending'", store.now(), ticketID, row.attempts);
    }
    const number = row.attempts + 1;
    store.run("UPDATE support_notifications SET delivery='sending',attempts=?,updated=? WHERE ticket_id=?", number, store.now(), ticketID);
    const id = randomUUID();
    store.run("INSERT INTO support_notification_attempts VALUES(?,?,?,'sending',?,?)", id, ticketID, number, store.now(), store.now());
    return { id, number };
  });
  if (!attempt) return store.get("SELECT delivery,attempts,updated FROM support_notifications WHERE ticket_id=?", ticketID);
  let delivery = "failed";
  try {
    const to = normalizeEmail(config.supportEmail);
    if (!to) throw Error("Invalid support mailbox configuration");
    const row = store.get(
      "SELECT t.id,t.category,t.message,g.game_title,g.game_id,g.store FROM support_tickets t JOIN game_support g ON g.ticket_id=t.id WHERE t.id=?",
      ticketID,
    );
    if (!row) throw Error("Support ticket not found");
    const result = await mailer.sendMail({
      from: { name: "Playmelt", address: to }, to: { address: to }, replyTo: { address: to },
      subject: "Playmelt — nouveau signalement " + row.id.slice(0, 8),
      messageId: "<playmelt-support-" + row.id + "@7agency.fr>",
      text: [
        "Nouveau signalement de jeu Playmelt.",
        "Référence : " + row.id, "Jeu : " + row.game_title,
        "Identifiant : " + row.game_id, "Boutique : " + row.store,
        "Catégorie : " + row.category, "Message :\n" + row.message,
        "Consultez l’administration Playmelt pour traiter ce signalement et son historique.",
        "Ce message signale l’enregistrement de la demande ; il ne confirme aucune résolution.",
      ].join("\n\n"),
    });
    delivery = Array.isArray(result?.accepted) &&
      result.accepted.some((address) => normalizeEmail(address) === to)
      ? "smtp_accepted" : "unconfirmed";
  } catch {
    // Store an outcome, never transport errors that could contain credentials.
  }
  store.transaction(() => {
    store.run("UPDATE support_notification_attempts SET delivery=?,updated=? WHERE id=?", delivery, store.now(), attempt.id);
    store.run("UPDATE support_notifications SET delivery=?,updated=? WHERE ticket_id=? AND attempts=?", delivery, store.now(), ticketID, attempt.number);
  });
  return store.get("SELECT delivery,attempts,updated FROM support_notifications WHERE ticket_id=?", ticketID);
}

export function gameSupportDetail(store, ticketID) {
  const row = store.get("SELECT client_id AS clientId,game_id AS gameId,game_title AS gameTitle,store,client_created AS createdAt,diagnostics FROM game_support WHERE ticket_id=?", ticketID);
  if (!row) return null;
  return {
    ...row, diagnostics: JSON.parse(row.diagnostics),
    notification: store.get("SELECT delivery,attempts,updated FROM support_notifications WHERE ticket_id=?", ticketID),
    notificationAttempts: store.all("SELECT attempt,delivery,created,updated FROM support_notification_attempts WHERE ticket_id=? ORDER BY attempt", ticketID),
    audit: store.all("SELECT a.previous_status AS previousStatus,a.status,a.created,u.email AS actor FROM support_status_audit a JOIN users u ON u.id=a.actor_id WHERE a.ticket_id=? ORDER BY a.created,a.rowid", ticketID),
  };
}

export function registerGameSupport(api, { store, config, mailer, auth, fail, staff }) {
  const device = (req, reply) => {
    const user = auth(req, reply);
    if (!user) return null;
    if (!user.device_id || !/^Bearer [A-Za-z0-9_-]{43}$/.test(req.headers.authorization || "")) {
      fail(reply, 403, "device_required");
      return null;
    }
    return user;
  };
  api.get("/v1/support/tickets", async (req, reply) => {
    const user = device(req, reply);
    if (!user) return;
    return { tickets: store.all("SELECT g.client_id AS clientId,t.id,t.status FROM game_support g JOIN support_tickets t ON t.id=g.ticket_id WHERE g.user_id=? ORDER BY t.created DESC,t.rowid DESC", user.id) };
  });
  api.post("/v1/support/tickets", {
    config: { rateLimit: { max: 20, timeWindow: 3600000 } },
  }, async (req, reply) => {
    const user = device(req, reply);
    if (!user) return;
    const body = request(req.body);
    if (!body) return fail(reply, 400, "invalid_support_request");
    const result = store.transaction(() => {
      const existing = store.get("SELECT t.id,t.status FROM game_support g JOIN support_tickets t ON t.id=g.ticket_id WHERE g.user_id=? AND g.client_id=?", user.id, body.clientId);
      if (existing) return { ...existing, created: false };
      const id = randomUUID();
      store.run("INSERT INTO support_tickets(id,user_id,category,message,status,created) VALUES(?,?,?,?,'received',?)", id, user.id, body.category, body.message, store.now());
      store.run("INSERT INTO game_support VALUES(?,?,?,?,?,?,?,?)", id, user.id, body.clientId, body.gameId, body.gameTitle, body.store, body.createdAt, JSON.stringify(body.diagnostics));
      store.run("INSERT INTO support_notifications(ticket_id,updated) VALUES(?,?)", id, store.now());
      return { id, status: "received", created: true };
    });
    if (result.created) await notifyGameSupport(store, mailer, config, result.id);
    return reply.code(result.created ? 201 : 200).send({ id: result.id, status: result.status });
  });
  api.post("/v1/admin/support/:id/status", async (req, reply) => {
    const actor = staff(req, reply);
    if (!actor) return;
    const status = req.body?.status;
    if (!gameSupportStatuses.includes(status)) return fail(reply, 400, "invalid_support_status");
    const result = store.transaction(() => {
      const ticket = store.get("SELECT t.id,t.status FROM support_tickets t JOIN game_support g ON g.ticket_id=t.id WHERE t.id=?", req.params.id);
      if (!ticket) return null;
      if (ticket.status !== status) {
        store.run("UPDATE support_tickets SET status=? WHERE id=?", status, ticket.id);
        store.run("INSERT INTO support_status_audit VALUES(?,?,?,?,?,?)", randomUUID(), ticket.id, actor.id, ticket.status, status, store.now());
      }
      return { id: ticket.id, status };
    });
    return result || fail(reply, 404, "ticket_not_found");
  });
  api.post("/v1/admin/support/:id/notification/retry", async (req, reply) => {
    if (!staff(req, reply)) return;
    if (!store.get("SELECT ticket_id FROM support_notifications WHERE ticket_id=?", req.params.id)) return fail(reply, 404, "ticket_not_found");
    return notifyGameSupport(store, mailer, config, req.params.id);
  });
}
