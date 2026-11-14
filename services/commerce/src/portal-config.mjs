const configurationID = /^bpc_[A-Za-z0-9]{1,200}$/;
const termsURL = "https://7agency.fr/Playmelt/legal/conditions-de-vente/";
const privacyURL = "https://7agency.fr/Playmelt/legal/confidentialite/";

function targets(config) {
  if (typeof config.live !== "boolean" || typeof config.publicURL !== "string")
    throw Error("Invalid Playmelt portal mode or target");
  const base = config.publicURL.replace(/\/$/, "");
  const expected = "https://7agency.fr/Playmelt/" + (config.live ? "compte" : "compte-test");
  if (base !== expected || config.termsURL !== termsURL || config.privacyURL !== privacyURL)
    throw Error("Invalid Playmelt portal mode or target");
  return { returnURL: base + "/", termsURL, privacyURL };
}

/** Validate the explicit dedicated configuration; never select an implicit default. */
export function validatePortalConfiguration(portal, config) {
  if (typeof config.portalConfigurationID !== "string" || !configurationID.test(config.portalConfigurationID))
    throw Error("A dedicated Playmelt portal configuration is required");
  const expected = targets(config), features = portal?.features;
  const named = typeof portal?.name === "string" && portal.name.length <= 120 &&
    /^Playmelt(?:\s|$)/.test(portal.name) && !/[\x00-\x1f\x7f]/.test(portal.name);
  // Older pinned API responses may omit name; the explicit product headline
  // and dedicated metadata identify the same independently created portal.
  const identified = named || ((portal?.name == null || portal.name === "") && portal?.business_profile?.headline === "Playmelt");
  if (!portal || portal.object !== "billing_portal.configuration" ||
      portal.id !== config.portalConfigurationID || portal.livemode !== config.live ||
      portal.active !== true || typeof portal.is_default !== "boolean" ||
      !identified ||
      portal.metadata?.playmelt_scope !== "billing-portal" ||
      portal.default_return_url !== expected.returnURL ||
      portal.business_profile?.terms_of_service_url !== expected.termsURL ||
      portal.business_profile?.privacy_policy_url !== expected.privacyURL ||
      features?.subscription_cancel?.enabled !== true ||
      features.subscription_cancel.mode !== "at_period_end" ||
      features.subscription_cancel.proration_behavior !== "none" ||
      features.payment_method_update?.enabled !== true ||
      features.invoice_history?.enabled !== true ||
      features.subscription_update?.enabled !== false ||
      features.customer_update?.enabled !== false ||
      portal.login_page?.enabled !== false)
    throw Error("Invalid dedicated Playmelt portal configuration");
  return Object.freeze({ id: portal.id, livemode: portal.livemode, returnURL: expected.returnURL });
}

/** Startup readback; absence is allowed only while commercial billing is off. */
export async function loadPortalConfiguration(stripe, config) {
  if (!config.portalConfigurationID && config.billingEnabled !== true) return null;
  if (typeof config.portalConfigurationID !== "string" || !configurationID.test(config.portalConfigurationID))
    throw Error("A dedicated Playmelt portal configuration is required");
  targets(config);
  const portal = await stripe.billingPortal.configurations.retrieve(config.portalConfigurationID);
  validatePortalConfiguration(portal, config);
  return portal;
}
