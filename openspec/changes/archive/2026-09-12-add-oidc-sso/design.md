## Context

The app ships app-native auth from M3: ASP.NET Identity for the user store, a short-lived JWT signed by `TokenService`, a rotated refresh token, and an `IsAdmin` boolean carried as a claim. The Angular client holds that session in `AuthStore` and attaches the token in `auth.interceptor.ts`. Every downstream authorization decision — `Coffee.IsModifiableBy`, `Review.IsDeletableBy`, the `Admin` policy on `AdminPhotosController` — reads from that JWT.

Behind a forward-auth gateway that is also an identity provider, users log in twice. But the app is public and meant to be self-hostable by anyone, which rules out coupling it to a specific identity provider or making one mandatory.

Two facts about the existing code shape this design:

- ASP.NET Identity already provides `AspNetUserLogins` (`LoginProvider` + `ProviderKey` → user) and the `UserManager.FindByLoginAsync` / `AddLoginAsync` API. This is exactly the external-identity mapping this change needs; no new table is required for it.
- The JWT + refresh machinery is mature and tested. Anything that preserves it keeps the blast radius small.

## Goals / Non-Goals

**Goals:**

- Sign in through any standards-compliant OIDC provider, discovered from `/.well-known/openid-configuration`.
- Leave the app fully functional, and visually unchanged, when no provider is configured.
- Keep one identity per human: an OIDC sign-in resolves to the same `AppUser` that owns their existing coffees.
- Let an admin decide, at runtime, whether app-created accounts may still register and sign in.
- Make it impossible to disable the last usable way in.

**Non-Goals:**

- Replacing the app's own JWT with provider tokens. The provider authenticates; the app keeps authorizing with its own short-lived token.
- Multiple simultaneous providers, back-channel logout, provider-side user provisioning, or role mapping beyond `IsAdmin`.
- Any provider-specific code path. Providers are named only in documentation, as examples.

## Decisions

### 1. The SPA runs the code flow; the API validates the resulting ID token

The Angular client performs Authorization Code + PKCE against the provider and posts the resulting **ID token** to a new `POST /api/auth/oidc`. The API validates it against the provider's JWKS — signature, issuer, audience equal to our client id, expiry — spends it once, then links or creates the user and returns the **existing** `AuthResponseDto`.

*Why:* everything after sign-in is untouched — the interceptor, the refresh rotation, the `IsAdmin` claim, the guards, the policies. The change is additive, and the local login keeps working beside it with no branching downstream.

*Alternative considered — backend-for-frontend (server-side flow, session cookie).* It is the stronger modern pattern: no token in JavaScript, no token in `localStorage`. Rejected here because it would replace the JWT and refresh model wholesale, rewriting `AuthStore`, `auth.interceptor.ts`, `TokenService` and their tests — a far larger change for a benefit the threat model does not demand on a single-tenant self-hosted app. Worth revisiting if the app ever becomes multi-tenant.

*Alternative considered — SPA posts the authorization code, API exchanges it.* Marginally better (the token never reaches JS) but requires the API to hold a client secret, which makes the provider a confidential client and complicates the self-hoster's setup. Rejected as not worth the configuration cost.

### 2. Identity mapping reuses `AspNetUserLogins`

`LoginProvider` holds the provider's issuer, `ProviderKey` holds the `sub` claim. Resolution order on sign-in:

1. `FindByLoginAsync(issuer, sub)` — the stable path for every sign-in after the first.
2. Otherwise, if the token carries `email` **and** `email_verified: true`, find the local user by that email and attach the login.
3. Otherwise, create a user and attach the login.

A token carrying an email that matches an existing user **without** `email_verified` is refused outright — not linked, not turned into a second account. Silently creating a duplicate would strand the user's coffees on the old account, and linking would let a provider that does not verify emails take over an account.

*Why `sub` and not email as the key:* emails change. `sub` is the only identifier the spec guarantees stable per issuer.

