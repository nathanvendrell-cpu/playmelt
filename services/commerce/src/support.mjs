import { randomUUID } from "node:crypto";
import { registerGameSupport, gameSupportDetail } from "./support-game.mjs";

const categories = new Set([
  "licence",
  "paiement",
  "retractation",
  "compatibilite",
  "donnees",
]);

/** Support remains available to signed-in customers without an active licence. */
export function registerSupport(api, { store, config, mailer, auth, fail }) {
  const staff = (req, reply) => {
    const user = auth(req, reply);
    if (!user) return null;
    if (user.device_id || !(config.adminEmails || []).includes(user.email) && !(config.supportAdmins || []).includes(user.email)) {
      fail(reply, 403, "staff_required");
      return null;
    }
    return user;
  };
  registerGameSupport(api, { store, config, mailer, auth, fail, staff });
  api.get("/v1/support", async (req, reply) => {
    const user = auth(req, reply);
    if (!user) return;
    return store
      .all(
        "SELECT * FROM support_tickets WHERE user_id=? ORDER BY created DESC LIMIT 100",
        user.id,
      )
      .map((ticket) => ({
        ...ticket,
        replies: store.all(
          "SELECT body,created,delivery FROM support_replies WHERE ticket_id=? ORDER BY created",
          ticket.id,
        ),
      }));
  });
  api.post(
    "/v1/support",
    { config: { rateLimit: { max: 5, timeWindow: 3600000 } } },
    async (req, reply) => {
      const user = auth(req, reply);
      if (!user) return;
      const category = req.body?.category,
        message = String(req.body?.message || "").trim();
      if (
        !categories.has(category) ||
        message.length < 10 ||
        message.length > 5000
      )
        return fail(reply, 400, "invalid_support_request");
      const id = randomUUID();
      store.run(
        "INSERT INTO support_tickets(id,user_id,category,message,created) VALUES(?,?,?,?,?)",
        id,
        user.id,
        category,
        message,
        store.now(),
      );
      return { id, status: "open", receivedAt: store.now() };
    },
  );
  api.get("/v1/admin/support", async (req, reply) => {
    if (!staff(req, reply)) return;
    return store.all(
      "SELECT t.*,u.email FROM support_tickets t JOIN users u ON u.id=t.user_id ORDER BY t.created DESC LIMIT 200",
    ).map((ticket) => ({
      ...ticket,
      game: gameSupportDetail(store, ticket.id),
      replies: store.all("SELECT body,created,delivery FROM support_replies WHERE ticket_id=? ORDER BY created,rowid", ticket.id),
    }));
  });
  api.get("/v1/admin/reserves", async (req, reply) => {
    if (!staff(req, reply)) return;
    const payments = store.all(
      "SELECT r.*,b.reason AS blocked_reason FROM payment_reserves r LEFT JOIN blocked_payments b ON b.payment_intent=r.payment_intent ORDER BY r.received DESC LIMIT 1000",
    );
    return {
      physicalPayoutControl: false,
      policyDays: 14,
      payments: payments.map((p) => ({
        ...p,
        state: p.blocked_reason
          ? "disputed_or_refunded"
          : p.reserved_until > store.now()
            ? "reserved"
            : "reserve_elapsed",
      })),
    };
  });
  api.post("/v1/admin/support/:id/reply", async (req, reply) => {
    if (!staff(req, reply)) return;
    const ticket = store.get(
      "SELECT t.*,u.email FROM support_tickets t JOIN users u ON u.id=t.user_id WHERE t.id=?",
      req.params.id,
    );
    if (!ticket) return fail(reply, 404, "ticket_not_found");
    const body = String(req.body?.message || "").trim();
    if (body.length < 1 || body.length > 5000)
      return fail(reply, 400, "invalid_support_request");
    const id = randomUUID();
    store.run(
      "INSERT INTO support_replies(id,ticket_id,body,created) VALUES(?,?,?,?)",
      id,
      ticket.id,
      body,
      store.now(),
    );
    try {
      const sent = await mailer.sendMail({
        from: config.mailFrom,
        replyTo: config.supportEmail,
        to: { address: ticket.email },
        subject: "Playmelt — réponse à votre demande " + ticket.id.slice(0, 8),
        text: body,
      });
      const accepted =
        Array.isArray(sent?.accepted) && sent.accepted.includes(ticket.email);
      store.run(
        "UPDATE support_replies SET delivery=? WHERE id=?",
        accepted ? "smtp_accepted" : "unconfirmed",
        id,
      );
      return {
        saved: true,
        delivery: accepted ? "smtp_accepted" : "unconfirmed",
      };
    } catch {
      store.run("UPDATE support_replies SET delivery='failed' WHERE id=?", id);
      return reply.code(502).send({ saved: true, delivery: "failed" });
    }
  });
}
