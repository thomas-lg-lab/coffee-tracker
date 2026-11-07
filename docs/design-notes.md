# Design notes

Standing rationale for Coffee Tracker, the decisions that shaped the app and still
govern it. For *what it does* and how to run it see [the README](../README.md); for
conventions when changing the code see [CLAUDE.md](../CLAUDE.md); for live behaviour
specs see [`openspec/specs/`](../openspec/specs/); for how each piece was built see the
archived changes in [`openspec/changes/archive/`](../openspec/changes/archive/).

## Context

A self-hosted coffee-cataloging web app, built as a vehicle to learn modern C#/.NET
while using familiar Angular. It is meant to be **shared publicly so others can
self-host it**, which is why security is a first-class requirement and every piece of
configuration is environment-driven.

Development happens **inside a dev container**, reproducible toolchain, no host setup.
Deployment is **GitHub Actions → GHCR (public image) → manual install from the NAS's
Docker GUI**; there is no Watchtower, SSH, or compose-on-NAS. The repo's
`docker-compose.yml` is a local dev/test and reference convenience, **not** the deploy
path. Images are published as a manifest list covering `linux/amd64` and
`linux/arm64`, so an x86 NAS and an ARM one both pull the right one.

## Settled choices

- **Controllers**, not minimal APIs. Clearer grouping across auth/coffees/reviews while
  learning. Minimal APIs are the modern alternative and would have worked too.
- Flavor tags are a full many-to-many (`FlavorTag` + join table) rather than a
  denormalized string column, the correct model, and better EF Core practice.
- The OCR engine sits behind `IOcrService` so it can be swapped for PaddleOCR or
  RapidOCR without the application layer noticing. The shipped adapter shells out to the
  `tesseract` CLI rather than binding a native library; [CLAUDE.md](../CLAUDE.md) § OCR
  says why the P/Invoke route was abandoned.
- **The first account registered becomes administrator.** A fresh instance accepts
  exactly one registration and then closes itself, so an internet-exposed instance is
  never open to signup by default and needs no environment variable to say so.

## Security

Instances may be internet-exposed and shared, so:

- There is **no default JWT signing key**. The app refuses to start if the key is
  missing or weak. Key and connection string are injected at runtime, never baked into
  the image or committed.
- The app keeps its own login. Every endpoint requires a token, and a global fallback
  authorization policy means an endpoint cannot be left public by forgetting
  `[Authorize]`, the reverse proxy is not the authentication.
- TLS terminates at the proxy. The container speaks HTTP and trusts `X-Forwarded-*` only
  from proxies named in `ForwardedHeaders:KnownProxies`. Absent that the headers are
  ignored, which is the secure default but also collapses rate-limiting onto the proxy's
  single IP.
- Access tokens are short-lived; refresh tokens rotate and can be revoked. Presenting a
  rotated token revokes **the whole session family**, on the assumption it was stolen.
- Login, register, the anonymous config endpoint and label scanning are rate-limited:
  the paths whose cost an anonymous or single caller could otherwise impose at will.
- Uploads are content-type allowlisted, magic-byte sniffed, size- and pixel-capped, and
  fully re-encoded, which strips any embedded payload or metadata. Filenames are
  server-generated, and photos are served only through short-lived signed URLs.
- Every response carries a content security policy with no inline script, plus
  `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer` and `nosniff`.
- The container runs as a non-root user; only `/config` and `/photos` are writable.
- Renovate (shared config in thomas-lg-lab/renovate-config) covers all seven ecosystems, and CI runs CodeQL plus a Trivy image scan that
  hard-gates on fixable criticals.

## Conventions

- DTOs at the boundary. Entities are never serialized directly.
- Dev config lives in `appsettings`, production config in environment variables. Real
  keys are never committed, `.env` is gitignored for exactly this reason.
- **Comments explain why, not what.** It is the rule this codebase is most deliberate
  about; see [CLAUDE.md](../CLAUDE.md) § Comment style.
- Feature branch → PR → CI green → squash-merge. Linear history, no merge commits.

## Backups

`coffee.db` and `photos/` should be backed up **before pulling a new image**: a failed
startup auto-migration has no rollback, and the schema change survives a rollback of the
container even though the old code does not expect it.

In WAL mode the live database is three files (`coffee.db`, `-wal`, `-shm`), so for a
consistent single-file snapshot use `sqlite3 coffee.db ".backup backup.db"` rather than
copying `coffee.db` alone. That is why **Admin → Backup** exists: it exports the catalog
over HTTP, which needs no shell on the host and cannot catch the database mid-write.

The export is data only, and it is the catalog only. It carries every coffee with its
reviews and flavour tags, and nothing else, so it is not a substitute for the two backups
above:

- **Photos are not in it.** A restored coffee keeps its photo path, which resolves only if
  `photos/` came along.
- **Accounts, sessions and settings are not in it.** A restore cannot grant anyone access,
  and cannot bring an instance's configuration back.
- **Restoring replaces the catalog**, so it is a recovery tool, not a merge tool. Flavour
  tags are matched by name against the seeded set; an unfamiliar name is skipped and
  reported rather than created.

## Known risks

- **OCR accuracy on real bags** is the biggest unknown. `IOcrService` is the designed
  escape hatch to another engine.
- EF auto-migration on startup has no rollback and assumes a single instance. WAL eases
  single-writer contention but does not change that assumption.
- A public instance is an abuse surface, mitigated by closed-by-default registration,
  rate limiting, TLS at the proxy, and a non-root, least-writable container.
