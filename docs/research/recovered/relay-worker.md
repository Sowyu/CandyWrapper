# T3 Connect relay Worker (infra/relay): client authentication and environment brokering

Research target: the t3code repository at `/Users/mrm/CandyWrapper-research/t3code`, tag `v0.0.46-nightly.20261009.2861` (HEAD `3b6af0bd1`). Every path below is relative to that repository root. Paths starting with `.repos/` are vendored library sources that live inside the same repository. This was read-only research: no servers were started and no network calls were made.

Purpose: document exactly how the relay authenticates clients and brokers environment connections, so a third-party native macOS client can use T3 Connect the same way the official clients do.

---

## 0. Method, versions, limits

- Relay code read: `infra/relay/README.md`, `infra/relay/.env.example`, `infra/relay/alchemy.run.ts`, `infra/relay/package.json`, `infra/relay/src/worker.ts`, `infra/relay/src/http/Api.ts`, `infra/relay/src/auth/RelayTokens.ts`, `infra/relay/src/auth/DpopProofs.ts`, `infra/relay/src/Config.ts`, `infra/relay/src/zone.ts`, `infra/relay/src/deploymentConfig.ts`, `infra/relay/src/persistence/schema.ts`, `infra/relay/src/environments/{EnvironmentConnector,ManagedEndpointProvider,ManagedEndpointAllocations,EnvironmentLinks,EnvironmentLinker,ManagedEndpointReaper}.ts`, plus the related tests. Shared code read: `packages/contracts/src/relay.ts`, `packages/shared/src/{dpop,dpopCommon,relayJwt,oauthScope,relaySigning,relayUrl,relayAuth}.ts`, `packages/client-runtime/src/relay/managedRelay.ts`.
- Library versions from the catalog: `@clerk/backend` 3.18.1 (`pnpm-workspace.yaml:26`), `@noble/curves` 1.9.1 (`pnpm-workspace.yaml:42`), `@noble/hashes` 1.8.0 (`pnpm-workspace.yaml:43`), `effect` 4.0.1 (`pnpm-workspace.yaml:49`), `jose` 6.2.2 (`pnpm-workspace.yaml:50`), `alchemy` 2.0.0-beta.80 (`infra/relay/package.json:23`).
- `node_modules` is not installed in the checkout. Clerk, jose and noble internals could not be read and are marked UNVERIFIED where they matter.
- Effect internals were read from `.repos/effect-smol`, which reports version 4.0.1 (`.repos/effect-smol/packages/effect/package.json:4`), matching the catalog. Alchemy internals were read from `.repos/alchemy-effect` (its `packages/alchemy/package.json:3` reports 2.0.0-beta.80). There is a local patch `patches/alchemy@2.0.0-beta.80.patch` that was not reviewed for these code paths.
- There are no wrangler config files in the repository. A search for `wrangler*.toml`, `wrangler*.json` and `wrangler*.jsonc` outside `node_modules` and `.repos` returned nothing. Deployment uses Alchemy: `infra/relay/alchemy.run.ts:17-65` and `infra/relay/src/worker.ts:112-497`. Worker settings: compatibility date `"2026-05-22"`, flags `["nodejs_compat"]`, custom domain `relayPublicDomain` (`infra/relay/src/worker.ts:113-123`).
- The relay is deployed from `main` on every push (`.github/workflows/deploy-relay.yml:3-6, 30, 69-70`). Production can therefore differ from this nightly tag (UNVERIFIED that production runs exactly this code).

---

## 1. Request pipeline and route map

### 1.1 Pipeline, outermost first

1. Alchemy converts the Worker fetch event into an Effect `HttpServerRequest` with `HttpServerRequest.fromWeb` (`.repos/alchemy-effect/packages/alchemy/src/Cloudflare/Workers/HttpServer.ts:25-37`). `fromWeb` keeps only path plus query in `request.url` (`.repos/effect-smol/packages/effect/src/http/HttpServerRequest.ts:434-435, 481-487`).
2. `traceRelayHttpRequest` opens the server span, taking its parent from incoming `traceparent`/`b3` headers (`.repos/effect-smol/packages/effect/src/http/HttpMiddleware.ts:214-217`), adds a `traceparent` response header (`infra/relay/src/http/Api.ts:113-125, 227-229`), and enforces a request deadline: 9,000 ms (`Api.ts:174, 182-213`), or 25,000 ms for `/v1/hooks/*` (`Api.ts:180, 242-257`). Wired at `worker.ts:449-457`.
3. Global CORS middleware (`Api.ts:127-153`, provided at `worker.ts:446`).
4. Router: `maxParamLength: 512` (`Api.ts:87-89`, `worker.ts:451`). OpenAPI at `/openapi.json` and Scalar docs at `/docs` (`worker.ts:440-444`). `GET /` returns 302 to `/docs` (`Api.ts:161-165`). Unmatched routes return an empty 404 (`Api.ts:155-159`, `worker.ts:448`).
5. Per endpoint (vendored Effect `HttpApiBuilder`): the security middleware runs first (`.repos/effect-smol/packages/effect/src/http-api/HttpApiBuilder.ts:850, 932-1000`). Then, inside, params are decoded (`:866`), then headers (`:869`), query (`:872`), payload (`:874-881`), and only then the handler runs. Decode failures (`HttpApiSchemaError`) become defects (`:907`) that render as an empty 400 (`.repos/effect-smol/packages/effect/src/http-api/HttpApiError.ts:22, 477-503`). Typed failures are encoded with the endpoint error schemas plus the middleware error schemas (`HttpApiBuilder.ts:908`; `.repos/effect-smol/packages/effect/src/http-api/HttpApiEndpoint.ts:295-305`).

Consequence: on authenticated endpoints, auth failures (401) take precedence over malformed headers or bodies (400), because the middleware runs before decoding.

### 1.2 Routes

Contract: `packages/contracts/src/relay.ts`. Handlers: `infra/relay/src/http/Api.ts`.

| Method | Path | Auth | Contract | Handler |
|---|---|---|---|---|
| GET | `/health` | none | relay.ts:966-979 | Api.ts:460-476 |
| GET | `/.well-known/oauth-authorization-server` | none | relay.ts:981-990 | Api.ts:426-447 |
| GET | `/.well-known/oauth-protected-resource` | none | relay.ts:981-990 | Api.ts:448-456 |
| POST | `/v1/client/dpop-token` | none (DPoP proof plus Clerk subject_token) | relay.ts:1111-1129 | Api.ts:994-1054 |
| GET | `/v1/environments` | Bearer (RelayClientAuth) | relay.ts:1055-1059 | Api.ts:826-832 |
| GET | `/v1/client/devices` | Bearer | relay.ts:1060-1064 | Api.ts:833-847 |
| GET | `/v2/client/devices` | Bearer | relay.ts:1065-1069 | Api.ts:848-855 |
| POST | `/v1/client/environment-links` | Bearer | relay.ts:1070-1075 | Api.ts:856-932 |
| POST | `/v1/client/environment-link-challenges` | Bearer | relay.ts:1076-1085 | Api.ts:933-954 |
| DELETE | `/v1/client/environment-links/:environmentId` | Bearer | relay.ts:1086-1091 | Api.ts:955-973 |
| DELETE | `/v1/client/environment-links/:environmentId/tunnel` | Bearer | relay.ts:1092-1106 | Api.ts:974-990 |
| POST | `/v1/environments/:environmentId/connect` | DPoP (RelayDpopClientAuth), scope `environment:connect` | relay.ts:1131-1143 | Api.ts:1064-1112 |
| POST | `/v1/environments/:environmentId/status` | DPoP, scope `environment:status` | relay.ts:1145-1156 | Api.ts:1113-1155 |
| POST | `/v1/mobile/devices` | DPoP, scope `mobile:registration` | relay.ts:992-1001 | Api.ts:763-774 |
| POST | `/v1/mobile/live-activities` | DPoP, `mobile:registration` | relay.ts:1003-1012 | Api.ts:775-786 |
| GET | `/v1/mobile/agent-activity` | DPoP, `mobile:registration` | relay.ts:1022-1030 | Api.ts:787-797 |
| DELETE | `/v1/mobile/devices/:deviceId` | DPoP, `mobile:registration` | relay.ts:1032-1041 | Api.ts:798-809 |
| POST | `/v1/environments/:environmentId/tunnel/recovery`, `/tunnel`, `/threads/:threadId/agent-activity`, `/link-preferences`, `/hooks/wake` | environment bearer (RelayEnvironmentAuth) | relay.ts:1175-1230 | Api.ts:1159-1409 |
| POST, PUT, PATCH, GET | `/v1/hooks/:endpointKey/:hookId/:token` | public (token in path) | relay.ts:1240-1254 | infra/relay/src/hooks/HookForwarder.ts |

Groups and middleware: health and metadata have no middleware. Mobile uses `RelayDpopClientAuth` (relay.ts:1043-1051). Client uses `RelayClientAuth` (relay.ts:1053-1109). Token has no middleware (relay.ts:1127-1129). dpopClient uses `RelayDpopClientAuth` (relay.ts:1158-1161). Server uses `RelayEnvironmentAuth` (relay.ts:1175-1230). The API is assembled at relay.ts:1256-1273 and the auth layers are wired at `worker.ts:343-354`.

