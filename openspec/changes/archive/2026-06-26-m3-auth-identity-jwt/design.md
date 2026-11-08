# Design notes — M3 Auth (Identity + JWT)

These are the decisions worth reviewing before implementation. Defaults chosen are noted; flag any you'd change.

## 1. How much of Identity to hide behind ports (the hexagon tension)

ASP.NET Core Identity (`UserManager`, `SignInManager`, `IdentityUser`) is deeply
framework- and EF-coupled. Fully abstracting it behind driven ports
(`IUserRepository`, `IPasswordHasher`, …) would re-implement most of Identity for
little value on a single-app project.

**Decision:** treat auth as an **infrastructure capability** exposed through one
**driving port** `IAuthService` (in Application, with plain DTOs). The
implementation `IdentityAuthService` lives in **Infrastructure** and uses
`UserManager<AppUser>`/`SignInManager` + `TokenService` directly. The controller
depends only on `IAuthService` — so the API layer stays free of Identity, which
is the boundary rule that actually matters here. We are *not* re-abstracting
Identity's internals.

Consequence: `AppUser : IdentityUser` lives in **Infrastructure**, not Domain —
`IdentityUser` is a framework type and Domain must stay framework-free. The
domain only ever sees a user **id string** (`Coffee.CreatedByUserId`).

## 2. Result shape — no exceptions for expected failures

`IAuthService` returns a typed result (`AuthResult` with a status enum:
`Success`, `RegistrationDisabled`, `InvalidCredentials`, `LockedOut`,
`DuplicateUser`, `WeakPassword`, …) plus the token on success. The controller
maps status → HTTP code (200 + token, 400, 401, 403, 423/429). Identity's own
`IdentityResult` errors are folded into these.

## 3. JWT signing key — fail fast, no default

`Jwt:Key` is read at startup. If it is missing or shorter than a safe minimum
(e.g. < 32 bytes / 256 bits, the floor for HS256), the app **throws and refuses
to start** — never falls back to a baked-in default. `Jwt:Issuer`/`Jwt:Audience`
default to `coffee-tracker`. Production injects `Jwt__Key` via env only; a
throwaway key may sit in `appsettings.Development.json` for convenience (it is
not a real secret and the README already documents `openssl rand -base64 48`).

## 4. `IsAdmin` as a claim, not Identity Roles

**Decision:** model admin as a single `IsAdmin` bool on `AppUser`, emitted as a
custom claim in the JWT — not the full ASP.NET Identity Roles system. The app has
exactly one privilege level beyond "user", so Roles would be overkill. Revisit if
M4+ needs finer-grained roles.

## 5. First-user-becomes-admin bootstrap

With `REGISTRATION_ENABLED=true`, the very first successful registration sets
`IsAdmin = true`; all later registrations are non-admin. "First" = there are no
existing users at insert time. This is a deliberate, documented bootstrap so a
fresh self-hosted instance has an admin without a seeding step. (A race on two
simultaneous first registrations is acceptable for this single-instance app; the
user-count check happens just before create.)

## 6. Which endpoints require auth

**Decision:** an account is mandatory to use the app, so **all** catalog
endpoints require a valid token — reads (`GET`) included, not just writes. Apply
`[Authorize]` at the `CoffeesController` level; only `register`/`login` are
anonymous (and the dev-only Swagger/OpenAPI middleware).

This is driven by the deployment: the app is meant to be internet-exposed behind a
reverse proxy, possibly with a forward-auth gateway in front. The app deliberately keeps
its **own** login behind such a gateway (defense-in-depth) rather than trusting the edge
alone. A future option is to make the app's login **SSO through an OIDC provider** — the
`IAuthService`/JWT-bearer boundary keeps that swap open, but M3 implements only
native credentials.

## 7. Stamping the owner — `ICurrentUser` driven port

Rather than thread a `userId` parameter through every write method, add a driven
port `ICurrentUser { string? Id }` in Application, implemented in the Api layer
over `IHttpContextAccessor` (reads the `sub`/NameIdentifier claim).
`CoffeeCatalogService.CreateAsync` stamps `CreatedByUserId` from it. This keeps
the service signature stable and is trivially faked in tests. Update/delete do
**not** yet enforce ownership (any authenticated user can edit any coffee) —
ownership-based authorization is an M4 concern (reviews are per-user); M3 only
records the creator. Flag if you want per-coffee ownership enforced now.

## 8. Rate limiting

Use the built-in `AddRateLimiter` (a fixed-window or sliding limiter) applied as
a named policy on the `auth` endpoints only, keyed by client IP. Tuned to allow
normal use but throttle credential-stuffing. Returns `429` when tripped.

## Migration

Switching `AppDbContext : DbContext` → `IdentityDbContext<AppUser>` changes the
model, so a new EF migration (`AddIdentity`) is generated, adding the
`AspNet*` tables. It applies on startup via the existing `MigrateAsync` path. The
existing `Coffees` table is unaffected.
