# syntax=docker/dockerfile:1
# Production image: build the Angular app, publish the API, and serve the SPA
# same-origin from the API on :8080. Built for linux/amd64 and linux/arm64.

# --- Stage 1: build the Angular PWA ---
# Pinned to the BUILD platform, not the target: this stage emits static files, which have
# no architecture. Letting it follow the target would run the whole Angular build under
# QEMU for an arm64 image, for bytes that would come out identical.
# node:24-slim -- keep in step with ci.yml's node-version and the devcontainer's node
# feature. 24 is the current LTS. Majors are pinned deliberately, not by parity: the gate
# is frontend/package.json's engines (^20.19 || ^22.12 || ^24, i.e. Angular's supported
# range) plus LTS status -- an even major is still "Current" until the October of its
# release year. Renovate ignores node majors here; move all three references at once.
FROM --platform=$BUILDPLATFORM node:24-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20 AS web
WORKDIR /web
# Restore deps in their own layer (cached until a manifest changes). This is an npm
# workspaces repo, so `npm ci` needs every member's package.json present up front;
# the lockfile links @coffee-tracker/* to packages/*; without their manifests the
# install fails. `packages/app` is the Angular app, not a workspace member, so it has
# no package.json and is copied with the sources below.
COPY frontend/package.json frontend/package-lock.json ./
COPY frontend/packages/admin/package.json ./packages/admin/
COPY frontend/packages/auth/package.json ./packages/auth/
COPY frontend/packages/coffees/package.json ./packages/coffees/
COPY frontend/packages/data/package.json ./packages/data/
COPY frontend/packages/ui/package.json ./packages/ui/
COPY frontend/packages/util/package.json ./packages/util/
# @playwright/test is a devDependency for e2e only; the image never runs it, so
# skip its multi-hundred-MB browser download during install.
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
RUN npm ci
COPY frontend/ ./
RUN npx ng build app --configuration production
# → /web/dist/app/browser

# --- Stage 2: publish the API ---
# mcr.microsoft.com/dotnet/sdk:10.0
#
# Also pinned to the BUILD platform. The publish is portable, no -r/-a, so the output is
# architecture-neutral IL plus a runtimes/ folder carrying every native asset, and the
# entrypoint starts it through the `dotnet` muxer rather than the apphost. The runtime
# stage below is what makes the image arm64 or amd64.
#
# Cross-compiling instead (-a $TARGETARCH) is not an option here: a RID-specific restore
# fails --locked-mode with NU1004, because the committed lock files carry no runtime
# identifiers. Emulating this stage would cost minutes per build for no difference in
# output.
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0@sha256:212fe4cb74627d5adf9817a4088906ae3edff1bd853bb27565d4b46731efe61e AS api
WORKDIR /src
# Restore in its own layer (cached until a manifest or lock file changes), the same shape
# as the npm restore in stage 1, otherwise every edit to any .cs file re-resolves and
# re-downloads the whole package graph. Only the Api's transitive closure is restored, so
# the test project's dependencies never enter the image's build.
COPY backend/Directory.Build.props ./backend/
COPY backend/CoffeeTracker.Api/CoffeeTracker.Api.csproj backend/CoffeeTracker.Api/packages.lock.json ./backend/CoffeeTracker.Api/
COPY backend/CoffeeTracker.Application/CoffeeTracker.Application.csproj backend/CoffeeTracker.Application/packages.lock.json ./backend/CoffeeTracker.Application/
COPY backend/CoffeeTracker.Domain/CoffeeTracker.Domain.csproj backend/CoffeeTracker.Domain/packages.lock.json ./backend/CoffeeTracker.Domain/
COPY backend/CoffeeTracker.Infrastructure/CoffeeTracker.Infrastructure.csproj backend/CoffeeTracker.Infrastructure/packages.lock.json ./backend/CoffeeTracker.Infrastructure/
# --locked-mode for the same reason CI uses it: the image must be built from the exact
# package graph the committed lock files describe, not whatever resolves today.
RUN dotnet restore backend/CoffeeTracker.Api/CoffeeTracker.Api.csproj --locked-mode
COPY backend/ ./backend/
RUN dotnet publish backend/CoffeeTracker.Api/CoffeeTracker.Api.csproj -c Release -o /publish --no-restore