Declared header schemas: Bearer endpoints require `authorization` (relay.ts:780-782). The token exchange requires `dpop` (relay.ts:784-786). DPoP endpoints require both `authorization` and `dpop` (relay.ts:788-791). `TrimmedNonEmptyString` means the value is trimmed when decoded and must not be blank (`packages/contracts/src/baseSchemas.ts:7-27`). `:environmentId` is `EnvironmentId`, a branded `TrimmedNonEmptyString` (`baseSchemas.ts:310-318`).

Fixed endpoint responses:
- `GET /health`: runs `SELECT 1`, then returns `{"ok":true,"service":"relay"}`. If that fails, it returns 500 `RelayInternalError` with reason `database_unavailable` (Api.ts:460-476; relay.ts:966-970).
- `GET /.well-known/oauth-authorization-server` (Api.ts:438-447):
  `{"issuer":"<issuer>","token_endpoint":"<issuer>/v1/client/dpop-token","grant_types_supported":["urn:ietf:params:oauth:grant-type:token-exchange"],"token_endpoint_auth_methods_supported":["none"],"dpop_signing_alg_values_supported":["ES256"],"scopes_supported":["environment:connect","environment:status","mobile:registration"]}`
- `GET /.well-known/oauth-protected-resource` (Api.ts:448-456):
  `{"resource":"<issuer>","authorization_servers":["<issuer>"],"scopes_supported":[...same three...],"dpop_bound_access_tokens_required":true,"dpop_signing_alg_values_supported":["ES256"]}`
- `<issuer>` is `normalizeRelayIssuer(relayIssuer)` (Api.ts:431). That function trims and removes trailing slashes (`packages/shared/src/relayJwt.ts:43-45`). `relayIssuer` is `https://<relayPublicDomain>` (`infra/relay/src/zone.ts:35-45`; `worker.ts:211-213`).

---

## 2. Question 1: client authentication on Bearer endpoints

### 2.1 Contract

`RelayClientAuth` uses `HttpApiSecurity.http({ scheme: "bearer" })` with the description "Clerk session or OAuth bearer token for the signed-in T3 Connect user." (relay.ts:656-669). The vendored Effect security decoder compares the scheme case-insensitively, requires at least one space after it, and skips extra spaces. If the scheme does not match or the header is missing, the credential becomes the empty string (`HttpApiBuilder.ts:553-561, 634-654`). The relay then applies `trimStart` (Api.ts:421-424).

### 2.2 Verification steps (Api.ts:307-344, 1631-1698)

1. Clerk session JWT path: `verifyToken(token, { secretKey: CLERK_SECRET_KEY, audience: config.clerkJwtAudience })` (Api.ts:1638-1654). The test asserts exactly these options (`infra/relay/src/http/Api.test.ts:202-205`). No `authorizedParties`, `jwtKey`, `clockSkewInMs` or issuer option is passed.
2. Session success requires a truthy `sub` and `hasExpectedClerkAudience(aud, clerkJwtAudience)`. That check passes if `aud` is a string equal to the configured audience, or an array that contains it (Api.ts:1631-1636, 1686-1691). Mode: `clerk_session_bearer`.
3. On any failure in step 1 or 2 (including a missing `aud`, mapped to the internal cause `missing_relay_audience`, Api.ts:1690), the relay falls back to OAuth verification:
   `createClerkClient({ secretKey, publishableKey }).authenticateRequest(new Request(config.relayIssuer, { headers: { authorization: "Bearer <token>" } }), { acceptsToken: "oauth_token" })`.
   It requires `state.isAuthenticated && auth.userId` and returns `sub = auth.userId`. Mode: `clerk_oauth_bearer` (Api.ts:1656-1680, 1692-1696). Test: Api.test.ts:217-234.
4. Any failure results in 401 `RelayAuthInvalidError` with reason `invalid_bearer` (Api.ts:314-322). A missing `sub` gives the same result (Api.ts:323-328). The failure category is written only to the span attribute `relay.auth.clerk_verification_failure` (Api.ts:315-320, 1611-1629). It never appears on the wire.
5. The principal is `{ userId: sub, token }` (Api.ts:334-339).

### 2.3 Configuration

The Worker reads only `CLERK_SECRET_KEY`, `CLERK_PUBLISHABLE_KEY` and `CLERK_JWT_AUDIENCE` (worker.ts:162-164, 217-219; `infra/relay/src/Config.ts:58-77`). `CLERK_JWT_TEMPLATE` is not read by the Worker; only client builds use it (see section 10). A repo-wide grep for `authorizedParties`, `authorized_parties`, `azp`, `CLERK_AUTHORIZED` and `jwtKey` found no relay usage.

### 2.4 Answers

- Accepted issuers: the relay pins none in its own code. Tokens are bound to the Clerk instance only through Clerk SDK verification with the instance secret key. How Clerk fetches keys (JWKS through the Backend API) and whether it checks `iss`: UNVERIFIED (library not in checkout).
- Audience: the session path requires `aud` equal to `CLERK_JWT_AUDIENCE`, which is `t3-code-relay` per `infra/relay/.env.example:22-27` and `docs/operations/connect-setup.md:50-61`. The value comes from the Clerk JWT template `t3-relay`.
- azp or authorized parties: not checked by relay code on either path.
- Clock skew: the relay passes none for Clerk tokens. Clerk's default is UNVERIFIED (Clerk documents 5 seconds).
- OAuth access tokens: accepted on Bearer endpoints through Clerk `authenticateRequest(..., { acceptsToken: "oauth_token" })`. The relay code checks no client id, scope or azp. So any OAuth access token that Clerk accepts for this instance works, whichever OAuth application issued it. Whether Clerk's own verification restricts tokens to a particular OAuth application, and whether it introspects through the Backend API or verifies a JWT locally: UNVERIFIED. The architecture docs state this design on purpose: "The relay accepts both session-template JWTs and CLI OAuth tokens" (`docs/internals/t3-connect.md:157-162`).
- OAuth tokens are NOT accepted by the DPoP token exchange (section 3). That endpoint uses only the session path plus an explicit audience check.
- User id: the Clerk `sub` (session path) or `auth.userId` (OAuth path). It keys environment links (`infra/relay/src/environments/EnvironmentLinks.ts:288-292, 335-339`) and becomes the DPoP access token `sub` (Api.ts:1037).
- Allowlists of client ids or origins on Bearer endpoints: none.
- A relay-issued DPoP access token sent as Bearer fails Clerk verification, giving 401 `invalid_bearer` (inferred from steps 1 to 4).

---

## 3. Question 2: DPoP access token exchange, `POST /v1/client/dpop-token`

### 3.1 Request contract (relay.ts:743-768, 1111-1125)

- Header `dpop`: required and non-blank (relay.ts:784-786).
- Body: `application/x-www-form-urlencoded` (`HttpApiSchema.asFormUrlEncoded()`, relay.ts:768). Fields:
  - `grant_type` = `urn:ietf:params:oauth:grant-type:token-exchange` (literal, relay.ts:743-744, 753)
  - `subject_token` = Clerk token (trimmed, non-blank, relay.ts:754-756)
  - `subject_token_type` = `urn:ietf:params:oauth:token-type:jwt` (literal, relay.ts:745, 757)
  - `requested_token_type` = `urn:ietf:params:oauth:token-type:access_token` (literal, relay.ts:746, 758)
  - `resource` (trimmed, non-blank, relay.ts:759-761)
  - `scope` (trimmed, non-blank, relay.ts:762-764)
  - `client_id` = `t3-mobile` or `t3-web` (literal union, relay.ts:747-750, 765)
- Content type is lowercased and stripped of parameters (`.repos/effect-smol/packages/effect/src/http-api/internal/mediaType.ts`). Any other content type returns 415 `text/plain` `Unsupported content-type: <type>` (`HttpApiBuilder.ts:768-775`). A JSON body is rejected with 415.
- A wrong literal, an unknown `client_id` or a missing field causes a payload decode error, which is an empty 400 (`HttpApiBuilder.ts:874-881, 907`; `HttpApiError.ts:22, 477-503`). This is not a 401.
- Extra fields are ignored, because Effect's default `onExcessProperty` is `"ignore"` (`.repos/effect-smol/packages/effect/src/SchemaAST.ts:463, 497-511`).

### 3.2 Handler order (Api.ts:994-1054)

