# Pay what you want

Snowy is available for $0. The download window starts the DMG download directly
when the visitor chooses $0; no account, checkout, email, or payment method is
required. The wish list offers the same voluntary support choice after someone
has tried the app.

Payments are deliberately disconnected. Positive amounts show a clear message
and keep the free download available. Nothing is charged, submitted to Polar,
or saved as a pledge. There is no payment SDK, API token, or checkout URL in the
browser bundle.

## Frontend contract

`src/payments.js` is shared by the download and support forms:

- `parseAmount(raw)` accepts US dollar decimal strings with at most two decimal
  places. It returns integer cents, or an error. Scientific notation, signs,
  fractional cents, and ambiguous currency formatting are rejected.
- The current site policy accepts $0 through $1,000. This is a local product
  limit, not a statement about Polar's limits. One cent is accepted by the UI;
  a future checkout must also respect the configured product/provider minimum.
- `createPaymentIntent(raw, "download")` resolves $0 to the fixed GitHub DMG
  release URL. `"support"` with $0 returns `no-contribution` without a download.
- Every positive intent is `support-unavailable`, with `amountCents`, `currency:
  "usd"`, and the allowlisted context. It includes a user-facing message, not a
  checkout address. No function makes a network request.

## Connect Polar later

Use a one-time, USD, pay-what-you-want Snowy product. Polar supports custom
pricing with a minimum and a suggested amount. [Polar product documentation](https://polar.sh/docs/features/products)

Add an authenticated-to-Polar server endpoint such as `POST /api/checkout` only
when the owner is ready to accept payments. Store the organization access token,
product ID, and webhook secret as server runtime secrets. Never copy them into
static source, `dist/`, or a public environment variable.

The endpoint should:

1. Accept a small JSON body containing only `amountCents` and context. Require an
   integer amount from 1 through 100,000, allowlist `download` / `support`, and
   choose currency and product from server configuration. Repeat validation on
   the server; browser validation is not a trust boundary. Reject oversized
   bodies and cross-origin requests, and rate-limit checkout creation.
2. Create a Polar checkout using the configured product and the validated
   `amount` in cents. Confirm the product uses custom pricing: Polar ignores
   this amount for fixed and free products. Set fixed same-site success and
   return URLs, rather than accepting arbitrary redirect addresses from the
   browser. Use a persisted unique request key to make retries safe and avoid
   creating multiple checkouts for one submission. Return only the hosted
   checkout URL. [Polar checkout API](https://polar.sh/docs/api-reference/2026-10/checkouts/create-checkout-session)
3. Keep the $0 route entirely local and free of provider requests. Disable the
   form during a positive checkout request and restore it on cancellation or
   failure. Do not label a redirect, button click, or `confirmed` checkout as a
   successful payment. Retrieve the checkout on the server to establish its
   `succeeded` state before showing payment confirmation. A failed payment must
   never block the free download.
4. For durable support records, verify Polar's webhook signature against the
   original request bytes before parsing. Deduplicate event IDs, handle
   redeliveries and out-of-order events, and retain only the minimal necessary
   records. [Polar webhook delivery documentation](https://polar.sh/docs/integrate/webhooks/delivery)

Before activation, exercise sandbox success, cancellation, provider failure,
repeat submission, tampered amount/product/redirect fields, and duplicate or
invalid webhook deliveries. Update the CSP only for the final chosen integration
and approved provider origins; a hosted checkout does not require embedding a
payment form or third-party script in the desktop.

Official documentation checked November 5, 2026. No Polar account or product has
been created or connected by this change.
