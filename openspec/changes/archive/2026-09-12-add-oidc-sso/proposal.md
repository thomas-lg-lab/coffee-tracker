## Why

Behind a forward-auth gateway, users authenticate twice: once at the reverse proxy, then again against the app's own login form. M3 shipped app-native Identity and explicitly left "a future OIDC SSO path open"; this change takes it.

The constraint that shapes the design: **the app must stay usable by someone self-hosting it without any identity provider**. OIDC is therefore an optional, standards-based add-on — never provider-specific, never mandatory. Local accounts remain the default and the only thing an operator has to understand.

## What Changes

- **Optional OIDC login.** When an OIDC provider is configured, the client offers a "Sign in with <provider>" action using Authorization Code + PKCE. When it is not configured, nothing about the app changes and no OIDC affordance is shown.
- **Provider-agnostic configuration.** Authority, client id, scopes and claim mappings come from configuration; the app discovers endpoints from the provider's `/.well-known/openid-configuration`. No provider name appears in the code.
- **Account linking on verified email.** An OIDC identity whose `email` matches an existing user is linked to that account **only when the token asserts `email_verified`**; otherwise the sign-in is refused rather than silently creating or hijacking an account. Linked identities are recorded in ASP.NET Identity's existing `AspNetUserLogins` table, so subsequent sign-ins match on the stable issuer + subject pair, not on the email.
- **Admin from a configurable claim, with bootstrap fallback.** An operator maps a claim and value (e.g. `groups` contains `admins`) to `IsAdmin`. With no mapping configured, the first OIDC user to sign in bootstraps as admin, mirroring the existing local rule.
- **Local-account policy, toggled from the admin view.** Two persisted settings govern whether app-created accounts may sign in and whether new ones may be registered. Both are stored in the database and editable by an admin at runtime.
- **A guard against lock-out.** Turning local sign-in off is refused while no admin has ever completed an OIDC sign-in — the only other door into the app. Registration carries no such condition.
- **BREAKING** — `REGISTRATION_ENABLED` is removed. A fresh instance opens registration until its first account exists, then closes it by itself, so no variable is needed to bootstrap. On an instance that already has users, the variable is read once to seed the registration setting, so existing deployments keep their posture; afterwards the admin view owns both settings.
- `GET /api/config` additionally reports whether local sign-in is accepted, whether registration is open, and whether an OIDC provider is available, so the client can render the right sign-in options.

Out of scope: refresh-token flows against the provider (the app keeps issuing its own short-lived JWT after sign-in, as today), back-channel logout, multiple simultaneous providers, provisioning users from the provider before their first sign-in, and per-group role mapping beyond the single `IsAdmin` flag.

## Capabilities

### New Capabilities

None. OIDC sign-in and the local-account policy are new requirements of the existing `auth` capability rather than a separate concern: they govern who may obtain a token, which is what `auth` already covers.

### Modified Capabilities

- `auth`: gains sign-in through an external OIDC provider, identity linking rules, claim-driven admin assignment, and a runtime local-account policy with its lock-out guard and self-closing first-account bootstrap. The registration requirement moves from a deploy-time flag to that policy.
- `web-client`: the sign-in screen gains a provider action when one is configured and hides the local form when local sign-in is off; the admin view gains both local-account toggles, including the refused state and its explanation.
- `deployment`: documents the optional OIDC configuration keys and the removal of `REGISTRATION_ENABLED`.

## Impact

- **New package:** an OIDC client library for the Angular app (Authorization Code + PKCE). The API validates the provider's tokens with `Microsoft.AspNetCore.Authentication.OpenIdConnect` / JWT bearer against the discovered JWKS — no new server-side identity framework.
- **Modified projects:**
  - `CoffeeTracker.Application` — a driving port for external sign-in, DTOs, and a port for reading/writing the account policy; `ConfigDto` grows three fields.
  - `CoffeeTracker.Infrastructure` — an external-identity adapter (link-or-create over `UserManager.FindByLoginAsync` / `AddLoginAsync`, claim→`IsAdmin` mapping) and a persisted settings store.
  - `CoffeeTracker.Api` — the sign-in endpoint, the admin settings endpoints, and wiring for provider discovery.
  - `frontend/packages/auth` — provider sign-in in `auth.store.ts` and `login.ts`; the admin view gains the toggle.
- **New EF migration:** a single-row settings table holding the two local-account flags, seeded at startup as described above. External identities need no new table — `AspNetUserLogins` already maps provider + subject to a user.
- **Configuration:** a new optional `Oidc` section (authority, client id, scopes, admin claim and value). Absent or incomplete, the feature stays dormant. `REGISTRATION_ENABLED` is read at most once, only on an instance that already has users, then ignored.
- **Behaviour change:** operators who set `REGISTRATION_ENABLED` expecting it to take effect on every restart must instead use the admin view. A fresh install no longer needs it at all. Documented in the README and the deployment spec.
- **Security surface:** sign-in now trusts assertions from an external issuer. The linking rule, the `email_verified` requirement, issuer and audience validation, and the lock-out guard are the mitigations, and each needs a test.
