# syntax=docker/dockerfile:1.7
# shop-worker - multi-stage, secret mount for the private index, per-arch pip cache, multi-arch
# without emulation: every RUN executes on the build platform, the target image only receives COPYs.
ARG PYTHON_IMAGE=python:3.12.15-slim-trixie

# ---- build-base: native image of the machine running the build (BUILDPLATFORM)
FROM --platform=$BUILDPLATFORM ${PYTHON_IMAGE} AS build-base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app

# ---- builder: runtime dependencies for the TARGET architecture, in a relocatable virtualenv
FROM build-base AS builder
# Set automatically by BuildKit for each target platform (amd64, arm64...).
ARG TARGETARCH
# The venv only holds symlinks to /usr/local/bin/python3.12, identical in every python image.
RUN python -m venv --without-pip /opt/venv
COPY requirements.txt .
# pip.conf (index URL + credentials) only exists for the duration of this RUN: never in a layer.
# The pip cache is isolated per target architecture (one lock per arch, no wheel mix-up).
# --platform/--only-binary: download prebuilt wheels for the target instead of executing it (no QEMU).
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf \
    --mount=type=cache,id=pip-${TARGETARCH},target=/root/.cache/pip,sharing=locked \
    case "${TARGETARCH}" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=aarch64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && pip install --target /opt/venv/lib/python3.12/site-packages \
         --implementation cp --python-version 3.12 --abi cp312 --only-binary=:all: \
         --platform "manylinux_2_17_${arch}" --platform "manylinux2014_${arch}" --platform "manylinux_2_28_${arch}" \
         -r requirements.txt

# ---- test: lint + unit tests, natively on the build platform
FROM build-base AS test
ARG BUILDARCH
COPY requirements.txt requirements-dev.txt ./
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf \
    --mount=type=cache,id=pip-${BUILDARCH},target=/root/.cache/pip,sharing=locked \
    pip install -r requirements-dev.txt
COPY worker ./worker
COPY tests ./tests
# "python -m pytest" puts the cwd on sys.path so tests can import the worker package.
RUN ruff check --no-cache worker tests && python -m pytest -q -p no:cacheprovider && touch /tmp/.tests-passed

# ---- users: /etc/passwd + /etc/group with the worker account, prepared natively
# The bind mount on the test stage makes every runtime build depend on passing tests.
FROM build-base AS users
RUN --mount=type=bind,from=test,source=/tmp/.tests-passed,target=/tmp/.tests-passed \
    groupadd --system --gid 10001 worker \
    && useradd --system --uid 10001 --gid worker --no-create-home --shell /usr/sbin/nologin worker

# ---- runtime: TARGET platform, no RUN at all
FROM ${PYTHON_IMAGE} AS runtime
ARG VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG SOURCE_URL=https://git.shop-sas.example/platform/shop-worker
LABEL org.opencontainers.image.title="shop-worker" \
      org.opencontainers.image.description="Shop SAS order queue consumer" \
      org.opencontainers.image.vendor="Shop SAS" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="${SOURCE_URL}"
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH
WORKDIR /app
COPY --from=users /etc/passwd /etc/group /etc/
COPY --from=builder /opt/venv /opt/venv
COPY worker ./worker
USER 10001:10001
EXPOSE 9100
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --start-interval=1s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9100/metrics', timeout=2)"]
CMD ["python", "-m", "worker.main"]
