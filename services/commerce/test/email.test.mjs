import test from "node:test";
import assert from "node:assert/strict";
import { normalizeEmail } from "../src/email.mjs";
test("authentication accepts a single mailbox, never a message header or recipient list", () => {
  assert.equal(
    normalizeEmail(" Person+tag@Example.test "),
    "person+tag@example.test",
  );
  assert.equal(normalizeEmail("user@éxample.test"), "user@xn--xample-9ua.test");
  for (const input of [
    "A <a@example.test>",
    "a@example.test,b@evil.test",
    "a@example.test;",
    "a@example.test(comment)",
    "a@example.test\r\nBcc:b@evil.test",
    "a..b@example.test",
    "a@-example.test",
    "a@localhost",
    {},
    null,
  ])
    assert.equal(normalizeEmail(input), null, String(input));
});
