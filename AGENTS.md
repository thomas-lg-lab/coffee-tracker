# Working on this repo

Conventions and hard-won context. The README is the user-facing documentation;
this file is what someone (or some agent) needs to *change* the code without
rediscovering the same things.

## Architecture

Hexagonal, and enforced in that direction: **Domain ← Application ← {Infrastructure, Api}**.

- Controllers depend only on application ports (`Ports/Driving`), **never on EF Core**.
- Adapters live behind driven ports (`Ports/Driven`): `IUserDirectory`, `IPhotoStorage`,
  `IOcrService`, `IRefreshTokenStore`, `ITokenIssuer`…
- DTOs at the boundary. Domain types don't cross the HTTP edge.
- Business rules that an adapter cannot hold belong in the application layer, which
  account an assertion resolves to, who is an administrator, who may edit what.

Two carve-outs, both deliberate, both documented where they happen. If you are about
to "fix" one, read the comment first:

- **`RoastLevel` does cross the edge.** It is a closed three-value enum with a
  `[JsonConverter]` pinning the wire format, and that one annotation drives both the
  JSON and the generated OpenAPI schema. Mirroring it in the Api layer would buy
  nothing and cost a type that has to be kept in step.
- **`ConfigController` depends on two driven ports**, not a driving one. It is the
  anonymous pre-sign-in endpoint, and routing it through a use case would make every
  unauthenticated caller construct the auth stack to read two booleans.

`backend/Directory.Build.props` carries the shared build settings: `net10.0`, nullable,
.NET analyzers, `TreatWarningsAsErrors` in **Release** only (CI builds Release), and
NuGet lock files.

## Comment style

**Write the simplest code you can, then comment the parts that still look complex.**
A comment earns its place by decoding a line that will make a reader stop, never by
narrating how the code is organised.

If a reader can answer *"why is this here, and why this way?"* from the code alone, a
comment adds nothing and starts rotting the moment the code moves. If they cannot, the
comment is required, not a nicety.

The trap is the plausible-sounding comment that decodes nothing. A class header saying
*"everything stateful lives in the store and the template reads it directly"* reads well
and is useless: the injected store and the single effect already say it. Architecture is
visible in the code; surprises are not.

Belongs in a comment, because the code cannot express it:

- why a step is ordered where it is (the fork check *before* the checkout, because the
  restore that follows is what executes attacker code)
- why the obvious approach was rejected (the CLI instead of the P/Invoke Tesseract
  binding)
- what breaks if the line is removed
- a constraint that lives somewhere else entirely: a provider's behaviour, a GitHub
  Actions rule, a library's quirk, a Tesseract 5 path convention

Does not, because the code already says it:

- what the next line does
- a name, type or signature restated in prose
- **where things live**, which layer owns what, what moved to a store, what a screen
  keeps. That is the file's shape, and the shape is readable
- the comment justifying its own existence

Density follows from the rule; it is not the rule. This codebase lands around 25-35%
comment lines as a *result*; don't pad to reach it, and never delete a comment the
code genuinely needs to stay under it. But a diff running far above it is usually
restating rather than explaining, and worth a second look.

## Commits & PRs

- Feature branch → PR → CI green → **squash-merge**. `main` is protected.
- PR titles follow **Conventional Commits** (commitlint types, `!` for a breaking change),
  enforced by the required `conventions / title` check of `pull-request.yml`.
- The PR, release, image and registry workflows call the reusable workflows of
  `thomas-lg-lab/.github` at a version tag: change them there, not here.
- Issues and PR descriptions follow the organisation's defaults in `thomas-lg-lab/.github`
  (issue forms, PR template, and how to fill them in its README); they are not in this repository.
  An issue opened through the API or `gh` skips the forms: use the same sections and set the issue
  type (`gh api repos/OWNER/REPO/issues -f title=... -f body=... -f type=Task`, or `Bug`, `Feature`).
- Commit with your personal (not work) git identity; check `git config user.email`
  in this clone before the first commit.
