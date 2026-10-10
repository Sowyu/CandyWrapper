# K. Remote environments: what the user sees

Research for milestone 6. Protocol details live in `C-auth-connect.md` and `protocol.md` section 10 and are not repeated. Source is T3 tag `v0.0.46-nightly.20261009.2861`. Prefixes: `W/` is `apps/web/src/`, `C/` is `apps/web/src/components/`, `R/` is `packages/client-runtime/src/`, `D/` is `apps/desktop/src/`. Strings are copied exactly. All of this is from reading code; nothing was run.

## 1. Where remote environments appear

- **Settings > Connections** (`W/routes/settings.connections.tsx:1-7`, `C/settings/ConnectionsSettings.tsx:2034`). Blocks: "This machine" (primary environment), folded "Authorized clients" (`:3739`), "Environments" (`:4067`) with saved machines plus T3 Connect discoveries, then "Load balancing" (only with two or more machines on, `C/settings/LoadBalancingSettings.tsx:67`).
- **Sidebar footer.** `Sign in to T3 Connect` button when signed out, Clerk avatar menu when signed in (`C/settings/SettingsSidebarNav.tsx:352-362`, `C/clerk/T3ConnectSidebarSignIn.tsx:61`). Both vanish without cloud config (`W/cloud/publicConfig.ts:72`).
- **Thread rows.** Threads from other environments share the main list. A remote thread gets a machine icon on its row (`C/Sidebar.tsx:2196-2205`), the label in its hover card (`:483-490`), and fallback label `Remote` (`C/ThreadStatusIndicators.tsx:993-1039`). Same-identity projects merge across environments (`W/sidebarProjectGrouping.ts:1-45`).
- **Project pickers.** Machine icon with tooltip `On <labels>` or `Also on <labels>`, only while the catalog spans environments (`C/ProjectEnvironmentBadge.tsx:30-35`).
- **Composer strip.** A "Run on" select (aria-label and group label `Run on`), one item per environment, `Auto balance` first when load balancing is on. Static label once the thread is locked (`C/BranchToolbarEnvironmentSelector.tsx:40-130`).
- **Routes.** `/pair` (primary pairing page or hosted pairing), `/welcome` (first-run wizard), `/connect` (hosted-only CLI login handshake, gated by `isHostedStaticApp()`, `W/cloud/connectCliAuth.ts:30`), `/connect-agent` (MCP agent approval, unrelated). Skip `/connect` and `/connect-agent` in the native app.
- **Clerk account modal** with custom pages `Mobile clients` and `T3 Connect` (`C/clerk/T3ConnectAccountPages.tsx:11-24`).

## 2. Status text

`connectionStatusText` (`R/connection/presentation.ts:60-79`):

| Phase | Text |
| --- | --- |
| available | `Available` |
| offline | `Offline` |
| connecting | `Connecting...` |
| reconnecting | `Failed to connect. Reconnecting... Reason: <error>` or `Reconnecting...` |
| connected | `Connected` |
| unsupported | `Client not supported` |
| error | `Connection failed. Reason: <error>` or `Connection failed` |

The Connections row subtitle uses shorter words (`C/settings/ConnectionsSettings.tsx:1452-1482`): `Off`, `Connected`, `Connecting`, `Reconnecting: <error>`, `Client not supported`, `Connection failed: <error>`, `Offline`, `Not connected`. Reconnecting and failed render in the destructive color. During a server update it reads `Restarting`.

Phase mapping (`R/connection/presentation.ts:34-58`): connecting is "connecting" only on attempt 1 with no earlier failure, otherwise "reconnecting". Backoff is "reconnecting". Blocked is "unsupported" when the failure reason is `unsupported`, else "error".

Subtitle format is `<transport> · <status>` plus the server version when it differs (`:1590-1599`). Transport (`C/settings/EnvironmentRow.tsx:26-52`) is `This machine`, `T3 Connect`, `WSL`, `SSH user@host`, the display URL, or `Remote link`. With several routes it reads `via <route>`. Route labels (`R/connection/routes.ts:170-189`): `T3 Connect`, `This device`, `LAN`, `Tailscale`, `SSH [user@]host`, hostname, `Remote link`. The tooltip adds `Switched off` or `Update available: <server> → <client>` (`:1604-1615`).

