# T3 Connect client research: Clerk sign-in, relay, DPoP, environment connect

Source: T3 Code repository at tag `v0.0.46-nightly.20261009.2861` (read-only research).
All citations are `path:line` relative to the repository root. Anything not confirmed in source is marked UNVERIFIED.
Some framework behavior is cited from the vendored Effect reference copy under `.repos/effect-smol`; the app actually depends on `effect@4.0.1` with a local patch (`patches/effect@4.0.1.patch`), so those citations are reference-quality, not proof of the installed build.

## 0. Key findings (short)

1. Interactive clients (desktop renderer, hosted web, mobile) sign in with Clerk and call `getToken({ template: "t3-relay", skipCache: true })` (`packages/shared/src/relayAuth.ts:84-89`, `apps/web/src/cloud/managedAuth.tsx:78`, `apps/mobile/src/features/cloud/CloudAuthProvider.tsx:136`). That Clerk session JWT is exchanged at `POST /v1/client/dpop-token` for a 30 minute relay DPoP access token.
2. The relay token exchange accepts ONLY a Clerk session JWT whose `aud` is the configured audience (`t3-code-relay`). It does not fall back to Clerk OAuth tokens (`infra/relay/src/http/Api.ts:1020-1025`). The OAuth fallback exists only for the Bearer endpoints such as `GET /v1/environments` (`infra/relay/src/http/Api.ts:307-344`, `1682-1698`). So the CLI OAuth client (`hzxSgY2cH10sDU2r`) can list environments but cannot get a relay DPoP token, and therefore cannot call `/v1/environments/:id/connect` or `/status`.
3. `client_id` on the relay is a closed set: `t3-mobile` or `t3-web` (`packages/contracts/src/relay.ts:747-750`). `t3-web` may request `environment:connect` and `environment:status`; `t3-mobile` additionally `mobile:registration` (`infra/relay/src/auth/RelayTokens.ts:63-73`). Desktop uses `t3-web` because its renderer is the web bundle (`apps/web/src/cloud/managedRelayLayer.ts:79-82`).
4. One P-256 DPoP key per client install is used for the relay and for every environment (`packages/client-runtime/src/authorization/service.ts:110`, `224-238`, `325-338`). Proofs are ES256 JWTs with `typ: "dpop+jwt"`, claims `htm`, `htu` (query and fragment stripped), `jti`, `iat`, optional `ath`. No `nonce`.
5. Connect flow: list (Bearer Clerk JWT) -> status (DPoP) -> connect (DPoP, body `clientKeyThumbprint`) -> one-time bootstrap credential (2 min) -> `POST {httpBaseUrl}/oauth/token` with DPoP proof -> environment DPoP access token (1 hour) -> `POST /api/auth/websocket-ticket` -> `wss://.../ws?wsTicket=...&orchestrationProtocol=2`.
6. There is no refresh token for environment access. When the environment token is within 60 s of expiry or is rejected, clients re-run the whole relay connect plus `/oauth/token` exchange (`packages/client-runtime/src/authorization/service.ts:381-466`).
7. Clerk redirect allowlists in the docs only cover the official apps: CLI loopback `http://127.0.0.1:34338/callback`, desktop `t3code://app/` and `t3code-dev://app/`, Android `clerk://com.t3tools.t3code[.dev|.preview].callback` (`docs/operations/connect-setup.md:42`, `65-70`, `80-86`). This is the main obstacle for a third-party native app.

---

## A. Build-time config plumbing and hard-coded values

### A.1 Canonical names and aliases

Root `.env.example` values (public identifiers, per comment at `.env.example:1-5`):

- `T3CODE_CLERK_PUBLISHABLE_KEY=pk_live_Y2xlcmsudDMuY29kZXMk` (`.env.example:9`)
- `T3CODE_CLERK_JWT_TEMPLATE=t3-relay` (`.env.example:10`)
- `T3CODE_CLERK_CLI_OAUTH_CLIENT_ID=hzxSgY2cH10sDU2r` (`.env.example:11`)
- `T3CODE_RELAY_URL=https://relay.t3.codes` (`.env.example:22`)
- `T3CODE_HOSTED_APP_URL` commented, default `https://app.t3.codes`, example `https://nightly.app.t3.codes` (`.env.example:24-26`)
- Optional passkey build vars `T3CODE_APPLE_TEAM_ID`, `T3CODE_MACOS_PROVISIONING_PROFILE`, `T3CODE_CLERK_PASSKEY_RP_DOMAINS` (`.env.example:13-18`)

Publishable key decoding: the Frontend API host is base64 of the part after `pk_live_`, with a trailing `$` removed: `Y2xlcmsudDMuY29kZXMk` -> `clerk.t3.codes$` -> `https://clerk.t3.codes` (`packages/shared/src/relayAuth.ts:31-78`).

Loader: `scripts/lib/public-config.ts`.
- Reads `.env` and `.env.local` at repo root and merges with the process env (`scripts/lib/public-config.ts:26-40`). Precedence for public values is process env, then `.env.local`, then `.env` (`scripts/lib/public-config.ts:35`, `106-169`; doc `docs/operations/connect-setup.md:25`).
- Accepted input names per value (first non-empty wins): publishable key `T3CODE_CLERK_PUBLISHABLE_KEY`, `VITE_CLERK_PUBLISHABLE_KEY`, `EXPO_PUBLIC_CLERK_PUBLISHABLE_KEY`; template `T3CODE_CLERK_JWT_TEMPLATE`, `VITE_CLERK_JWT_TEMPLATE`, `EXPO_PUBLIC_CLERK_JWT_TEMPLATE`; CLI client id `T3CODE_CLERK_CLI_OAUTH_CLIENT_ID`, `VITE_CLERK_CLI_OAUTH_CLIENT_ID`; relay `T3CODE_RELAY_URL`, `VITE_T3CODE_RELAY_URL` (`scripts/lib/public-config.ts:106-125`).
- Emitted aliases: `VITE_CLERK_PUBLISHABLE_KEY`, `EXPO_PUBLIC_CLERK_PUBLISHABLE_KEY` (`scripts/lib/public-config.ts:41-47`), `VITE_CLERK_JWT_TEMPLATE`, `EXPO_PUBLIC_CLERK_JWT_TEMPLATE` (`48-54`), `VITE_CLERK_CLI_OAUTH_CLIENT_ID` only (no Expo alias) (`55-60`), `VITE_T3CODE_RELAY_URL` (`61-66`), plus tracing aliases (`67-102`).
- `T3CODE_HOSTED_APP_URL` is not part of this loader; it is a server runtime value (see below).

### A.2 Per client

Web (also the desktop renderer, which is the same bundle served from `t3code://app`, `docs/internals/remote.md:100-102`):
- `apps/web/vite.config.ts:17`, `21-22` load repo env. Values: `apps/web/vite.config.ts:38-41`. Hosted app URL: explicit `VITE_HOSTED_APP_URL`, else Vercel production URL, else `VERCEL_URL` (`apps/web/vite.config.ts:47-59`). Baked with `define` (`apps/web/vite.config.ts:201-221`: relay `208`, publishable key `209`, template `210`, CLI client id `211-213`, hosted URL `219`, channel `220`). No runtime override.
- Consumed in `apps/web/src/cloud/publicConfig.ts:40-59` (relay URL normalized with `normalizeSecureRelayUrl`), `apps/web/src/cloud/connectCliAuth.ts:12-14`, `apps/web/src/hostedPairing.ts:13-15`, `apps/web/src/main.tsx:30`.
- Cloud is considered configured only when publishable key, JWT template and relay URL are all present (`apps/web/src/cloud/publicConfig.ts:72-75`).
- If the relay URL is missing, the runtime uses `http://relay.invalid`, which `normalizeSecureRelayUrl` rejects, producing a disabled relay client (`apps/web/src/lib/runtime.ts:16-18`, `packages/client-runtime/src/relay/managedRelay.ts:436-439`, `406-430`).

Desktop main process:
- Only the publishable key is baked, as `__T3CODE_BUILD_CLERK_PUBLISHABLE_KEY__` (`apps/desktop/vite.config.ts:7`, `17-21`, `57`). Used to derive the Clerk Frontend API host (`apps/desktop/src/app/DesktopClerk.ts:22`, `61-78`) for the renderer CSP (`apps/desktop/src/electron/ElectronProtocol.ts:71-81`).

Server and CLI (`t3`):
- Baked via `define`: `__T3CODE_BUILD_RELAY_URL__`, `__T3CODE_BUILD_CLERK_PUBLISHABLE_KEY__`, `__T3CODE_BUILD_CLERK_CLI_OAUTH_CLIENT_ID__` (`apps/server/vite.config.ts:113-131`).
- Runtime env overrides allowed: `T3CODE_RELAY_URL` (`apps/server/src/cloud/publicConfig.ts:98-105`), `T3CODE_HOSTED_APP_URL` default `DEFAULT_HOSTED_APP_URL` (`apps/server/src/cloud/publicConfig.ts:112-115`, validated as https origin or http loopback `117-143`), `T3CODE_CLERK_PUBLISHABLE_KEY` and `T3CODE_CLERK_CLI_OAUTH_CLIENT_ID` (`apps/server/src/cloud/publicConfig.ts:168-210`).

Mobile (Expo):
- `apps/mobile/app.config.ts:4`, `8-9` load repo env; values put into `extra`: `relay.url` from `T3CODE_RELAY_URL` (`apps/mobile/app.config.ts:469-471`), `clerk.publishableKey` and `clerk.jwtTemplate` from the `EXPO_PUBLIC_*` aliases (`472-475`), Google native client IDs `EXPO_PUBLIC_CLERK_GOOGLE_WEB_CLIENT_ID`, `_IOS_CLIENT_ID`, `_ANDROID_CLIENT_ID`, `_IOS_URL_SCHEME` (`476-484`).
- Read at runtime from `Constants.expoConfig.extra` (`apps/mobile/src/features/cloud/publicConfig.ts:59-74`); configured only if key, template and relay URL exist (`76-79`).

Relay deployment writes the relay URL back into the root `.env` (`infra/relay/src/clientConfig.ts:42-51`, `infra/relay/alchemy.run.ts:35-47`, doc `docs/operations/connect-setup.md:33-35`).