- `GH_TOKEN` in this environment lacks the `workflow` scope, so for any PR touching
  `.github/workflows/`, use `env -u GH_TOKEN gh ...` and let `gh` use its own auth.

## Testing

See the README's *Running the tests* for the commands. What matters when writing them:

- **Backend integration** tests boot the real app via `WebApplicationFactory<Program>`,
  each against its own throwaway SQLite DB (`ApiFactory` + `ApiClient` helpers).
- **Playwright** starts only the Angular dev server; the API must be running on `:5000`
  against an **empty** database. `e2e/support/global-setup.ts` claims the first account
  (→ administrator) and reopens registration, because a fresh instance allows exactly
  one registration and `fullyParallel` would otherwise make a race decide who gets it.
- `/api/auth` is rate-limited to **10/min**, so e2e specs seed sessions into
  `localStorage` via `injectSession()` rather than logging in repeatedly.
- The e2e OpenID Connect provider (`e2e/support/fake-oidc-provider.ts`) is a real
  minimal server: discovery, JWKS, PKCE, nonce and RSA signatures all genuinely
  happen. A test account on a real provider would be unreachable from CI and would
  make the suite depend on someone else's uptime.
- `provider-sign-in.spec.ts` documents which guards were verified by *reintroducing
  the bug and watching the test go red*, including one that could not be, left
  documented rather than faked. Keep that honesty if you extend it.

## OCR

Two engines behind `IOcrService`, chosen **at runtime from the admin view** and stored
in the settings row. `Ocr:Engine` is only the default an instance starts from, which is
what an upgraded instance keeps: the column is nullable, and null means "whatever the
deployment configured", so adding this could not change how an existing instance scans.

`SwitchingOcrService` is the `IOcrService` the app resolves. Both engines stay singletons
because each caps its own concurrency with a semaphore that a per-request copy would not
cap; the wrapper is scoped because reading the policy needs the request's DbContext. Its
`IsAvailable` answers "some engine could run", deliberately weaker than "the chosen one
can", because the port's check is synchronous and the choice lives in the database.
`ReadAsync` returns `Unavailable` when the chosen engine cannot run, and the endpoint
maps both to the same 503.

**`rapidocr` is the default.** PP-OCRv6 detection and recognition on onnxruntime,
driven through `deploy/rapidocr/read.py`. It reads photographs, which is what the app
actually gets: on the benchmark's real bags Tesseract returns "lam" where the label says
"LA LIBERTAD" and nothing at all for "INTENSO BLEND", while RapidOCR reads both, and
"TORRÉFACTEUR" with its accent at 99.7% where Tesseract manages "TORREFACTEY,". It scores
82.8% against Tesseract's 74.4%. It costs the image 351 MB to 784 MB on disk, or 145 MB
to 302 MB to pull, which is the whole argument against it.

Install `rapidocr`, **not** `rapidocr-onnxruntime`. The second is the same project's
earlier name, frozen since January 2025 on PP-OCRv4; the first is where the work went.
Measured on this corpus the difference is 77.9% against 82.8%, so it is not cosmetic.

**`tesseract` is still there**, a tenth of the size and one setting away, for anyone who
would rather not carry that. `none` disables scanning; `appsettings.Development.json`
uses it so a bare host doesn't 503-loop.

Both adapters follow the same rules, and they are not negotiable:

- The image is piped over **stdin**. No caller-controlled value becomes a path or an
  argument. RapidOCR's own CLI only accepts `-img <path>`, which is why the repo ships a
  reader that takes stdin instead of calling it.
- Arguments go through `ArgumentList` with `UseShellExecute = false`.
- Neither adapter throws: a process that will not start, a non-zero exit and a run past
  the timeout all degrade to `OcrResult.Unavailable`, so a scan fails as a 503 rather
  than a 500. That also means a failure is invisible without the log, which is why the
  benchmark routes it into the test output.
