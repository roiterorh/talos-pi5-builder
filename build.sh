#!/usr/bin/env bash
# Build a Talos RPi5 installer image and metal disk image.
# Usage: ./build.sh [TALOS_VERSION]
# Example: ./build.sh v1.13.0
#
# Env overrides:
#   REGISTRY       default: ghcr.io
#   USERNAME       default: roiterorh
#   OVERLAY_NAME   default: rpi_5
#   OVERLAY_IMAGE  auto-detected from TALOS_VERSION if not set
#   PUSH           set to "false" to skip pushing the installer image
#   OUT_DIR        default: ./_out
set -euo pipefail

TALOS_VERSION=${1:-v1.13.0}
REGISTRY=${REGISTRY:-ghcr.io}
USERNAME=${USERNAME:-roiterorh}
OVERLAY_NAME=${OVERLAY_NAME:-rpi_5}
PUSH=${PUSH:-true}
OUT_DIR=${OUT_DIR:-${PWD}/_out}

# Determine overlay image from Talos version.
# rpi_5 was added in sbc-raspberrypi:v0.1.8 (overlays v1.13.0)
resolve_overlay_image() {
  local version=$1
  local major minor
  major=$(echo "${version#v}" | cut -d. -f1)
  minor=$(echo "${version#v}" | cut -d. -f2)
  if [ "${major}" -gt 1 ] || { [ "${major}" -eq 1 ] && [ "${minor}" -ge 13 ]; }; then
    echo "ghcr.io/siderolabs/sbc-raspberrypi:v0.2.0"
  else
    # Pre-v1.13 had no official rpi_5 overlay; fallback to talos-rpi5 pattern
    echo "ghcr.io/siderolabs/sbc-raspberrypi:v0.1.8"
  fi
}

OVERLAY_IMAGE=${OVERLAY_IMAGE:-$(resolve_overlay_image "${TALOS_VERSION}")}
INSTALLER_IMAGE="${REGISTRY}/${USERNAME}/installer:${TALOS_VERSION}"
IMAGER="ghcr.io/siderolabs/imager:${TALOS_VERSION}"

echo "==> Talos ${TALOS_VERSION} | ${OVERLAY_NAME} | ${OVERLAY_IMAGE}"
echo "==> Installer: ${INSTALLER_IMAGE}"
echo "==> Output:    ${OUT_DIR}"
echo ""

mkdir -p "${OUT_DIR}"

# ── 1. Build installer image ──────────────────────────────────────────────────
echo "==> Building installer image..."
# The imager runs natively on the host arch and produces arm64 artifacts
# via --arch; no buildx/QEMU required on the host.
docker run --rm -t \
  -v "${OUT_DIR}:/out" \
  "${IMAGER}" \
  installer \
  --arch arm64 \
  --overlay-name="${OVERLAY_NAME}" \
  --overlay-image="${OVERLAY_IMAGE}"

# ── 2. Push installer image ───────────────────────────────────────────────────
if [ "${PUSH}" = "true" ]; then
  echo "==> Pushing ${INSTALLER_IMAGE}..."
  if command -v crane &>/dev/null; then
    crane push "${OUT_DIR}/installer-arm64.tar" "${INSTALLER_IMAGE}"
  else
    docker load -i "${OUT_DIR}/installer-arm64.tar"
    docker tag "ghcr.io/siderolabs/installer:${TALOS_VERSION}" "${INSTALLER_IMAGE}"
    docker push "${INSTALLER_IMAGE}"
  fi
fi

# ── 3. Build metal disk image ─────────────────────────────────────────────────
echo "==> Building metal disk image..."
docker run --rm -t \
  -v "${OUT_DIR}:/out" \
  -v /dev:/dev --privileged \
  "${IMAGER}" \
  metal \
  --arch arm64 \
  --overlay-name="${OVERLAY_NAME}" \
  --overlay-image="${OVERLAY_IMAGE}" \
  --base-installer-image="${INSTALLER_IMAGE}"

echo ""
echo "==> Done!"
echo "    Installer: ${INSTALLER_IMAGE}"
echo "    Disk image: ${OUT_DIR}/metal-arm64.raw.zst"