CI: release builds get the values from GitHub environment vars (`.github/workflows/release.yml:339-447`; relay URL is `https://$RELAY_DOMAIN` or `https://relay.$RELAY_API_ZONE_NAME` at `.github/workflows/release.yml:423-426`, `444-447`), passed to builds at `.github/workflows/release.yml:462-465`, `969-972`, `1046-1049`, `.github/workflows/release-desktop.yml:108-111`, `.github/workflows/desktop-macos-preview-publish.yml:226`.

### A.3 Hard-coded production hostnames, keys, client ids, redirect URIs

Searched apps, packages, infra, scripts, native, .github for `t3.codes`, `t3code.app`, `trycloudflare`, `pk_live`, `pk_test_`, `accounts.dev`, the client id, and the encoded key.

- No Clerk publishable key and no CLI OAuth client id are hard-coded in source code (only `.env.example` and tests).
- No `trycloudflare` and no `t3code.app` hostnames anywhere.
- The relay URL is not hard-coded in source (only `.env.example:22`).

Hard-coded values found:
- `packages/shared/src/connectAuth.ts:15` `DEFAULT_HOSTED_APP_URL = "https://app.t3.codes"`.
- `packages/shared/src/providerAuthReturnUrl.ts:8`, `11` allowed return origins `t3code:` / `t3code-dev:` with host `app`, and `https://app.t3.codes`.
- `apps/web/vercel.ts:3`, `5`, `6` `app.t3.codes`, `https://latest.app.t3.codes`, `https://nightly.app.t3.codes`.
- `apps/marketing/vercel.ts:31` redirect destination `https://app.t3.codes`.
- `apps/web/src/legalLinks.ts:1`, `apps/mobile/src/features/settings/lib/legal-document-url.ts:1` `https://t3.codes`.
- `apps/mobile/app.config.ts:80`, `88`, `96` `relyingParty: "clerk.t3.codes"`; schemes `t3code-dev`, `t3code-preview`, `t3code` (`77`, `85`, `93`); bundle ids `com.t3tools.t3code.dev`, `.preview`, `com.t3tools.t3code` (`78-79`, `86-87`, `94-95`); `appleTeamId: "ARK85ZXQ4Z"` (`258`); associated domains `applinks:clerk.t3.codes`, `webcredentials:clerk.t3.codes` (`259-262`); Expo updates URL `https://u.expo.dev/d763fcb8-d37c-41ea-a773-b54a0ab4a454` (`244`); Axiom traces default `https://api.axiom.co/v1/traces` (`486`); EAS project id (`491`).
- `apps/server/src/cloud/publicConfig.ts:21` CLI loopback port `34338`; redirect built as `http://127.0.0.1:${port}/callback` (`packages/shared/src/connectAuth.ts:85-87`).
- `apps/desktop/src/electron/ElectronProtocol.ts:15-17` `DESKTOP_HOST = "app"`, schemes `t3code`, `t3code-dev`; CSP allows `https://challenges.cloudflare.com` (`apps/desktop/src/electron/ElectronProtocol.ts:80`).
- `apps/server/src/http.ts:54` `DESKTOP_RENDERER_ORIGINS = ["t3code://app", "t3code-dev://app"]` (used only in dev CORS).
- macOS packaging registers URL schemes `t3code`, `t3code-dev` (`scripts/build-desktop-artifact.ts:2727-2732`; dev launcher `apps/desktop/scripts/electron-launcher.mjs:22`, `286`).
- Passkey RP domain for desktop builds is derived from the publishable key unless `T3CODE_CLERK_PASSKEY_RP_DOMAINS` is set; entitlement `webcredentials:<domain>` (`scripts/build-desktop-artifact.ts:1252-1268`, `1295-1297`).
- Relay naming: prod relay label `relay`, other stages `relay-<stage>` under `RELAY_API_ZONE_NAME` (`infra/relay/src/deploymentConfig.ts:75-86`, `infra/relay/src/zone.ts:22-46`); relay issuer is `https://<relayPublicDomain>` (`infra/relay/src/zone.ts:42`, `infra/relay/src/worker.ts:211-213`).
- Managed tunnel endpoints: hostname `<stage-slug>-<16 hex>.<RELAY_TUNNEL_ZONE_NAME>` (prod: `prod-<16hex>.<zone>`), `httpBaseUrl: "https://<host>/"`, `wsBaseUrl: "wss://<host>/ws"`, `providerKind: "cloudflare_tunnel"` (`infra/relay/src/deploymentConfig.ts:96-99`, `112-118`; README `infra/relay/README.md:104-111`). Tunnel name prefix `t3coderelay-managedendpoint` (`infra/relay/src/deploymentConfig.ts:6`). The production tunnel zone is not in source (only `tunnels.example.com` in `infra/relay/.env.example:6`): UNVERIFIED.
- Relay secrets/config names: `CLERK_SECRET_KEY`, `CLERK_PUBLISHABLE_KEY`, `CLERK_JWT_AUDIENCE` (`infra/relay/src/worker.ts:162-164`), example audience `t3-code-relay` (`infra/relay/.env.example:27`).
- Release workflow defaults `https://app.t3.codes`, `latest.app.t3.codes`, `nightly.app.t3.codes` (`.github/workflows/release.yml:1029`, `1101-1103`).
- Test fixtures: `rpId: "clerk.t3.codes"` (`apps/web/src/components/clerk/electronPasskeys.test.ts:7`), `clerk.t3.codes` (`packages/shared/src/relayAuth.test.ts:23-27`), `https://app.t3.codes` origin (`infra/relay/src/http/Api.test.ts:1391`).
- There is no wrangler config; the relay is deployed with Alchemy (`infra/relay/alchemy.run.ts:17-65`). OpenAPI is served at `/openapi.json` and Scalar docs at `/docs` (`infra/relay/src/worker.ts:440-443`), `/` redirects to `/docs` (`infra/relay/src/http/Api.ts:161-165`).

Redirect URI allowlists (docs, not code):
- CLI OAuth app: `http://127.0.0.1:34338/callback`, scopes `openid profile email offline_access`, device grant enabled (`docs/operations/connect-setup.md:37-48`).
- Desktop Native API SSO redirects: `t3code-dev://app/`, `t3code://app/`; Backend API `allowed_origins` gets `t3code-dev://app` / `t3code://app` (`docs/operations/connect-setup.md:63-76`).
- Android: `clerk://com.t3tools.t3code.dev.callback`, `clerk://com.t3tools.t3code.preview.callback`, `clerk://com.t3tools.t3code.callback` (`docs/operations/connect-setup.md:78-88`). iOS SSO callback is not documented: UNVERIFIED.
- JWT template `t3-relay` with claims `{ "aud": "t3-code-relay" }` (`docs/operations/connect-setup.md:50-61`).

---

## B. Clerk sign-in per client

### B.1 Desktop (Electron, `@clerk/electron` 0.0.44, `@clerk/electron-passkeys` 0.0.3, `pnpm-workspace.yaml:28-29`)

- Main process creates the bridge: `createClerkBridge({ storage: storage({ path: stateDir }), passkeys: true, renderer: { scheme: "t3code" | "t3code-dev", host: "app" } })` (`apps/desktop/src/app/DesktopClerk.ts:80-89`). The bridge holds the single-instance lock so OAuth deep-link callbacks reach the running app; secondary instances quit (`apps/desktop/src/app/DesktopClerk.ts:131-139`).
- `stateDir` is `~/.t3/userdata` (or `~/.t3/dev` in development, or `$T3 home/...` when configured) (`apps/desktop/src/app/DesktopStatePaths.ts:13-32`, `apps/desktop/src/app/DesktopEnvironment.ts:183-188`). Token persistence format and encryption inside `@clerk/electron/storage` are UNVERIFIED (package source not in repo). Doc: "The Clerk Electron integration handles token persistence and system-browser callback delivery" (`docs/operations/connect-setup.md:75-76`).
- Preload exposes the bridge: `exposeClerkBridge({ passkeys: true })` (`apps/desktop/src/preload.ts:10`, `33`).
- Renderer uses `ClerkProvider` from `@clerk/electron/react` with `passkeys` from `@clerk/electron/passkeys` (`apps/web/src/components/clerk/ElectronManagedAuthShell.tsx:1-25`), loaded lazily only in Electron (`apps/web/src/main.tsx:50-55`).
- Sign-in UI: Clerk prebuilt modal via `clerk.openSignIn(...)` (`apps/web/src/components/clerk/useT3ConnectAuthPrompt.tsx:6-12`). In Electron the redirect is the hash-routed root: `forceRedirectUrl` and `signUpForceRedirectUrl` = current URL with pathname `/` and empty search (`apps/web/src/components/clerk/authRedirect.ts:6-17`).
- The desktop `open-url` handler in `DesktopClerk` only handles provider (Codex) handoffs and settings returns (`apps/desktop/src/app/DesktopClerk.ts:141-199`); Clerk SSO callback handling is inside the bridge: UNVERIFIED.
- Passkeys: macOS associated domains `webcredentials:<Clerk FAPI host>` (`scripts/build-desktop-artifact.ts:1252-1297`), AASA must list `<TEAM_ID>.com.t3tools.t3code` (`docs/operations/connect-setup.md:90-99`). RP id `clerk.t3.codes` in tests (`apps/web/src/components/clerk/electronPasskeys.test.ts:7`).
- Relay token: `ManagedRelayAuthProvider` uses `useAuth({ treatPendingAsSignedOut: false })` (`apps/web/src/cloud/managedAuth.tsx:32-34`) and sets the session token provider `() => getToken(resolveRelayClerkTokenOptions())` (`apps/web/src/cloud/managedAuth.tsx:78`), i.e. `{ template: "t3-relay", skipCache: true }` (`apps/web/src/cloud/publicConfig.ts:77-83`, `packages/shared/src/relayAuth.ts:84-89`). How Clerk maps this to the Frontend API is UNVERIFIED (Clerk internals).
- Account change or sign-out: relay routes removed from saved environments and relay token cache reset (`apps/web/src/cloud/managedAuth.tsx:52-99`, `packages/client-runtime/src/connection/registry.ts:993-1013`).
- Refresh: the runtime caches the Clerk token until `exp - 5 s`, then calls the provider again (`packages/client-runtime/src/relay/managedRelayState.ts:24-26`, `78-144`). Same-account token-reader updates keep the session object (`packages/client-runtime/src/relay/managedRelayState.ts:146-167`). Clerk's own background session refresh is UNVERIFIED.

