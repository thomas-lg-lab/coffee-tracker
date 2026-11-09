# Deployment & operations runbook

How an instance of Coffee Tracker is deployed and kept running. The model is **GitHub Actions →
GHCR (public image) → the host pulls the image**; nothing pushes to the host. Images cover
`linux/amd64` and `linux/arm64`.

Canonical image: `ghcr.io/thomas-lg-lab/coffee-tracker`. Tags: `latest` (last release), `X.Y.Z`,
`X.Y` and `X` (releases, without the `v`), `edge` (every merge to `main`, for trying a change before
a release) and `sha-<short>` (ephemeral: pruned after 30 days, never pin one). Pin a version or a
digest for anything that must keep pulling.

---

## 1. Make the GHCR package public (one-time, GitHub UI)

So the NAS can pull without authenticating. There is no REST API for this, do it in
the web UI:

1. Go to the package: **https://github.com/orgs/thomas-lg-lab/packages/container/package/coffee-tracker**
2. **Package settings** → **Danger Zone** → **Change visibility** → **Public**.

Verify from any Docker host (no login):

```bash
docker pull ghcr.io/thomas-lg-lab/coffee-tracker:latest
```

---

## 2. Branch protection on `main` (applied)

Two rulesets, kept as code in [`.github/rulesets/`](../.github/rulesets/) and applied with the
organisation's `apply-standards.sh` (thomas-lg-lab/.github):

- **Protect main**: pull request required (no approval, solo maintainer), squash only, linear
  history, signed commits, no deletion or force push, no bypass. Required checks, **up to date**:
  `conventions / title`, `backend`, `frontend`, `e2e`, `image / build`, plus CodeQL results
  (default setup). `e2e` matters more than its name suggests, it runs the OpenAPI drift guard,
  so without it a backend contract change can merge with a stale typed client.
- **Code owner review**: a change under `.github/` needs the code owner's approval.

---

## 3. Install on Unraid (manual, per host)

The app keeps its **own** login (every endpoint needs a token); still put it behind a
TLS-terminating reverse proxy (SWAG/Authelia/NPM/Traefik): the PWA and camera need a
secure context. Don't publish the container port directly to the internet.

1. Copy [`unraid/my-coffee-tracker.xml`](./unraid/my-coffee-tracker.xml) to
   `/boot/config/plugins/dockerMan/templates-user/my-coffee-tracker.xml` on the NAS.
2. **Add Container** → Template: **User templates** → `coffee-tracker`.
3. Map the volumes and set the env vars:
   - `/config` → e.g. `/mnt/user/appdata/coffee-tracker/config` (SQLite DB)
   - `/photos` → e.g. `/mnt/user/appdata/coffee-tracker/photos` (uploads)
   - **`Jwt__Key`** (required), `openssl rand -base64 48`
   - **`ForwardedHeaders__KnownProxies`**, your reverse proxy's name or IP
   - **`PUID`/`PGID`**, match the host owner of the appdata dirs (Unraid default
     `99`/`100`); the container chowns the volumes to this on start and drops to it.
   - **`Oidc__Authority` / `Oidc__ClientId`** *(optional)*, an OpenID Connect provider
     to sign in through; see the app README for the rest of the `Oidc__*` settings.
4. **Bootstrap the admin:** start the container and register at `/register`. A fresh
   instance accepts exactly one account, the first, and closes registration behind it.
   Both settings live in **Admin → Account settings** from then on.
5. Point the reverse proxy at the container's `8080`.

### Behind SWAG + Authelia

The app runs fine behind a forward-auth gateway, but two things are worth knowing.

**Bypass Authelia for `/api`.** Every API endpoint already requires the app's own JWT
(plus rate-limited login), so gate only the pages with Authelia and let the API defend
itself, the same model the sonarr/radarr sample confs use for their API keys:

```yaml
access_control:
  rules:
    - domain: coffee.example.com
      resources: ['^/api/.*']
      policy: bypass
```

Keep everything else (including `/photos`, which has **no** app-level auth) behind
Authelia. Without the bypass, an expired Authelia session makes every API call fail
with a gateway 401 while the page still renders, the app detects that (a 401 without
the API's `WWW-Authenticate: Bearer` challenge) and does one full-page reload so
Authelia can re-authenticate the browser.

**Why this app behaves differently from non-PWA containers.** The service worker
serves the app shell from the browser cache, so opening/refreshing the app doesn't
necessarily hit the proxy, and `fetch()` calls can never redirect the window, Authelia
answers them 401, not 302. The service worker uses network-first navigations
(`navigationRequestStrategy: freshness` in `ngsw-config.json`) so that refreshes do
reach the proxy and get the usual redirect to the Authelia portal; don't remove that
setting if the deployment sits behind forward auth.

### Updating

Pull a newer tag (`:latest` or a pinned `:sha-…` / `:X.Y.Z`) and recreate the
container. **Back up `/config` + `/photos` first**, startup auto-applies EF
migrations with no rollback. In WAL mode `/config` holds three files; for a
consistent single-file snapshot use `sqlite3 coffee.db ".backup backup.db"`.

---

See the repo [README](../README.md) for the full environment-variable reference and
[docs/design-notes.md](../docs/design-notes.md) for the design rationale.