Cloud list rows (`C/cloud/CloudEnvironmentConnectList.tsx:337-390`) read `T3 Connect · Not added · Relay online|Relay offline|Checking relay status…|Relay status unavailable|Client not supported`, with `Saved without T3 Connect` replacing `Not added` for machines saved by another route. Saved-row button labels (`C/cloud/cloudEnvironmentConnectionPresentation.ts`) are `Connected`, `Connecting…`, `Reconnecting…`, `Client not supported`, `Connection failed`, `Offline`, `Not connected`.

Offline reason `tunnel_released` shows: `Offline for a while, so its T3 Connect tunnel was removed. Start T3 Code on that computer and update it to the latest version to reconnect.` (`R/relay/errorPresentation.ts:71-72`).

**Auth expired.** No banner and no dedicated screen. A rejected token ends in `Connection failed: <reason>` or `Reconnecting: <reason>`. Reasons seen in source: `Your cloud sign-in changed. Sign in again to authorize the environment.` (`R/authorization/service.ts:254`), `Relay rejected the cloud session token.`, and DPoP errors with a hint starting `Hint: Check that automatic date and time is enabled on both devices` (`R/relay/errorPresentation.ts:4-65`, copy that table when mapping relay errors). For old paired sessions a persistent toast says `Permissions have changed for <label>` / `This connection still uses the old permissions, so some actions may no longer be available. Pair again using a new link with the permissions you need.` with action `Open Connections` (`C/PermissionUpdateNotice.tsx:51-60`).

Errors with a trace ID get a `Copy trace ID` action and a row menu item.

## 3. Flows

### 3.1 Add by link, or by host and code

1. Environments header button `Add environment` (`:4089`).
2. Dialog `Add Environment` / `Pair another environment to this client.` (`:4098-4108`). Cards: `Remote link` / `Enter a backend host and pairing code.`; on desktop also `SSH` / `Use local SSH config, agent, and tunnels for the backend.`
3. Fields `Host` (placeholder `backend.example.com`) and `Pairing code` (`PAIRCODE`), hint `Paste a full pairing URL here to fill both fields automatically.` (`:2926-2950`). A pasted URL splits into host and code (`:331-360`); a bare host gets `https://`; hosted links with `?host=&token=&label=` also parse (`W/hostedPairing.ts:55-64`).
4. Button `Add environment` (`Adding…`). Errors show inline and as toast `Could not add backend`: `Enter a backend host.`, `Enter a pairing code.` (`:372-376`), else the server message or `Failed to add backend.`
5. Success toast `Backend added` / `The environment is saved and will reconnect on app startup.` (`:2658`).

Pairing the same machine again over another address adds a route. The dialog title becomes `Add a route to <label>` with `Pair this machine again over another address, such as its Tailscale name. It joins the existing routes instead of adding a second machine.` Toast `Route added` / `<label> now has another way to connect.` The route list (`C/settings/EnvironmentRoutesList.tsx`) has `Routes` / `<n> routes`, `In use` chip, drag handle, `Remove route`, `Add route`, aria-label `Routes to <label>, preferred first`. If the account also reaches the machine, the dialog offers `This machine is on your T3 Connect account. Use it as a fallback route.` with button `Add T3 Connect` (`:2990-3001`).

SSH mode (desktop only, `:3050-3116`) has fields `SSH host or alias`, `Username`, `Port` and toast `Environment connected`. Skip unless asked.

### 3.2 QR codes and pairing links (this machine as host)

QR is display only. No scanner exists on desktop or web.