### B.2 Mobile (Expo, `@clerk/expo` 4.6.8 with patch, `pnpm-workspace.yaml:30`, `patches/@clerk__expo@4.6.8.patch`)

- `ClerkProvider publishableKey={...} tokenCache={tokenCache}` with `tokenCache` from `@clerk/expo/token-cache` (`apps/mobile/src/features/cloud/CloudAuthProvider.tsx:1-2`, `198-217`). `expo-secure-store` plugin installed (`apps/mobile/app.config.ts:344`). That the token cache uses SecureStore is UNVERIFIED (Clerk internals).
- Sign-in UI: Clerk native prebuilt views `AuthView` and `UserProfileView` from `@clerk/expo/native` (`apps/mobile/src/features/settings/SettingsAuthRouteScreen.tsx:1-2`, `50-63`). The patch shows the iOS side is Clerk's native Swift bridge (`ClerkNativeBridge.swift`, `ClerkAuthNativeView.swift`) (`patches/@clerk__expo@4.6.8.patch`).
- Methods hinted in config: Sign in with Apple entitlement via `["@clerk/expo", { appleSignIn: !isIosPersonalTeamBuild }]` (`apps/mobile/app.config.ts:357-359`); native Google sign-in client ids (`apps/mobile/app.config.ts:476-484`); passkeys via `webcredentials:clerk.t3.codes` (`apps/mobile/app.config.ts:259-262`) with team `ARK85ZXQ4Z` (`258`). Which strategies are actually enabled (email code, GitHub, etc.) is a Clerk dashboard setting: UNVERIFIED.
- Redirects: Android `clerk://<applicationId>.callback` (`docs/operations/connect-setup.md:78-88`); navigation schemes `t3code-dev` / `t3code-preview` / `t3code` are separate (`docs/operations/connect-setup.md:88`). iOS SSO callback: UNVERIFIED.
- Relay token: `getToken(resolveRelayClerkTokenOptions())` (`apps/mobile/src/features/cloud/CloudAuthProvider.tsx:136`, `apps/mobile/src/features/cloud/publicConfig.ts:99-105`).

### B.3 Web (hosted app.t3.codes, `@clerk/react` 6.16.1)

- `ClerkProvider` from `@clerk/react` (hotloads clerk-js) (`apps/web/src/components/clerk/BrowserManagedAuthShell.tsx:1-25`), lazily loaded (`apps/web/src/main.tsx:50-55`).
- Sign-in modal `clerk.openSignIn({ forceRedirectUrl: href, signUpForceRedirectUrl: href })` (`apps/web/src/components/clerk/authRedirect.ts:18-20`), `UserButton` with custom T3 Connect pages (`apps/web/src/components/clerk/T3ConnectSidebarSignIn.tsx:27-45`). Session storage in the browser is clerk-js internal: UNVERIFIED.
- Hosted `/connect` page for the CLI loopback flow:
  - Route enabled only when hosted, cloud configured and CLI client id configured (`apps/web/src/cloud/connectCliAuth.ts:27-29`, `apps/web/src/routes/connect.tsx:6-13`; rendered without app chrome `apps/web/src/routes/__root.tsx:162-169`).
  - Reads `state`, `challenge`, `port` from the URL fragment (`packages/shared/src/connectAuth.ts:3-8`, `62-79`).
  - If signed out, opens Clerk sign-in with `forceRedirectUrl` set to the Clerk authorize URL itself (`apps/web/src/cloud/connectCliAuth.ts:63-68`, `apps/web/src/components/cloud/ConnectCliAuthSurface.tsx:54-75`). If signed in, `window.location.assign(authorizeUrl)` (`apps/web/src/components/cloud/ConnectCliAuthSurface.tsx:77-82`).
  - Authorize URL: `https://clerk.t3.codes/oauth/authorize?client_id=<CLI id>&redirect_uri=http://127.0.0.1:<port>/callback&response_type=code&scope=openid profile email offline_access&state=<state>&code_challenge=<challenge>&code_challenge_method=S256` (`apps/web/src/cloud/connectCliAuth.ts:37-51`, `packages/shared/src/connectAuth.ts:89-106`, scopes `packages/shared/src/connectAuth.ts:22`).

### B.4 CLI (`apps/server/src/cloud/CliTokenManager.ts`, `apps/server/src/cli/connect.ts`)

Config: token endpoint `https://clerk.t3.codes/oauth/token`, device endpoint `https://clerk.t3.codes/oauth/device_authorization`, client id, loopback port `34338`, redirect `http://127.0.0.1:34338/callback`, scopes `["openid","profile","email","offline_access"]` (`apps/server/src/cloud/publicConfig.ts:21-22`, `159-210`).

Loopback authorization code + PKCE (`apps/server/src/cloud/CliTokenManager.ts:459-526`):
1. `verifier = base64url(32 random bytes)`, `challenge = base64url(SHA-256(verifier))`, `state = base64url(16 random bytes)` (`apps/server/src/cloud/CliTokenManager.ts:300-308`; base64url is unpadded per `.repos/effect-smol/packages/effect/src/encoding/Base64Url.ts:40-41`).
2. HTTP server on `127.0.0.1:34338`, route `GET /callback`; rejects if `state` mismatches or `code` missing (400 text), else returns an HTML "You're connected" page (`apps/server/src/cloud/CliTokenManager.ts:464-492`, `apps/server/src/cloud/cliAuthHtml.ts:15-150`).
3. Prints `https://app.t3.codes/connect#state=<s>&challenge=<c>&port=34338` (`packages/shared/src/connectAuth.ts:47-60`, `apps/server/src/cloud/CliTokenManager.ts:497-503`). Enter opens a browser; `H` switches to headless (`apps/server/src/cloud/CliTokenManager.ts:49-57`, `63-119`). Callback wait timeout 10 minutes (`apps/server/src/cloud/CliTokenManager.ts:40`, `506-511`).
4. Token exchange `POST /oauth/token` form fields `grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, `code_verifier` (`apps/server/src/cloud/CliTokenManager.ts:518-524`, `288-298`). Response schema `{ access_token, refresh_token?, id_token?, expires_in, token_type }` (`apps/server/src/cloud/CliTokenManager.ts:133-139`). Identity is read best-effort from the `id_token` (`email`, `preferred_username`, `sub`) (`apps/server/src/cloud/CliTokenManager.ts:155-181`).

Device authorization grant (`apps/server/src/cloud/CliTokenManager.ts:385-416`):
1. `POST https://clerk.t3.codes/oauth/device_authorization` form `client_id`, `scope="openid profile email offline_access"`.
2. Response `{ device_code, user_code, verification_uri, verification_uri_complete?, expires_in, interval? }` (`apps/server/src/cloud/CliTokenManager.ts:146-153`). Prompt text at `apps/server/src/cli/connect.ts:77-90`. The verification URI value is Clerk's: UNVERIFIED.
3. Poll `POST /oauth/token` form `grant_type=urn:ietf:params:oauth:grant-type:device_code`, `device_code`, `client_id`; first wait = `interval` or 5 s; `authorization_pending` continue; `slow_down`, transport errors and 5xx add 5 s; `expired_token` timeout; `access_denied` denied; others error; whole loop bounded by `expires_in` (`apps/server/src/cloud/CliTokenManager.ts:42-46`, `327-376`, `409-414`).
4. Headless is chosen with `--headless`, with `H` at the prompt, or automatically when `SSH_CONNECTION` or `SSH_TTY` is set (`apps/server/src/cli/connect.ts:57`, `67-72`, `93-129`).

Refresh and storage:
- Persisted JSON `{ accessToken, refreshToken, expiresAtEpochMs, identity? }` (`apps/server/src/cloud/CliTokenManager.ts:121-127`) under secret name `cloud-cli-oauth-token` (`apps/server/src/cloud/CliTokenManager.ts:39`, `431-445`), stored as `<stateDir>/secrets/cloud-cli-oauth-token.bin` with dir mode 0700 and file mode 0600 (`apps/server/src/auth/ServerSecretStore.ts:161-172`, `204-237`, `apps/server/src/config.ts:166`). Not encrypted beyond file permissions (no encryption code seen in that store: UNVERIFIED for completeness).
- Refresh when `expiresAtEpochMs - 5 min <= now`: `POST /oauth/token` form `grant_type=refresh_token`, `refresh_token`, `client_id` (`apps/server/src/cloud/CliTokenManager.ts:41`, `447-457`, `528-536`). A failed refresh falls through to a new login (`apps/server/src/cloud/CliTokenManager.ts:550-572`).

How the CLI uses the OAuth token with the relay: only Bearer endpoints, never `/v1/client/dpop-token`:
- `POST /v1/client/environment-link-challenges`, `POST /v1/client/environment-links` (`apps/server/src/cloud/CloudLink.ts:887-932`), `DELETE /v1/client/environment-links/:id` (`apps/server/src/cli/connect.ts:324-347`), `DELETE /v1/client/environment-links/:id/tunnel` (`apps/server/src/cloud/CloudLink.ts:1259-1280`).

### B.5 How the relay verifies subject tokens

- Bearer endpoints (`RelayClientAuth`): `verifyRelayClientBearerToken` first tries `verifyToken(token, { secretKey, audience: CLERK_JWT_AUDIENCE })` plus an explicit `aud` check, mode `clerk_session_bearer`; on failure falls back to `createClerkClient(...).authenticateRequest(new Request(relayIssuer, { headers: { authorization: "Bearer <token>" } }), { acceptsToken: "oauth_token" })`, mode `clerk_oauth_bearer` (`infra/relay/src/http/Api.ts:307-344`, `1638-1698`; tests `infra/relay/src/http/Api.test.ts:190-244`). Not `/oauth/userinfo`; what `authenticateRequest` calls internally is UNVERIFIED.
- Token exchange `POST /v1/client/dpop-token`: only `verifyClerkBearerToken` plus `hasExpectedClerkAudience` (`infra/relay/src/http/Api.ts:1020-1025`, `1631-1636`). No OAuth fallback. A Clerk OAuth access token would only pass if Clerk issued it as a JWT verifiable by `verifyToken` with `aud` equal to `t3-code-relay`; nothing in source configures that: UNVERIFIED and unlikely.
- The doc statement "The relay accepts both session-template JWTs and CLI OAuth tokens" (`docs/internals/t3-connect.md:157-162`) refers to the Bearer path.

