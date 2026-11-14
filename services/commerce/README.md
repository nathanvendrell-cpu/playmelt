# Playmelt account service

The hosted service is `2.2.0-commerce-20261113`, with commercial billing disabled. Its selective deployment preserved the owner lifetime entitlement, existing sessions, private keys and protected files. The HTTPS readback confirms Google remains enabled and the served 13 November CGV match their accepted fingerprint. The commerce source passes 147 tests. Stripe catalogues have been read back separately in Test and Live. The isolated Test recipe verified card collection with 3D Secure, a 30-day monthly trial, receipt of the contract confirmation, browser-session persistence and period-end cancellation followed by restoration. The first nonzero invoice failed its off-session authentication, then succeeded after the Test 3D Secure challenge; a later monthly renewal was paid. Native `launch` and `runtime.download` grants were refused after the failed payment, allowed with verified signatures after regularization, and refused again after a full refund. A product-scoped, single-use Test promotion code reduced a lifetime purchase from EUR 399.00 to EUR 359.10; Stripe opened the simulated dispute and both native capabilities remained refused. Revoking the temporary device then returned HTTP 401. These are sandbox receipts with fictitious cards and an advanced test clock, not real charges or a qualified public client release.

The service keeps payment-account data separate from the local game library. Email verifies a new account; email/password authentication binds a Mac, and an Ed25519 ticket authorizes a launch. Legacy device codes remain compatible at `/device`. Stripe Checkout collects cards directly. No card number, CVC, platform password or game library belongs in this database.

## Run and verify

Node 22.13 or newer is required. Install with `npm ci --ignore-scripts`, then run `npm test`. `src/main.mjs` reads the variables listed in `.env.example`; the template contains no credentials. SQLite, the signing key and the environment file must live outside the document root with private permissions. `app.cjs` is the o2switch Passenger entry point; standalone mode binds only to loopback.

`test/preview.mjs` is a loopback-only browser fixture with fake Stripe and email. It must never be deployed. Tests do not establish an actual purchase, email delivery, native activation or public deployment.

## Contracts

| Endpoint                                  | Purpose                                                                                                                      |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `/v1/auth/email`, `/v1/auth/confirm`      | Verified email, single-use 15-minute link; secure HttpOnly session                                                           |
| `/v1/auth/register`, `/v1/auth/login`     | Verified registration; salted scrypt credentials, browser session only, no password in mail/URLs                            |
| `/v1/auth/device-login`                  | Email/password to a 30-day device-bound token; no licence or admin grant; then reuse `/me` and `/launch-ticket`              |
| `/v1/auth/providers`, `/v1/auth/google/start`, `/callback` | Optional Google OpenID Connect, official Google signature verification, browser-bound state/nonce and S256           |
| `/v1/auth/google/native/start`, `/native/exchange` | System-browser native sign-in, fixed callback scheme, a one-use 60-second code and the original PKCE proof              |
| `/v1/auth/password`, `/reset`, `/reset/confirm` | Browser-only setup/change; one-use 15-minute recovery revokes account sessions and pending grants, preserves licences   |
| `/v1/device/start`, `/approve`, `/token`  | User-approved device association with proof of possession                                                                    |
| `/v1/launch-ticket`                       | Signed account/device-bound access, at most 900 seconds and capped at entitlement expiry                                     |
| `/v1/checkout`                            | Server-owned price, explicit current CGV acceptance, first 30-day subscription trial, card collection and Stripe promo codes |
| `/v1/billing/portal`                      | Browser-only, dedicated Playmelt Stripe portal, current configuration read back before each session; period-end cancellation without commercial prorations |
| `/v1/stripe/webhook`                      | Raw-body signature, mode check, deduplication and authoritative reconciliation                                               |
| `/v1/support`                             | Private requests, including inactive licences                                                                                |
| `/v1/admin/support`, `/v1/admin/reserves` | Explicitly allowlisted browser-session operators only                                                                        |

The reserve is an internal accounting record for 14 days after receipt. It does **not** delay Stripe payouts, initiate refunds or prove a bank balance. SMTP acceptance does not prove delivery or reading.

## Administration and owner access

`/admin` and `/v1/admin/*` require an authenticated browser session explicitly listed in `PLAYMELT_ADMINS`; paired desktop tokens cannot access staff data. Visits and download requests are daily aggregate counters without visitor identifiers. The dashboard distinguishes missing history, download requests and GitHub's cumulative DMG download counts. It does not infer installations or unique people.

`PLAYMELT_INTERNAL_EMAILS` defaults to the owner address. Internal accounts remain usable and listed with an internal badge; customer/licence/revenue/support totals exclude them. Historical anonymous visits and GitHub totals cannot be retroactively attributed. New customer-login/download counters start at the persisted `customer_metrics_started` timestamp; the UI leaves earlier days unavailable. Existing accounts, tokens and lifetime grants survive this additive migration.