1. "Authorized clients" > `Create link` opens `Create pairing link`. Optional label (placeholder `e.g. Living room iPad`), `Permissions` / `Limit what the paired client can do.`, quick buttons `Read only` and `Standard`, scope checkboxes, error `Select at least one permission.`, admin warning `This client can create or revoke access for other devices.`, buttons `Cancel` and `Create link` (`Creating…`) (`:1114-1225`). Failure toast `Could not create pairing URL` (`:1075`).
2. The row shows label (default `Pairing link`), `Link created at <time>` on the dot, expiry label, scope summary, buttons `Copy code`, `Show link` or `Show code`, `Revoke` (`:736-847`). Notes: `Create a new link to share from this client.` (`:753`), `Copy the token and pair from another client using this backend's reachable host.` (`:757`).
3. Expanded view: radio group `Reach this machine via`, `Copy link`, `Copy code only`, a 192 px QR (error level M, margin 1, title `Pairing link — scan to open on another device`), or for loopback `No QR for this endpoint. Another device scanning a loopback link would dial itself; copy the URL for use on this machine instead.` (`:863-937`).
4. Copy toasts: `Pairing URL copied`, `Pairing code copied`, `Hosted app link copied`; failures `Could not copy pairing URL`, `Clipboard copy unavailable` (`:666-690`).

The credential only lives in memory while the page stays open. Link shape is `<origin>/pair#token=<code>`. Code format and lifetime are in `C-auth-connect.md` 0.3.

### 3.3 Sign in to T3 Connect, see the account's environments

1. `Sign in to T3 Connect` (sidebar) opens Clerk's sign-in modal (`C/clerk/useT3ConnectAuthPrompt.tsx`).
2. After a fresh sign-in or account switch, `Set up T3 Connect` opens: `Mesh your devices together — publish this environment and connect the rest, all in one place.` Steps `Publish` and `Connect devices`; checkbox `Don't show this again` (stored per account, `W/cloud/connectOnboarding.ts`); buttons `Not now`, `Continue` (`Enabling…`), `Done` (`C/cloud/ConnectOnboardingDialog.tsx:242-325`).
   - Publish toggles: `Publish this environment` / `Make this environment available to your other devices through T3 Connect.` and `Publish agent activity` / `Send activity from this environment to your mobile clients for push notifications and Live Activities.` Toast `T3 Connect enabled` (`:223`). The step is skipped without relay read and write scopes.
   - Devices step lists other machines, or `No other environments are published to your account yet. Publish one from another device and it will show up here.` (`:418`).
3. Discovered machines appear under Environments with `Add` (`Adding…`, or `Add route`; disabled with tooltip if unsupported). Toasts `Environment added` / `Connecting to <label> through T3 Connect.`, `T3 Connect route added` / `<label> falls back to T3 Connect when its other routes are unreachable.`, failure `Could not connect environment` (`C/cloud/CloudEnvironmentConnectList.tsx:160-198`).
4. Empty: `No saved remote environments` / `Click “Add environment” to pair another environment, or connect one from T3 Connect.` (`:2005-2012`). Discovery failure: `Could not load T3 Connect environments`, the reason (`You appear to be offline.` when offline), button `Try again` (`CloudEnvironmentConnectList.tsx:293-312`).
5. Sign-out or account switch deletes every relay-only catalog entry and the token cache (`W/cloud/managedAuth.tsx:46-57`).

### 3.4 Link this machine to T3 Connect

No row says "Allow remote access". The control is a switch titled `T3 Connect` in "This machine", shown only when `window.desktopBridge` exists (`C/settings/ConnectionsSettings.tsx:1916`).