### B.6 Options for a native macOS app (analysis from source)

Option (a): ASWebAuthenticationSession + Clerk OAuth (CLI client `hzxSgY2cH10sDU2r`) with PKCE.
- Endpoints work as in B.4. The only allowlisted redirect is `http://127.0.0.1:34338/callback` (`docs/operations/connect-setup.md:42`). A native app must run its own listener on that port (collides with a running `t3 connect`) or use the device grant (no redirect). Whether ASWebAuthenticationSession can complete on an http loopback redirect is an Apple API question: UNVERIFIED.
- Signed-out browsers lose authorize parameters across Clerk sign-in, which is why the CLI goes through the hosted `/connect` page (`docs/internals/t3-connect.md:164-168`, `packages/shared/src/connectAuth.ts:34-46`).
- Result is usable for `GET /v1/environments` and `GET /v2/client/devices` and link/unlink, but NOT for `POST /v1/client/dpop-token` (B.5). Without a relay DPoP token there is no `/connect` or `/status`. Blocker for connecting.

Option (b): Clerk Frontend API session on `clerk.t3.codes` (like desktop/mobile), then a `t3-relay` template token.
- This is the only path the relay accepts for DPoP exchange.
- Native API is enabled per the runbook (`docs/operations/connect-setup.md:65`). A Swift app would use Clerk's iOS SDK or raw FAPI with the publishable key. macOS support of Clerk's Swift SDK and the FAPI native protocol details are UNVERIFIED (not in repo).
- Constraints: OAuth/SSO redirect must be allowlisted (only official schemes listed); passkeys need the app's `TEAMID.bundleid` in the AASA of `clerk.t3.codes`; native Apple/Google sign-in configs are tied to the official bundle ids (`apps/mobile/app.config.ts:357-359`, `476-484`). Email code or password strategies need no redirect and are the most plausible third-party path if enabled: UNVERIFIED. Bot protection (Cloudflare Turnstile) may be required, hinted by the desktop CSP allowing `https://challenges.cloudflare.com` (`apps/desktop/src/electron/ElectronProtocol.ts:80`): UNVERIFIED.

Option (c): Direct pairing without Clerk (not T3 Connect).
- Pairing URL carries a one-time token in the fragment `#token=` (`packages/shared/src/remote.ts:3`, `144-170`; hosted form `https://app.t3.codes/pair?host=...&label=...#token=...` `apps/web/src/hostedPairing.ts:73-87`).
- Exchange `POST {httpBaseUrl}/oauth/token` without DPoP -> Bearer token, 30 day session (`packages/client-runtime/src/authorization/remote.ts:115-140`, `apps/server/src/auth/EnvironmentAuth.ts:908-918`, `apps/server/src/auth/SessionStore.ts:432`). One-time tokens default to 5 minute TTL (`apps/server/src/auth/PairingGrantStore.ts:254`).
- Bearer tokens are not origin bound (`docs/internals/remote.md:46-53`), so they should work on any URL that reaches the same environment, including a tunnel URL if known: UNVERIFIED in practice.

---

## C. Relay usage from clients

Shared implementation: `packages/client-runtime/src/relay/managedRelay.ts` (Effect `HttpApiClient` generated from `RelayApi`, `packages/client-runtime/src/relay/managedRelay.ts:441`). Base URL is the relay origin from `normalizeSecureRelayUrl` (https only, no path, query, fragment or credentials, returns `url.origin`) (`packages/shared/src/relayUrl.ts:1-18`, `packages/client-runtime/src/relay/managedRelay.ts:436`).

Common behavior:
- Timeout 10 s per request (`packages/client-runtime/src/relay/managedRelay.ts:225`, `336-362`). Relay server deadline 9 s, returning `504 {"error":"relay_request_deadline_exceeded"}` (`infra/relay/src/http/Api.ts:174`, `182-213`).
- Errors decode as `RelayProtectedError` with JSON like `{"_tag":"RelayAuthInvalidError","code":"auth_invalid","reason":"invalid_bearer","traceId":"..."}` (`packages/contracts/src/relay.ts:392-609`; example in `packages/client-runtime/src/relay/managedRelay.test.ts:413-419`), wrapped in `ManagedRelayRequestFailedError { action, transportFailed?, relayError?, traceId? }` (`packages/client-runtime/src/relay/managedRelay.ts:145-159`, `309-318`).
- Relay sets `cache-control: no-store`, `pragma: no-cache` on credential responses (`infra/relay/src/http/Api.ts:95-103`), `www-authenticate: DPoP` on 401 for DPoP endpoints (`infra/relay/src/http/Api.ts:105-111`, `385`), and a `traceparent` response header (`infra/relay/src/http/Api.ts:113-125`).
- CORS: any origin (`*`), methods `GET, POST, DELETE, OPTIONS`, headers `authorization, b3, traceparent, content-type, dpop`, exposed `traceparent, www-authenticate`, max age 86400 (`infra/relay/src/http/Api.ts:127-153`; test `infra/relay/src/http/Api.test.ts:1385`, `1390-1420`).
- Effect's HTTP client propagates `b3` and `traceparent` request headers by default (`.repos/effect-smol/packages/effect/src/http/HttpTraceContext.ts:44-53`, `.repos/effect-smol/packages/effect/src/http/HttpClient.ts:745-746`). Not required by the relay.

### C.1 Calls

1. `POST /v1/client/dpop-token` (token exchange, no auth middleware) (`packages/contracts/src/relay.ts:1111-1129`)
   - Headers: `dpop: <proof>` required (`packages/contracts/src/relay.ts:784-786`). Proof: `htm=POST`, `htu=https://relay.t3.codes/v1/client/dpop-token`, no `ath` (`packages/client-runtime/src/relay/managedRelay.ts:449-453`, `493-499`).
   - Body `application/x-www-form-urlencoded` (`HttpApiSchema.asFormUrlEncoded`, `packages/contracts/src/relay.ts:752-769`):
     - `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`
     - `subject_token=<Clerk t3-relay session JWT>`
     - `subject_token_type=urn:ietf:params:oauth:token-type:jwt`
     - `requested_token_type=urn:ietf:params:oauth:token-type:access_token`
     - `resource=https://relay.t3.codes` (must equal the relay issuer with trailing slashes stripped, `infra/relay/src/http/Api.ts:1006`, `1016-1018`, `packages/shared/src/relayJwt.ts:43-45`)
     - `scope=<space separated>` (e.g. `environment:status environment:connect`)
     - `client_id=t3-web | t3-mobile`
     (`packages/client-runtime/src/relay/managedRelay.ts:500-516`). Exact form encoding of spaces is Effect's: UNVERIFIED.
   - Response `{ "access_token": "...", "issued_token_type": "urn:ietf:params:oauth:token-type:access_token", "token_type": "DPoP", "expires_in": 1800, "scope": "..." }` (`packages/contracts/src/relay.ts:771-778`, `infra/relay/src/http/Api.ts:1034-1050`, TTL `infra/relay/src/auth/RelayTokens.ts:29`).
   - Client requires the returned scope set to equal the requested set (`packages/client-runtime/src/relay/managedRelay.ts:517-522`, `packages/shared/src/oauthScope.ts:54-61`).
   - Failure modes: bad `resource`, unknown or disallowed scope for the client id -> 401 `auth_invalid` with `reason: "invalid_dpop"`, `dpopFailureReason: "invalid_proof"` (misleading label) (`infra/relay/src/http/Api.ts:1016-1018`, `1513-1527`); bad Clerk token -> 401 `reason: "invalid_bearer"` (`1020-1025`); bad proof -> 401 `invalid_dpop` with mapped `dpopFailureReason` (`1464-1485`, `1498-1512`). Unknown `client_id` fails schema decoding (`packages/contracts/src/relay.ts:747`, `765`); exact status UNVERIFIED.
   - Relay token claims: `{ iss, aud: iss, sub: <Clerk user id>, jti, iat, exp, client_id, scope, cnf: { jkt } }`, EdDSA, `typ: "t3-relay-dpop-access+jwt"` (`infra/relay/src/auth/RelayTokens.ts:27`, `45-55`, `168-186`, `packages/shared/src/relayJwt.ts:55-69`). Verified with max age 30 min (`infra/relay/src/auth/RelayTokens.ts:188-216`).

2. `GET /v1/environments` (`packages/contracts/src/relay.ts:1055-1059`)
   - Headers: `authorization: Bearer <Clerk JWT or Clerk OAuth token>` (`packages/client-runtime/src/relay/managedRelay.ts:395-397`, `713-725`).
   - Response `{ "environments": [ { "environmentId": "<uuid>", "label": "<label or environmentId>", "endpoint": { "httpBaseUrl": "https://<host>/", "wsBaseUrl": "wss://<host>/ws", "providerKind": "manual" | "cloudflare_tunnel" | "t3_relay" }, "linkedAt": "<ISO>" } ] }` (`packages/contracts/src/relay.ts:158-170`, `701-712`, `infra/relay/src/environments/EnvironmentLinks.ts:277-304`). Includes publish-only links (`providerKind: "manual"`) which cannot be connected (`infra/relay/src/environments/EnvironmentConnector.ts:322-327`).
   - Environment ids are UUID v4 strings (`apps/server/src/environment/ServerEnvironment.ts:155-177`).

3. `POST /v1/environments/:environmentId/status` (`packages/contracts/src/relay.ts:1145-1156`)
   - Headers: `authorization: DPoP <relay token>`, `dpop: <proof htm=POST htu=https://relay.t3.codes/v1/environments/<id>/status ath=...>` (`packages/client-runtime/src/relay/managedRelay.ts:399-404`, `786-811`). No body.
   - Scopes requested by clients: `["environment:status","environment:connect"]` (`packages/client-runtime/src/relay/managedRelayState.ts:403-407`, `packages/client-runtime/src/relay/discovery.ts:156-161`).
   - Response `{ environmentId, endpoint, status: "online" | "offline", checkedAt, descriptor?, error?, offlineReason?: "tunnel_released", traceId? }` (`packages/contracts/src/relay.ts:823-844`). The relay probes `POST {httpBaseUrl}/api/t3-connect/health` with a signed proof, 10 s timeout; offline results include `error` and `offlineReason` when the tunnel was released (`infra/relay/src/environments/EnvironmentConnector.ts:131`, `170-173`, `426-573`).
   - Client validates `environmentId`, the full endpoint, and descriptor id against the listed record (`packages/client-runtime/src/relay/managedRelayState.ts:254-280`, `packages/client-runtime/src/relay/discovery.ts:57-93`).