1. Adds `cache-control: no-store` and `pragma: no-cache` (Api.ts:95-103, 1005).
2. Resolves scopes from `client_id` and `scope` (Api.ts:1007-1010; `infra/relay/src/auth/RelayTokens.ts:63-83`; `packages/shared/src/oauthScope.ts:3, 22-33, 63-75`):
   - The scope string is split on a single space. Every token must match `/^[!#-[]-~]+$/`, so empty tokens, double spaces, tabs, `"` and `\` are rejected. Duplicates are removed, keeping first-seen order.
   - Every scope must be in the allowed set for that client id. `t3-mobile`: `environment:connect`, `environment:status`, `mobile:registration`. `t3-web`: `environment:connect`, `environment:status`. Subsets are allowed. The test also confirms order independence (`infra/relay/src/auth/RelayTokens.test.ts:132-143`).
3. `if (args.payload.resource !== issuer || requestedScopes === null)` raises `HttpApiError.Unauthorized`, which is mapped to 401 `{"_tag":"RelayAuthInvalidError","code":"auth_invalid","reason":"invalid_dpop","dpopFailureReason":"invalid_proof","traceId":"..."}` (Api.ts:1016-1018, 1051, 1513-1526). `resource` must be exactly the issuer string after trimming. The issuer has no trailing slash, so `https://relay.t3.codes/` fails.
4. `subject_token` is checked with `verifyClerkBearerToken` only. There is NO OAuth fallback here (Api.ts:1020-1022). Failure returns 401 reason `invalid_bearer` with no `dpopFailureReason` (Api.ts:1753-1761).
5. A truthy `sub` and the audience match are required (Api.ts:1023-1025). Otherwise the result is 401 `invalid_bearer`.
6. DPoP proof: `requireDpopProof()` runs with no expected thumbprint and no expected access token (Api.ts:1026-1028, 1734-1751). Any `ath` in this proof is ignored, because `ath` is checked only when an access token is expected (`packages/shared/src/dpop.ts:152-161`). Verification details are in section 4.3. Replay is consumed here.
7. Sets `now`, `expiresAt = now + "30 minutes"` (RelayTokens.ts:29; Api.ts:1029-1030) and `jti = randomUUIDv4` (Api.ts:1031-1033).
8. Issues the token (Api.ts:1034-1045; RelayTokens.ts:168-186).

The Clerk token is verified before the DPoP proof is consumed, so a Clerk failure does not burn the proof `jti` (inferred from the order above).

### 3.3 Response (Api.ts:1034-1050; relay.ts:771-777)

```json
{"access_token":"<JWT>","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"DPoP","expires_in":1800,"scope":"<deduplicated scopes, space separated>"}
```

- `expires_in` is `Duration.toSeconds("30 minutes")`, which is 1800 (Api.ts:1048; RelayTokens.ts:29). The official client test fixture uses `expires_in: 1_800` (`packages/client-runtime/src/relay/managedRelay.test.ts:395-405`).
- Headers: `cache-control: no-store`, `pragma: no-cache`.
- No refresh token, no revocation endpoint, no client authentication (`token_endpoint_auth_methods_supported: ["none"]`, Api.ts:443).

### 3.4 Issued access token format

- A JWT signed EdDSA (Ed25519) with the relay key pair `Alchemy.KeyPair("CloudMintKeyPair")` (worker.ts:105, 166-167, 220-221). Alchemy's `KeyPair` defaults to ed25519 (`.repos/alchemy-effect/packages/alchemy/src/KeyPair.ts:12, 100`). Signing: `signRelayJwt` uses `importPKCS8(..., "EdDSA")` and `setProtectedHeader({ alg: "EdDSA", typ })` (`packages/shared/src/relayJwt.ts:55-69`).
- Protected header: `{"alg":"EdDSA","typ":"t3-relay-dpop-access+jwt"}` (RelayTokens.ts:27, 171-174).
- Claims (RelayTokens.ts:174-184): `iss` = issuer, `aud` = issuer, `sub` = Clerk user id, `jti` (UUID v4), `iat`, `exp` (iat + 1800), `client_id`, `scope` (space-separated string), `cnf: { jkt: <RFC 7638 thumbprint of the exchange proof JWK> }`. The thumbprint is the return value of `verifyAndConsume` (`infra/relay/src/auth/DpopProofs.ts:148`; dpop.ts:141, 190-195).
- The same Ed25519 key also signs link challenges, mint and health requests, and hook delivery proofs. Its public key is handed to environments as `cloudMintPublicKey` in the link response (Api.ts:872). A client never needs to verify the access token.

### 3.5 Exchange errors (wire)

| Condition | Status | Body |
|---|---|---|
| Missing or blank `dpop` header, bad or missing form field, `client_id` not `t3-web` or `t3-mobile` | 400 | empty |
| Body not form-urlencoded | 415 | `text/plain`: `Unsupported content-type: <type>` |
| `resource` is not the issuer, or a scope is not allowed for the client id | 401 | `RelayAuthInvalidError` reason `invalid_dpop`, dpopFailureReason `invalid_proof` |
| Clerk verification fails, no `sub`, or audience mismatch | 401 | `RelayAuthInvalidError` reason `invalid_bearer` |
| DPoP proof rejected | 401 | `RelayAuthInvalidError` reason `invalid_dpop`, dpopFailureReason from the table in section 4.4 |
| Replay store failure (also a `jti` longer than 255 characters, inferred from the `varchar(255)` column, `infra/relay/src/persistence/schema.ts:188-201`) | 500 | `RelayInternalError` reason `persistence_failed` (Api.ts:1430-1451, 1528-1536) |
| UUID or signing failure | 500 | `RelayInternalError` reason `internal_error` (Api.ts:1031-1033, 1045) |

There is no `www-authenticate` header on this endpoint. The `DPoP` challenge header is added only by the DPoP middleware (Api.ts:385), and the token group has no middleware (relay.ts:1127-1129).

### 3.6 Sequence: token exchange

```
Client                       Clerk Frontend API (clerk.t3.codes)        Relay (https://relay.t3.codes)
  | getToken(template "t3-relay", skipCache) -->|                              |
  |<-- session JWT (aud "t3-code-relay") -------|                              |
  | make DPoP proof P0:                                                        |
  |   header {"typ":"dpop+jwt","alg":"ES256","jwk":{kty,crv,x,y}}              |
  |   payload {"htm":"POST","htu":"https://relay.t3.codes/v1/client/dpop-token",
  |            "jti":"<uuid>","iat":<now s>}  (no ath needed)                  |
  | POST /v1/client/dpop-token                                                 |
  |   Content-Type: application/x-www-form-urlencoded, DPoP: P0                |
  |   grant_type, subject_token=<session JWT>, subject_token_type,             |
  |   requested_token_type, resource=https://relay.t3.codes,                   |
  |   scope="environment:connect environment:status", client_id=t3-web ------>|
  |                                    decode header and form (400 / 415)      |
  |                                    scope policy, resource == issuer (401 invalid_dpop)
  |                                    Clerk verifyToken + aud check (401 invalid_bearer)
  |                                    verify P0 and consume (thumbprint, jti) (401 invalid_dpop)
  |                                    sign EdDSA JWT, cnf.jkt = thumbprint(P0.jwk), exp = iat + 1800
  |<-- 200 {access_token, issued_token_type, token_type:"DPoP", expires_in:1800, scope}
```

---

## 4. Question 3: DPoP on connect, status and `/v1/mobile/*`

### 4.1 Middleware `RelayDpopClientAuth` (Api.ts:379-415)

1. Registers `www-authenticate: DPoP` on any 401 response for this request (Api.ts:105-111, 385). It carries no `error=` parameter, and there is no `DPoP-Nonce` header.
2. The raw `Authorization` header must match `/^DPoP +/iu` (Api.ts:387-389, 417-419). Otherwise the result is 401 `invalid_bearer`. The scheme `"DPoP"` is declared at relay.ts:686-699. The token is the decoded credential after `trimStart` (Api.ts:390, 421-424).
3. `verifyDpopAccessToken` (RelayTokens.ts:188-216) calls `verifyRelayJwt` with: public key `cloudMintPublicKey`, `typ` `t3-relay-dpop-access+jwt`, `issuer` = `audience` = relay issuer, `algorithms: ["EdDSA"]`, `maxTokenAge: "30 minutes"`, `clockTolerance: 60` (`packages/shared/src/relayJwt.ts:71-103`). Claims must decode as `iss`, `aud`, `sub`, `jti` strings, `iat` and `exp` integers, `client_id` in `t3-mobile`/`t3-web`, a `scope` string and `cnf.jkt` (RelayTokens.ts:45-55). The scope is re-validated against the client id policy on every request (RelayTokens.ts:207-213). Any failure returns null, which gives 401 `invalid_bearer` (Api.ts:396-398).
   - Test evidence: a token with iat 100 and exp 1900 verifies at 700 and fails at 1961, which matches exp + 60 s tolerance (RelayTokens.test.ts:82-107). A `t3-web` token carrying `mobile:registration` is rejected (RelayTokens.test.ts:167-188). Exact jose semantics: UNVERIFIED.
4. Principal: `{ userId: sub, token, proofKeyThumbprint: cnf.jkt, dpopScopes }` (Api.ts:403-410).
5. Access tokens are not re-checked against Clerk after issuance, so a token stays usable until expiry (about 30 minutes plus 60 s) even if the Clerk session ends (inferred from RelayTokens.ts:188-216 and Api.ts:379-415).

### 4.2 Handler checks

- `requireDpopPrincipalScope(scope)`: the principal must have a thumbprint and the scope. Otherwise `Unauthorized` gives 401 `invalid_dpop` / `invalid_proof` (Api.ts:1700-1709, 1513-1526). Required scopes: connect needs `environment:connect` (Api.ts:1070), status needs `environment:status` (Api.ts:1119), mobile needs `mobile:registration` (Api.ts:768, 780, 791, 803).
- Connect only: the JSON body must contain `clientKeyThumbprint` (deprecated alias) or `clientProofKeyThumbprint`. If both are present they must be equal, and the value must equal `cnf.jkt`. Otherwise the result is 401 `invalid_dpop` / `invalid_proof` (Api.ts:1071-1074, 1592-1605; relay.ts:714-730). This check runs before the proof is consumed.
- `requireDpopThumbprint(cnf.jkt, { expectedAccessToken: token })` calls `DpopProofReplay.verifyAndConsume` (Api.ts:1711-1732; DpopProofs.ts:99-149), which calls `verifyDpopProof` (dpop.ts:113-199).
- The URL checked is `HttpServerRequest.toURL(request).href` (Api.ts:1719, 1727). In vendored Effect, `toURL` builds `new URL(request.url, "<proto>://<Host>")`, where proto is `https` only if the `x-forwarded-proto` header equals `https`, and `http` otherwise (`.repos/effect-smol/packages/effect/src/http/HttpServerRequest.ts:1050-1058`). That Cloudflare sets `x-forwarded-proto: https` on Worker requests is UNVERIFIED, but official clients send `https` htu values, so it must hold in production.