Passwords require 15–128 Unicode characters and are never trimmed. Scrypt uses a random 16-byte salt, N=131072, r=8, p=1, with two concurrent derivations maximum. Known and unknown mailboxes share the same failure counter behavior and generic credential errors. Registration and recovery mail jobs are bounded and drained before SQLite closes; SMTP completion does not reveal account existence through public response latency. First password setup preserves current sessions; an explicit recovery reset invalidates sessions, device grants and pending magic links, without modifying platform data or entitlements.

Google requests only `openid email`, with online access and no refresh-token storage. `PLAYMELT_GOOGLE_OAUTH_FILE` optionally points to the private web-client JSON (owned by the service, mode0600, no links, exact HTTPS callback); credentials never belong in Git or a client bundle. Without valid configuration the provider is unavailable and its button stays hidden. Stable Google subjects identify accounts. Initial email linking requires Google to be authoritative (verified Gmail or Workspace); an existing account, entitlement and internal flag are retained. Other email authorities must use the verified email flow. An explicit password recovery also removes pending native Google grants. Configuration and mock tests are not proof of real Google consent or an OS callback.

`PLAYMELT_SUPPORT_ADMINS` grants support operations only; it never falls back to general administration. Paired-device credentials cannot approve another device, revoke devices, create Checkout sessions or open the billing portal. These account-management actions use the verified web session; device access and existing connections remain valid. Production entrypoints require a mode-matching restricted `rk_` Stripe key and reject unrestricted `sk_` keys. The actual resource permissions still need verification in Stripe.

`tools/issue-owner-code.mjs` runs only on the host. It issues a seven-day, single-use code bound to `PLAYMELT_OWNER_EMAIL`, which must be an allowlisted admin. The database stores its hash. Redemption grants lifetime owner access without creating a Stripe payment. Reissuing an unused code invalidates the previous one.

`PLAYMELT_BILLING_VERIFIED=0` is the default. Accounts, support, owner redemption and administration remain available while Checkout and payment webhook processing fail closed. Enable billing only after the hosted payment recipe is complete. The o2switch loopback mail relay uses no application mail password; actual inbox delivery still requires verification.

`STRIPE_PORTAL_CONFIGURATION` selects a dedicated Playmelt portal by its explicit ID. Before billing starts, and again before a customer session is created, the service verifies its mode, product identity, metadata, exact legal/return URLs and bounded features. Missing, changed or invalid configuration refuses the operation; it never falls back to Stripe's account-wide default. Stripe can automatically mark the first created configuration as its default; this flag does not replace any of those checks or change which ID Playmelt uses.

The private download requires an exact version, filename, byte count and SHA-256. A durable database pin prevents downgrades, replacement under the same version, and relabelling the retained legacy bytes. Live billing requires an approved 2.2.0 private artifact; a development build or a proposed manifest is not that approval. Selecting a new artifact can promote the primary pin even while billing is off, so do not use the production database for package experiments. A separately signed, owner-only `compte-test` recipe has a separate database and signing key, no Google/admin/download access, and a distinct pin namespace. It may exercise Test billing without distributing a client. Browser download is separate from automatic updates; the current commercial client disables unqualified updater transport.

## Before activation

Verify SMTP inbox delivery, raw signed webhooks, account persistence after restart, checkout/card/trial/cancellation/refund behavior and the actual native device gate. Subscription reconciliation accepts exactly one recognized, unit-quantity item; supports newer invoice subscription parents; caps the first trial at 30 days with a collected payment method; and refuses terminal/unpaid states. A full refund or dispute blocks its payment. A cancellation scheduled for the end of a paid period preserves that paid term. There is no commercial partial-refund offer; statutory remedies remain unaffected.

A completed Checkout releases only its own cached URL after its settled payment state, current entitlement and contractual confirmation are verified. A pending, newer or other user's Checkout stays unchanged. This prevents a later purchase from reopening an already completed session without weakening the single-pending-Checkout guard.

Complete the durable contractual confirmation, qualified client distribution and consumer mediation before opening sales. The hosted CGV include the continuous digital-service guarantee notice from Annex D.211-4, under the documented editorial classification; this is not external legal certification. Nathan confirmed VAT exemption and declined mediator affiliation on 12 November; consumer-sale compliance is not marked complete. Review distribution rights for runtime dependencies separately.

Only the public licence verification key belongs in the app. Stripe credentials, webhook secrets and signing private keys stay server-side. An official-client entitlement gate does not make public source code impossible to modify. No commercial release is activated by this preparation.
