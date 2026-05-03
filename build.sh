#!/usr/bin/env bash
# Build a Talos RPi5 installer with a custom RPi kernel and push to GHCR.
#
# WHY: official Talos kernel (6.18.x) + sbc-raspberrypi DTBs (RPi 6.12.25)
# create a version mismatch — RP1 southbridge never inits, so no Ethernet
# and no USB. Building with raspberrypi/linux stable_20250428 (6.12.25) keeps
# kernel and DTBs in sync.
#
# Usage:
#   ./build.sh [TALOS_VERSION]       # defaults to v1.13.0
#
# Key env overrides:
#   REGISTRY    default: ghcr.io
#   USERNAME    default: roiterorh
#   PUSH        default: true  (set false to skip pushing)
#   CLEAN       default: false (set true to delete checkouts/ before starting)
#
# Requirements:
#   git, docker (logged in: docker login ghcr.io -u roiterorh), crane (optional)
set -euo pipefail

TALOS_VERSION=${1:-v1.13.0}
PKG_VERSION=${PKG_VERSION:-${TALOS_VERSION%.*}.0}
REGISTRY=${REGISTRY:-ghcr.io}
USERNAME=${USERNAME:-roiterorh}
PUSH=${PUSH:-true}
CLEAN=${CLEAN:-false}

RPI_KERNEL_VERSION=stable_20250428
RPI_KERNEL_SHA256=c95906cfbc7808de5860c6d86537bea22e3501f600a5209de59a86cb436886f6
RPI_KERNEL_SHA512=0ed5d490c491e590b5980dccf6fcac0dd3c47accbfacd40d91507c12801cff34fa6a1c68991c8a6c57bb259c909121414766f35a0b11c4bd5d62c3e11d710839
OVERLAY_NAME=rpi_5
OVERLAY_IMAGE=ghcr.io/siderolabs/sbc-raspberrypi:v0.2.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKOUTS="${SCRIPT_DIR}/checkouts"
OUT_DIR="${SCRIPT_DIR}/_out"
PATCHES_DIR="${CHECKOUTS}/talos-rpi5-builder/patches"
GIT="git -c user.email=bot@build -c user.name=bot"

[ "${CLEAN}" = "true" ] && rm -rf "${CHECKOUTS}"
mkdir -p "${CHECKOUTS}" "${OUT_DIR}"

echo "==> Talos ${TALOS_VERSION}  |  RPi kernel ${RPI_KERNEL_VERSION}"
echo "==> Registry: ${REGISTRY}/${USERNAME}"
echo ""

# ── 1. Clone talos-rpi5 patches (reference build) ─────────────────────────────
if [ ! -d "${CHECKOUTS}/talos-rpi5-builder" ]; then
  echo "==> Cloning talos-rpi5/talos-builder (for patches)..."
  git clone --depth 1 https://github.com/talos-rpi5/talos-builder.git \
    "${CHECKOUTS}/talos-rpi5-builder"
fi

# ── 2. Extract RPi5 kernel config ─────────────────────────────────────────────
if [ ! -f "${CHECKOUTS}/rpi5-config-arm64" ]; then
  echo "==> Extracting RPi5 kernel config (patching pkgs v1.11.0)..."
  git clone --depth 1 --branch v1.11.0 \
    https://github.com/siderolabs/pkgs.git "${CHECKOUTS}/pkgs-v1110"
  ${GIT} -C "${CHECKOUTS}/pkgs-v1110" \
    am "${PATCHES_DIR}/siderolabs/pkgs/0001-Patched-for-Raspberry-Pi-5.patch"
  cp "${CHECKOUTS}/pkgs-v1110/kernel/build/config-arm64" \
     "${CHECKOUTS}/rpi5-config-arm64"
fi

# ── 3. Extract RPi5 module list ────────────────────────────────────────────────
if [ ! -f "${CHECKOUTS}/rpi5-modules-arm64.txt" ]; then
  echo "==> Extracting RPi5 module list (patching talos v1.11.5)..."
  git clone --depth 1 --branch v1.11.5 \
    https://github.com/siderolabs/talos.git "${CHECKOUTS}/talos-v1115"
  ${GIT} -C "${CHECKOUTS}/talos-v1115" \
    am "${PATCHES_DIR}/siderolabs/talos/0001-Patched-for-Raspberry-Pi-5.patch"
  cp "${CHECKOUTS}/talos-v1115/hack/modules-arm64.txt" \
     "${CHECKOUTS}/rpi5-modules-arm64.txt"
fi

