#!/usr/bin/env bash
# =============================================================================
# scripts/package-tarball.sh
#
# Packages ./dist (populated by build-tkg.sh) into the layout nix/kernel.nix
# expects: boot/{bzImage,System.map,config}, lib/modules/<ver>/,
# usr/src/linux-headers-<ver>/. Also splits the .config out as its own small
# file, since nix/kernel.nix fetches that separately from the big tarball
# (see the comment in nix/kernel.nix for why).
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
OUT_DIR="${REPO_ROOT}/out"

: "${MOD_DIR_VERSION:?set to the modDirVersion build-tkg.sh printed}"

mkdir -p "${OUT_DIR}"

for required in "boot/bzImage" "boot/System.map" "boot/config" "lib/modules/${MOD_DIR_VERSION}"; do
  if [ ! -e "${DIST_DIR}/${required}" ]; then
    echo "error: ${DIST_DIR}/${required} is missing, refusing to package a broken build" >&2
    exit 1
  fi
done

TARBALL="${OUT_DIR}/zenith-kernel-${MOD_DIR_VERSION}.tar.zst"
echo "==> Packaging ${TARBALL}"
tar -C "${DIST_DIR}" --zstd -cf "${TARBALL}" boot lib usr 2>/dev/null \
  || tar -C "${DIST_DIR}" --zstd -cf "${TARBALL}" boot lib   # usr/ is best-effort

cp "${DIST_DIR}/boot/config" "${OUT_DIR}/zenith-kernel-${MOD_DIR_VERSION}.config"

TARBALL_SHA256="$(sha256sum "${TARBALL}" | cut -d' ' -f1)"
CONFIG_SHA256="$(sha256sum "${OUT_DIR}/zenith-kernel-${MOD_DIR_VERSION}.config" | cut -d' ' -f1)"

echo "==> tarball sha256:  ${TARBALL_SHA256}"
echo "==> config  sha256:  ${CONFIG_SHA256}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "tarball_path=${TARBALL}"
    echo "tarball_sha256=${TARBALL_SHA256}"
    echo "config_path=${OUT_DIR}/zenith-kernel-${MOD_DIR_VERSION}.config"
    echo "config_sha256=${CONFIG_SHA256}"
  } >> "${GITHUB_OUTPUT}"
fi