### 4.3 `verifyDpopProof` rules (packages/shared/src/dpop.ts)

Checks run in this order. The first failure determines the reported reason.

1. Blank or missing proof gives `missing_proof` (122-124). Over HTTP this is unreachable, because the header schema returns 400 first.
2. The proof must have three non-empty dot-separated parts. Otherwise `malformed_proof` (126-129).
3. Header JSON must be `{"typ":"dpop+jwt","alg":"ES256","jwk":{"kty":"EC","crv":"P-256","x":"...","y":"..."}}`. The private member `d` is forbidden (12-13, 33-44; `packages/shared/src/dpopCommon.ts:3-8`). Extra header members and extra JWK members are ignored (Effect default). A JSON or schema failure gives `malformed_proof` (134-139). Invalid base64url throws and gives `invalid_proof` (75-81, 196-198). Test: a private JWK is rejected (`packages/shared/src/dpop.test.ts:263-288`).
4. Payload: `htm`, `htu` and `jti` must be non-empty strings, `iat` an integer, `ath` an optional string (47-55). Extra claims such as `nonce` are ignored.
5. Thumbprint = base64url(SHA-256(`stableStringify({crv,kty,x,y})`)), unpadded (83-94; `packages/shared/src/relaySigning.ts:5-17`; `.repos/effect-smol/packages/effect/src/encoding/Base64Url.ts:40-41`). This is the RFC 7638 member order. It is compared with `cnf.jkt` when expected, and a mismatch gives `key_mismatch` (141-144).
6. `htm` is compared case-insensitively with the request method (145-147). A mismatch gives `method_mismatch`.
7. `htu`: the relay strips search and hash from ITS OWN URL (`dpopCommon.ts:11-20`) and compares the result to the proof's `htu` by exact string equality (148-151). The client htu is not normalized, so it must contain no query or fragment, use a lowercase host, omit the default port, and keep the exact path. Test: `packages/shared/src/dpop.test.ts:236-261`. A mismatch gives `url_mismatch`.
8. `ath`: when an access token is expected, `ath` must equal base64url(SHA-256(access token)), unpadded (96-98, 152-161). Otherwise `access_token_hash_mismatch`. Test: `infra/relay/src/auth/DpopProofs.verifyAndConsume.test.ts:161-188`.
9. Signature: P-256 verification over SHA-256(`header.payload`) with `prehash: false` and `format: "compact"` (163-176), so the signature must be raw 64-byte `r||s`, not DER. `x` and `y` must each decode to 32 bytes, otherwise an exception gives `invalid_proof` (100-111). A bad signature gives `invalid_signature`.
   - Low-S enforcement in noble: UNVERIFIED. Indirect evidence that high-S is accepted: relay tests sign with Node `dsaEncoding: "ieee-p1363"` without normalization and expect success (DpopProofs.verifyAndConsume.test.ts:53-56, 128-158), and the official web client signs with WebCrypto through jose (`apps/web/src/cloud/dpop.ts:166-180`).
10. Time window, checked last: reject if `iat > now + 5` or `now - iat > 300` (14, 178-188). `now` is the relay time floored to seconds (DpopProofs.ts:111). Accepted: iat between now - 300 s and now + 5 s, inclusive. Test: dpop.test.ts:149, and DpopProofs.verifyAndConsume.test.ts:100-126 (iat - 301 is rejected).

### 4.4 Replay store and failure mapping

- Replay (DpopProofs.ts:69-97, 128-143): INSERT `(thumbprint, jti, iat, expiresAt = now + 5 minutes, createdAt)` ON CONFLICT DO NOTHING. If no row is returned, the result is `replayed`. The table `relay_dpop_proofs` has primary key `(thumbprint, jti)`, `thumbprint varchar(128)`, `jti varchar(255)` (`infra/relay/src/persistence/schema.ts:188-201`; `infra/relay/migrations/postgres/20260527044716_baseline/migration.sql:27-34`). Replay is scoped per key thumbprint. Storage is PlanetScale Postgres through Hyperdrive (worker.ts:168-175; README.md:94-97). A cron `"*/5 * * * *"` deletes rows with `expires_at < now` (worker.ts:395-399; DpopProofs.ts:151-167). Test: DpopProofs.verifyAndConsume.test.ts:128-159.
- Observation (inferred): rows expire 300 s after first use, but a proof with iat up to 5 s in the future stays inside the time window for up to 305 s. A replay within those few seconds could pass if pruning runs in that gap. This does not affect clients.
- Server nonces: none. A grep for `dpop-nonce`, `use_dpop_nonce` and `dpop_nonce` in `infra/relay`, `packages/shared/src`, `packages/contracts/src` and `packages/client-runtime/src` found nothing.
- `dpopFailureReason` mapping (Api.ts:1464-1485; values listed at `packages/contracts/src/baseSchemas.ts:37-44`):

| Verifier code | Wire `dpopFailureReason` |
|---|---|
| time_window | time_window |
| key_mismatch | key_mismatch |
| method_mismatch, url_mismatch | request_mismatch |
| access_token_hash_mismatch | token_mismatch |
| replayed | replay |
| missing_proof, malformed_proof, invalid_signature, invalid_proof | invalid_proof |

Error precedence on DPoP endpoints:
1. Middleware: wrong scheme, or invalid or expired access token: 401 `invalid_bearer` plus `www-authenticate: DPoP`.
2. Decode: missing `dpop` header, or bad params or body: empty 400.
3. Handler: missing scope or thumbprint mismatch: 401 `invalid_dpop` / `invalid_proof`. Proof failures: 401 `invalid_dpop` plus the mapped reason. Replay store failure: 500 `persistence_failed`.

---

## 5. Question 4: `EnvironmentConnector.ts`, the connect and status flows

### 5.1 Connect (infra/relay/src/environments/EnvironmentConnector.ts:574-704)

1. A blank thumbprint gives `client_proof_key_thumbprint_missing` (581-587). In practice Api.ts already rejects this case first.
2. Two concurrent lookups (588-594):
   - `links.getForUser({userId, environmentId})`: a `relay_environment_links` row with matching `user_id` and `environment_id` and `revoked_at IS NULL`, limit 1 (EnvironmentLinks.ts:319-372).
   - `allocations.get(...)`: a `relay_managed_endpoint_allocations` row by `(user_id, environment_id)` (ManagedEndpointAllocations.ts:222-242).
3. No link gives `environment_link_not_found` (595-601).
4. `validateManagedEndpoint` (316-387):
   - `providerKind` must be `cloudflare_tunnel` (322-327).
   - The allocation must exist (328-330).
   - The base domain must be configured (337-342).
   - `readyAt`, `tunnelId` and `dnsRecordId` must all be non-null (343-352).
   - The hostname must be valid and under the base domain (353-361; deploymentConfig.ts:101-110).
   - The derived endpoint (`https://<host>/`, `wss://<host>/ws`) must equal the link's stored `httpBaseUrl` and `wsBaseUrl` (362-385).
   - Each failure maps to its own `EnvironmentConnectNotAuthorized` reason (contract list at relay.ts:454-463).
5. Mint proof payload (607-641):
   - `iss`: relay issuer
   - `aud`: `t3-env:<environmentId>`
   - `sub`: Clerk user id
   - `jti`: UUID v4
   - `iat`: floor(now in seconds)
   - `exp`: iat + 120 (`DateTime.add(now, {minutes: 2})`, 608)
   - `environmentId`
   - `clientProofKeyThumbprint`: the thumbprint
   - `cnf: {jkt: thumbprint}`
   - `deviceId`: only if the client sent one
   - `nonce`: UUID v4 (609-618)
   - `scope: ["environment:connect"]`
   Signed EdDSA with the relay Ed25519 key, header `typ` `t3-cloud-mint+jwt` (642-655; relayJwt.ts:8, 55-69). The claims are asserted in `EnvironmentConnector.test.ts:691-732`.
6. Request: POST JSON `{"proof":"<jwt>"}` to `<origin of httpBaseUrl>/api/t3-connect/mint-credential` (656-658). The environment client is created with the base URL reduced to the origin plus `/` (`packages/client-runtime/src/rpc/http.ts:89-100`). Endpoint contract: `packages/contracts/src/environmentHttp.ts:729-735`. Test URL: `https://env.example.test/api/t3-connect/mint-credential` (EnvironmentConnector.test.ts:714).
   - The relay NEVER calls `/api/connect/mint-credential` and has no fallback to it. The environment serves both paths with the same handler (`environmentHttp.ts:722-735`; `apps/server/src/cloud/http.ts:148-159`).
