# Playmelt account service

Prepared locally; hosted activation and a real Stripe sandbox flow remain unverified.

The service keeps payment-account data separate from the local game library. Email links verify the account, device pairing binds a Mac, and an Ed25519 ticket authorizes a launch. Stripe Checkout collects cards directly. No card number, CVC, platform password or game library belongs in this database.

## Run and verify

Node 22.13 or newer is required. Install with `npm ci --ignore-scripts`, then run `npm test`. `src/main.mjs` reads the variables listed in `.env.example`; the template contains no credentials. SQLite, the signing key and the environment file must live outside the document root with private permissions. `app.cjs` is the o2switch Passenger entry point; standalone mode binds only to loopback.

`test/preview.mjs` is a loopback-only browser fixture with fake Stripe and email. It must never be deployed. Tests do not establish an actual purchase, email delivery, native activation or public deployment.

## Contracts

| Endpoint                                  | Purpose                                                                                                                      |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `/v1/auth/email`, `/v1/auth/confirm`      | Verified email, single-use 15-minute link; secure HttpOnly session                                                           |
| `/v1/device/start`, `/approve`, `/token`  | User-approved device association with proof of possession                                                                    |
| `/v1/launch-ticket`                       | Signed account/device-bound access, at most 900 seconds and capped at entitlement expiry                                     |
| `/v1/checkout`                            | Server-owned price, explicit current CGV acceptance, first 30-day subscription trial, card collection and Stripe promo codes |
| `/v1/billing/portal`                      | Stripe management and cancellation                                                                                           |
| `/v1/stripe/webhook`                      | Raw-body signature, mode check, deduplication and authoritative reconciliation                                               |
| `/v1/support`                             | Private requests, including inactive licences                                                                                |
| `/v1/admin/support`, `/v1/admin/reserves` | Explicitly allowlisted browser-session operators only                                                                        |

The reserve is an internal accounting record for 14 days after receipt. It does **not** delay Stripe payouts, initiate refunds or prove a bank balance. SMTP acceptance does not prove delivery or reading.

## Before activation

Verify test and live catalogs separately, SMTP, raw signed webhooks, account persistence after restart, checkout/card/trial/cancellation/refund behavior, the native device flow and the signed updater. Configure Stripe portal cancellation and customer receipts. Complete the durable contractual confirmation and statutory guarantee notice. Nathan confirmed VAT exemption and declined mediator affiliation on 12 November; consumer-sale compliance is not marked complete. Review distribution rights for runtime dependencies separately.

Only the public licence verification key belongs in the app. Stripe credentials, webhook secrets and signing private keys stay server-side. An official-client entitlement gate does not make public source code impossible to modify. No commercial release is activated by this preparation.