4. `POST /v1/environments/:environmentId/connect` (`packages/contracts/src/relay.ts:1131-1143`)
   - Headers: `authorization: DPoP <relay token>`, `dpop: <proof htm=POST htu=.../connect ath=...>`; JSON body.
   - Body sent by official clients: `{ "deviceId"?: "<uuid>", "clientKeyThumbprint": "<jkt>" }` (deprecated alias field) (`packages/client-runtime/src/relay/managedRelay.ts:812-843`). Relay accepts `clientKeyThumbprint` or `clientProofKeyThumbprint`; if both present they must match; the value must equal the token's `cnf.jkt` (`infra/relay/src/http/Api.ts:1070-1074`, `1592-1605`; schema `packages/contracts/src/relay.ts:714-731`).
   - Scopes: `["environment:connect"]` (`packages/client-runtime/src/authorization/service.ts:290-297`).
   - `deviceId`: mobile sends the UUID from SecureStore key `t3code.agent-awareness.device-id` (`apps/mobile/src/connection/platform.ts:199-213`, `apps/mobile/src/persistence/mobile-storage.ts:17`, `191-200`); web and desktop send none (`apps/web/src/connection/platform.ts:262-264`). The relay uses it only for tracing and the mint proof (`infra/relay/src/environments/EnvironmentConnector.ts:578-579`, `638`).
   - Response `{ "environmentId", "endpoint": { "httpBaseUrl", "wsBaseUrl", "providerKind" }, "credential": "<one-time bootstrap>", "expiresAt": "<ISO>" }` (`packages/contracts/src/relay.ts:815-821`, `infra/relay/src/environments/EnvironmentConnector.ts:698-703`). Credential TTL 2 minutes (`apps/server/src/cloud/CloudLink.ts:1619-1625`).
   - Errors: 403 `environment_connect_not_authorized` with optional `reason` from `client_proof_key_thumbprint_missing`, `environment_link_not_found`, `endpoint_provider_not_managed`, `managed_endpoint_allocation_not_found`, `managed_endpoint_base_domain_not_configured`, `managed_endpoint_allocation_not_ready`, `managed_endpoint_hostname_invalid`, `managed_endpoint_mismatch`; 502 `environment_endpoint_unavailable` (`endpoint_request_failed`, `endpoint_response_invalid`); 504 `environment_endpoint_timed_out` (`packages/contracts/src/relay.ts:454-510`, `infra/relay/src/http/Api.ts:1087-1110`).

5. Other Bearer endpoints: `GET /v2/client/devices` (web lists devices) (`packages/client-runtime/src/relay/managedRelay.ts:726-740`), `POST /v1/client/environment-link-challenges` (challenge valid 5 min, `infra/relay/src/http/Api.ts:933-954`), `POST /v1/client/environment-links`, `DELETE /v1/client/environment-links/:id` (Deregister) returning `{ "ok": boolean }` (`packages/client-runtime/src/relay/managedRelay.ts:741-785`, `packages/contracts/src/relay.ts:1053-1109`).

6. Mobile-only DPoP endpoints with scope `mobile:registration` and `client_id=t3-mobile`: `POST /v1/mobile/devices`, `POST /v1/mobile/live-activities`, `GET /v1/mobile/agent-activity`, `DELETE /v1/mobile/devices/:deviceId` (`packages/contracts/src/relay.ts:992-1051`, `packages/client-runtime/src/relay/managedRelay.ts:694-709`, `844-930`).

7. Discovery metadata (no auth): `GET /.well-known/oauth-authorization-server` -> `{ issuer, token_endpoint: issuer + "/v1/client/dpop-token", grant_types_supported: ["urn:ietf:params:oauth:grant-type:token-exchange"], token_endpoint_auth_methods_supported: ["none"], dpop_signing_alg_values_supported: ["ES256"], scopes_supported: ["environment:connect","environment:status","mobile:registration"] }`; `GET /.well-known/oauth-protected-resource` -> `{ resource: issuer, authorization_servers: [issuer], scopes_supported, dpop_bound_access_tokens_required: true, dpop_signing_alg_values_supported: ["ES256"] }` (`infra/relay/src/http/Api.ts:426-458`).

### C.2 Relay DPoP token caching and retry

- Cache entry `{ accountId, clientId, relayUrl, thumbprint, scopes, accessToken, expiresAtMillis }` (`packages/client-runtime/src/relay/managedRelay.ts:227-235`). `accountId` is the Clerk JWT `sub` decoded locally (`packages/client-runtime/src/relay/managedRelay.ts:385-393`).
- Reuse rule: same account, client id, relay URL, key thumbprint, `expiresAtMillis > now + 5000`, and cached scopes include all requested scopes (`packages/client-runtime/src/relay/managedRelay.ts:364-383`). `expiresAtMillis = now + expires_in * 1000` (`packages/client-runtime/src/relay/managedRelay.ts:592-600`).
- On 401 `RelayAuthInvalidError` with `reason: "invalid_bearer"` from a DPoP endpoint, the cached token is dropped and the request retried once (`packages/client-runtime/src/relay/managedRelay.ts:328-334`, `655-692`).
- Web and desktop: memory only (no store passed, `apps/web/src/cloud/managedRelayLayer.ts:79-82`, `packages/client-runtime/src/relay/managedRelay.ts:442`). Mobile: persisted in SecureStore key `t3code.cloud.relay-access-tokens` as `{"version":1,"entries":[...]}` (`apps/mobile/src/features/cloud/managedRelayTokenStore.ts:6-26`, `119-133`, `apps/mobile/src/features/cloud/managedRelayLayer.ts:67-72`). Stored entries for the other client id are ignored on load (`packages/client-runtime/src/relay/managedRelay.ts:442-445`).
- Query refresh: SWR stale 15 s, idle TTL 5 min for environment list, device list, status (`packages/client-runtime/src/relay/managedRelayState.ts:24-25`, `340-420`). Discovery refreshes on sign-in (`credentials-changed` wakeup) and when connectivity returns (`packages/client-runtime/src/relay/discovery.ts:313-345`). Web polls every 5 s while the list is empty in onboarding (`apps/web/src/components/cloud/CloudEnvironmentConnectList.tsx:40`, `237-279`).
- Connection retry policy (supervisor): exponential backoff with jitter from 1 s up to 5 min, reset after 30 s connected; establishment timeout 15 s (`packages/client-runtime/src/connection/supervisor.ts:35-49`; doc `docs/internals/connection-runtime.md:9-17`).

### C.3 Error mapping in clients

- `relayProtectedErrorMessage` (`packages/client-runtime/src/relay/errorPresentation.ts:24-66`): `invalid_bearer` -> "Relay rejected the cloud session token."; `invalid_dpop` -> "Relay rejected the DPoP proof." plus clock hint for `time_window` (`packages/client-runtime/src/relay/errorPresentation.ts:4-22`); `environment_link_not_found` -> "Relay has no active link for this environment. The environment server may not have re-established its link yet."; other not-authorized reasons -> "Relay rejected the environment connection request (<reason>)." (`packages/client-runtime/src/relay/errorPresentation.ts:40-48`).
- Connection error classes (`packages/client-runtime/src/connection/errors.ts:37-113`): `RelayAuthInvalidError` -> blocked `authentication`; `RelayEnvironmentConnectNotAuthorizedError` -> blocked `permission`; timeout -> transient `timeout`; endpoint unavailable -> transient `endpoint-unavailable`; internal -> transient `relay-unavailable`.

---

## D. DPoP on the client

### D.1 Shared helpers

- `packages/shared/src/dpopCommon.ts:3-8` JWK schema `{ kty: "EC", crv: "P-256", x, y }`; `normalizeDpopHtu` = `new URL(url)`, clear `hash` and `search`, `toString()` (`packages/shared/src/dpopCommon.ts:11-20`).
- `packages/shared/src/dpop.ts`: `typ "dpop+jwt"`, `alg "ES256"`, default max age 300 s (`12-14`); header schema forbids `d` in `jwk` (`33-44`); payload schema `htm`, `htu`, `jti` non-empty strings, `iat` integer, `ath` optional (`47-55`); thumbprint (`83-94`); `ath = base64url(SHA-256(access token))` (`96-98`); verifier (`113-199`).
- Thumbprint input is sorted-key compact JSON `{"crv":"P-256","kty":"EC","x":"...","y":"..."}` via `stableStringify` (`packages/shared/src/relaySigning.ts:5-17`), SHA-256, unpadded base64url. This matches RFC 7638 for EC keys.
- Signer interface used everywhere: `ManagedRelayDpopSigner { thumbprint, createProof({ method, url, accessToken? }) }` (`packages/client-runtime/src/relay/managedRelay.ts:49-53`, `215-223`).

### D.2 Web and desktop renderer (`apps/web/src/cloud/dpop.ts`, `apps/web/src/cloud/managedRelayLayer.ts`)

- Key: WebCrypto `generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign","verify"])`, private key exported to JWK and re-imported with `jose.importJWK(..., "ES256", { extractable: false })`; public JWK decoded to `{kty, crv, x, y}` (`apps/web/src/cloud/dpop.ts:110-143`).
- Persistence: IndexedDB database `t3code:cloud-auth` version 1, store `keys`, key `relay-dpop-proof-key`, value `{ privateKey: CryptoKey, publicJwk, thumbprint }` (`apps/web/src/cloud/dpop.ts:13-17`, `24-27`, `64-108`). Loaded once per runtime under a semaphore (`apps/web/src/cloud/managedRelayLayer.ts:16-37`). Desktop renderer IndexedDB belongs to the `t3code://app` origin.
- Proof: `jose.SignJWT({ htm: method.toUpperCase(), htu, jti, ath? }).setProtectedHeader({ typ: "dpop+jwt", alg: "ES256", jwk: publicJwk }).setIssuedAt()` (`apps/web/src/cloud/dpop.ts:145-185`); `htu` from `new URL(url)` with `search` and `hash` cleared (`156-161`); `jti` is UUID v4 (`162-165`).