# ── 4. Patch pkgs at PKG_VERSION ──────────────────────────────────────────────
if [ ! -d "${CHECKOUTS}/pkgs" ]; then
  echo "==> Patching siderolabs/pkgs:${PKG_VERSION} for RPi kernel..."
  git clone --depth 1 --branch "${PKG_VERSION}" \
    https://github.com/siderolabs/pkgs.git "${CHECKOUTS}/pkgs"

  # Detect current upstream linux_version line so the sed is version-agnostic
  UPSTREAM_VER=$(grep 'linux_version:' "${CHECKOUTS}/pkgs/Pkgfile" | head -1 | awk '{print $2}')
  UPSTREAM_SHA256=$(grep 'linux_sha256:' "${CHECKOUTS}/pkgs/Pkgfile" | head -1 | awk '{print $2}')
  UPSTREAM_SHA512=$(grep 'linux_sha512:' "${CHECKOUTS}/pkgs/Pkgfile" | head -1 | awk '{print $2}')

  sed -i \
    -e "s|linux_version: ${UPSTREAM_VER}|linux_version: ${RPI_KERNEL_VERSION}|" \
    -e "s|linux_sha256: ${UPSTREAM_SHA256}|linux_sha256: ${RPI_KERNEL_SHA256}|" \
    -e "s|linux_sha512: ${UPSTREAM_SHA512}|linux_sha512: ${RPI_KERNEL_SHA512}|" \
    -e "s|depName=git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git|depName=https://github.com/raspberrypi/linux.git|" \
    "${CHECKOUTS}/pkgs/Pkgfile"

  # Note: use .* not [^"]* — the CDN URL contains quotes inside template
  # expressions like regexReplaceAll "(\d+)" which would truncate [^"]*
  sed -i \
    -e 's|url: https://cdn\.kernel\.org.*|url: "https://github.com/raspberrypi/linux/archive/refs/tags/{{ .linux_version }}.tar.gz"|' \
    -e 's|destination: linux\.tar\.xz|destination: linux.tar.gz|' \
    -e 's|tar -xJf linux\.tar\.xz|tar -xzf linux.tar.gz|' \
    "${CHECKOUTS}/pkgs/kernel/prepare/pkg.yaml"

  cp "${CHECKOUTS}/rpi5-config-arm64" "${CHECKOUTS}/pkgs/kernel/build/config-arm64"

  # Skip hardening checks that don't apply to the RPi vendor kernel:
  #   - CONFIG_ARM64_GCS: requires Armv9.4-A; RPi5 Cortex-A76 is Armv8.2-A
  #   - others: simply not present in the 6.12.25 RPi vendor config
  FILTER_SCRIPT="${CHECKOUTS}/pkgs/kernel/build/scripts/filter-hardened-check.py" \
  python3 - << 'PYEOF'
import os
path = os.environ['FILTER_SCRIPT']
text = open(path).read()
additions = (
    "        'CONFIG_ARM64_GCS', # requires Armv9.4-A; RPi5 Cortex-A76 is Armv8.2-A\n"
    "        'CONFIG_ARM64_BTI_KERNEL', # not in RPi vendor kernel config\n"
    "        'CONFIG_ZERO_CALL_USED_REGS', # not in RPi vendor kernel config\n"
    "        'CONFIG_HARDENED_USERCOPY_DEFAULT_ON', # not in RPi vendor kernel config\n"
)
marker = "    'arm64': {\n"
text = text.replace(marker, marker + additions, 1)
open(path, 'w').write(text)
PYEOF

  ${GIT} -C "${CHECKOUTS}/pkgs" commit -am "rpi5: use raspberrypi/linux ${RPI_KERNEL_VERSION}"
fi

# ── 5. Build RPi5 kernel ───────────────────────────────────────────────────────
echo "==> Building RPi5 kernel (~30 min)..."
make -C "${CHECKOUTS}/pkgs" \
  REGISTRY="${REGISTRY}" USERNAME="${USERNAME}" PUSH="${PUSH}" \
  PLATFORM=linux/arm64 \
  kernel

PKGS_TAG=$(git -C "${CHECKOUTS}/pkgs" describe --tags --always --dirty --match 'v[0-9]*')
echo "==> Kernel: ${REGISTRY}/${USERNAME}/kernel:${PKGS_TAG}"

# ── 6. Patch talos at TALOS_VERSION ───────────────────────────────────────────
if [ ! -d "${CHECKOUTS}/talos" ]; then
  echo "==> Patching siderolabs/talos:${TALOS_VERSION} for RPi5 modules..."
  git clone --depth 1 --branch "${TALOS_VERSION}" \
    https://github.com/siderolabs/talos.git "${CHECKOUTS}/talos"
  cp "${CHECKOUTS}/rpi5-modules-arm64.txt" "${CHECKOUTS}/talos/hack/modules-arm64.txt"
  ${GIT} -C "${CHECKOUTS}/talos" commit -am "rpi5: modules-arm64.txt for ${RPI_KERNEL_VERSION}"