7. Redirects are not followed: `FetchHttpClient.RequestInit { redirect: "manual" }` (200-201, 660). The `HttpClient` is the Alchemy runtime `FetchHttpClient.layer` (`.repos/alchemy-effect/packages/alchemy/src/Cloudflare/Workers/WorkerBridge.ts:267-272`). That the deployed build uses this exact layer is UNVERIFIED.
8. Timeout: `ENVIRONMENT_MINT_REQUEST_TIMEOUT_MS = 10_000` (131, 669-681). A timeout gives `EnvironmentMintRequestTimedOut`, which maps to 504 `environment_endpoint_timed_out`. Any other request failure (non-2xx, decode error or transport error) gives `EnvironmentMintRequestFailed`, which maps to 502 `environment_endpoint_unavailable` with reason `endpoint_request_failed` (661-668; Api.ts:1093-1103).
9. Response check (683-697, 226-257). The response shape is `{credential, expiresAt, proof}` (relay.ts:929-933).
   - The `proof` is verified with the link's `environmentPublicKey` (EdDSA): `typ` `t3-env-mint+jwt`, `iss` `t3-env:<environmentId>`, `aud` relay issuer, default `maxTokenAge` 5 minutes, `clockTolerance` 60 s (relayJwt.ts:11, 71-103).
   - The decoded claims (relay.ts:919-925) must match: `environmentId`, `requestNonce == nonce`, `clientProofKeyThumbprint`, `credential` equal to the top-level `credential`, and floor(`expiresAt` in seconds) == `proof.exp`.
   - Any mismatch gives `EnvironmentMintResponseInvalid`, which maps to 502 with reason `endpoint_response_invalid` (Api.ts:1104-1109). Tests: wrong key (EnvironmentConnector.test.ts:736-763), overlong `expiresAt` (800-828).
10. Return value (698-703; relay.ts:815-820) with `cache-control: no-store` and `pragma: no-cache` (Api.ts:1068):
   `{"environmentId":"<link.environmentId>","endpoint":{"httpBaseUrl":"https://<host>/","wsBaseUrl":"wss://<host>/ws","providerKind":"cloudflare_tunnel"},"credential":"<from environment>","expiresAt":"<ISO from environment>"}`

Environment side, for context:
- It verifies the relay proof with its stored `cloudMintPublicKey` and relay issuer, `aud` `t3-env:<id>`, `sub` equal to the linked cloud user, `cnf.jkt` equal to `clientProofKeyThumbprint`, `exp > iat`, `exp - iat <= 300`, `iat <= now + 60`, scope exactly `["environment:connect"]`, and a one-time `jti` and `nonce` (`apps/server/src/cloud/CloudLink.ts:1553-1616`; `apps/server/src/cloud/linkChecks.ts:14-15, 122-139`).
- It mints a one-time pairing credential: scopes `AuthStandardClientScopes`, subject `"cloud-connect"`, ttl 2 minutes, label `"T3 Connect connect"`, bound to the proof key thumbprint (CloudLink.ts:1619-1625).
- Its response proof uses `exp` = credential expiry (CloudLink.ts:1626-1654).
- The credential string format is UNVERIFIED. It is opaque and comes from `issueOneTimeToken` (`apps/server/src/auth/EnvironmentAuth.ts:980-1001`).
- The client then redeems it directly with the environment using the same DPoP key (`docs/internals/t3-connect.md:35-43`). That step is out of scope here.

### 5.2 Status (EnvironmentConnector.ts:426-573)

- Uses the same link and allocation lookup and the same validation (431-449). These produce the same 403 reasons.
- Health proof: `iss`, `aud` `t3-env:<id>`, `sub`, `jti`, `iat`, `exp` = iat + 120, `environmentId`, `nonce`, `scope: ["environment:status"]`, header `typ` `t3-cloud-health+jwt` (450-495; relayJwt.ts:9).
- POST `{"proof"}` to `/api/t3-connect/health` (498-499; environmentHttp.ts:716-721). Redirects are not followed and the timeout is 10,000 ms (500-506). Test URL: `https://env.example.test/api/t3-connect/health` (EnvironmentConnector.test.ts:315).
- Timeout: 200 with `status: "offline"`, `error: "Managed endpoint health request timed out."`, `checkedAt` = relay now, optional `offlineReason`, and `traceId` (507-526).
- Request failure: 200 with `status: "offline"` and `error: "Managed endpoint health request failed: <environment error message>"` for typed environment errors, otherwise `"Managed endpoint health request failed."` (527-549, 176-180). Test: EnvironmentConnector.test.ts:528-558.
- Success: the proof is verified with the link key (`typ` `t3-env-health+jwt`, `iss` `t3-env:<id>`, `aud` issuer). These must all match: response `environmentId`, proof `environmentId`, `requestNonce`, `status`, `checkedAt`, and `stableStringify(descriptor)`. `checkedAt` must also lie between request time - 60 s and now + 60 s (551-565, 259-301, constant 132). A failure gives 502 `endpoint_response_invalid`.
- Online body: `{"environmentId","endpoint","status":"online","checkedAt":"<environment value>","descriptor":{...}}` (566-572). Descriptor shape: `{environmentId, label, platform, serverVersion, orchestrationProtocolVersion?, capabilities}` (`packages/contracts/src/environment.ts:218-226`).
- `offlineReason: "tunnel_released"` appears exactly when `allocation.tunnelReleasedAt` is set (170-174; test EnvironmentConnector.test.ts:560-588).
- The `traceId` on offline bodies is the current span trace id, or `"unavailable"` (195-198).
- No status caching: nothing in `environments/*.ts` or Api.ts caches status. Status responses do not set `cache-control` (Api.ts:1113-1127).
- The status response contract is at relay.ts:823-843.

### 5.3 Timeouts in one place

| What | Value | Source |
|---|---|---|
| Relay request deadline, non-hook | 9,000 ms, then 504 `{"error":"relay_request_deadline_exceeded"}` | Api.ts:174, 191-208 |
| Hook request deadline | 25,000 ms | Api.ts:180 |
| Mint and health request to environment | 10,000 ms | EnvironmentConnector.ts:131 |
| Relay to environment proof lifetime | 120 s | EnvironmentConnector.ts:451, 608 |
| Cloudflare tunnel and DNS API calls (provisioning only) | 8 s each | ManagedEndpointProvider.ts:1376-1515 |
| Official client request timeout | 10,000 ms | packages/client-runtime/src/relay/managedRelay.ts:225, 336-362 |

Because 9 s is less than 10 s, a hung environment yields the generic 504 deadline body before the typed `environment_endpoint_timed_out` error (connect) or the timed-out offline body (status) can be produced. This is inferred from the constants. A tunnel with no connector usually fails fast (Cloudflare 530), which gives 502 on connect and offline on status (test EnvironmentConnector.test.ts:560-588 uses a 530).

### 5.4 Sequence: connect

```
Client                                Relay                                   Environment (via managed tunnel)
  | POST /v1/environments/{id}/connect   |                                          |
  |  Authorization: DPoP <access_token>  |                                          |
  |  DPoP: P1 {htm POST, htu https://relay.t3.codes/v1/environments/{id}/connect,  |
  |            jti, iat, ath=b64url(sha256(access_token))}                          |
  |  {"clientProofKeyThumbprint":"<jkt>","deviceId":"<opt>"} ---------->|          |
  |                     middleware: DPoP scheme, verify EdDSA token (401 invalid_bearer)
  |                     decode params, headers, JSON body (400)                     |
  |                     scope environment:connect, body thumbprint == cnf.jkt (401 invalid_dpop)
  |                     verify P1 (key == cnf.jkt, ath, htu, window), consume jti   |
  |                     load link + allocation, validate managed endpoint (403)     |
  |                     sign t3-cloud-mint+jwt {iss relay, aud t3-env:{id}, sub, jti, iat,
  |                       exp=iat+120, environmentId, clientProofKeyThumbprint, cnf.jkt,
  |                       deviceId?, nonce, scope ["environment:connect"]}          |
  |                     POST https://<host>/api/t3-connect/mint-credential {"proof"} (no redirects, 10 s)
  |                                       |----------------------------------------->|
  |                                       |<-- {credential, expiresAt, proof t3-env-mint+jwt}
  |                     verify proof with link key, nonce, jkt, credential, exp (502 on mismatch)
  |<-- 200 {environmentId, endpoint{httpBaseUrl, wsBaseUrl, providerKind}, credential, expiresAt}
```

---

## 6. Question 5: `ManagedEndpointProvider.ts`, hostnames, lifecycle

### 6.1 Hostname and URLs