### D.3 Mobile (`apps/mobile/src/features/cloud/dpop.ts`, `apps/mobile/src/features/cloud/managedRelayLayer.ts`)

- Key: random 32-byte scalar from `expo-crypto`, validated with `@noble/curves` p256, public key from the uncompressed point (`apps/mobile/src/features/cloud/dpop.ts:149-192`). Not Secure Enclave.
- Persistence: SecureStore key `t3code.cloud.dpop-proof-key`, value private JWK JSON `{ kty, crv, x, y, d }`; on load the public key is recomputed and must match (`apps/mobile/src/features/cloud/dpop.ts:23-30`, `89`, `194-237`). Cached for the app lifetime (`apps/mobile/src/features/cloud/managedRelayLayer.ts:13-26`).
- Thumbprint input `JSON.stringify({ crv, kty, x, y })` (same bytes as shared) (`apps/mobile/src/features/cloud/dpop.ts:112-128`).
- Proof: header `{ typ: "dpop+jwt", alg: "ES256", jwk }`, payload `{ htm, htu, jti, iat: floor(now/1000), ath? }`, signature `p256.sign(SHA-256(header.payload), d, { prehash: false }).toCompactRawBytes()` (64-byte r||s) (`apps/mobile/src/features/cloud/dpop.ts:246-302`).

### D.4 Verification rules (relay and environment use the same verifier)

- Header `typ` exactly `dpop+jwt`, `alg` exactly `ES256`, `jwk` is EC P-256 with 32-byte `x`/`y` and no `d` (`packages/shared/src/dpop.ts:33-44`, `100-111`).
- Thumbprint must equal the expected one when given (`packages/shared/src/dpop.ts:141-144`).
- `htm` compared case-insensitively to the request method (`packages/shared/src/dpop.ts:145-147`).
- `htu` must equal `normalizeDpopHtu(requestUrl)` exactly (`packages/shared/src/dpop.ts:148-151`). The server rebuilds the URL from the `Host` header and `x-forwarded-proto` (https only if that header is `https`) (`.repos/effect-smol/packages/effect/src/http/HttpServerRequest.ts:1050-1058`, `481-487`; used by `infra/relay/src/http/Api.ts:1719`, `1739` and `apps/server/src/auth/dpop.ts:63`). That Cloudflare (relay Worker) and cloudflared (tunnel) set `x-forwarded-proto: https` is inferred from production working: UNVERIFIED. Tunnel ingress does not override the Host header (`infra/relay/src/environments/ManagedEndpointProvider.ts:627-632`).
- `ath` must equal `base64url(SHA-256(access token))` when the server expects a token (`packages/shared/src/dpop.ts:152-161`).
- Signature: ECDSA P-256 over SHA-256 of `b64(header).b64(payload)`, compact 64-byte format (`packages/shared/src/dpop.ts:163-176`). `@noble/curves` is 1.9.1 (`pnpm-workspace.yaml:42`); whether high-S signatures are accepted (`lowS` default for p256) is UNVERIFIED, but WebCrypto signatures (not low-S normalized) are used in production, which suggests they are. A native client should normalize to low-S to be safe.
- Time window: `iat <= now + 5` and `now - iat <= 300` (`packages/shared/src/dpop.ts:178-188`).
- Replay: relay stores `(thumbprint, jti)` as primary key for 5 minutes (`infra/relay/src/auth/DpopProofs.ts:99-149`, `infra/relay/src/persistence/schema.ts:188-201`, `jti` max length 255); environment stores a marker keyed by `SHA-256(thumbprint:jti)` in its secret store (`apps/server/src/auth/dpop.ts:87-124`). Every proof needs a fresh `jti`.
- No `nonce` claim and no `DPoP-Nonce` handling anywhere in source.

### D.5 Key sharing

One key per install is used for: relay token exchange and relay DPoP requests (`packages/client-runtime/src/relay/managedRelay.ts:611-639`), the environment `/oauth/token` bootstrap proof and WebSocket ticket proof (`packages/client-runtime/src/authorization/service.ts:110`, `224-238`, `325-338`), and every environment HTTP request (`packages/client-runtime/src/state/environmentHttpAuth.ts:65-96`). The bootstrap credential is bound to that key's thumbprint (`apps/server/src/cloud/CloudLink.ts:1595-1604`, `1619-1625`), and the environment DPoP session stores `proofKeyThumbprint` (`apps/server/src/auth/EnvironmentAuth.ts:908-918`).

### D.6 Example proof (shape)

Header: `{"typ":"dpop+jwt","alg":"ES256","jwk":{"kty":"EC","crv":"P-256","x":"<b64url 32B>","y":"<b64url 32B>"}}`
Payload: `{"htm":"POST","htu":"https://relay.t3.codes/v1/environments/<uuid>/connect","jti":"<uuid v4>","iat":1760000000,"ath":"<b64url sha256(relay access token)>"}`
Signature: `base64url(r || s)`.

---

## E. End-to-end connect flow

### E.1 Sequence (relay route)

```
Client                         Clerk FAPI (clerk.t3.codes)     Relay (relay.t3.codes)              Environment (https://<tunnel>/)
  | sign in (SDK)  ------------------->|
  | getToken({template:"t3-relay",skipCache:true}) -> session JWT (aud t3-code-relay)
  | GET /v1/environments  [Bearer JWT] ------------------------------>|
  |<---------------------------- {environments:[{environmentId,label,endpoint,linkedAt}]}
  | POST /v1/client/dpop-token [dpop proof, form body] -------------->|  verify Clerk JWT + proof
  |<---------------------------- {access_token, token_type:"DPoP", expires_in:1800, scope}
  | POST /v1/environments/:id/status [DPoP token + proof] ---------->|-- POST /api/t3-connect/health (signed) -->|
  |<---------------------------- {status:"online"|"offline", descriptor?, offlineReason?}
  | POST /v1/environments/:id/connect [DPoP + proof, {clientKeyThumbprint}] ->|-- POST /api/t3-connect/mint-credential -->|
  |<---------------------------- {environmentId, endpoint, credential (2 min, bound to jkt), expiresAt}
  | GET /.well-known/t3/environment ------------------------------------------------------------------------>|
  |<-------------------------------------------------------------------------------- descriptor (id, protocol)
  | POST /oauth/token [dpop proof, form: token-exchange + bootstrap] ------------------------------------->|
  |<-------------------------------------------------------------------- {access_token, token_type:"DPoP", expires_in ~3600}
  | POST /api/auth/websocket-ticket [Authorization: DPoP <env token>, dpop proof with ath] ----------------->|
  |<-------------------------------------------------------------------------------- {ticket, expiresAt (5 min)}
  | GET /.well-known/t3/environment (re-check id) --------------------------------------------------------->|
  | WebSocket wss://<tunnel>/ws?wsTicket=...&...&connectionMethod=relay&orchestrationProtocol=2 ----------->|
```

Code path: `RelayConnectionTarget` -> relay broker -> `authorizeDpop` (`packages/client-runtime/src/connection/resolver.ts:180-200`, `packages/client-runtime/src/authorization/service.ts:490-544`).

### E.2 Steps with code references

1. Bootstrap: `obtainBootstrap` calls relay `connectEnvironment` with scopes `["environment:connect"]` and optional `deviceId`; response `environmentId` must match (`packages/client-runtime/src/authorization/service.ts:278-306`).
2. Descriptor: `GET {httpBaseUrl}/.well-known/t3/environment` (unauthenticated) must report the same `environmentId` (`packages/client-runtime/src/authorization/service.ts:315-324`, `packages/client-runtime/src/environment/descriptor.ts:8-17`, `packages/contracts/src/environmentHttp.ts:449-453`). Descriptor fields `{ environmentId, label, platform, serverVersion, orchestrationProtocolVersion?, capabilities }` (`packages/contracts/src/environment.ts:218-226`).
3. Environment token: `POST {httpBaseUrl}/oauth/token` with header `dpop` (proof `htm=POST`, `htu=https://<host>/oauth/token`, no `ath`) (`packages/client-runtime/src/authorization/service.ts:325-338`) and form body (`packages/client-runtime/src/authorization/remote.ts:86-113`, schema `packages/contracts/src/auth.ts:298-307`):
   - `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`
   - `subject_token=<credential from relay>`
   - `subject_token_type=urn:t3:params:oauth:token-type:environment-bootstrap`
   - `requested_token_type=urn:ietf:params:oauth:token-type:access_token`
   - `scope` omitted by the relay flow (optional; unknown scopes are dropped, empty result fails `invalid_scope`) (`apps/server/src/auth/http.ts:359-365`)
   - `client_label`, `client_device_type`, `client_os` (`client_os` omitted when `unknown` or `other`) (`packages/client-runtime/src/authorization/remote.ts:27-38`)
   Response `{ access_token, issued_token_type, token_type: "DPoP", expires_in, scope }` (`packages/contracts/src/auth.ts:310-316`; server `apps/server/src/auth/http.ts:353-414`, `apps/server/src/auth/EnvironmentAuth.ts:893-955`). Session method `dpop-access-token`, TTL 1 hour (`apps/server/src/auth/EnvironmentAuth.ts:910-917`). Granted scopes are `AuthStandardClientScopes` (`apps/server/src/cloud/CloudLink.ts:1620`, `packages/contracts/src/auth.ts:205-219`): `orchestration:read`, `orchestration:operate`, `settings:write`, `providers:manage`, `environment:maintain`, `preview:operate`, `diagnostics:read`, `terminal:read`, `terminal:operate`, `source-control:write`, `filesystem:read`, `filesystem:write`, `relay:read`. The bootstrap is single use, expires in 2 minutes, and is rejected without a matching DPoP thumbprint (`apps/server/src/auth/PairingGrantStore.ts:496-505`, `559-572`, `607-612`).
   Client stores `RemoteDpopAccessToken { environmentId, accountId, label, endpoint, accessToken, expiresAtEpochMs = now + expires_in*1000, dpopThumbprint }` (`packages/client-runtime/src/authorization/service.ts:350-359`, `packages/client-runtime/src/authorization/tokenStore.ts:11-21`).