- EXIF orientation is honoured in `UprightImage`, shared because it is a property of
  cameras rather than of an engine. Both Leptonica and OpenCV ignore the tag.

Tesseract specifics worth keeping: it shells out to the CLI rather than a P/Invoke NuGet,
whose native loading proved too brittle on Linux (it probes version-pinned `lib*.dll.so`
names and needs a `libdl` shim), and it passes `--tessdata-dir` explicitly because
Tesseract 5 treats `TESSDATA_PREFIX` as the directory itself, not its parent.

**The confidence gate is per engine**, and it travels with the read: `OcrResult` carries
the floor the engine that produced it calls for, so nothing downstream has to know which
engine is plugged in. That matters more now that the engine changes at runtime, and it is
why there is no gate in DI any more.

The two floors are not the same kind of number, which is worth knowing before tuning
either. Tesseract's 55 sits in a real gap: its clutter scores under 50 and its printed
lines above 58. RapidOCR's 70 does not, because it reads small print confidently too, and
a barcode caption came back at 81. It was chosen by sweeping (55 and 70 both score 82.8%,
80 scores 81.8%, 90 upward drops real lines), and what actually keeps that caption out of
the fields is the rest of the parser: the four-letter minimum and the height ranking.

### Measuring it

**Do not change the OCR adapter or the label parser without running the benchmark.**
`OcrBenchmarkTests` scores the whole pipeline against a fixed corpus and fails below a
floor, so a change can be compared instead of argued about. It prints a scorecard: per
field, per shooting condition, and every wrong answer as `wanted X, got Y`.

**Both engines are scored on every run**, each against its own floor, and CI publishes
both scorecards. That is not thoroughness for its own sake: every constant in
`CoffeeLabelParser` is shared between the engines, and all three were swept against
Tesseract before RapidOCR existed. Measured since, the optima coincide, but only because
RapidOCR is insensitive to the line gap and the letter minimum that Tesseract needs:

| | RapidOCR | Tesseract |
| --- | --: | --: |
| band tolerance 0.70 (shipped) | **82.8%** | **74.4%** |
| band tolerance 0.80 | 79.2% | 72.8% |
| line gap 0.4 | 82.8% | 70.8% |
| line gap 0.8 (shipped) | **82.8%** | **74.4%** |
| four-letter minimum, at 3 | 82.8% | 73.8% |

Nothing guarantees that stays true, so scoring one engine would let a tuning pass for it
quietly cost the other.

The dev container carries **both** engines and defaults to `rapidocr`, so both halves
run there and reproduce CI's numbers exactly (82.8% and 74.4%). On a host missing an
engine that half **skips with a reason**, so on a bare Windows host you have measured
nothing and the number to quote is CI's.

There are two corpora, scored separately and never averaged into one number.
`synthetic/` is rendered: `node scripts/generate-ocr-fixtures.mjs` draws six labels under
five bad-photo conditions and writes the manifest from the same objects that drew them,
so expectations cannot drift from the images. `real/` is nine photographs of actual bags,
six of them pulled off a live instance's own photo volume.

**Weight the photographs.** The rendered corpus scores the pipeline at about 85% and the
photographs at about 50%, and the photographs are what overturned two decisions the
rendered fixtures had "proved". Read a rendered score as a regression signal and a real
one as the accuracy figure.

Four things have been swept against it, and each result is recorded next to the constant
it set:

- **Preprocessing bought nothing.** Grayscale was worth +0.3, and upscaling *cost* two to
  four points. Don't re-add a pipeline without a scorecard showing it pays.
- **The page segmentation mode was swept three times and reversed twice.** Mode 6 looked
  worth five points over the default; then the parser was fixed and every mode tied; then
  real photographs arrived and mode 6 turned out to be the *worst* of the five on them
  (32% on a handheld shot where mode 11 scores 54%), because it reads the kitchen table as
  part of the text block. It ships as 11. Two lessons, and both were expensive: a sweep is
  only true of the code it was run against, and a corpus scores highest on the images it
  most resembles.