- Hash: lowercase hex of SHA-256(`"<namespace>:<userId>:<environmentId>"`). The namespace is the Alchemy stage (ManagedEndpointProvider.ts:998-1016; deploymentConfig.ts:88-94; worker.ts:223).
- Hostname: `<stageSlug>-<first 16 hex>.<baseDomain>`. The stage slug is lowercased, with every character outside `[a-z0-9-]` replaced by `-`. The label is capped at 63 characters (deploymentConfig.ts:4-7, 44-65, 96-99). Production pattern: `prod-<16 hex>.<RELAY_TUNNEL_ZONE_NAME>` (README.md:104-111; deploymentConfig.test.ts:72-91).
- Tunnel name: `t3coderelay-managedendpoint-<stageSlug>-<16 hex>` (deploymentConfig.ts:6, 120-126). The hook `endpointKey` is the same 16 hex characters (deploymentConfig.ts:128-139).
- Base domain: the managed endpoint zone name from `RELAY_TUNNEL_ZONE_NAME` (worker.ts:181, 222; zone.ts:25, 48-62). The production value is not in the repository; it is a GitHub variable (deploy-relay.yml:41) and is UNVERIFIED. Example value: `tunnels.example.com` (`infra/relay/.env.example:1-6`). The test fixture `t3coderelay.com` (deploymentConfig.test.ts:82-83) does not prove the production value.
- URLs: `httpBaseUrl = "https://<hostname>/"`, `wsBaseUrl = "wss://<hostname>/ws"`, `providerKind = "cloudflare_tunnel"` (deploymentConfig.ts:112-118; test deploymentConfig.test.ts:104-113).
- Hostname validation: it must already be lowercase with no trailing dot, use DNS-valid labels, and end with `.<baseDomain>` (deploymentConfig.ts:22-42, 101-110).
- DNS: a proxied CNAME from `<hostname>` to `<tunnelId>.cfargotunnel.com` with ttl 1 (ManagedEndpointProvider.ts:1195-1201). Ingress maps the hostname to `http://<loopback>:<port>`, then falls through to `http_status:404` (1143-1151, 367-372). The origin must be loopback (`127.0.0.1`, `::1` or `localhost`) (382-390).

### 6.2 Lifecycle

Allocation fields: ManagedEndpointAllocations.ts:16-29. Table: schema.ts:90-114.

- `provision` (ManagedEndpointProvider.ts:982-1360): reserve the allocation (1043-1062), find or create the tunnel by name (1065-1085), then `recordTunnel`. `recordTunnel` bumps `generation`, resets `readyAt` and `origin` to null if the tunnel id changed, and clears `tunnelReleasedAt` (ManagedEndpointAllocations.ts:321-357). Next come configure, DNS and token, then `markReady`, which sets `readyAt` (ManagedEndpointAllocations.ts:389-420).
- Connect and status are authorized only when `readyAt`, `tunnelId` and `dnsRecordId` are all set (EnvironmentConnector.ts:343-352; ManagedEndpointAllocations.ts:37-51).
- `release` (DELETE `.../tunnel`, or environment shutdown) deletes the Cloudflare tunnel but deliberately keeps the allocation row with its recorded tunnel id. The code comment says this is so status keeps reporting "offline" rather than "not authorized" (ManagedEndpointProvider.ts:792-981, comment at 974-979; `docs/internals/t3-connect.md:72-77`).
- Reaper cron, every 5 minutes (worker.ts:395, 416-428):
  - Deletes tunnels that have been down at least 5 minutes, or that never connected and are at least 60 minutes old, when cleanup is enabled (ManagedEndpointReaper.ts:16-19, 205-211).
  - Legacy hosts (no recovery registration) are cleaned up only after 7 days, and that release sets `tunnelReleasedAt` (ManagedEndpointReaper.ts:26-30, 197-202, 386-390; ManagedEndpointAllocations.ts:540-574).
  - Modes are `off`, `dry-run` or `enabled`; the default is `off` (Config.ts:11-33). Production mode values are UNVERIFIED (deploy-relay.yml:42-43).
- `unlink` revokes the link, then deletes the DNS record, the tunnel and the allocation (Api.ts:478-568; ManagedEndpointProvider.ts:683-791). Afterwards connect and status return `environment_link_not_found`.
- Linking enforces at most 3 managed tunnels per user by default (`infra/relay/src/environments/ManagedTunnelLimits.ts:18`). Exceeding it gives 403 `environment_link_limit_exceeded` (Api.ts:905-910).

### 6.3 "Not authorized" versus "offline"

| State | connect | status |
|---|---|---|
| No active link for (user, environment) | 403 `environment_link_not_found` | same 403 |
| Link `providerKind` is not `cloudflare_tunnel` (for example a CLI publish-only link with `providerKind: "manual"`, `apps/server/src/cloud/CloudLink.ts:915`) | 403 `endpoint_provider_not_managed` | same |
| No allocation row | 403 `managed_endpoint_allocation_not_found` | same |
| Base domain not configured | 403 `managed_endpoint_base_domain_not_configured` | same |
| `readyAt`, `tunnelId` or `dnsRecordId` is null (provisioning in progress, or a replacement tunnel not yet ready) | 403 `managed_endpoint_allocation_not_ready` | same |
| Hostname outside the base domain | 403 `managed_endpoint_hostname_invalid` | same |
| Link endpoint differs from the allocation endpoint | 403 `managed_endpoint_mismatch` | same |
| Ready allocation, but the tunnel was released or has no connector | 502 `endpoint_request_failed` (or a 504) | 200 `offline` with `error` text |
| Same, released by legacy cleanup (`tunnelReleasedAt` set) | 502 | 200 `offline` plus `offlineReason: "tunnel_released"` |
| Environment answers, but its proof or binding is invalid | 502 `endpoint_response_invalid` | 502 `endpoint_response_invalid` |

Sources: EnvironmentConnector.ts:170-174, 316-387, 426-704; Api.ts:1086-1154.

---

## 7. Question 6: listing, `GET /v1/environments`

- Auth: Bearer (section 2). Response: `{"environments":[{"environmentId":"...","label":"...","endpoint":{"httpBaseUrl":"...","wsBaseUrl":"...","providerKind":"manual|cloudflare_tunnel|t3_relay"},"linkedAt":"<ISO>"}]}` (relay.ts:158-169, 701-712; Api.ts:826-832).
- Included: every link for the user with `revoked_at IS NULL`, of any provider kind, with no ORDER BY and no pagination (EnvironmentLinks.ts:277-317). Only `cloudflare_tunnel` entries can be connected (EnvironmentConnector.ts:322-327).
- `label`: the stored `environment_label`, taken from the link proof `descriptor.label` at link time (EnvironmentLinks.ts:204, 221). If blank, the `environmentId` is used instead (EnvironmentLinks.ts:298-299).
- `endpoint`: stored at link time. For managed links it is the provisioned endpoint; for publish-only links it is the endpoint from the link proof (EnvironmentLinker.ts:311-318). Managed links must be `https`/`wss` (EnvironmentLinker.ts:323-330).
- `linkedAt`: the row `created_at`, which a relink does not update (EnvironmentLinks.ts:216-233, 306).
- The listing contains no status information and no `cache-control` header. Errors: 401 `invalid_bearer` and 500 `persistence_failed`.

Related Bearer endpoints, briefly:
- `GET /v1/client/devices` returns only iOS devices with a major version (Api.ts:833-847; relay.ts:100-109). `GET /v2/client/devices` returns all devices (Api.ts:848-855).
- Link challenge: body `{notificationsEnabled, liveActivitiesEnabled, managedTunnelsEnabled}` (booleans) returns `{challenge, expiresAt}`. The challenge is an EdDSA JWT with `typ` `t3-link-challenge+jwt`, `kind` `environment_link_challenge`, `iss` = `aud` = issuer, and a 5 minute lifetime (relay.ts:305-323; Api.ts:933-954; RelayTokens.ts:26-28, 122-139).
- Link: body `{deviceId?, proof, notificationsEnabled, liveActivitiesEnabled, managedTunnelsEnabled}` returns `{ok, cloudUserId, environmentId, endpoint, endpointRuntime, relayIssuer, environmentCredential, cloudMintPublicKey}` (relay.ts:325-349; Api.ts:856-932).
- Unlink and tunnel release return `{ok}` (Api.ts:955-990).

---

## 8. Question 7: CORS, client identification, rate limits

- CORS (Api.ts:127-153):
  - `allowedMethods` GET, POST, DELETE, OPTIONS
  - `allowedHeaders` `authorization,b3,traceparent,content-type,dpop`
  - `exposedHeaders` `traceparent,www-authenticate`
  - `maxAge` 86400
  - No `allowedOrigins`, so every origin gets `access-control-allow-origin: *` (`.repos/effect-smol/packages/effect/src/http/HttpMiddleware.ts:358, 378-380`). Credentials are false (`:362`).
  - The headers are added by a pre-response handler, so they appear on errors, defects, 404s and the deadline 504 (Api.ts:134-136; tests Api.test.ts:1390-1473). Preflight returns 204 (Api.test.ts:1395-1422).
  - Hook paths are excluded (Api.ts:146-149).
- A native client does not need an `Origin` header, and the relay never checks `Origin` or `Referer`.
- Request headers that client-facing relay code reads:
  - `Authorization` (security)
  - `dpop` (Api.ts:1725, 1745)
  - `Host` and `x-forwarded-proto`, indirectly through `toURL` (Api.ts:1719, 1739; HttpServerRequest.ts:1050-1058)
  - `content-type` (payload decoding)
  - `traceparent`/`b3`, only to parent the trace (HttpMiddleware.ts:214-217)
