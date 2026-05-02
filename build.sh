#!/usr/bin/env bash
# Build a Talos RPi5 installer with a custom RPi kernel.
#
# WHY custom kernel: the official Talos kernel (6.18.x) + sbc-raspberrypi DTBs
# (from RPi 6.12.25) cause a version mismatch — RP1 southbridge doesn't
# initialise, leaving no Ethernet and no USB. Building with the RPi kernel
# (stable_20250428 / 6.12.25) keeps kernel and DTBs in sync.
#
# Usage: ./build.sh [TALOS_VERSION]
#   TALOS_VERSION  default: v1.13.0
#
# Env overrides:
#   REGISTRY   default: ghcr.io
#   USERNAME   default: roiterorh
#   PUSH       set to "false" to skip pushing (default: true)
#   OUT_DIR    default: ./_out
#   KEEP       set to "true" to keep checkout directories after build
#
# Requirements: git, docker (logged in to GHCR), crane or docker, make
# Runs best on an ARM64 host — cross-compiling adds ~3× build time.
set -euo pipefail

TALOS_VERSION=${1:-v1.13.0}
# PKG_VERSION tracks siderolabs/pkgs; matches TALOS_VERSION for official releases
PKG_VERSION=${PKG_VERSION:-${TALOS_VERSION%.*}.0}
REGISTRY=${REGISTRY:-ghcr.io}
USERNAME=${USERNAME:-roiterorh}
PUSH=${PUSH:-true}
OUT_DIR=${OUT_DIR:-${PWD}/_out}
KEEP=${KEEP:-false}
WORK_DIR=$(mktemp -d)

# RPi stable kernel (6.12.25) — same source used by sbc-raspberrypi:v0.2.0 DTBs
RPI_KERNEL_VERSION=stable_20250428
RPI_KERNEL_SHA256=c95906cfbc7808de5860c6d86537bea22e3501f600a5209de59a86cb436886f6
RPI_KERNEL_SHA512=0ed5d490c491e590b5980dccf6fcac0dd3c47accbfacd40d91507c12801cff34fa6a1c68991c8a6c57bb259c909121414766f35a0b11c4bd5d62c3e11d710839

# Overlay: official sbc-raspberrypi:v0.2.0 DTBs built from the same RPi 6.12.25 source
OVERLAY_NAME=rpi_5
OVERLAY_IMAGE=ghcr.io/siderolabs/sbc-raspberrypi:v0.2.0

KERNEL_IMAGE="${REGISTRY}/${USERNAME}/kernel:${TALOS_VERSION}-rpi5"
INSTALLER_IMAGE="${REGISTRY}/${USERNAME}/installer:${TALOS_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cleanup() {
  if [ "${KEEP}" != "true" ] && [ -d "${WORK_DIR}" ]; then
    rm -rf "${WORK_DIR}"
  fi
}
trap cleanup EXIT

echo "==> Talos ${TALOS_VERSION} | RPi kernel ${RPI_KERNEL_VERSION}"
echo "==> Kernel:    ${KERNEL_IMAGE}"
echo "==> Installer: ${INSTALLER_IMAGE}"
echo "==> Work dir:  ${WORK_DIR}"
echo ""
mkdir -p "${OUT_DIR}"


# ── 1. Get RPi5 kernel config and module list via the existing talos-rpi5 patch ─
echo "==> Extracting RPi5 kernel config from talos-rpi5/talos-builder..."
git clone --depth 1 https://github.com/talos-rpi5/talos-builder.git "${WORK_DIR}/talos-rpi5-builder"

# Apply original patch to v1.11.0 pkgs to extract the RPi5 kernel config
git clone --depth 1 --branch v1.11.0 https://github.com/siderolabs/pkgs.git "${WORK_DIR}/pkgs-v1110"
git -C "${WORK_DIR}/pkgs-v1110" -c user.email="bot@build" -c user.name="bot" \
  am "${WORK_DIR}/talos-rpi5-builder/patches/siderolabs/pkgs/0001-Patched-for-Raspberry-Pi-5.patch"
RPI5_CONFIG="${WORK_DIR}/pkgs-v1110/kernel/build/config-arm64"

# Apply original patch to v1.11.5 talos to extract the RPi5 module list
git clone --depth 1 --branch v1.11.5 https://github.com/siderolabs/talos.git "${WORK_DIR}/talos-v1115"
git -C "${WORK_DIR}/talos-v1115" -c user.email="bot@build" -c user.name="bot" \
  am "${WORK_DIR}/talos-rpi5-builder/patches/siderolabs/talos/0001-Patched-for-Raspberry-Pi-5.patch"
RPI5_MODULES="${WORK_DIR}/talos-v1115/hack/modules-arm64.txt"


# ── 2. Patch siderolabs/pkgs at TALOS_VERSION ─────────────────────────────────
echo "==> Patching siderolabs/pkgs:${PKG_VERSION} for RPi kernel..."
git clone --depth 1 --branch "${PKG_VERSION}" https://github.com/siderolabs/pkgs.git "${WORK_DIR}/pkgs"

python3 - "${WORK_DIR}/pkgs/Pkgfile" <<PYEOF
import sys, re

path = sys.argv[1]
text = open(path).read()

