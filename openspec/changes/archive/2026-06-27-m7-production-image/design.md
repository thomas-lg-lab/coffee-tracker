## 1. Three-stage build, one runtime image

`node:22-slim` builds the Angular app (`ng build app --configuration production` →
`dist/app/browser`); the .NET SDK image publishes the API; the ASP.NET runtime
image (Ubuntu Noble) is the final layer. Only the published API + the Angular
`browser` output ship — no SDK, node, or sources in the runtime image.

## 2. SPA served same-origin by the API

The Angular `browser` output is copied to the API's `wwwroot`. In production the API
adds `UseStaticFiles()` + `MapFallbackToFile("index.html")`, so `/api`, `/photos`,
and `/openapi` match first and everything else falls through to the SPA shell —
client routes like `/coffees/1` work on refresh. Same-origin means **no CORS in
prod** (the dev CORS policy stays dev-only). All of this is guarded to non-dev so
the dev experience (Swagger at `/`, `ng serve` on 4200) is unchanged.

## 3. HSTS, not HTTPS redirection

TLS is terminated at the reverse proxy in front of the app; the container speaks plain
HTTP on 8080. We emit **HSTS** in prod but deliberately do **not** call
`UseHttpsRedirection` (the container has no HTTPS listener; redirecting would loop).
`UseForwardedHeaders` (already configured) honors `X-Forwarded-Proto` so the app
sees the real scheme.

## 4. Non-root, least-writable

Runs as the base image's non-root `app` user. Only `/config` (the SQLite DB) and
`/photos` (uploads) are created and `chown`ed writable; the rest of the filesystem
stays owned by root/read-only to the process. Env defaults point the connection
string at `/config/coffee.db` and photos at `/photos`, matching the Unraid template
volumes.

## 5. Config via environment

`Jwt__Key` is required at runtime (the app fails fast without a strong key) and is
never baked in. `REGISTRATION_ENABLED`, JWT issuer/audience, and OCR engine are
env-overridable; `Ocr:Engine` defaults to `tesseract` and the native libs are in the
image (unlike the macOS host, which uses `none`).

## 6. compose is local-only

`docker-compose.yml` exists for local build/test and as documentation of the env +
volumes. An Unraid install runs the published GHCR image via the Docker GUI (M8) — not
this compose file.

## 7. Verification is CI-side

The dev container has no Docker, so the image can't be built/run here. The
`ci.yml` `docker-build` job (guard now removed) builds it for `linux/amd64` on every
PR; `docker compose up --build` on any machine with Docker is the local check.
