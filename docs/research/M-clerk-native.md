# M. Native Clerk sign-in for CandyWrapper

Goal: get a Clerk session that can mint a `t3-relay` JWT, without claiming `t3code://`. Path prefixes: `T3` is `/Users/mrm/CandyWrapper-research/t3code`. `clerk-ios` is `github.com/clerk/clerk-ios` (main, read 2026-10-10, `Sources/ClerkKit/...`). `ENV` is the live `GET https://clerk.t3.codes/v1/environment?_is_native=true` response, fetched 2026-10-10.

## 1. How T3's mobile app signs in

- The app wraps everything in `<ClerkProvider publishableKey tokenCache={tokenCache}>` from `@clerk/expo` 4.6.8 (`T3/apps/mobile/src/features/cloud/CloudAuthProvider.tsx:1-2,214`; version `T3/pnpm-workspace.yaml:30`). The token cache import is `@clerk/expo/token-cache`. Its backing store is not visible in the repo.
- The app contains no custom sign-in code. It renders Clerk's prebuilt native screens: `AuthView` when signed out, `UserProfileView` when signed in (`T3/apps/mobile/src/features/settings/SettingsAuthRouteScreen.tsx:2,54-60`). So the strategies are whatever the Clerk instance enables, listed below from ENV.
- Strategies on the production instance (ENV `auth_config.first_factors`, `user_settings.social`, `passkey_settings`): `email_code`, `password`, `passkey`, and OAuth for Apple, GitHub, Google and Microsoft. `oauth_token_apple` (native Apple ID token) and `google_one_tap` are also listed. No second factor is offered (`second_factors: []`). `single_session_mode` is true. Sign-up mode is `public`.
- Mobile config enables Sign in with Apple through the Expo plugin (`T3/apps/mobile/app.config.ts:359`), passes Google client ids through `extra` (`:476-484`), and sets `associatedDomains` `applinks:` and `webcredentials:clerk.t3.codes` (`:259-262`). The URL schemes are `t3code`, `t3code-preview` and `t3code-dev` (`:77,85,93`).
- OAuth redirect: not set in T3 source. The grep for `redirectUrl|redirectConfig|clerk://` finds only the Android table in docs. Clerk's iOS default is `{bundleIdentifier}://callback` (clerk-ios `Configuration/ClerkOptions.swift`, `RedirectConfig`; also stated in Clerk's Expo guide, https://clerk.com/docs/guides/development/deployment/expo). The Android SDK uses `clerk://<applicationId>.callback` (`T3/docs/operations/connect-setup.md:80-88`).
- Token call: `getToken(resolveRelayClerkTokenOptions())` (`CloudAuthProvider.tsx:136`), which is `{ template, skipCache: true }` (`T3/packages/shared/src/relayAuth.ts:84-89`). The template comes from `extra.clerk.jwtTemplate` (`T3/apps/mobile/src/features/cloud/publicConfig.ts`). It is `t3-relay` in production (`T3/docs/operations/connect-setup.md:50-61`).
- Session storage and refresh: Clerk's SDK owns both. T3 only watches `isSignedIn` and `userId` from `useAuth` (`CloudAuthProvider.tsx:54,73`). On account change it wipes relay environments and the relay token cache (`:89-114`).
- Sign-out: no T3 call. The user does it inside Clerk's native `UserProfileView`. When `isSignedIn` flips to false, the bridge unregisters the device and clears caches (`:123-133`).

## 2. Frontend API calls without an SDK

Source of truth is Clerk's own Swift SDK, because Clerk publishes no complete FAPI reference. Base URL is `https://clerk.t3.codes` (derived from the key, `T3/packages/shared/src/relayAuth.ts:32-78`).

