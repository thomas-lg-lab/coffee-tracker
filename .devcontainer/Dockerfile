# Dev container image for Coffee Tracker.
# Base: Microsoft's .NET 10 dev container image, UBUNTU 24.04 "Noble"
# (.NET 10 moved off Debian; there is no 1-10.0-bookworm/trixie release tag).
# Ships the .NET 10 SDK + the `vscode` non-root user. Node + Angular CLI are
# layered via the devcontainer Node feature + post-create.sh; this Dockerfile
# only adds the OCR engines that features can't.
# Fallback tag if 1-10.0 ever fails: 1-10.0-noble.
FROM mcr.microsoft.com/devcontainers/dotnet:11.0@sha256:e1ad6d87ed91afc347d9efd214531268f0f83bace13a9309ccdf162dd2876bf5

# The base image ships a yarn apt source whose GPG signing key has rotated,
# so `apt-get update` hard-fails on dl.yarnpkg.com ("NO_PUBKEY ... repository
# is not signed"). We don't use that repo, Node/yarn come from the Node
# devcontainer feature, so remove the source before updating.
#
# Both OCR engines, because the one that ships as the default is the one worth
# developing against. Before this the container carried only Tesseract and pinned
# Ocr__Engine to it, so every scan tried here went through the engine production does
# not use, and the benchmark's rapidocr half skipped for want of the import. It costs
# the dev image roughly 400 MB; the alternative was leaving RapidOCR measurable only in
# CI, which is how the segmentation-mode sweep came to be reversed twice.
#
# The app shells out to the tesseract CLI, so that half needs only the binary
# (tesseract-ocr) + the English data (tesseract-ocr-eng). No -dev packages, those
# were only for the old P/Invoke NuGet, which we dropped for the CLI.
#
# The RapidOCR half mirrors the production Dockerfile, pins and opencv dance included:
# both opencv builds come out before the headless one goes back, because they share the
# `cv2` directory and pip would otherwise skip the reinstall as already present.
# --break-system-packages because Noble's system Python is PEP 668 managed.
COPY deploy/rapidocr/requirements.txt /tmp/requirements.txt
RUN rm -f /etc/apt/sources.list.d/yarn.list \
    && apt-get update \
    && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends \
        tesseract-ocr tesseract-ocr-eng \
        python3 python3-pip libglib2.0-0 \
    && pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements.txt \
    && pip3 uninstall -y --break-system-packages opencv-python opencv-python-headless \
    && pip3 install --no-cache-dir --break-system-packages "$(grep '^opencv-python-headless' /tmp/requirements.txt)" \
    && rm -f /tmp/requirements.txt \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# The reader the RapidOCR adapter pipes into, at the path the production image uses
# because the adapter has that path compiled in.
COPY deploy/rapidocr/read.py /opt/rapidocr/read.py

# Fetch the models at build time rather than on the first scan. They land inside the
# installed package, which is root-owned and world-readable, so the non-root `vscode`
# user reads the same copy instead of downloading its own.
RUN python3 -c "from rapidocr import RapidOCR; RapidOCR()"

# TESSDATA_PREFIX must be the PARENT of the tessdata dir (Tesseract appends
# /tessdata). On Ubuntu Noble eng.traineddata is at /usr/share/tesseract-ocr/5/tessdata.
ENV TESSDATA_PREFIX=/usr/share/tesseract-ocr/5