4. WebSocket ticket: `POST {httpBaseUrl}/api/auth/websocket-ticket`, headers `authorization: DPoP <env token>` and `dpop: <proof htm=POST htu=https://<host>/api/auth/websocket-ticket ath=...>`, no body (`packages/client-runtime/src/authorization/service.ts:218-249`, `packages/client-runtime/src/authorization/remote.ts:180-199`). Response `{ ticket, expiresAt }` (`packages/contracts/src/auth.ts:319-323`), ticket TTL 5 minutes (`apps/server/src/auth/SessionStore.ts:433`).
5. Socket URL: `wsBaseUrl` (path `/ws`, set to `/ws` if empty or `/`) plus `wsTicket=<ticket>` and client params (`packages/client-runtime/src/authorization/remote.ts:42-84`, `226-250`), then `orchestrationProtocol=2` appended (`packages/client-runtime/src/connection/resolver.ts:306-318`, `packages/client-runtime/src/connection/compatibility.ts:38-42`, `packages/contracts/src/environment.ts:13-16`). Example: `wss://<host>/ws?wsTicket=<t>&clientSurface=desktop&clientAppVersion=<v>&clientDeviceType=desktop&clientOs=macOS&connectionMethod=relay&orchestrationProtocol=2`.
   - Server rejects `/ws` without `orchestrationProtocol=2` with `426 {"code":"orchestration_protocol_incompatible",...}` (`apps/server/src/ws.ts:3136-3151`); authenticates via `wsTicket` first, else request credentials (`apps/server/src/auth/EnvironmentAuth.ts:1173-1194`).
   - RPC uses Effect RPC over WebSocket with JSON serialization; the session waits for the initial server config subscription (`packages/client-runtime/src/rpc/session.ts:198-229`).
6. Environment HTTP after connect: `authorization: DPoP <env token>` plus a fresh proof per request (`htm`, `htu`, `ath`) and, for orchestration endpoints, header `x-t3-orchestration-protocol: 2` (`packages/client-runtime/src/state/environmentHttpAuth.ts:27-36`, `65-96`; contract `packages/contracts/src/environmentHttp.ts:80-84`, `608-640`). Server requires exact `DPoP ` prefix (case-sensitive) and rejects DPoP-bound tokens sent as Bearer (`apps/server/src/auth/EnvironmentAuth.ts:584-586`, `641-648`, `717-768`).
7. Compatibility: server protocol other than 2 blocks connection: "This client requires a newer server. Update T3 Code on <label> to connect." or "This client is not supported by this server..." (`packages/client-runtime/src/connection/compatibility.ts:9-27`).

Timeouts: env requests 10 s (`packages/client-runtime/src/authorization/remote.ts:25`), cached-token ticket attempt 3 s (`packages/client-runtime/src/authorization/service.ts:89`), whole renewal 30 s (`packages/client-runtime/src/authorization/service.ts:91`, `441-450`).

### E.3 How environments are presented

- Discovery state per environment: `availability: "checking" | "online" | "offline" | "error"` (`packages/client-runtime/src/relay/discovery.ts:26-40`), filled by list then parallel status checks (`packages/client-runtime/src/relay/discovery.ts:151-311`).
- Web list rows (`apps/web/src/components/cloud/CloudEnvironmentConnectList.tsx:320-510`): label from relay record; status texts `T3 Connect · Not added · Relay online`, `... · Relay offline`, `... · Checking relay status…`, `... · Relay status unavailable`, `Saved without T3 Connect`, `Client not supported` (`366-383`); offline reason text when `offlineReason` present (`343-346`); buttons `Add`, `Add route`, `Adding…` (`494-505`). Adding registers `RelayConnectionRegistration(new RelayConnectionTarget({ environmentId, label }))` (`111-122`).
- Saved environment labels: `Connected`, `Connecting…`, `Reconnecting…`, `Client not supported`, `Connection failed`, `Offline`, `Not connected` (`apps/web/src/components/cloud/cloudEnvironmentConnectionPresentation.ts:17-64`), with status text from `connectionStatusText` (`packages/client-runtime/src/connection/presentation.ts:60-81`).
- Mobile: `Available · Relay online`, offline message, `Available · Checking relay status...`, `Available · Relay status unknown`, `Client not supported` (`apps/mobile/src/features/cloud/cloudEnvironmentPresentation.ts:15-70`).
- Account pages: rows show `Linked <date> · Managed tunnel` or `Activity publishing only` and a `Deregister` action that calls `DELETE /v1/client/environment-links/:id` with the Clerk token (`apps/web/src/components/clerk/T3ConnectUserProfilePage.tsx:35-111`, `129-181`; mobile `apps/mobile/src/features/cloud/T3ConnectProfilePage.tsx:39-56`; `packages/client-runtime/src/relay/managedRelayState.ts:193-209`). Removing locally only forgets it on the device (`docs/user/remote-access.md:287-291`).
- Relay error to UI mapping: there is no literal "Not authorized" or "Update needed" label. `environment_connect_not_authorized` -> blocked `permission` with "Relay rejected the environment connection request (<reason>)." or the `environment_link_not_found` text (`packages/client-runtime/src/relay/errorPresentation.ts:40-48`, `packages/client-runtime/src/connection/errors.ts:48-55`). `status: "offline"` with `offlineReason: "tunnel_released"` -> "Offline for a while, so its T3 Connect tunnel was removed. Start T3 Code on that computer and update it to the latest version to reconnect." (`packages/client-runtime/src/relay/errorPresentation.ts:68-84`; user doc `docs/user/remote-access.md:293-302`).

---

## F. Credential persistence and lifetimes

### F.1 Connection catalog document (all clients)

`ConnectionCatalogDocument` (`packages/client-runtime/src/platform/storageDocument.ts:14-43`):
```
{
  "schemaVersion": 1,
  "targets": [ {"_tag":"RelayConnectionTarget","environmentId":"...","label":"..."},
               {"_tag":"BearerConnectionTarget","environmentId":"...","label":"...","connectionId":"..."},
               {"_tag":"SshConnectionTarget",...} ],
  "profiles": [ {"_tag":"BearerConnectionProfile","connectionId","environmentId","label","httpBaseUrl","wsBaseUrl","learned"?:true,"authorization"?:"t3-connect"} | {"_tag":"SshConnectionProfile",...} ],
  "credentials": [ {"connectionId":"...","credential":{"_tag":"BearerConnectionCredential","token":"..."}} ],
  "remoteDpopTokens": [ {"environmentId","accountId"?,"label","endpoint":{"httpBaseUrl","wsBaseUrl","providerKind"},"accessToken","expiresAtEpochMs","dpopThumbprint"} ],
  "githubRoutingPermissions"?: [...],
  "disabledEnvironmentIds": []
}
```
Sources: targets `packages/client-runtime/src/connection/model.ts:9-54`; profiles and credential `packages/client-runtime/src/connection/catalog.ts:13-81`; token `packages/client-runtime/src/authorization/tokenStore.ts:11-21`. The `_tag` key in encoded TaggedClass values is expected from Effect Schema: UNVERIFIED exact encoding. A relay environment has one route (`RELAY_ROUTE_ID = "relay"`) and no stored credential; its DPoP token is kept only while a relay target is registered (`packages/client-runtime/src/connection/routes.ts:25-38`, `packages/client-runtime/src/platform/storageDocument.ts:219-238`). Learned LAN/tailnet routes reuse the T3 Connect token via `authorization: "t3-connect"` (`packages/client-runtime/src/connection/routes.ts:209-309`, `packages/client-runtime/src/connection/resolver.ts:143-149`).

After pairing (non-relay): `BearerConnectionRegistration` with `connectionId = "bearer:<environmentId>:<origin>"`, profile with `httpBaseUrl`/`wsBaseUrl`, credential `{ token: access_token }` from `/oauth/token` without DPoP (`packages/client-runtime/src/connection/onboarding.ts:100-155`). 30 day session, no refresh (`apps/server/src/auth/SessionStore.ts:432`).

### F.2 Where it lives

- Mobile: SecureStore key `t3code.connection-catalog.v1` (legacy `t3code.connections` migrated) (`apps/mobile/src/connection/catalog-store.ts:16-17`, `51-121`, `apps/mobile/src/persistence/mobile-secure-storage.ts:31-50`); DPoP key `t3code.cloud.dpop-proof-key`; relay tokens `t3code.cloud.relay-access-tokens`; device id `t3code.agent-awareness.device-id` (`apps/mobile/src/persistence/mobile-storage.ts:16-19`); Clerk token cache via `@clerk/expo/token-cache` (keys UNVERIFIED).
- Web (hosted): IndexedDB `t3code:connection-runtime` v4, store `catalog`, key `document` (JSON string), plus `shell`, `thread`, `server-config`, `vcs-refs` caches (`apps/web/src/connection/storage.ts:41-48`, `423-430`); GitHub routing permissions in localStorage `t3code:github-routing:<environmentId>` (`apps/web/src/connection/storage.ts:502-563`); DPoP key IndexedDB `t3code:cloud-auth`; relay token memory only.
- Desktop: catalog via desktop bridge in `~/.t3/userdata/connection-catalog.json` as `{"version":1,"encryptedCatalog":"<base64 safeStorage ciphertext>"}` (`apps/web/src/connection/storage.ts:396-421`, `apps/desktop/src/app/DesktopConnectionCatalogStore.ts:29-33`, `384-431`); Clerk tokens via `@clerk/electron` storage in `stateDir` (format UNVERIFIED); DPoP key in renderer IndexedDB; relay token memory only. Electron safeStorage being Keychain-backed on macOS is Electron behavior: UNVERIFIED here.

### F.3 Lifetimes and renewal