- A grep of `infra/relay/src` for reads of origin, referer, user-agent or `x-t3*` headers found only hook and APNs code (`hooks/HookForwarder.ts`, `hooks/upstream.ts`, `agentActivity/ApnsClient.ts`). No `x-t3-client`, client version or User-Agent check exists.
- Rate limits exist only for hooks: 60 requests per 60 s per hook URL and 600 per 60 s per endpoint (HookForwarder.ts:33-38; worker.ts:190-203). They fail open (worker.ts:321-337) and answer 429 `rate_limited` with `retry-after` (HookForwarder.ts:292-302). Client, token and DPoP endpoints have no rate limit and no 429.
- No WAF or bot rules are defined in the relay infra code (grep found none). Zone-level Cloudflare settings outside the repository are UNVERIFIED.
- Response headers to expect:
  - `traceparent` on non-hook responses (Api.ts:113-125).
  - `cache-control: no-store` and `pragma: no-cache` on token exchange, connect, device lists, link, link challenge and tunnel recovery (Api.ts:836, 851, 861, 936, 1005, 1068, 1326, 1362).
  - `www-authenticate: DPoP` on 401 responses from the dpopClient and mobile groups (Api.ts:105-111, 385).
- Sending `traceparent` makes the relay span a child of the client trace, so the `traceId` in error bodies matches the client trace (HttpMiddleware.ts:214-217; Api.ts:1425-1428).

---

## 9. Question 8: error mapping on the wire

Encoding:
- `Schema.TaggedError` includes a `_tag` field (`.repos/effect-smol/packages/effect/src/Schema.ts:15151-15181`). The HTTP status comes from the `httpApiStatus` annotation (relay.ts:411-593), and the body is JSON.
- JSON key order is not guaranteed (`SchemaAST.ts:455-476`), so parse bodies as objects.
- Client fixtures show the shape, for example `{"_tag":"RelayAuthInvalidError","code":"auth_invalid","reason":"invalid_bearer","traceId":"trace-stale-token"}` with status 401 (`packages/client-runtime/src/relay/managedRelay.test.ts:410-420, 576-586, 603-613`).
- `traceId` is the current parent span trace id, or `"unavailable"` (Api.ts:1425-1428). Its hex format is UNVERIFIED.

| `_tag` | HTTP | `code` | Other fields | Source |
|---|---|---|---|---|
| RelayAuthInvalidError | 401 | auth_invalid | `reason`: invalid_bearer, invalid_dpop, not_authorized (missing_bearer is in the schema but no relay code produces it); `dpopFailureReason?`; `traceId` | relay.ts:392-425 |
| RelayEnvironmentConnectNotAuthorizedError | 403 | environment_connect_not_authorized | `reason?` (8 literals, relay.ts:454-463), `traceId` | relay.ts:467-483 |
| RelayEnvironmentEndpointUnavailableError | 502 | environment_endpoint_unavailable | `reason`: endpoint_request_failed or endpoint_response_invalid, `traceId` | relay.ts:378-383, 485-497 |
| RelayEnvironmentEndpointTimedOutError | 504 | environment_endpoint_timed_out | `traceId` | relay.ts:499-510 |
| RelayInternalError | 500 | internal_error | `reason`: database_unavailable, persistence_failed, upstream_unavailable, internal_error; `traceId` | relay.ts:403-408, 581-593 |
| RelayEnvironmentLinkProofExpiredError | 401 | environment_link_proof_expired | `traceId` | relay.ts:427-438 |
| RelayEnvironmentLinkProofInvalidError | 400 | environment_link_proof_invalid | `reason`: invalid_signature_or_scope, descriptor_mismatch, replayed_nonce, challenge_invalid, origin_not_allowed, endpoint_not_secure | relay.ts:352-359, 440-452 |
| RelayEnvironmentLinkUnavailableError | 503 | environment_link_unavailable | `reason`: managed_endpoint_not_configured, managed_endpoint_provisioning_failed | relay.ts:371-374, 526-538 |
| RelayEnvironmentLinkLimitExceededError | 403 | environment_link_limit_exceeded | `maxTunnels` (number) | relay.ts:540-552 |
| RelayEnvironmentLinkFailedError | 500 | environment_link_failed | `reason`: link_persistence_failed, credential_persistence_failed, replay_persistence_failed, internal_error | relay.ts:363-368, 512-524 |
| RelayAgentActivityPublishProofExpiredError and RelayAgentActivityPublishProofInvalidError | 401 | (server group only) | | relay.ts:554-579 |

Mapping rules (`mapRelayCommonApiErrors`, Api.ts:1495-1544):
- `DpopProofRejected` becomes 401 with `reason` = the endpoint's auth reason. `dpopFailureReason` is added only when that reason is `invalid_dpop`.
- `HttpApiError.Unauthorized` becomes 401 with the endpoint's reason, plus `dpopFailureReason: "invalid_proof"` when the reason is `invalid_dpop`.
- Persistence errors (list at Api.ts:1430-1451) become 500 `persistence_failed`.
- The endpoint auth reason is `invalid_dpop` for the token exchange, connect, status and mobile endpoints (Api.ts:773-808, 1051, 1085, 1128). It is `not_authorized` for the Bearer client group and the server group (Api.ts:831-989, 1304-1406).
- Middleware errors are not remapped. Bearer and DPoP middleware failures are always `invalid_bearer` (Api.ts:321, 327, 388, 397). `not_authorized` comes only from environment bearer auth and a missing publish key (Api.ts:363, 1196-1201).

Untagged responses:
- 504 `{"error":"relay_request_deadline_exceeded"}` after the deadline (Api.ts:205-208).
- Empty 400 for decode failures (HttpApiError.ts:22, 500-502).
- 415 `text/plain` `Unsupported content-type: ...` (HttpApiBuilder.ts:774).
- Empty 404 for unknown routes (Api.ts:155-159).
- 302 to `/docs` for `GET /` (Api.ts:161-165).
- Empty 500 for defects (`.repos/alchemy-effect/packages/alchemy/src/Http.ts:78-101`; `.repos/effect-smol/packages/effect/src/http/HttpServerError.ts:297-337`).
- 429 occurs only on hooks.

---

## 10. Question 9: production deployment facts

- Stage: `prod` (deploymentConfig.ts:7; deploy-relay.yml:69-70), deployed on every push to main (deploy-relay.yml:3-6, 30). Personal stages are `dev_$USER` (README.md:104-107).
- Relay hostname: `relay.<RELAY_API_ZONE_NAME>` for prod, or `relay-<stage slug>.<zone>` for other stages (deploymentConfig.ts:75-86; zone.ts:22-46). An optional `RELAY_DOMAIN` override exists (zone.ts:26-37).
  - The root `.env.example` declares the production relay: `T3CODE_RELAY_URL=https://relay.t3.codes` (`.env.example:20-22`), and states these values are "the same public identifiers baked into official release builds" (`.env.example:1-5`).
  - Release builds derive `relay_url=https://relay.$RELAY_API_ZONE_NAME`, or use `RELAY_DOMAIN` (`.github/workflows/release.yml:418-446`).
  - The GitHub variable values themselves are not in the repository, so the issuer `https://relay.t3.codes` is inferred and UNVERIFIED.
- Issuer, and therefore the required `resource`: `https://<relay domain>` with no trailing slash (zone.ts:42; worker.ts:213; relayJwt.ts:43-45).
- Clerk Frontend API: the publishable key `pk_live_Y2xlcmsudDMuY29kZXMk` (`.env.example:9`) base64-decodes to `clerk.t3.codes$`, so the Frontend API is `https://clerk.t3.codes` (decoding logic `packages/shared/src/relayAuth.ts:31-74`; test `packages/shared/src/relayAuth.test.ts:23-27`).
- JWT template: `t3-relay` (`.env.example:10`; `docs/operations/connect-setup.md:50-61`). Official clients call `getToken({ template: "t3-relay", skipCache: true })` (`packages/shared/src/relayAuth.ts:84-89`; `apps/web/src/cloud/publicConfig.ts:77-82`; `apps/web/src/cloud/managedAuth.tsx:78`). The relay Worker does not read the template name (worker.ts:162-164), and the deploy workflow does not pass it to the Worker (deploy-relay.yml:36-49).
- Audience: `CLERK_JWT_AUDIENCE=t3-code-relay` (`infra/relay/.env.example:22-27`; connect-setup.md:52-60, which says it is the same across stages). The production variable value (deploy-relay.yml:45) is UNVERIFIED.
- Authorized parties or azp configuration: none exists.
- CLI OAuth app: `T3CODE_CLERK_CLI_OAUTH_CLIENT_ID=hzxSgY2cH10sDU2r` (`.env.example:11`). It is a public PKCE client with redirect `http://127.0.0.1:34338/callback` and the device grant enabled (connect-setup.md:37-48).
- Tunnel base domain: `RELAY_TUNNEL_ZONE_NAME`, production value UNVERIFIED (see 6.1).
- Database: PlanetScale Postgres owned by the `prod` stage, reached through Hyperdrive (README.md:94-97; worker.ts:168-175).
- Public API docs are served at `/docs` and `/openapi.json` (worker.ts:440-444).

---

## 11. How the official clients call the relay (to mimic)

