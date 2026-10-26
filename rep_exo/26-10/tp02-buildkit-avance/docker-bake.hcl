# Shop SAS stack: one command builds the API (TP01) and the worker.
#   docker buildx bake --print                        # plan, no build
#   docker buildx bake                                # api + worker, multi-arch, registry cache
#   docker buildx bake worker-test                    # worker test stage only
#   docker buildx bake --set '*.platform=linux/amd64' --load
# Requires a docker-container builder (registry cache export, multi-platform): BUILDX_BUILDER=shop.

variable "REGISTRY" {
  default = "localhost:5000"
}

variable "VERSION" {
  default = "0.0.0-dev"
}

variable "GIT_SHA" {
  default = "unknown"
}

# Comma separated, e.g. PLATFORMS=linux/amd64 for a quick local build.
variable "PLATFORMS" {
  default = "linux/amd64,linux/arm64"
}

function "image" {
  params = [name]
  result = ["${REGISTRY}/${name}:${VERSION}", "${REGISTRY}/${name}:sha-${GIT_SHA}"]
}

function "cache_from" {
  params = [name]
  result = ["type=registry,ref=${REGISTRY}/cache:${name}"]
}

function "cache_to" {
  params = [name]
  result = ["type=registry,ref=${REGISTRY}/cache:${name},mode=max"]
}

group "default" {
  targets = ["api", "worker"]
}

# Abstract target (leading underscore, not in any group): shared settings.
target "_common" {
  platforms = split(",", PLATFORMS)
  labels = {
    "org.opencontainers.image.version"  = VERSION
    "org.opencontainers.image.revision" = GIT_SHA
    "org.opencontainers.image.vendor"   = "Shop SAS"
  }
}

target "api" {
  inherits   = ["_common"]
  context    = "../tp01-optimisation-image/shopapi"
  dockerfile = "Dockerfile"
  args = {
    APP_VERSION = VERSION
    GIT_SHA     = GIT_SHA
  }
  tags       = image("shopapi")
  cache-from = cache_from("shopapi")
  cache-to   = cache_to("shopapi")
}

target "worker" {
  inherits   = ["_common"]
  context    = "shop-worker"
  dockerfile = "Dockerfile"
  args = {
    VERSION = VERSION
    GIT_SHA = GIT_SHA
  }
  # Private index credentials: secret mount, never a build arg.
  secret     = ["id=pipconf,src=shop-worker/pip.conf"]
  tags       = image("shop-worker")
  cache-from = cache_from("shop-worker")
  cache-to   = cache_to("shop-worker")
}

# Runs lint + unit tests only: same context/secret/cache as "worker", no image produced.
target "worker-test" {
  inherits  = ["worker"]
  target    = "test"
  # The test stage runs on the build platform anyway: one platform is enough.
  platforms = ["linux/amd64"]
  tags      = []
  cache-to  = []
  output    = ["type=cacheonly"]
}