- **Line merging** (`BandTolerance`, `MaxLineGap` in the parser) is where the points
  actually were: 70.7% → 82.0% on the rendered corpus.
- **The confidence gate sits on a plateau.** The rendered fixtures alone argued for
  dropping it from 55 to 45; the photographs then showed 45, 50, 55 and 60 all scoring
  identically, with only ≤40 (noise gets in) and ≥65 (real lines dropped) costing
  anything. It stays at 55, and holding it against rendered-only evidence turned out to be
  right for a better reason than the one available at the time.

The photographs are French and Italian, and every list in this parser used to be
English. `Origins` now maps the spelling a bag prints onto the one the app stores, so
"Brésil" and "Brazil" land in the same filter bucket rather than splitting it; that took
origin from 87% to 95%. `RoasterKeywordRegex` gained torréfacteur, torrefazione,
Rösterei and tostadería, which moved nothing measurable, because OCR mangles exactly
those words ("TORRÉFACTEUR" comes back "TORREFACTEY"). They are kept as correct domain
knowledge that this corpus cannot show a gain for.

What remains on the photographs is almost entirely the name field, and it splits in two:
the brand outranking the product ("MOKXA" where the bag means "Kekchi") and the engine
returning nothing usable ("ry. SPEC COFFEE" off distressed type). The second is an engine
question, not a parser one, and it is the measured argument for trying another engine.

What preprocessing *is* there is EXIF auto-orientation, and it earns its place on a
different argument: Leptonica ignores the orientation tag, so a bag photographed in
portrait reaches the engine sideways and comes back as mirrored nonsense. The rendered
corpus cannot see that (it has no EXIF), so `TesseractOrientationTests` covers it
instead, and it was written red first.

Two scoring rules are deliberate and worth knowing before reading a scorecard:

- A `null` expectation is a real assertion: it says the parser should leave the field
  alone. Inventing a value there scores as **wrong**.
- Origin, roast level and weight are closed vocabularies, so they are scored
  exact-or-nothing. "Kenyq" scores zero, because it is a value no filter will match.

## Backend dependency bumps

`backend/Directory.Build.props` enables NuGet lock files and CI restores with
`--locked-mode`, so a bump cannot land without a reviewed `packages.lock.json`. NuGet
keeps **one lock file per project**, so changing a package in `Application` or
`Infrastructure` also invalidates the ones in `Api` and `Tests`, and the restore fails
with **NU1004**. Refresh them all:

```powershell
./scripts/refresh-lockfiles.ps1          # rewrite the lock files (--force-evaluate)
./scripts/refresh-lockfiles.ps1 -Check   # just reproduce the CI restore (--locked-mode)
```

The script uses a local .NET SDK if there is one and the pinned SDK container
otherwise, so it works on a bare host.