- `client_id`: the web and desktop renderer use `t3-web` (`apps/web/src/cloud/managedRelayLayer.ts:79-82`). Mobile uses `t3-mobile` (`apps/mobile/src/features/cloud/managedRelayLayer.ts:67-72`).
- `resource` = `normalizeSecureRelayUrl(relayUrl)`, which is the URL origin with no trailing slash (`packages/shared/src/relayUrl.ts:1-18`; managedRelay.ts:436, 508).
- The `htu` comes from `HttpApiClient.urlBuilder(RelayApi, {baseUrl: relayUrl})` (managedRelay.ts:446-482). Web strips search and hash (`apps/web/src/cloud/dpop.ts:156-161`); mobile uses `normalizeDpopHtu` (`apps/mobile/src/features/cloud/dpop.ts:239-267`).
- Proof contents: `jti` is a UUID v4, `iat` is in seconds and `htm` is uppercase (apps/web/src/cloud/dpop.ts:162-180; apps/mobile/src/features/cloud/dpop.ts:262-288). The JWK contains only `kty`, `crv`, `x` and `y` (apps/web/src/cloud/dpop.ts:123-133; apps/mobile/src/features/cloud/dpop.ts:149-159). Mobile signs raw compact `r||s` (apps/mobile/src/features/cloud/dpop.ts:293-298). The thumbprint is computed as `JSON.stringify({crv,kty,x,y})`, hashed and base64url-encoded (apps/mobile/src/features/cloud/dpop.ts:112-128).
- Headers: `authorization: DPoP <token>` and `dpop: <proof>` (managedRelay.ts:399-404). Bearer calls send `authorization: Bearer <clerk token>` (managedRelay.ts:395-397). The same Clerk template token is used both for Bearer calls and as `subject_token`.
- Scopes requested: status uses `[environment:status, environment:connect]` (`packages/client-runtime/src/relay/discovery.ts:156-161`). Connect uses `[environment:connect]` (`packages/client-runtime/src/authorization/service.ts:291-296`). Mobile endpoints use `[mobile:registration]` (managedRelay.ts:694-709). After an exchange, the client checks that the granted scope set equals the requested set (managedRelay.ts:517-522).
- The connect body sends `clientKeyThumbprint` (managedRelay.ts:823-827).
- Token cache: entries are keyed by account, client id, relay URL, thumbprint and scope, and are reused until 5 s before expiry (managedRelay.ts:364-383, 527-609). On 401 `invalid_bearer` from a DPoP endpoint, the client drops the cached token and retries once (managedRelay.ts:328-334, 655-692).
- No clock-skew correction. On `time_window` the client only shows a hint (`packages/client-runtime/src/relay/errorPresentation.ts:4-22`).

---

## 12. Native client wire summary

Hostnames are inferred (see section 10).

1. Get a Clerk session JWT from `https://clerk.t3.codes` using template `t3-relay`. Its `aud` must be `t3-code-relay`.
2. List environments: `GET https://relay.t3.codes/v1/environments` with `Authorization: Bearer <clerk JWT>`.
3. Keep one P-256 key per install. JWK: `{"kty":"EC","crv":"P-256","x":b64url(32 bytes),"y":b64url(32 bytes)}`. Thumbprint: `b64url(SHA256('{"crv":"P-256","kty":"EC","x":"..","y":".."}'))`, unpadded.
4. Exchange the token:
   - Request: `POST https://relay.t3.codes/v1/client/dpop-token` with `Content-Type: application/x-www-form-urlencoded` and `DPoP: <proof htm=POST htu=https://relay.t3.codes/v1/client/dpop-token>`.
   - Body fields: `grant_type`, `subject_token`, `subject_token_type`, `requested_token_type`, `resource=https://relay.t3.codes`, `scope=environment:connect environment:status`, `client_id=t3-web`.
   - Result: an `access_token` valid for 1800 s.
5. Check status: `POST https://relay.t3.codes/v1/environments/<id>/status` with no body.
   - Headers: `Authorization: DPoP <access_token>` and `DPoP: <proof htm=POST htu=https://relay.t3.codes/v1/environments/<id>/status ath=b64url(SHA256(access_token))>`.
6. Connect: `POST https://relay.t3.codes/v1/environments/<id>/connect`.
   - Headers: the same as status, with the htu path ending in `/connect`, plus `Content-Type: application/json`.
   - Body: `{"clientProofKeyThumbprint":"<thumbprint>"}`, optionally with `deviceId`.
   - Result: `{environmentId, endpoint{httpBaseUrl, wsBaseUrl, providerKind}, credential, expiresAt}`. The credential lives about 2 minutes and is bound to the same key.
7. Every proof needs a fresh `jti` (255 characters or fewer) and an `iat` between relay time - 300 s and relay time + 5 s.

---

## 13. UNVERIFIED items

1. Clerk `verifyToken` internals: how keys are fetched (JWKS through the Backend API with the secret key), whether `iss` is checked, the default clock skew (Clerk documents 5 s), behavior when `aud` is missing, and the default azp handling. The relay itself passes only `{secretKey, audience}` (Api.ts:1644-1647).
2. Clerk `authenticateRequest` with `acceptsToken: "oauth_token"`: the verification mechanism, and whether it restricts tokens to a specific OAuth application. The relay itself checks no client id.
3. Whether any Clerk OAuth JWT access token could pass the exchange (it would need `aud` `t3-code-relay`). Believed not, but unverified.
4. Exact jose semantics of `maxTokenAge` and `clockTolerance`. Test evidence supports an expiry tolerance of exp + 60 s.
5. noble P-256 low-S handling, and DER rejection beyond `format: "compact"`.
6. That Cloudflare Workers receive `x-forwarded-proto: https`. The `htu` comparison depends on it.
7. Production values: `RELAY_API_ZONE_NAME` (inferred `t3.codes` from `.env.example:22`), `RELAY_TUNNEL_ZONE_NAME` (unknown), `CLERK_JWT_AUDIENCE` (documented as `t3-code-relay`), cleanup modes, and whether production runs this exact tag.
8. Zone-level Cloudflare WAF, bot or rate rules (none are defined in the repository).
9. Clerk dashboard restrictions (allowed origins, native app allowlist, redirect allowlists, bot protection, sign-up restrictions) that could stop a third-party app from getting a session or template token (see connect-setup.md:63-88, 133-139).
10. The format of the environment-minted `credential` string.
11. That the deployed `HttpClient` is `FetchHttpClient` (seen in the vendored Alchemy copy).
12. That a `jti` longer than 255 characters causes a Postgres error and therefore a 500 (inferred from the column type).
13. The `traceId` format, and that defect 500 bodies are empty (from the vendored Alchemy comment).
14. Whether Cloudflare adds a `Date` response header that could be used to estimate clock skew.

---

## 14. Things that could block a third-party native macOS client

1. Clerk identity is mandatory for connecting. The DPoP exchange accepts only a Clerk session JWT that passes `verifyToken` and has `aud` `t3-code-relay` (Api.ts:1020-1025). That means signing the user into T3's Clerk instance (`clerk.t3.codes`) and minting the `t3-relay` template token. The relay performs no azp or origin check, but Clerk-side configuration might restrict third-party apps (UNVERIFIED).
2. `client_id` allowlist: only the literals `t3-web` and `t3-mobile` are accepted. Anything else gets an empty 400 (relay.ts:747-750, 765). The value is self-asserted (`token_endpoint_auth_methods_supported: ["none"]`) and is recorded in telemetry as `relay.oauth.client_id` (Api.ts:1011-1015). `t3-web` grants connect and status; `t3-mobile` also grants `mobile:registration` (RelayTokens.ts:63-73).
3. CLI OAuth tokens work only on Bearer endpoints (listing, linking). They cannot be exchanged for a DPoP token, so an OAuth-only client can list environments but cannot connect (Api.ts:1020-1025 compared with Api.ts:1682-1698).
4. `resource` must be byte-exact: the issuer with no trailing slash. A mismatch gives a misleading 401 `invalid_dpop`/`invalid_proof` (Api.ts:1016-1018, 1513-1526).
5. The exchange body must be form-urlencoded. JSON gets 415 (HttpApiBuilder.ts:768-775).
6. DPoP strictness:
   - ES256 only, and the signature must be raw 64-byte `r||s`.
   - The JWK must carry public members only.
   - `typ` must be `dpop+jwt`.
   - `htu` must match the exact URL string the relay rebuilds: `https`, lowercase host, no default port, no query or fragment.
   - `iat` may be at most 5 s ahead of the relay clock.
   - `jti` must be unique per key.
   - `ath` is required on connect, status and mobile, but not on the exchange.
   - There is no nonce support, so do not wait for `DPoP-Nonce` (dpop.ts:113-199; Api.ts:1711-1751).
7. Status is POST, not GET (relay.ts:1145-1147). Connect requires a JSON body whose thumbprint equals `cnf.jkt` (Api.ts:1071-1074).
8. Only `cloudflare_tunnel` links can be connected. Publish-only (`manual`) links still appear in the listing, but connect and status on them return 403 `endpoint_provider_not_managed` (EnvironmentLinks.ts:277-317; EnvironmentConnector.ts:322-327).
9. Server deadline of 9 s: expect the untagged 504 `{"error":"relay_request_deadline_exceeded"}` as well as tagged errors (Api.ts:174, 205-208). Use a client timeout of at least 10 s, as the official clients do (managedRelay.ts:225).
10. No refresh token: re-exchange with a fresh Clerk token before the 1800 s expiry (Api.ts:1048).
11. Not a blocker: the relay requires no Origin, User-Agent or custom client header and applies no rate limit to these endpoints. CORS does not matter for a native client (Api.ts:127-153; worker.ts:190-203).