# Swap upstream kernel for RPi kernel
text = re.sub(
    r'  # renovate: datasource=git-tags extractVersion=\^v\(\?<version>\.\*\)\$ depName=git://git\.kernel\.org[^\n]*\n'
    r'  linux_version: [^\n]+\n'
    r'  linux_sha256: [^\n]+\n'
    r'  linux_sha512: [^\n]+',
    (
        '  # renovate: datasource=git-tags extractVersion=^v(?<version>.*)$ '
        'depName=https://github.com/raspberrypi/linux.git\n'
        '  linux_version: ${RPI_KERNEL_VERSION}\n'
        '  linux_sha256: ${RPI_KERNEL_SHA256}\n'
        '  linux_sha512: ${RPI_KERNEL_SHA512}'
    ),
    text
)

open(path, 'w').write(text)
PYEOF

# Fix kernel download URL to point at GitHub RPi archive
python3 - "${WORK_DIR}/pkgs/kernel/prepare/pkg.yaml" <<'PYEOF'
import sys

path = sys.argv[1]
text = open(path).read()
text = text.replace(
    'url: https://cdn.kernel.org/pub/linux/kernel/v{{ regexReplaceAll "(\\\\d+)(.\\\\d+)(\\\\.\\\\d+)?$" .linux_version "${1}" }}.x/linux-{{ .linux_version }}.tar.xz',
    'url: "https://github.com/raspberrypi/linux/archive/refs/tags/{{ .linux_version }}.tar.gz"'
)
text = text.replace('destination: linux.tar.xz', 'destination: linux.tar.gz')
text = text.replace('tar -xJf linux.tar.xz', 'tar -xzf linux.tar.gz')
open(path, 'w').write(text)
PYEOF

# Install the RPi5-compatible kernel config (from 6.12.25 RPi kernel)
cp "${RPI5_CONFIG}" "${WORK_DIR}/pkgs/kernel/build/config-arm64"

git -C "${WORK_DIR}/pkgs" -c user.email="bot@build" -c user.name="bot" \
  commit -am "rpi5: use raspberrypi/linux ${RPI_KERNEL_VERSION}"


# ── 3. Build RPi5 kernel ───────────────────────────────────────────────────────
echo "==> Building RPi5 kernel (this takes ~30 min on ARM64)..."
make -C "${WORK_DIR}/pkgs" \
  REGISTRY="${REGISTRY}" USERNAME="${USERNAME}" PUSH="${PUSH}" \
  PLATFORM=linux/arm64 \
  kernel

# Determine the pkgs image tag (git describe of the patched checkout)
PKGS_TAG=$(git -C "${WORK_DIR}/pkgs" describe --tags --always --dirty --match 'v[0-9]*')
echo "==> Kernel built as ${REGISTRY}/${USERNAME}/kernel:${PKGS_TAG}"


# ── 4. Patch siderolabs/talos at TALOS_VERSION ────────────────────────────────
echo "==> Patching siderolabs/talos:${TALOS_VERSION} for RPi5 modules..."
git clone --depth 1 --branch "${TALOS_VERSION}" https://github.com/siderolabs/talos.git "${WORK_DIR}/talos"
cp "${RPI5_MODULES}" "${WORK_DIR}/talos/hack/modules-arm64.txt"
git -C "${WORK_DIR}/talos" -c user.email="bot@build" -c user.name="bot" \
  commit -am "rpi5: update modules-arm64.txt for RPi kernel"


# ── 5. Build installer + metal image ──────────────────────────────────────────
echo "==> Building Talos installer and metal image..."
make -C "${WORK_DIR}/talos" \
  REGISTRY="${REGISTRY}" USERNAME="${USERNAME}" PUSH="${PUSH}" \
  PKG_KERNEL="${REGISTRY}/${USERNAME}/kernel:${PKGS_TAG}" \
  INSTALLER_ARCH=arm64 PLATFORM=linux/arm64 \
  IMAGER_ARGS="--overlay-name=${OVERLAY_NAME} --overlay-image=${OVERLAY_IMAGE}" \
  kernel initramfs imager installer-base installer

# Tag the installer with the clean TALOS_VERSION
if [ "${PUSH}" = "true" ]; then
  docker pull "${REGISTRY}/${USERNAME}/installer:$(git -C "${WORK_DIR}/talos" describe --tags --always --dirty --match 'v[0-9]*')"
  docker tag "${REGISTRY}/${USERNAME}/installer:$(git -C "${WORK_DIR}/talos" describe --tags --always --dirty --match 'v[0-9]*')" "${INSTALLER_IMAGE}"
  docker push "${INSTALLER_IMAGE}"
fi

# Build metal raw image
docker run --rm -t \
  -v "${OUT_DIR}:/out" \
  -v /dev:/dev --privileged \
  "${REGISTRY}/${USERNAME}/imager:$(git -C "${WORK_DIR}/talos" describe --tags --always --dirty --match 'v[0-9]*')" \
  metal --arch arm64 \
  --base-installer-image="${INSTALLER_IMAGE}" \
  --overlay-name="${OVERLAY_NAME}" \
  --overlay-image="${OVERLAY_IMAGE}"

echo ""
echo "==> Done!"
echo "    Installer: ${INSTALLER_IMAGE}"
echo "    Disk image: ${OUT_DIR}/metal-arm64.raw.zst"
