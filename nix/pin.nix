# =============================================================================
# nix/pin.nix
#
# THIS FILE IS MACHINE-WRITTEN. Do not hand-edit the values below — the
# "package-and-push" job in .github/workflows/build-kernel.yml overwrites
# this file after every successful kernel build and commits it back to the
# repo (with "[skip ci]" so it doesn't retrigger a build), so that:
#
#   - `nix flake show` / `nixos-rebuild switch` always evaluate against a
#     git-committed, reproducible pin, not a mutable "latest" tag.
#   - Anyone who clones this repo gets the exact kernel that was actually
#     built and pushed to Cachix, byte for byte — `fetchurl` with a pinned
#     sha256 is a fixed-output derivation, so Nix will refuse to accept
#     anything that doesn't hash-match this file, whether that's a corrupted
#     download, a compromised release asset, or a stale cache entry.
#
# Placeholder values below (lib.fakeHash) intentionally fail evaluation with
# a clear "you haven't run the build workflow yet" error rather than silently
# building nothing.
# =============================================================================
{ lib }:
{
  # Kernel version reported by `uname -r`-style tooling, e.g. "6.12.108".
  version = "6.12.108";

  # Full module directory name under /lib/modules, e.g.
  # "6.12.108-tkg-bore". Must exactly match what linux-tkg's `make
  # modules_install` actually created on the build runner — CI reads this
  # back out of the build rather than guessing it.
  modDirVersion = "6.12.108-tkg-zenith-t480";

  # The pinned linux-tkg source revision this kernel was built from.
  tkgRev = "REPLACE_ME_TKG_REV";

  # Big tarball: bzImage + System.map + installed modules tree + (best
  # effort) headers for out-of-tree module builds. zstd-compressed.
  kernelTarball = {
    url = "https://example.invalid/REPLACE_ME";
    sha256 = lib.fakeSha256;
  };

  # Small standalone .config text file, fetched separately so it's available
  # to Nix as a real source file *before* the kernel derivation builds (the
  # big tarball's contents aren't usable for this since they only exist
  # after the derivation that unpacks them runs).
  configFile = {
    url = "https://example.invalid/REPLACE_ME";
    sha256 = lib.fakeSha256;
  };

  buildDate = "REPLACE_ME_DATE";
  githubRunUrl = "REPLACE_ME_RUN_URL";
}