- Description off: `Make this environment available to your other devices through T3 Connect.` On: `This environment is available to your other devices through T3 Connect.`
- Disabled tooltips: `Sign in to T3 Connect to manage this environment.`, `Your session does not have permission to manage T3 Connect access.`. Without relay read: `To edit these settings, pair this connection with both View relay and Manage relay permissions.` (`:1991`).
- The toggle calls `reconcileCloudState` (`W/cloud/useCloudLinkController.ts`): needs the `relay:write` scope and a Clerk `t3-relay` token, links in mode `managed` or `publish_only`, sets preferences, refreshes discovery. Toasts `T3 Connect linked`, `T3 Connect unlinked`, `T3 Connect tunnel disabled` / `The managed tunnel was removed. Agent activity publishing stays on.`; failure `Could not update T3 Connect`. Error strings: `Local environment is not ready yet.`, `This connection needs permission to view and manage T3 Connect settings.`, `Wait until the current T3 Connect settings can be read.`, `Sign in to T3 Connect before enabling this.`
- Sibling rows `Publish agent activity` and, with the tunnel on, `Hold webhooks while offline` / `Keep webhook requests for up to 24 hours while this environment is offline, then deliver them. Off: T3 Connect only forwards requests and stores nothing.` (`:1900-1976`).
- If the server lacks the tunnel binary (RPC `cloud.getRelayClientStatus`), a dialog asks first: `Install relay client?` / `T3 Code needs the relay client to make this environment available through T3 Connect.`, card `Managed relay client`, buttons `Cancel` and `Download and install`. Progress shows seven steps (`Checking current installation` through `Activating installation`) as `n of 7` with `Keep T3 Code open while the relay client is installed.` (`C/cloud/RelayClientInstallDialog.tsx:60-123`, `W/cloud/linkEnvironment.ts:51-100`).

For CandyWrapper this row is optional. It manages the server it talks to, and only works if the Mac app can sign in to Clerk.

### 3.5 Rename, switch off, remove, revoke

- **Rename.** No UI found. Labels come from the server or pairing link.
- **Switch.** Row switch, tooltips `Switch off` / `Switch on`. Failure `Could not switch backend on|off`.
- **Remove locally.** Menu item `Remove from this device…`. Confirm: `Remove <label> from this device?` / `This forgets its pairing, credentials, and cached threads here. Switch it off instead to keep it saved.` (`:2821`). Failure `Could not remove backend`. For T3 Connect machines a different dialog adds `It stays on your T3 Connect account and keeps its host space. Deregister it in T3 Connect settings to free it.` with buttons `Cancel` and `Remove from this device` (`C/clerk/RemoveT3ConnectEnvironmentDialog.tsx:46-72`).
- **Deregister (account).** Clerk page `T3 Connect`: `Environments registered to your account. Connections on this device are managed in Settings.` Rows show `Linked <date>` and `Managed tunnel` or `Activity publishing only`. `Deregister` expands `Deregister server` / `"<label>" will be removed from this account.` / `T3 Connect access will be revoked, any managed tunnel will be removed, and a host space will become available. Local connections on your devices are not changed.` Buttons `Cancel`, `Deregister` (`Deregistering…`). Toasts `Server deregistered` / `T3 Connect access was revoked and a host space is now available.`, `Could not deregister server`. Empty `No T3 Connect environments` / `Link an environment from its local Settings to make it available through T3 Connect.` (`C/clerk/T3ConnectUserProfilePage.tsx:78-250`). Native replacement is `DELETE /v1/client/environment-links/:id`.
- **Revoke (host side).** `Revoke` per row, `Revoke others` in the header. Toast `Revoked 1 other client` or `Revoked <n> clients` / `Other paired clients will need a new pairing link before reconnecting.` Failures `Could not revoke pairing link|client access|other clients`. Session rows show a `This device` chip and `Connected` / `Not connected yet.` Empty: `No pairing links or client sessions.` (`:995`, `:1295`, `:2470-2540`).
- **Offline.** The row stays and says `Offline`. Reconnect is automatic with backoff.

### 3.6 Host-only and first-run screens (skip for M6)

Desktop host settings are the `Network access` switch (`Enable network access?` / `Disable network access?` confirms, `:3792-3830`), `Tailscale HTTPS` (`:3495`) and `Local environment` (`C/settings/LocalEnvironmentSetting.tsx:44-70`). CandyWrapper does not start servers. The welcome wizard (`C/onboarding/WelcomeWizard.tsx:338-640`, field `Pairing link`, button `Pair`, `npx t3 connect`, `npx t3 pair`) and `/pair` (`Pair with this environment`, field `Pairing token`, `C/auth/PairingRouteSurface.tsx:24-250`) are replaced by the Add Environment sheet.

## 4. Web content and JS runtime

Only Clerk needs it. Everything else above is forms, lists, dialogs and toasts.

