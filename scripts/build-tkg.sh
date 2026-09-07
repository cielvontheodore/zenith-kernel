#!/usr/bin/env bash
# =============================================================================
# scripts/build-tkg.sh
#
# Runs on a plain Ubuntu GitHub Actions runner — NOT inside Nix, NOT inside
# NixOS. Clones the pinned linux-tkg revision, drops in customization.cfg
# and the .myfrag config fragments from the repo root, and builds.
#
# customization.cfg sets _install_after_building="no" on purpose: we do NOT
# want linux-tkg's interactive "sudo cp -R ... / sudo make install / sudo
# dracut / sudo grub-mkconfig" system-install flow (it's meant for someone
# installing onto the machine they're building on, prompts for confirmation,
# and assumes dracut/grub which this Ubuntu runner may not even have
# configured the way TKG expects). Instead we let it compile, then reach
# into the resulting build tree ourselves and copy out exactly the artifacts
# we need with INSTALL_MOD_PATH, which is scriptable and doesn't touch the
# runner's actual boot config at all.
#
# NOTE on the build directory name: linux-tkg's internal working-directory
# naming (something like "linux<major><minor>-tkg-<flavor>/") isn't part of
# its documented/stable interface and has varied across revisions in the
# wild. Rather than hardcode a guess, this script locates it by searching
# for a directory containing both a patched Makefile and a .config with our
# CONFIG_LOCALVERSION marker. If linux-tkg changes its layout again, this is
# the first thing to check — see docs/NOTES.md.
# =============================================================================
set -euo pipefail

: "${ZENITH_KERNEL_VERSION:?set to the pinned linux-tkg _version, e.g. 6.12.108}"
: "${TKG_REV:?set to the pinned Frogging-Family/linux-tkg commit SHA}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
DESTDIR="${REPO_ROOT}/dist"
LOCALVERSION="zenith-t480"

echo "==> Installing build dependencies"
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
  build-essential bison flex libncurses-dev libelf-dev libssl-dev \
  dwarves pahole bc kmod cpio rsync git zstd \
  clang lld llvm libpci-dev

echo "==> Cloning linux-tkg @ ${TKG_REV}"
git clone https://github.com/Frogging-Family/linux-tkg.git "${WORK_DIR}/linux-tkg"
cd "${WORK_DIR}/linux-tkg"
git checkout "${TKG_REV}"

echo "==> Installing pinned customization.cfg and config fragments"
cp "${REPO_ROOT}/customization.cfg" ./customization.cfg
cp "${REPO_ROOT}"/zenith-t480-*.myfrag ./
sed -i "s/^_version=.*/_version=\"${ZENITH_KERNEL_VERSION}\"/" ./customization.cfg
sed -i "s/^_kernel_localversion=.*/_kernel_localversion=\"${LOCALVERSION}\"/" ./customization.cfg

if [ -f "${REPO_ROOT}/modprobed.db" ]; then
  echo "==> Using provided modprobed.db"
  cp "${REPO_ROOT}/modprobed.db" ./modprobed.db
else
  echo "==> No modprobed.db present — disabling modprobed-db for this build"
  echo "    (falls back to the full default module set; safe, just bigger)."
  sed -i 's/^_modprobeddb=.*/_modprobeddb="false"/' ./customization.cfg
fi

echo "==> Building (this is the slow part — expect 30-90+ minutes)"
./install.sh install

echo "==> Locating the built kernel tree"
BUILD_DIR="$(
  find . -maxdepth 2 -type f -name Makefile -exec grep -l '^VERSION = ' {} \; \
    | xargs -n1 dirname \
    | while read -r d; do
        if [ -f "${d}/.config" ] && grep -q "CONFIG_LOCALVERSION=\"-${LOCALVERSION}\"" "${d}/.config" 2>/dev/null; then
          echo "$d"
        fi
      done \
    | head -n1
)"

if [ -z "${BUILD_DIR}" ]; then
  echo "error: couldn't locate the built kernel tree automatically." >&2
  echo "This means linux-tkg's internal directory layout changed since" >&2
  echo "this script was written — see docs/NOTES.md for how to fix it." >&2
  exit 1
fi
echo "    found: ${BUILD_DIR}"
cd "${BUILD_DIR}"

MOD_DIR_VERSION="$(make -s kernelrelease)"
echo "    modDirVersion = ${MOD_DIR_VERSION}"

echo "==> Installing modules into ${DESTDIR}"
mkdir -p "${DESTDIR}"
make -j"$(nproc)" INSTALL_MOD_PATH="${DESTDIR}" INSTALL_MOD_STRIP=1 modules_install

echo "==> Copying boot artifacts"
mkdir -p "${DESTDIR}/boot"
cp arch/x86/boot/bzImage "${DESTDIR}/boot/bzImage"
cp System.map "${DESTDIR}/boot/System.map"
cp .config "${DESTDIR}/boot/config"

echo "==> Capturing build tree for out-of-tree module headers (best effort)"
HDR_DIR="${DESTDIR}/usr/src/linux-headers-${MOD_DIR_VERSION}"
mkdir -p "${HDR_DIR}"
# Mirrors roughly what Debian's linux-headers packages ship: enough to build
# an out-of-tree module against, without the full multi-GB build tree.
rsync -a --delete \
  --include='Makefile' --include='Module.symvers' --include='.config' \
  --include='include/***' --include='scripts/***' --include='arch/x86/include/***' \
  --include='arch/x86/Makefile*' --include='Kconfig*' \
  --include='*/' --exclude='*' \
  ./ "${HDR_DIR}/" || true

echo "==> Done. modDirVersion=${MOD_DIR_VERSION}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "modDirVersion=${MOD_DIR_VERSION}" >> "${GITHUB_OUTPUT}"
fi
