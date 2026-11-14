import test from "node:test";
import assert from "node:assert/strict";
import { mailTransportOptions } from "../src/mail-transport.mjs";
test("the local relay is fixed to loopback with no password, while external SMTP requires TLS", () => {
  const local = mailTransportOptions({
    MAIL_TRANSPORT: "local-smtp",
    SMTP_HOST: "attacker.example",
    SMTP_USER: "ignored",
    SMTP_PASSWORD: "ignored",
  });
  assert.equal(local.host, "127.0.0.1");
  assert.equal(local.port, 25);
  assert.equal(local.auth, undefined);
  assert.equal(local.disableFileAccess, true);
  assert.equal(local.disableUrlAccess, true);
  for (const port of ["465", "587"]) {
    const smtp = mailTransportOptions({
      SMTP_HOST: "mail.example",
      SMTP_PORT: port,
      SMTP_USER: "user",
      SMTP_PASSWORD: "fixture",
    });
    assert.equal(smtp.requireTLS, true);
    assert.equal(smtp.secure, port === "465");
  }
  assert.throws(() => mailTransportOptions({ SMTP_PORT: "25" }));
  assert.throws(() => mailTransportOptions({ MAIL_TRANSPORT: "shell" }));
  assert.throws(() => mailTransportOptions({ SMTP_HOST: "mail.example" }));
});