| Credential | Lifetime | Client reuse rule | Renewal |
|---|---|---|---|
| Clerk `t3-relay` JWT | template setting (UNVERIFIED) | until `exp - 5 s` (`packages/client-runtime/src/relay/managedRelayState.ts:26`, `84-111`) | `getToken` again (skipCache) |
| Relay DPoP token | 30 min (`infra/relay/src/auth/RelayTokens.ts:29`) | until `expires - 5 s` (`packages/client-runtime/src/relay/managedRelay.ts:380`) | re-exchange Clerk JWT; one retry on `invalid_bearer` |
| Bootstrap credential | 2 min, one use (`apps/server/src/cloud/CloudLink.ts:1622`) | n/a | new `/connect` |
| Environment DPoP token | 1 h (`apps/server/src/auth/EnvironmentAuth.ts:916`) | until `expires - 60 s` (`packages/client-runtime/src/connection/model.ts:108`, `packages/client-runtime/src/authorization/service.ts:389-403`) | full relay connect + `/oauth/token` again (`packages/client-runtime/src/authorization/service.ts:404-466`) |
| WebSocket ticket | 5 min (`apps/server/src/auth/SessionStore.ts:433`) | single connect | new ticket per socket |
| Paired Bearer token | 30 days (`apps/server/src/auth/SessionStore.ts:432`) | until rejected | re-pair (UI behavior UNVERIFIED) |
| CLI OAuth token | `expires_in` from Clerk | until `expires - 5 min` | refresh_token grant |
| DPoP proof | 300 s window | one use per `jti` | new proof per request |

Environment HTTP requests rejected with `EnvironmentAuthInvalidError` `invalid_credential` retry once with a renewed token (`packages/client-runtime/src/state/environmentHttpAuth.ts:124-231`). Credential expiry does not close a healthy socket on the client (`docs/internals/connection-runtime.md:34-46`); whether the server closes sockets when the session expires is UNVERIFIED.

---

## G. Client identification

- `/oauth/token` fields: `client_label`, `client_device_type` (`desktop|mobile|tablet|bot|unknown`), `client_os` (`packages/contracts/src/auth.ts:276-307`, `packages/client-runtime/src/authorization/remote.ts:27-38`). Values: desktop `T3 Code Desktop` / `desktop` / `macOS|Windows|Linux` (`apps/web/src/connection/clientMetadata.ts:14-25`, `78-86`); web `T3 Code Web` with UA-derived device type, OS, browser, `webDeployment: hosted|server` (`apps/web/src/connection/clientMetadata.ts:88-96`); mobile `T3 Code Mobile`, `mobile|tablet|unknown`, `iOS|Android`, OS major version, device model (`apps/mobile/src/lib/authClientMetadata.ts:5-23`).
- WebSocket query params: `clientSurface` (`web|desktop|mobile|cli`, `packages/contracts/src/baseSchemas.ts:345`), `clientAppVersion`, `clientDeviceType` (`mobile` becomes `phone`), `clientOs`, `clientWebDeployment`, `clientBrowser` (web only), `clientOsMajorVersion`, `clientDeviceModel` (mobile only), `connectionMethod` (`direct|ssh|relay|unknown`, `packages/contracts/src/baseSchemas.ts:366`) (`packages/client-runtime/src/authorization/remote.ts:42-84`).
- Header `x-t3-orchestration-protocol: 2` on orchestration HTTP endpoints (`packages/contracts/src/environment.ts:16`, `packages/contracts/src/environmentHttp.ts:80-84`); allowed in server CORS (`apps/server/src/httpCors.ts:3-11`). Exact status for a missing header is UNVERIFIED (schema decode failure).
- No `x-t3-client`, `x-t3-client-version` or `x-t3-surface` headers exist in source (searched).
- Server checks: metadata is display and analytics only; WS params are parsed leniently and unknown values ignored (`apps/server/src/ws.ts:620-684`); request `user-agent` and IP are stored with the session (`apps/server/src/auth/utils.ts:182-198`); "client labels and device metadata have no authorization role" (`docs/internals/environment-auth.md:13-15`). Enforced: `orchestrationProtocol=2` on `/ws` (`apps/server/src/ws.ts:3142-3151`) and the orchestration header.
- Relay: no User-Agent or Origin checks; `client_id` is checked against `t3-mobile|t3-web` and drives allowed scopes (`infra/relay/src/auth/RelayTokens.ts:52`, `63-83`).

---

## H. Derived checklist for a Swift 6 macOS client (guidance, built from the above)

1. Obtain a Clerk session on `clerk.t3.codes` (publishable key `pk_live_Y2xlcmsudDMuY29kZXMk`) and fetch the `t3-relay` template JWT; decode `sub` for the cache key and `exp` for caching (refresh at `exp - 5 s`).
2. Generate one P-256 key (CryptoKit, Secure Enclave possible). JWK `{kty:"EC",crv:"P-256",x,y}` from the 65-byte X9.63 point; thumbprint = unpadded base64url SHA-256 of `{"crv":"P-256","kty":"EC","x":"...","y":"..."}`.
3. Build proofs: header `{"typ":"dpop+jwt","alg":"ES256","jwk":{...}}`, payload `{"htm","htu","jti":UUIDv4,"iat":seconds,"ath"?}`, signature raw 64-byte r||s (normalize to low-S), unpadded base64url everywhere. `htu` = scheme://host/path with no query, no fragment, no default port.
4. `GET https://relay.t3.codes/v1/environments` with `Authorization: Bearer <jwt>`.
5. `POST https://relay.t3.codes/v1/client/dpop-token` (form) with `client_id=t3-web`, `resource=https://relay.t3.codes`, scope `environment:status environment:connect`; cache until 5 s before expiry; on 401 `invalid_bearer` from DPoP endpoints, re-exchange once.
6. Optional `POST /v1/environments/<id>/status`; then `POST /v1/environments/<id>/connect` with JSON `{"clientKeyThumbprint":"<jkt>"}` (or `clientProofKeyThumbprint`).
7. Within 2 minutes: `GET <httpBaseUrl>.well-known/t3/environment` (check id and `orchestrationProtocolVersion == 2`), then `POST <host>/oauth/token` with `dpop` header and the form fields in E.2 step 3.
8. `POST <host>/api/auth/websocket-ticket` with `Authorization: DPoP <env token>` and proof including `ath`; open `wss://<host>/ws?wsTicket=...&clientSurface=desktop&clientOs=macOS&connectionMethod=relay&orchestrationProtocol=2`.
9. Re-run steps 5 to 8 when the environment token is within 60 s of expiry or rejected; keep the socket open meanwhile.

---

## I. UNVERIFIED items

1. Clerk SDK internals: `@clerk/electron` storage file and encryption; `@clerk/expo/token-cache` backing store and keys; clerk-js browser session storage; how `getToken({ template, skipCache: true })` maps to Frontend API calls; how `@clerk/electron` delivers SSO callbacks.
2. Which sign-in strategies are enabled on the production Clerk instance (email code, password, GitHub, Google, Apple, passkeys) and whether bot protection or CAPTCHA applies.
3. The `t3-relay` JWT template lifetime.
4. iOS SSO callback scheme used by the mobile app; macOS support of Clerk's Swift SDK.
5. Production tunnel zone (`RELAY_TUNNEL_ZONE_NAME`) and therefore the exact tunnel hostnames.
6. That Cloudflare Workers and cloudflared set `x-forwarded-proto: https` (required for the `htu` the servers reconstruct to be `https://...`); inferred from production working.
7. `@noble/curves` 1.9.1 p256 `lowS` default (high-S acceptance); inferred acceptable from WebCrypto use.
8. Effect framework behaviors cited from `.repos/effect-smol` (form encoding of payloads, excess property handling in schema decoding, `toURL`, CORS default, trace header propagation) may differ slightly from the installed patched `effect@4.0.1`.
9. Exact HTTP status and body for schema decode failures (unknown `client_id`, missing `dpop` header, missing `x-t3-orchestration-protocol`).
10. Clerk OAuth access token format and whether it could ever carry `aud: t3-code-relay`.
11. Whether ASWebAuthenticationSession can complete an http loopback redirect.
12. Clerk device verification URI value.
13. Whether the environment server closes a WebSocket when the underlying 1 hour DPoP session expires.
14. Whether a paired Bearer token works over the T3 Connect tunnel hostname in practice.
15. Clerk Backend `allowed_origins` effect on native (Origin-less) Frontend API requests.

---

## J. Possible blockers for a third-party native client

1. Relay DPoP exchange requires a Clerk session JWT from template `t3-relay` with `aud` `t3-code-relay` (`infra/relay/src/http/Api.ts:1020-1025`, `docs/operations/connect-setup.md:50-61`). CLI OAuth tokens are not accepted there, so OAuth-only sign-in cannot connect to environments.
2. `client_id` must be `t3-web` or `t3-mobile` (`packages/contracts/src/relay.ts:747`); there is no third-party client registration. Using these, and the public CLI OAuth client id, means presenting as an official client (policy consideration, not a code check).
3. Clerk native SSO redirect allowlist only lists official redirects (`docs/operations/connect-setup.md:63-88`); reusing `t3code://app/` would collide with the official desktop app's registered scheme (`scripts/build-desktop-artifact.ts:2727-2732`).
4. CLI OAuth redirect is fixed to `http://127.0.0.1:34338/callback` (`docs/operations/connect-setup.md:42`, `apps/server/src/cloud/publicConfig.ts:21`); port collision with a running `t3 connect`.
5. Passkeys need the app's `TEAMID.bundleid` in the AASA on `clerk.t3.codes` (`docs/operations/connect-setup.md:90-99`); native Apple and Google sign-in configs are tied to official bundle ids (`apps/mobile/app.config.ts:357-359`, `476-484`).
6. Possible bot protection on sign-up (CSP hint `apps/desktop/src/electron/ElectronProtocol.ts:80`): UNVERIFIED.
7. Clock skew: proofs older than 300 s or more than 5 s in the future fail (`packages/shared/src/dpop.ts:178-188`).
8. Server orchestration protocol must equal 2 (`packages/contracts/src/environment.ts:13-16`, `apps/server/src/ws.ts:3142-3151`).
9. Publish-only links (`providerKind: "manual"`) are listed but not connectable (`infra/relay/src/environments/EnvironmentConnector.ts:322-327`).
10. Relay request deadline 9 s versus 10 s environment mint timeout can yield a `504` with a non-standard body (`infra/relay/src/http/Api.ts:174`, `182-213`, `infra/relay/src/environments/EnvironmentConnector.ts:131`).
11. CORS and Origin checks are not a blocker: the relay allows `*` (`infra/relay/src/http/Api.test.ts:1385`) and the environment server uses a wildcard in production (`apps/server/src/http.ts:239-262`).
