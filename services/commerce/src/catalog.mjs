import { plans } from "./billing.mjs";

/** Check the server's fixed catalog, including the equivalent yearly Stripe interval. */
export function validatePrice(planID, price, live) {
  const expected = plans[planID];
  if (!expected) throw Error("Unknown plan");
  const recurrence = price.recurring;
  const months =
    recurrence?.interval === "year"
      ? recurrence.interval_count * 12
      : recurrence?.interval === "month"
        ? recurrence.interval_count
        : null;
  if (
    !price.active ||
    price.livemode !== live ||
    price.currency !== "eur" ||
    price.unit_amount !== expected.cents ||
    price.billing_scheme !== "per_unit" ||
    (expected.months ? months !== expected.months : !!recurrence)
  ) {
    throw Error("Stripe price mismatch: " + planID);
  }
  return price;
}
