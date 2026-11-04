# Cloudflare deployment

Production is **https://snowy.aauburn.com**, served by the `snowy` Worker with
Cloudflare Static Assets. The Worker handles payment API routes and uses small SQLite Durable Objects
for checkout idempotency, rate buckets and webhook deduplication. Static files
still bypass Worker execution. There is no client analytics.

## Publish

Use Node.js 22 or later and an authorized Cloudflare account with access to the
active `aauburn.com` zone. The checked-in account ID is a public identifier,
not a credential.

```sh
cd website
npm ci
npx wrangler whoami
# Secrets must already exist: POLAR_ACCESS_TOKEN and POLAR_WEBHOOK_SECRET
npm test
npm run check
npm run deploy:dry-run
npm run deploy
```

Wrangler is pinned as a development dependency. The deploy command rebuilds
`dist` before upload. Authentication stays in Wrangler's local credential
store; never add tokens to this repository. For unattended deployments, use a
scoped account-owned API token in the CI secret store rather than committing
OAuth credentials.

`wrangler.jsonc` owns the exact `snowy.aauburn.com` Custom Domain. Cloudflare
manages its DNS and HTTPS certificate. It does not modify other hostnames or
any zone-wide settings. The `workers.dev` and version preview URLs are disabled.
The earlier private Sites preview remains a separate publication.

## Delivery behavior

- Only `dist` is uploaded, excluding its private build marker.
- `_headers` supplies the CSP, content-type protection, referrer policy, and
  disabled camera/microphone/geolocation permissions.
- Missing assets return 404; there is no application-shell fallback.
- ETag/revalidation caching keeps unversioned JavaScript, CSS, and audio current
  after deploys. The `no-transform` directive prevents zone-level automatic Web
  Analytics script injection on this site, without changing other hostnames.
  The small MP3 is loaded only after a user interaction.
- The free DMG is a public GitHub release asset and needs no checkout or login.

After deployment, verify the main page, JavaScript, SVG favicon, audio MIME/range
responses, a missing-file 404, and the $0 download. No app launch or performance
benchmark is part of deployment verification.

References: [Static Assets](https://developers.cloudflare.com/workers/static-assets/),
[Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/),
[asset headers](https://developers.cloudflare.com/workers/static-assets/headers/),
[automatic analytics injection](https://developers.cloudflare.com/web-analytics/faq/).