### 3. Admin comes from a configured claim, falling back to bootstrap

`Oidc:AdminClaim` and `Oidc:AdminClaimValue` (e.g. `groups` / `admins`) map an assertion to `IsAdmin`, re-evaluated on every sign-in so revoking the group in the provider takes effect at next sign-in. With no mapping configured, the first OIDC user to sign in is promoted by the same race-free conditional UPDATE that bootstraps the first local user, and subsequent users are not.

*Why re-evaluate every time:* an admin flag that only ever gets set is a flag that can never be revoked from the provider — the whole point of centralising identity.

### 4. The local-account policy is two persisted settings, not configuration

A single `AppSettings` row holds `LocalLoginEnabled` and `LocalRegistrationEnabled`, read through a port so the application layer stays free of storage concerns, and served to the client through the existing `GET /api/config`. `PUT /api/admin/settings` updates them behind the existing `Admin` policy.

*Why persisted rather than an env var:* the request is a toggle in the admin view. A setting an admin flips at runtime cannot live in a file that requires a container restart.

*Why two settings and not one.* A single flag was the first design, and it is unrepresentable on upgrade. `REGISTRATION_ENABLED` defaults to `false`, and "registration closed, login open" is the recommended posture once an instance is set up — so a merged flag seeded from it would lock every such deployment out, and seeded to `true` would silently reopen registration on every deployment that had closed it. There is no third value. Two settings seed to exactly the behaviour each deployment already had.

*The incoherent state this admits* — "may register, may not log in" — is real but harmless: registration succeeds and the new account simply cannot sign in until login is re-enabled. The admin view shows both settings together, so the combination is visible rather than surprising.

### 4b. `REGISTRATION_ENABLED` disappears; a fresh instance opens itself

The row is created once, at startup, when it is absent:

- **An instance that already has users** (an upgrade) seeds `LocalLoginEnabled = true` and `LocalRegistrationEnabled` from `REGISTRATION_ENABLED`. This is the only read of that variable, and it exists solely so no existing deployment changes behaviour.
- **An instance with no users** (a fresh install) seeds `LocalLoginEnabled = true` and `LocalRegistrationEnabled = true`, so the operator can create the first account. Registration closes itself as soon as that first account exists.

*Why self-closing rather than an env var:* requiring an environment variable to create the very first account is friction that every new self-hoster pays, and a variable that only matters once is a variable people later change expecting an effect. Opening registration exactly while there is nobody to protect, and closing it the moment there is, needs no configuration and leaves no trap.

*Why the variable is not simply deleted:* dropping it outright would reopen registration on upgraded instances that had deliberately closed it. It survives as a one-shot migration input, documented as such, and is otherwise ignored.

### 4c. Replay is closed by spending the token, not by a server-issued nonce

The API remembers each token it has exchanged — by its `jti`, or a hash of the token when the provider mints none — until that token expires, and refuses a second exchange.

*Why not the OIDC nonce, which is what normally binds a token to one authorization request:* `angular-auth-oidc-client` generates the nonce itself (`flowsDataService.createNonce`) and exposes no way to impose one from the server. A nonce the client both creates and presents proves nothing to the API, so the alternative was to hand-roll the authorization request — the very thing decision 5 takes the dependency to avoid. Single use is what is actually enforceable here, and it closes the same attack: a token captured from a log, a proxy or an extension cannot be exchanged a second time.