fi

TALOS_TAG=$(git -C "${CHECKOUTS}/talos" describe --tags --always --dirty --match 'v[0-9]*')

# ── 7. Build installer ─────────────────────────────────────────────────────────
echo "==> Building Talos installer..."
make -C "${CHECKOUTS}/talos" \
  REGISTRY="${REGISTRY}" USERNAME="${USERNAME}" PUSH="${PUSH}" \
  PKG_KERNEL="${REGISTRY}/${USERNAME}/kernel:${PKGS_TAG}" \
  INSTALLER_ARCH=arm64 PLATFORM=linux/arm64 \
  IMAGER_ARGS="--overlay-name=${OVERLAY_NAME} --overlay-image=${OVERLAY_IMAGE}" \
  kernel initramfs imager installer-base installer

# Re-tag with the clean TALOS_VERSION for easy reference
if [ "${PUSH}" = "true" ]; then
  INSTALLER_IMAGE="${REGISTRY}/${USERNAME}/installer:${TALOS_VERSION}"
  docker pull "${REGISTRY}/${USERNAME}/installer:${TALOS_TAG}"
  docker tag  "${REGISTRY}/${USERNAME}/installer:${TALOS_TAG}" "${INSTALLER_IMAGE}"
  docker push "${INSTALLER_IMAGE}"
  echo "==> Pushed: ${INSTALLER_IMAGE}"
fi

# ── 8. Build metal disk image ──────────────────────────────────────────────────
echo "==> Building metal disk image..."
docker run --rm -t \
  -v "${OUT_DIR}:/out" \
  -v /dev:/dev --privileged \
  "${REGISTRY}/${USERNAME}/imager:${TALOS_TAG}" \
  metal --arch arm64 \
  --base-installer-image="${REGISTRY}/${USERNAME}/installer:${TALOS_VERSION}" \
  --overlay-name="${OVERLAY_NAME}" \
  --overlay-image="${OVERLAY_IMAGE}"

# ── 9. Inject RPi5 UEFI firmware into metal image boot partition ──────────────
echo "==> Injecting RPi5 UEFI firmware..."

# Decompress if imager compressed it
if [ -f "${OUT_DIR}/metal-arm64.raw.zst" ] && [ ! -f "${OUT_DIR}/metal-arm64.raw" ]; then
  zstd -d "${OUT_DIR}/metal-arm64.raw.zst" && rm "${OUT_DIR}/metal-arm64.raw.zst"
fi

# Download worproject/rpi5-uefi (BCM2712-aware UEFI, replaces rpi_arm64 U-Boot)
UEFI_ZIP="${CHECKOUTS}/RPi5_UEFI_Release_v0.3.zip"
if [ ! -f "${UEFI_ZIP}" ]; then
  curl -sLo "${UEFI_ZIP}" \
    "https://github.com/worproject/rpi5-uefi/releases/download/v0.3/RPi5_UEFI_Release_v0.3.zip"
fi
mkdir -p "${CHECKOUTS}/rpi5-uefi"
unzip -qo "${UEFI_ZIP}" -d "${CHECKOUTS}/rpi5-uefi"

LOOP=$(sudo losetup -f --show -P "${OUT_DIR}/metal-arm64.raw")
sudo mkdir -p /mnt/efi
sudo mount "${LOOP}p1" /mnt/efi

sudo cp "${CHECKOUTS}/rpi5-uefi/RPI_EFI.fd" /mnt/efi/
# UEFI firmware's own BCM2712 DTB (used by the firmware during hardware init)
sudo cp "${CHECKOUTS}/rpi5-uefi/bcm2712-rpi-5-b.dtb" /mnt/efi/
# sbc-raspberrypi DTBs already on the partition from the imager; no need to re-copy

printf 'armstub=RPI_EFI.fd\ndevice_tree_address=0x1f0000\ndevice_tree_end=0x210000\nenable_uart=1\ndisable_overscan=1\n' \
  | sudo tee /mnt/efi/config.txt

echo "==> Boot partition contents:"
ls /mnt/efi/

sudo umount /mnt/efi
sudo losetup -d "${LOOP}"

[ -f "${OUT_DIR}/metal-arm64.raw.zst" ] || zstd --rm "${OUT_DIR}/metal-arm64.raw" -o "${OUT_DIR}/metal-arm64.raw.zst"

echo ""
echo "==> Done!"
echo "    Installer: ${REGISTRY}/${USERNAME}/installer:${TALOS_VERSION}"
echo "    Disk image: ${OUT_DIR}/metal-arm64.raw.zst"