Authenticating requests:
- Every request gets `?_is_native=true` (clerk-ios `Networking/Middleware/ClerkQueryItemsRequestMiddleware.swift`).
- Native clients use an `Authorization` header holding the client (device) token instead of the `__client` cookie (https://clerk.com/docs/guides/development/sdk-development/terminology, entry "Authorization header").
- The first request, `POST /v1/client/sign_ins`, has no token. The server returns one in the response `Authorization` header. The SDK stores it and sends it on every later call. An empty or `Bearer`-only value clears it (`ClerkDeviceTokenResponseMiddleware.swift`).
- The SDK also sends `x-clerk-client-id`, `x-native-device-id`, `x-device-type`, `x-device-model`, `x-os-version`, `x-app-version`, `x-bundle-id`, `x-is-sandbox` (`ClerkHeaderRequestMiddleware.swift`). Whether the server enforces `x-bundle-id` is not documented. ENV says `fraud_settings.native.device_attestation_mode: "disabled"` and `native_settings.api_enabled: true`.
- Bodies are form-urlencoded (`ClerkURLEncodedFormEncoderMiddleware.swift`). The SDK retries 408, 425 and 429, honoring `Retry-After` up to 5 s (`ClerkRateLimitRetryMiddleware.swift`).

Sign-in (paths from `Domains/Auth/SignIn/SignInAPI.swift`, params from `SignIn+ServiceParams.swift`, calls from `SignIn.swift`):

| Strategy | Calls |
| --- | --- |
| Email code | `POST /v1/client/sign_ins` `{identifier}`; `POST .../sign_ins/{id}/prepare_first_factor` `{strategy:email_code, email_address_id}`; `POST .../attempt_first_factor` `{strategy:email_code, code}` |
| Password | `POST /v1/client/sign_ins` `{identifier, password, strategy:password}`, or `attempt_first_factor` `{strategy:password, password}` |
| OAuth | create `{strategy:oauth_google, redirect_url}`, or create then `prepare_first_factor {strategy:oauth_<provider>, redirect_url}`. Open `first_factor_verification.external_verification_redirect_url` in a web session. On callback, `GET /v1/client/sign_ins/{id}?rotating_token_nonce=<nonce from callback URL>` |
| Passkey | `POST .../sign_ins {strategy:passkey}`; WebAuthn assertion against the nonce challenge; `attempt_first_factor {strategy:passkey, public_key_credential}` |

- Status is `complete` when done (`SignIn+Status.swift`). Then the response carries `created_session_id`. The sign-in response also embeds the updated client, so read the session from there.
- If the callback URL lacks `rotating_token_nonce`, the SDK reloads the sign-in without it and runs the sign-up transfer flow (`SignIn.swift` `handleRedirectCallbackUrl`, lines 763-794).
- Clerk says it passes the security-critical nonce only to allowlisted redirect URLs (https://clerk.com/docs/guides/development/deployment/expo, "Allowlist for mobile SSO redirect"). A non-allowlisted redirect probably yields no nonce. I did not test this.

Minting the template JWT: `POST /v1/client/sessions/{sessionId}/tokens/t3-relay` returns `{jwt}` (`Session/SessionAPI.swift` `fetchToken`, `TokenResource.swift`). With `skipCache` the SDK always calls it.

Lifetimes and refresh:
- The session token lives 60 seconds, and the SDK refreshes it each minute (https://clerk.com/docs/guides/how-clerk-works/overview.md, "Token refresh mechanism"). A template token lives for the template's "Token lifetime", default 60 seconds (https://clerk.com/docs/guides/sessions/jwt-templates.md). The T3 template's lifetime is not in source.
- The long-lived part is the client token. It expires with the session lifetime (same overview page). A client needs only that token to mint fresh JWTs, so store it in the Keychain.
- Mint a new template JWT for each `dpop-token` call. T3 does the same (`skipCache: true`).

Sign-out: `POST /v1/client/sessions/{id}/remove`, or `DELETE /v1/client/sessions` for all (`SessionAPI.swift`; `Core/Auth.swift:587-595`). Then delete the stored device token.

Rate limits: sign-in create 5 per 10 s, factor attempts 3 per 10 s, per IP; 429 carries `Retry-After` (https://clerk.com/docs/guides/how-clerk-works/system-limits).

## 3. T3's production Clerk settings

Visible in the repo:
- Publishable key `pk_live_Y2xlcmsudDMuY29kZXMk`, host `clerk.t3.codes`, template `t3-relay` with `{"aud":"t3-code-relay"}` (`C-auth-connect.md` 0.4; `T3/docs/operations/connect-setup.md:50-61`).
- Native API is on. SSO redirect allowlist holds `t3code://app/` and `t3code-dev://app/` (`connect-setup.md:63-76`), plus the three Android `clerk://com.t3tools.t3code[.dev|.preview].callback` entries (`:80-88`). No iOS entry is documented. If the iOS app uses the default, `com.t3tools.t3code://callback` is probably allowlisted, but nothing in the repo confirms it.
- Passkeys: the instance's iOS app registration uses Team `ARK85ZXQ4Z` and bundle `com.t3tools.t3code` (`connect-setup.md:92-99`; `app.config.ts:253`).

Visible from the live instance (ENV, and `https://clerk.t3.codes/.well-known/apple-app-site-association`):
- `webcredentials.apps` lists only `ARK85ZXQ4Z.com.t3tools.t3code`, `.preview`, `.dev`, `.swiftui` and `.swiftui.dev`.
- Restricting sign-ups is allowed by the docs (`connect-setup.md:133-139`). ENV shows sign-up `public`, so anyone can sign up today.

What blocks a different app id:
- Passkeys: yes, hard block (section 4).
- OAuth: only if the redirect URL is not allowlisted.
- Email code and password: nothing I can find. The relay checks only signature and audience (`T3/infra/relay/src/http/Api.ts:1020-1025,1638-1656`). A grep for `azp` or `authorizedParties` in relay and shared source finds nothing, so the relay does not check which app minted the token.
- Server-side bundle checks on `x-bundle-id`: unknown.

Relay constraint: `POST /v1/client/dpop-token` verifies only a template JWT (`Api.ts:1020-1025`). The other client routes also accept a Clerk OAuth token, e.g. from the CLI PKCE client (`Api.ts:1682-1698`, used by `clientBearer` at `:314`). `/v1/environments` therefore works with a CLI token, but connect and status need a DPoP access token and so need the template JWT.

## 4. macOS

- `ASWebAuthenticationSession` "ensures that only the calling app's session receives the authentication callback, even when more than one app registers the same callback URL scheme" (https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession.md). The init takes `callbackURLScheme` or, on macOS 14.4+, `Callback.customScheme(_:)` (https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/callback.md).
- Apple's page does not say the scheme must be declared in Info.plist. Forum threads say no entry is needed (https://developer.apple.com/forums/thread/679251). Blogs say to add one. Those sources conflict.
- Apple's Info.plist key in the Callback page is for browser apps, not callers.
- Inference: CandyWrapper can pass `clerk://com.t3tools.t3code.callback` as both the Clerk `redirect_url` and the session's callback, so the system never registers the scheme for CandyWrapper. This is untested on macOS 27. A spike must confirm it.
- On macOS the session opens the default browser if it supports web auth sessions, otherwise Safari (same Apple page). The user sees a system prompt naming `clerk.t3.codes`.
- The official app is not affected, since only the active session gets the callback.
- Passkeys: Apple requires the RP domain as an associated domain of the app, otherwise the request errors (https://developer.apple.com/documentation/authenticationservices/supporting-passkeys). The `webcredentials` entitlement is checked against the AASA file, and T3's file does not list our Team ID and bundle id. Passkey sign-in is impossible for CandyWrapper unless T3 adds it.

## 5. Recommended flow

1. At sign-in, `GET /v1/environment?_is_native=true`. Offer only the strategies it lists, minus `passkey` and `oauth_token_apple`. The Apple ID token path needs T3's Apple client config and is not worth it.
2. Email code first (needs no redirect): create, prepare, attempt. Add password next. These two work on any app id as far as I can tell.
3. OAuth second: create/prepare with `redirect_url=clerk://com.t3tools.t3code.callback`, open the redirect in `ASWebAuthenticationSession(callback: .customScheme("clerk"))`, read `rotating_token_nonce`, `GET` the sign-in with it, check `complete`. Use `prefersEphemeralWebBrowserSession` off so users keep their GitHub or Google login.
4. Keep the device token (the `Authorization` response header) and `created_session_id` in the Keychain. Nothing else needs storing.
5. Per relay call: `POST /v1/client/sessions/{sid}/tokens/t3-relay`, then the DPoP token exchange (`C-auth-connect.md` 4.7).
6. On 401 from FAPI, drop the stored token and show sign-in. Sign-out: `remove`, then wipe Keychain and relay caches.

Spike before building (about 1 hour): run steps 1 and 2 against production with a throwaway account, then a custom-scheme redirect test from a plain `ASWebAuthenticationSession`.

## Risks

- Terms: I did not read T3's terms (`https://t3.codes/terms-of-service`, `privacy-policy` are linked from ENV `display_config`). Check them for rules on third-party clients. This client reuses the mobile app's Clerk key, template and redirect.
- Allowlist drift: T3 can remove the Android `clerk://` entries or the iOS default, or swap the publishable key. OAuth then fails, email code survives. A Clerk key change breaks everything.
- Template change: a different name or audience breaks `dpop-token` with `invalid_bearer`. Read the name from T3's config, not a constant, if you can.
- Native checks: T3 could turn on device attestation (currently `disabled`) or check bundle ids. A third-party app would fail.
- Rate limits are per IP and tight (3 attempts per 10 s). Show the `Retry-After`.
- Anything built on undocumented FAPI shapes can change without notice. Clerk publishes the Swift SDK as the reference.
- Asking T3 to allowlist our own redirect and register our bundle id is the durable fix. It also unlocks passkeys. Ask before shipping, per the wire-compatibility rule in `CLAUDE.md`.

## Not determined

- Whether FAPI rejects or silently strips the nonce for a non-allowlisted `redirect_url`.
- Whether `ASWebAuthenticationSession` completes on an unregistered scheme on macOS 27.
- T3's iOS allowlist entry, template token lifetime and session lifetime.
- Whether T3's terms allow third-party clients.