*What it does not close:* an attacker who obtains a token **before** the legitimate client exchanges it can still spend it first. Nothing short of the backend-for-frontend flow (decision 1's rejected alternative) closes that, and the token's few minutes of life bound the window.

### 5. The lock-out guard is derived, not stored

Turning `LocalAccountsEnabled` off is refused unless at least one user satisfies `IsAdmin = 1` **and** has a row in `AspNetUserLogins` for the configured issuer — i.e. an admin has actually completed an OIDC sign-in. The API answers `409 Conflict` with an explanation the admin view renders inline.

*Why derived:* the condition is a query over state that already exists. A stored "OIDC has been proven to work" flag would be one more thing to keep truthful.

*Note:* the guard constrains only the act of disabling local accounts. An operator who never configures OIDC never encounters it.

### 6. Absent configuration means the feature does not exist

If `Oidc:Authority` or `Oidc:ClientId` is missing, the OIDC services are not registered, `GET /api/config` reports no provider, and the client renders no provider action. Partial configuration fails fast at startup with a clear message rather than presenting a sign-in button that cannot work — the same stance the existing code takes on a missing `Jwt:Key`.

## Risks / Trade-offs

- **A provider that lies about `email_verified` can take over an account** → The risk is inherent to email-based linking. Mitigated by requiring the claim rather than assuming it, and by the operator choosing their own provider. An operator who does not trust their provider can leave linking unused by giving OIDC users distinct emails.
- **The ID token passes through JavaScript and is exchanged for an app token** → Mitigated by full validation server-side (signature, issuer, audience, expiry), by the token being single-use for the exchange, and by the app's own short-lived JWT being what is actually stored afterwards. Accepted as a deliberate trade against the BFF rewrite (decision 1).
- **Removing `REGISTRATION_ENABLED` as the live source of truth is a breaking change** → Mitigated by seeding the setting from it on migration, so no deployment changes behaviour on upgrade. Documented in the README and the `deployment` spec.
- **Admin re-evaluated from the claim on every sign-in can demote the only admin** → If the claim mapping is configured and nobody carries the value, the deployment ends up with no admin. Mitigated by the bootstrap fallback applying only when no mapping is configured, and by the lock-out guard keeping local sign-in available in exactly that scenario.
- **Discovery makes a network call at startup** → A provider that is slow or down must not prevent the app from booting. Discovery is lazy and cached, and a failure degrades to "provider unavailable" in `GET /api/config` rather than a failed startup.

### 7. Every deployment carries the OIDC library, configured or not

`provideAuth` has to run in the root injector, so `angular-auth-oidc-client` lands in the initial bundle even on an instance with no provider. That is roughly 43 kB raw (~13 kB transferred), and the initial-bundle warning threshold moves from 500 kB to 560 kB to account for it.

*Why accept it:* moving the library behind a dynamic import would mean building the flow around a lazily-resolved service and losing the library's own bootstrap handling — real complexity for a cost that is a fraction of a single photo. Recorded here rather than absorbed silently, so the trade is visible if the bundle ever becomes the constraint.

## Migration Plan

1. Ship the migration (settings table) and the seeding from `REGISTRATION_ENABLED`. At this point behaviour is identical and OIDC is dormant.
2. The operator adds the `Oidc` section and restarts; the sign-in screen gains the provider action. Local accounts still work.
3. An admin signs in through the provider at least once, which satisfies the guard.
4. Optionally, the admin turns local accounts off.

**Rollback:** remove the `Oidc` configuration and restart — the provider action disappears and local sign-in is unaffected, provided the setting is back on. If it was turned off, it is a single row to flip back, either from the admin view of a still-valid admin session or in SQL. The migration itself is additive and needs no rollback.

## Open Questions

None outstanding. The two questions raised while drafting are settled:

- **Angular OIDC library — resolved: `angular-auth-oidc-client`.** (Renumbered as decision 5 in this document.) Version 22.0.0 (MIT, published 2026-08-15) declares `@angular/core >=20.0.0` and tracks Angular's major releases closely, so the app's Angular 22 is covered. Hand-rolling code + PKCE was the alternative; rejected because the flow is small to write and easy to get subtly wrong in ways that only fail as a security hole, and this is the one dependency worth taking for that reason. Pin the exact version.
- **Provider diagnostics in the admin view — resolved: deferred.** Showing which provider is configured and whether discovery currently succeeds is diagnostics, not policy, and the admin view in this change is about policy. Revisit only if a misconfiguration proves hard to diagnose from logs.