# --- Stage 3: runtime ---
# mcr.microsoft.com/dotnet/aspnet:10.0
# The only stage that follows the target platform, and the only one that needs to: the
# apt packages below (tesseract, gosu, curl) are the image's native dependencies.
FROM mcr.microsoft.com/dotnet/aspnet:10.0@sha256:1a48394b6f29d3a32c79d9edecd4abda0ecbe8776d567dbfc4590ed6979c740c AS runtime
# Two OCR engines, both driven by shelling out and piping the image over stdin.
#
# RapidOCR (PP-OCR on onnxruntime) is the default, and it is what costs the size here:
# the image goes from 351 MB to 784 MB on disk (145 MB to 302 MB compressed, which is
# what a pull actually costs), all of it Python, numpy and onnxruntime. It buys reading a photograph rather
# than a scanned page. On the benchmark's real bags Tesseract returns "lam" where the
# label says "LA LIBERTAD" and nothing at all for "INTENSO BLEND"; RapidOCR reads both.
# Versions are pinned in deploy/rapidocr/requirements.txt, which CI installs too, so the
# engine the benchmark scores is the engine that ships. Both opencv builds are removed
# before the headless one goes back: they share the `cv2` directory, so uninstalling one
# takes it away and pip then skips reinstalling the other as already present.
#
# The package is `rapidocr`, not `rapidocr-onnxruntime`: the latter is the same
# project's earlier name, frozen since January 2025 on PP-OCRv4, while `rapidocr` ships
# PP-OCRv6 and reads these bags visibly better (TORREFACTEUR at 99.7% against a mangled
# "TORREFACTEY,"). It depends on opencv-python, whose GUI build carries ~116 MB of X11
# libraries to draw windows a server will never open, so it is swapped for the headless
# build afterwards. Installing headless alongside does not help: pip honours the
# dependency and ships both.
#
# Tesseract stays installed and one setting away (Ocr:Engine=tesseract), because it is a
# tenth of the size and a fair answer for anyone who would rather not carry the rest.
# gosu drops privileges in the entrypoint; curl is only for the HEALTHCHECK (the aspnet
# image ships neither curl nor wget). TESSDATA_PREFIX is the parent of the tessdata dir.
COPY deploy/rapidocr/requirements.txt /tmp/requirements.txt
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        tesseract-ocr tesseract-ocr-eng \
        python3 python3-pip libglib2.0-0 \
        gosu curl \
    && pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements.txt \
    && pip3 uninstall -y --break-system-packages opencv-python opencv-python-headless \
    && pip3 install --no-cache-dir --break-system-packages "$(grep '^opencv-python-headless' /tmp/requirements.txt)" \
    && rm -rf /var/lib/apt/lists/*

# The reader the RapidOCR adapter pipes into. RapidOCR's own CLI only takes a file path,
# which would mean writing a temp file for every scan; this takes stdin and prints one
# JSON line per recognised line, with the confidence and geometry the parser needs.
COPY deploy/rapidocr/read.py /opt/rapidocr/read.py

# Fetch the models at build time rather than on the first user's scan, which would
# otherwise pay a download on a machine that may have no route out.
RUN python3 -c "from rapidocr import RapidOCR; RapidOCR()"

# PUID/PGID default to Unraid's nobody:users. Override at runtime to match whoever
# owns the host appdata dirs, so the bind-mounted volumes are writable. HOME points
# into the /config volume so the non-root user's ASP.NET Data Protection key ring
# persists there instead of warning and falling back to ephemeral keys.
ENV TESSDATA_PREFIX=/usr/share/tesseract-ocr/5 \
    ASPNETCORE_URLS=http://+:8080 \
    ConnectionStrings__Default="Data Source=/config/coffee.db" \
    Storage__PhotosPath=/photos \
    FileLog__Directory=/config/logs \
    PUID=99 \
    PGID=100 \
    HOME=/config

WORKDIR /app
COPY --from=api /publish ./
COPY --from=web /web/dist/app/browser ./wwwroot
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# The entrypoint starts as root to re-own the volumes for PUID/PGID, then uses gosu
# to run the app as that (non-root) user. Don't set USER here, the entrypoint drops
# privileges itself after fixing ownership.
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS http://localhost:8080/health || exit 1
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