Dependency PRs come from Renovate (shared config in `thomas-lg-lab/renovate-config`, this
repository's rules in `renovate.json`), which runs `dotnet restore --force-evaluate` on
every project that depends on a changed `.csproj` and commits all their lock files. The
script is for changes made by hand. Dependabot only refreshed the lock file of the
project it edited, which is what the former `refresh-lockfiles.yml` workflow patched.

## OpenSpec

Live specs: `auth`, `backup`, `coffee-catalog`, `label-scan`, `photo-storage`,
`reviews`, `web-client`, `deployment`. Workflow: one change per feature → PR → CI green →
squash-merge → a separate PR archiving the change into `openspec/specs/`.

## Deployment context

Self-hosted on a NAS, internet-exposed behind a TLS-terminating reverse proxy with
forward auth. The app keeps **its own** login: every endpoint requires a token; the
reverse proxy is not the authentication. The production container starts as root,
`chown`s `/config` and `/photos` to `PUID:PGID`, then drops privileges via `gosu`.

## Frontend layout

`frontend/` is an npm workspace of Angular packages: `app` (the shell) plus `ui`, `util`,
`data`, `auth`, `coffees`, `admin`. Inside every package:

- **`pages/` holds what a router loads, `components/` what a page renders.** One folder per
  unit, holding its `.ts`, its `.html` and its `.spec.ts`. A component may not import a page.
- **A store with one consumer lives in that consumer's folder** (`pages/backup/backup.store.ts`);
  a store with several lives in `services/` (`coffees.store.ts`, `auth.store.ts`). Which it is
  can change, and moving it is the whole edit.
- `Home` is a page of `coffees`, not of `app`, because it is a coffee dashboard and reaches
  into that package for everything it renders. It is the only page any barrel exports, since
  `app.routes.ts` owns the landing route.

Two alias namespaces, and the difference is the point: **`@coffee-tracker/x` is another
package's public surface; `@x/…` is your own package's inside.** `eslint.config.js` expands one
`MAY_IMPORT` map into both directions of that — which packages a package may reach, and the ban
on borrowing anyone else's internal alias or walking a relative path past a `public-api.ts`.
Adding an edge to the graph means editing that map, which is the point of it being a map.

## Frontend upgrades: current state

- **`@ngrx/signals`**: *unblocked*. 22.0.1 peers on `@angular/core@^22.0.0` and the
  project runs 22.1.5. The three stores (`AuthStore`, `CoffeesStore`,
  `PhotoCleanupStore`) ship as native-signals stores with the same surface, so the swap
  is a deliberate refactor, not a required update.
- **`@lucide/angular`**: *adopted*. An earlier note here called `lucide-angular`
  blocked on `13.x - 21.x`; that package is **deprecated** in favour of the scoped
  `@lucide/angular`, which peers on `@angular/core: >=17.0.0`. Check the scoped name
  before repeating a claim about a lucide package. Icons are now per-icon standalone
  components on an `svg` attribute selector (`<svg lucideSearch [size]="16">`), each
  imported by the component that uses it, so a missing import is a template error, and
  there is no central icon map to keep in step. It costs ~26 kB raw (~1.7 kB over the
  wire) against the old hand-rolled `ct-icon`, which is why the initial bundle warning
  moved to 600 kB.
- **`openapi-typescript`** runs via `npx` (it peers on TS 5, the project is on TS 6).
  Fine as-is. The e2e CI job regenerates the client from the running backend and fails
  on drift, so a backend contract change cannot ship a stale typed client.

## Regenerating the screenshots

`docs/screenshots/*.png` are captured by `scripts/capture-screenshots.mjs`, not grabbed
by hand, so a layout change is a re-run, not a reason to leave them stale. They need a
running, seeded instance. Nothing on the host but Docker:

```bash
# A fresh `config` volume opens registration for the first account. If you have run this
# before, `docker compose down -v` first or the register form will already be closed.
JWT_KEY=$(openssl rand -base64 48) docker compose up -d --build
# register an account, add a few coffees and some dated reviews, then:
docker run --rm -v "$PWD:/work" -w /work \
  -e BASE_URL=http://host.docker.internal:8080 \
  --add-host host.docker.internal:host-gateway \
  mcr.microsoft.com/playwright:v1.63.0-noble \
  bash -lc 'npm i -s --no-save playwright@1.63.0 && node scripts/capture-screenshots.mjs'
```

Keep the Playwright image tag in step with `@playwright/test` in `frontend/package.json`.
Review timestamps are server-set, so demo reviews all land on today; back-date them
directly in SQLite (stop the container first; WAL keeps the file open) or the
"ratings over time" shot shows the same date twice and sells nothing.

## Gotchas

- **macOS: port 5000 is squatted by AirPlay Receiver.** Either disable it or run the
  API elsewhere (`ASPNETCORE_URLS=http://localhost:5099`) and remap `proxy.conf.json`.
  Stale backgrounded `dotnet run` processes also serve old binaries; kill them first.
- Development happens **in the dev container**; the host is not expected to carry the
  .NET SDK, Node or Tesseract.
