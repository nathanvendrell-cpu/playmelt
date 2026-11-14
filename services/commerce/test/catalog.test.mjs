import test from "node:test";
import assert from "node:assert/strict";
import { validatePrice } from "../src/catalog.mjs";

test("the approved annual amount accepts one year or twelve months, never a wrong billing period", () => {
  const annual = {
    active: true,
    livemode: true,
    currency: "eur",
    unit_amount: 16799,
    billing_scheme: "per_unit",
    recurring: { interval: "year", interval_count: 1 },
  };
  assert.equal(validatePrice("annual", annual, true), annual);
  validatePrice(
    "annual",
    { ...annual, recurring: { interval: "month", interval_count: 12 } },
    true,
  );
  for (const changed of [
    { livemode: false },
    { unit_amount: 1679 },
    { currency: "usd" },
    { recurring: { interval: "month", interval_count: 1 } },
    { active: false },
    { billing_scheme: "tiered" },
  ]) {
    assert.throws(
      () => validatePrice("annual", { ...annual, ...changed }, true),
      /mismatch/,
    );
  }
});
test("lifetime is fixed and non-recurring", () => {
  const price = {
    active: true,
    livemode: false,
    currency: "eur",
    unit_amount: 39900,
    billing_scheme: "per_unit",
    recurring: null,
  };
  validatePrice("lifetime", price, false);
  assert.throws(
    () =>
      validatePrice(
        "lifetime",
        { ...price, recurring: { interval: "year", interval_count: 1 } },
        false,
      ),
    /mismatch/,
  );
});
