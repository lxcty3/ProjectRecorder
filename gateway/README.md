# ProjectRecorder Cloud Gateway

This service reverse-proxies the mobile app's auth, REST, storage, functions,
and realtime traffic to the existing Supabase project. End users only need
access to the Cloudflare domain, not `supabase.co`.

Production gateway:

```text
https://projectrecorder-gateway-pages2.pages.dev
```

The app reads this address from `mobile/cloud-config.js`.

## Deploy

```powershell
cd gateway
npm install
npx wrangler login
npm run deploy:pages
```

The Worker deployment uses Cloudflare's newer Workers hosting:

```powershell
npm run deploy:worker
```

The anon key stays in the app. Supabase RLS remains the security boundary.
