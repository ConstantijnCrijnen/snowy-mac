# Voluntary support

Snowy downloads directly for $0. Positive amounts from the price sheet and wish
list use Polar hosted checkout. Card details stay on Polar; no payment SDK is
loaded in the browser. Production API requests and the webhook use `2026-10`.

The existing one-time custom USD Snowy product is configured by POLAR_PRODUCT_ID
in wrangler.jsonc. POLAR_ACCESS_TOKEN and POLAR_WEBHOOK_SECRET are encrypted
Cloudflare bindings, never source files or frontend variables.

## Routes

- POST /api/checkout: same-origin JSON only, exact integer cents from 0 to100000,
  allowlisted context and UUIDv4 request reference. Zero bypasses Polar. Product,
  currency, return URL and success URL are controlled by the server.
- GET /api/payment?ref=UUID: returns only checkout status, amount and context.
  It retrieves the session directly from Polar, verifies product/currency, and
  never returns customer or billing information. Only succeeded shows thanks.
- POST /api/webhooks/polar: validates the original body using Standard Webhooks,
  checks the signed timestamp, and deduplicates authenticated event IDs. No
  account entitlement is created: Snowy remains freely downloadable. Refunds
  and repeated events cannot revoke downloads or trigger duplicate fulfillment.

## Storage and failure handling

SQLite Durable Objects serialize checkout creation by request reference. A
retry returns the existing URL. A timeout of uncertain outcome never sends a
second provider request for the same reference. Changed amounts require a new
reference. The UI disables repeated submission and restores controls on failure.

Checkout references, provider session IDs and URLs expire after24hours. Webhook
IDs expire after7days. Shared rate buckets expire after60seconds:15checkout
requests and60status requests per client IP per minute. Only an IP hash is used
to name the bucket; raw IPs, card details, emails, names and webhook bodies are
not saved. Payment bookkeeping and refunds remain in the Polar dashboard.

The free download remains available during cancellation, processing, provider
outage, or validation failure. Return parameters alone never prove payment.

## Verification

Run npm ci --ignore-scripts, npm test, npm run check and npm run deploy:dry-run.
Tests cover amount tampering, origins, size limits, duplicate/concurrent checkout,
provider ambiguity, rate limits, verified status and signed/replayed webhooks.
Browser checks simulate a provider outage and verify the free fallback.

A live checkout can be opened without entering card details or completing a
purchase. No real charge should be made by an automated deployment check.

References: [Checkout API](https://polar.sh/docs/api-reference/2026-10/checkouts/create-checkout-session),
[Webhook validation](https://polar.sh/docs/integrate/webhooks/delivery).
