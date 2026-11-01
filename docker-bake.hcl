# docker buildx bake definition. Variables are exported from versions.json by
# scripts/bake-env.sh so the JSON stays the single source of truth:
#   eval "$(scripts/bake-env.sh)" && docker buildx bake stable --load
variable "IMAGE" { default = "ghcr.io/rocketedge/brokersre-ib-gateway" }
variable "UBUNTU_DIGEST" { default = "" }
variable "IBC_VERSION" { default = "" }
variable "IBC_RELEASE_TAG" { default = "" }
variable "IBC_SHA256" { default = "" }
variable "STABLE_VERSION" { default = "" }
variable "STABLE_MINOR" { default = "" }
variable "STABLE_SHA256_X64" { default = "" }
variable "STABLE_SHA256_ARM" { default = "" }
variable "LATEST_VERSION" { default = "" }
variable "LATEST_MINOR" { default = "" }
variable "LATEST_SHA256_X64" { default = "" }
variable "LATEST_SHA256_ARM" { default = "" }
# Rebuild suffix (e.g. -r20261201) for OS-patch rebuilds of an unchanged Gateway version.
variable "REBUILD_SUFFIX" { default = "" }
variable "PLATFORMS" { default = "linux/amd64,linux/arm64" }
variable "SOURCE_REVISION" { default = "" }
variable "CREATED" { default = "" }

group "default" {
  targets = ["stable", "latest"]
}

target "common" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = split(",", PLATFORMS)
  args = {
    UBUNTU_DIGEST   = UBUNTU_DIGEST
    IBC_VERSION     = IBC_VERSION
    IBC_RELEASE_TAG = IBC_RELEASE_TAG
    IBC_SHA256      = IBC_SHA256
  }
  labels = {
    "org.opencontainers.image.revision" = SOURCE_REVISION
    "org.opencontainers.image.created"  = CREATED
    "org.opencontainers.image.base.digest" = UBUNTU_DIGEST
  }
}

target "stable" {
  inherits = ["common"]
  args = {
    IB_GATEWAY_CHANNEL    = "stable"
    IB_GATEWAY_VERSION    = STABLE_VERSION
    IB_GATEWAY_SHA256_X64 = STABLE_SHA256_X64
    IB_GATEWAY_SHA256_ARM = STABLE_SHA256_ARM
  }
  tags = [
    "${IMAGE}:${STABLE_VERSION}${REBUILD_SUFFIX}",
    "${IMAGE}:${STABLE_VERSION}",
    "${IMAGE}:${STABLE_MINOR}",
    "${IMAGE}:stable",
  ]
}

target "latest" {
  inherits = ["common"]
  args = {
    IB_GATEWAY_CHANNEL    = "latest"
    IB_GATEWAY_VERSION    = LATEST_VERSION
    IB_GATEWAY_SHA256_X64 = LATEST_SHA256_X64
    IB_GATEWAY_SHA256_ARM = LATEST_SHA256_ARM
  }
  # "latest" here is IBKR's channel name. Docker's conventional :latest is never published.
  tags = [
    "${IMAGE}:${LATEST_VERSION}${REBUILD_SUFFIX}",
    "${IMAGE}:${LATEST_VERSION}",
    "${IMAGE}:${LATEST_MINOR}",
    "${IMAGE}:latest",
  ]
}