- **Sign-in modal** (`clerk.openSignIn`). Clerk's JS renders email, social and passkey sign-in. Desktop uses `@clerk/electron` with redirect `t3code://app/` and passkeys (`D/app/DesktopClerk.ts:79-90`, `C/clerk/ElectronManagedAuthShell.tsx`). Web hotloads clerk-js (`BrowserManagedAuthShell.tsx`).
- **Account modal** (`UserButton`). Hosts the two custom pages. Replace both with native views backed by `GET /v1/environments` and the deregister call. Only profile edits (email, password, sessions) would need Clerk's UI.
- **Gate.** The feature hides unless the publishable key, JWT template and relay URL are set (`W/cloud/publicConfig.ts:72-76`). Production values: `C-auth-connect.md` 0.4.

What the native side must do around a web sign-in:

1. Create the WKWebView (or `ASWebAuthenticationSession`) only when the user presses `Sign in to T3 Connect`. Destroy it when the sheet closes.
2. Catch the redirect with a CandyWrapper URL scheme. Clerk only accepts allowlisted redirects (`t3code://app/`, `t3code-dev://app/`, `docs/operations/connect-setup.md:63-76`) and only T3's operators can add ours. This is the main blocker. The loopback or device OAuth flow with the public CLI client id (`C-auth-connect.md` section 4) avoids it and needs no WebView beyond the system browser.
3. Keep tokens in the Keychain. On sign-out or account switch, delete relay-only entries and cached relay tokens first.
4. Offer the onboarding choice after each new sign-in unless the account opted out.

## 5. Desktop-only behavior

- **Menu.** `Settings...` with `CmdOrCtrl+,` in the app and File menus sends `open-settings` (`D/window/DesktopApplicationMenu.ts:141-178, 200-203`). No connections-specific item.
- **URL scheme.** `t3code` (production), `t3code-dev` (development) (`D/electron/ElectronProtocol.ts:16-17`). It also serves the renderer, for example `t3code://app/settings/connections`. The `open-url` and `second-instance` handlers only act on ChatGPT sign-in handoff and provider auth return (`D/app/DesktopClerk.ts:187-199`). **No handler opens a pairing link.** Users paste `https://...#token=` URLs by hand, so a native `t3code://` pair handler would be new behavior; ask before adding one.
- **Bridge methods for connections** (`D/preload.ts:105-188`). Catalog (`getConnectionCatalog`, `setConnectionCatalog`, `clearConnectionCatalog`), stored encrypted with Electron safeStorage (`D/app/DesktopConnectionCatalogStore.ts:25`); the native version is a Keychain store. Local environment (`getLocalEnvironmentBootstraps`, `getLocalEnvironmentBearerToken`, `get/setLocalEnvironmentEnabled`). SSH (`discoverSshHosts`, `resolveSshHost`, `ensureSshEnvironment`, `disconnectSshEnvironment` and five session helpers). Exposure (`getServerExposureState`, `setServerExposureMode`, `setTailscaleServeEnabled`).
- **Bridge-gated UI.** The `T3 Connect` link switch, `Network access`, `Tailscale HTTPS`, `Local environment`, SSH mode. Viewing remote environments, pairing by code and T3 Connect discovery work without the bridge.

## 6. Suggested M6 scope

Environments list with the section 2 strings and 3.5 menu, Add Environment (Remote link only), T3 Connect sign-in once the section 4 decision is made, sidebar machine icon, project badge and "Run on" picker. Later: SSH, QR display, link switch, onboarding, load balancing.

## 7. Not determined

- No rename UI found for saved environments.
- Whether the production Clerk instance accepts a custom redirect for the OAuth route.
- Whether a Clerk session cookie in a WKWebView can mint `t3-relay` JWTs without clerk-js.
- Copy of the `Permissions` panel (`C/settings/SessionPermissions.tsx`) and the load balancing options, which the docs name `Normal`, `Prefer`, `Less often`, `Manual only` (`docs/user/remote-access.md`).
- A distinct UI for an expired or revoked bearer session on a paired remote; only the generic failure text exists.
