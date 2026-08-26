# Authentication & Organizations

This doc covers how Erebrus AI signs users in and how organization / workspace
models are shared. It is meant for developers integrating or debugging auth.

---

## Supported sign-in methods

The app picks the right path at runtime based on `PlatformCapabilities`:

| Platform | Primary method | Notes |
|----------|----------------|-------|
| Solana Mobile (Seeker / Saga) | Mobile Wallet Adapter (MWA) | Native wallet selector, signed challenge. |
| Desktop (macOS / Windows / Linux) | Web login (`erebrusai://auth`) | Browser opens erebrus.io; PASETO returns via deep link. |
| Other mobile | Reown AppKit modal | Solana or EVM wallet modal. |
| All platforms | Social (Google / Apple) | Used when the gateway advertises those methods. |

---

## Environment variables

Copy `env.example` to `.env` and set the values before running:

```bash
cp env.example .env
```

| Variable | Required for | Description |
|----------|--------------|-------------|
| `REOWN_PROJECT_ID` | Reown modal | Your Reown / WalletConnect project id. |
| `EREBRUS_WEB_ORIGIN` | Desktop web login | Allowed origin for web auth (e.g. `https://erebrus.io`). |
| `GOOGLE_SERVER_CLIENT_ID` | Google sign-in | Server-side OAuth client id. |
| `APPLE_SERVICE_ID` | Apple sign-in | Apple service identifier. |
| `APPLE_REDIRECT_URI` | Apple sign-in | Apple redirect URI. |
| `GATEWAY_URL` | Gateway client | Erebrus gateway base URL. Defaults to `https://gateway.erebrus.io`. |

`.env` is bundled as a Flutter asset and parsed by `RuntimeConfig` at startup.
For CI or release builds you can also pass these as `--dart-define` values.
OAuth client IDs and redirect URLs are public configuration identifiers, not
client secrets. The repository contains production defaults where applicable;
explicit `.env` values override them for development and alternate deployments.

---

## Deep links

- **Scheme:** `erebrusai`
- **Host:** `auth`
- **iOS / macOS:** registered in `CFBundleURLTypes`.
- **Android:** registered as a `VIEW` intent filter for `erebrusai://auth`.

`DeepLinkHandler` receives the URL and either:

1. routes it to `WalletAuthController.handleWebAuthCallback()` for desktop web
   auth, or
2. dispatches it to `ReownAppKitModal.dispatchEnvelope()` for mobile Reown
   callbacks.

### Desktop web login flow

1. `DesktopWebAuth.buildLoginUrl()` creates a URL with a random `state`.
2. `url_launcher` opens the URL in the system browser.
3. User authenticates on `erebrus.io`.
4. Browser redirects to `erebrusai://auth?token=...&state=...`.
5. `DeepLinkHandler` parses and validates the state.
6. `WalletAuthController` persists the session.

---

## Session persistence

`AuthSessionStore` uses `flutter_secure_storage`:

- `erebrus_ai_gateway_token`
- `erebrus_ai_wallet_address`
- `erebrus_ai_user_id`
- `erebrus_ai_user_role`
- `erebrus_ai_auth_method`
- `erebrus_ai_mwa_auth_token`

The token is read at startup in `WalletAuthController.initialize()`.

---

## Organizations

`OrgState` fetches the user's organizations from the gateway and, for the
selected organization, lists shared models.

- `OrgClient.fetchOrganizations(token)` — list orgs the user belongs to.
- `OrgClient.fetchOrgModels(orgId, token)` — list models shared in the org.
- `OrgClient.inviteMember(...)` — invite a wallet/email to an org.
- `OrgClient.sharePersona(orgId: …, personaId: …, bearerToken: …)` — share a persona.

The UI surfaces org data in:

- `SettingsScreen` — account card, org card, pending invites.
- `ModelsScreen` — signed-in users see an org node card with shared models.
- `PersonaEditor` — share toggle shows the selected org name.

---

## Gateway API v2

`GatewayAuthClient` covers:

- `fetchFlowId(walletAddress, chain)` — start wallet login.
- `authenticate(...)` — complete login with signature.
- `fetchSubscription(token)` — entitlement status.
- `fetchProfile(token)` — user profile.
- `fetchAccountOrgInvites(token)` — pending org invites.
- `createOrg(name, slug, token)` — create a new org (`POST /api/v2/orgs`).
- `redeemReferralCode(code, token)` — redeem a referral / invite code
  (`POST /api/v2/referrals/redeem`).
- `fetchReferralSummary(token)` — the caller's code, referrer, and referees
  (`GET /api/v2/referrals/me`).
- `fetchRank(token)` — the caller's XP standing (`GET /api/v2/rank/me`).

Base URL is configured by `GATEWAY_URL` (default `https://gateway.erebrus.io`).

> **Note on org paths.** The gateway exposes org collection/creation at
> `/api/v2/orgs` while per-org sub-resources (`/models`, `/personas`,
> `/invites`) live under `/api/v2/organizations/{id}`. Keep this split in mind
> when adding endpoints — confirm the correct prefix with the gateway team
> rather than assuming one form.

---

## Referrals & XP

A user redeems a referral / invite code from **Settings → Referrals** (the
`_ReferralCard`). The APPLY button calls `AppState.redeemReferralCode(code)`,
which delegates to `WalletAuthController.redeemReferralCode` →
`GatewayAuthClient.redeemReferralCode` (`POST /api/v2/referrals/redeem`).

Redeeming binds the caller's *referrer* — one per account, ever. XP is awarded
to **both** the referee and the referrer, but only once the referee **qualifies**
(has an active organization membership); binding before then simply records the
relationship and the award reconciles later. The redeem response is the caller's
referral summary, not an XP payload:

```json
{ "code": "ABC12345", "referred_count": 0, "referral_bound": true,
  "referred_by": "wallet…addr", "recent": [] }
```

Gateway errors are a **flat** envelope — `{"error": "invite code not found"}`
(404), `{"error": "you can't redeem your own invite code"}` (400),
`{"error": "an invite code is already applied to this account"}` (409).

### XP display

Lifetime XP is **not** on the account profile (`GET /api/v2/account/profile`).
It comes from `GET /api/v2/rank/me` as `xp_earned` (`RankStanding.xpEarned`,
exposed as `AppState.xpEarned`). The controller refreshes rank after sign-in,
session restore, and a successful redeem, so the account card's `XP` badge stays
current.

### Captured codes

`AppState.capturedReferralCode` lets a code be pre-filled into the field before
the user redeems it (e.g. from a future share/deep link). Deep-link capture is
**not wired yet** — the field is filled manually today, and
`setCapturedReferralCode` is the seam a deep-link handler would call.

---

## Testing auth in widget tests

Real wallet / social plugins cannot run under `flutter test`. The smoke tests in
`test/screens_smoke_test.dart` inject auth/org controllers and toggle
`AppState.signedIn` directly to verify the signed-in UI surfaces.
