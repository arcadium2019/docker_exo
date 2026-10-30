# syntax=docker/dockerfile:1.7
# shopapi - Shop SAS image standards compliant Dockerfile.
ARG NODE_IMAGE=node:20.20.2-alpine3.23

# ---- base: lockfile only, so dependency layers depend on nothing else
# Build stages run on the build machine's platform: deps are pure JS (--ignore-scripts), so they are
# architecture independent and a multi-arch build does not emulate npm ci.
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS base
WORKDIR /app
COPY package.json package-lock.json ./

# ---- deps-dev: full dependency tree (lint/test tooling)
FROM base AS deps-dev
RUN --mount=type=cache,target=/root/.npm \
    npm ci --ignore-scripts --no-audit --no-fund

# ---- test: lint + unit tests, fails the build on error
FROM deps-dev AS test
COPY src ./src
COPY test ./test
RUN npm run lint && npm test && touch /tmp/.tests-passed

# ---- deps-prod: runtime dependencies only
# The bind mount on the test stage forces BuildKit to run the tests before any release build.
FROM base AS deps-prod
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=bind,from=test,source=/tmp/.tests-passed,target=/tmp/.tests-passed \
    npm ci --omit=dev --ignore-scripts --no-audit --no-fund

# ---- runtime
FROM ${NODE_IMAGE} AS runtime
# Global ARG must be re-declared to be visible inside the stage (used by a label).
ARG NODE_IMAGE
ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG SOURCE_URL=https://git.shop-sas.example/platform/shopapi
LABEL org.opencontainers.image.title="shopapi" \
      org.opencontainers.image.description="Shop SAS product catalogue API" \
      org.opencontainers.image.vendor="Shop SAS" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.base.name="${NODE_IMAGE}"
ENV NODE_ENV=production \
    APP_VERSION=${APP_VERSION} \
    PORT=3000
# Node 20 is EOL: its base image is no longer rebuilt. Apply pending Alpine security fixes and drop
# the package managers bundled with the image (npm ships vulnerable tar/minimatch/cross-spawn...),
# which the runtime never uses. Flagged by trivy in the TP03 release gate.
RUN apk upgrade --no-cache \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /opt/yarn-* \
              /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /usr/local/bin/yarn /usr/local/bin/yarnpkg
WORKDIR /app
# Files stay owned by root: the node user can read but not modify the application.
COPY --from=deps-prod /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
# Numeric uid (= node) so Kubernetes runAsNonRoot can verify it without /etc/passwd.
USER 1000:1000
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --start-interval=1s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:3000/health"]
# Exec form: node is PID 1 and receives SIGTERM directly (handled in src/server.js).
CMD ["node", "src/server.js"]
