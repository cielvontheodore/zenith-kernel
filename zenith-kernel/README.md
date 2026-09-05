# Zenith Kernel

A CI-built, Cachix-distributed custom Linux 6.6 kernel for the ThinkPad T480:
BORE scheduler, Clang/LLVM + ThinLTO, x86-64-v3 tuning, and a module set
trimmed against a real `modprobed.db` from the machine — with the entire
build reproducible from this repository plus `flake.lock`, on GitHub Actions,
with no dependency on any local machine state.

```text
zenith-kernel/
├── flake.nix                     # exposes zenithKernel / linuxPackages_zenith
├── flake.lock                    # generate with `nix flake lock`
├── kernel.nix                    # the actual derivation logic
├── patches/
│   └── README.md                 # BORE + x86-64-v3 patch sourcing notes
├── config/
│   ├── zenith.config             # Kconfig safety-net fragment
│   └── modprobed.db              # PLACEHOLDER — replace with your real db
├── nixos/
│   ├── example-flake.nix         # how to consume this from your T480 config
│   └── example-overlay-usage.nix # alternative overlay-based consumption
└── .github/workflows/
    ├── build.yml                 # push-to-main + workflow_dispatch
    └── release.yml               # optional: tag-triggered
```

## Why this isn't what you first sketched, and why

Three things in the original design were checked against the actual
nixpkgs/kernel APIs and turned out not to exist as specified:

1. **There is no `buildLinux` attribute for modprobed.db.** Nixpkgs has no
   `modprobed-db = ./modprobed.db;` knob. `modprobed.db` is only ever
   consumed by the kernel's own `make LSMOD=<db> localmodconfig` target.
   `kernel.nix` has a dedicated derivation (`zenithConfig`) that runs
   `defconfig` → `localmodconfig` (using your db) → forces a safety-net
   Kconfig fragment back on → `olddefconfig`, and hands the resulting
   `.config` file to `linuxManualConfig` as `configfile`. `buildLinux`'s
   `structuredExtraConfig` is a Kconfig-symbol-level merge tool and has no
   equivalent of "diff against a list of modules actually probed on real
   hardware," so it's the wrong tool for this specific job — `linuxManualConfig`
   with a pre-built configfile is the idiomatic escape hatch nixpkgs itself
   uses for exactly this kind of fine-grained control.

2. **`GENERIC_CPU3 = yes;` is not a real kernel option**, in mainline or in
   current third-party patches. Mainline Linux has *no* x86-64 microarchitecture
   level Kconfig option at all — `-march=x86-64-v3`-equivalent kernel-wide
   tuning only exists via the out-of-tree
   [graysky2/kernel_compiler_patch](https://github.com/graysky2/kernel_compiler_patch).
   That patch *used to* expose `GENERIC_CPU2`/`GENERIC_CPU3`/`GENERIC_CPU4`
   booleans, but was refactored to a single `CONFIG_X86_64_VERSION` int
   (range 1–3) symbol instead. `config/zenith.config` applies the current
   patch and sets `CONFIG_X86_64_VERSION=3`.

3. **`-O3` is not the technically correct choice for the kernel.** The
   kernel build system only officially supports `-O2`
   (`CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE`, the default) or `-Os`
   (`CONFIG_CC_OPTIMIZE_FOR_SIZE`). There's no supported `-O3` Kconfig path;
   forcing `-O3` via `KCFLAGS`/`EXTRA_CFLAGS` bypasses testing the kernel
   community actually does and is a recurring source of miscompilation
   reports in kernels that carry such patches. `config/zenith.config`
   deliberately does not touch this — the kernel's default `-O2` path is
   used as-is. Throughput here should instead come from ThinLTO
   (`CONFIG_LTO_CLANG_THIN`) and the x86-64-v3 vectorization/ISA baseline,
   which *are* supported mechanisms.

## First build

The `fetchurl`/`fetchpatch` calls in `kernel.nix` use `lib.fakeHash`
placeholders — Nix's normal, safe way of pinning a hash you don't have yet.
Fill them in like this:

```bash
git clone https://github.com/<you>/zenith-kernel
cd zenith-kernel

# 1. Get your real modprobed.db onto disk first (see config/modprobed.db).
cp /path/to/your/real/modprobed.db config/modprobed.db

# 2. Run the build once; it will fail on hash mismatch and print the
#    correct hash for each fakeHash placeholder, in this order:
#    kernel source tarball -> BORE patch -> ISA-level patch.
nix build .#zenithKernel -L
# Copy each reported "got: sha256-..." value into the matching `hash = ...`
# field in kernel.nix, then re-run. Repeat until all three are filled in.

nix build .#zenithKernel -L
```

## Testing the build locally

```bash
# Full kernelPackages set (kernel + modules + headers):
nix build .#linuxPackages_zenith.kernel -L

# Just the bare kernel image + config it was built from:
nix build .#zenithKernel -L
nix run nixpkgs#file -- result/bzImage
zcat result/config.gz | grep -E 'SCHED_BORE|X86_64_VERSION|LTO_CLANG_THIN|HZ_1000|PREEMPT_DYNAMIC'

# Sanity-check the flake itself:
nix flake check
```

If you want to try the kernel before switching your real machine over,
build a NixOS VM with it:

```bash
nix build .#nixosConfigurations.t480-vm.config.system.build.vm
```

That `t480-vm` output isn't shipped here by default — wire it up the same
way as `nixos/example-flake.nix`, adding `virtualisation.vmVariant`, if you
want a throwaway VM to test-boot the kernel before touching real hardware.

## Setting up Cachix

```bash
# One-time, as the cache owner:
cachix authtoken <your-cachix-auth-token>      # or: cachix login
cachix create zenith-kernel                     # https://app.cachix.org

# Generate a CI write token in the Cachix dashboard for the "zenith-kernel"
# cache, then, in the GitHub repo:
#   Settings -> Secrets and variables -> Actions -> New repository secret
#   Name: CACHIX_AUTH_TOKEN
#   Value: <the write token>
```

`.github/workflows/build.yml` uses `cachix/install-nix-action` to install
Nix with flakes enabled, then `cachix/cachix-action` to authenticate against
the `zenith-kernel` cache. `cachix-action` installs a post-build hook for
the rest of the job, so the subsequent `nix build .#zenithKernel` step
automatically pushes every store path it builds — there's no separate
`cachix push` step needed.

## Consuming the cache on the T480

```bash
# One-time, on the T480 itself:
cachix use zenith-kernel
# This appends the cache's substituter URL and public key to
# /etc/nix/nix.conf. On NixOS, prefer declaring it instead (see
# nixos/example-flake.nix), so it survives `nixos-rebuild` and is
# reproducible from your own config repo rather than living only in
# mutable /etc/nix/nix.conf state.
```

Declaratively (recommended, see `nixos/example-flake.nix` in full):

```nix
nix.settings = {
  substituters = [ "https://zenith-kernel.cachix.org" ];
  trusted-public-keys = [ "zenith-kernel.cachix.org-1:<public-key-from-cachix-use>" ];
};

boot.kernelPackages = zenith.packages.${pkgs.stdenv.hostPlatform.system}.linuxPackages_zenith;
```

Then:

```bash
sudo nixos-rebuild switch --flake .#t480
```

Nix will evaluate the `zenith` input, see that the resulting kernel
derivation's store path is already signed and present on
`zenith-kernel.cachix.org`, and download the prebuilt kernel instead of
compiling it — **as long as your system's nixpkgs pin matches the one
`zenith-kernel`'s CI built against.** This is the single most common way
this kind of setup silently stops hitting the cache: use
`zenith.inputs.nixpkgs.follows = "nixpkgs";` in your system flake (already
in `nixos/example-flake.nix`) so both sides evaluate against the identical
nixpkgs revision, and re-run `nix flake update zenith` deliberately (not
automatically) so you control when that pin moves.

## Reproducibility notes

* Nothing in `kernel.nix` reads `$HOME`, `/home/<user>`, or any other local
  environment state — `modprobed.db`, the Kconfig fragment, and both
  patches are all committed to (or fetched with a pinned hash from) this
  repository, and the kernel source itself is fetched from kernel.org with
  a pinned hash.
* `flake.lock` pins the exact nixpkgs revision. Commit it, and don't run
  `nix flake update` casually on either this repo or the consuming NixOS
  flake without re-running a build to confirm the cache still hits (or
  accepting a rebuild).
* CI builds on GitHub-hosted runners, which are not huge — a full kernel +
  ThinLTO build is CPU- and memory-heavy. `build.yml` adds 8GB of swap as
  cheap insurance against an OOM during the link step; if builds are still
  too slow or fail on this, moving to a larger GitHub-hosted runner tier or
  a self-hosted runner is the next step, not turning off ThinLTO.

## Updating the kernel version

1. Bump `kernelPatchVersion` in `kernel.nix`.
2. Re-check that the BORE patch (`patches/README.md`) still applies to the
   new point release.
3. Reset the three `lib.fakeHash` placeholders and re-run the "First build"
   steps above to get fresh hashes.
4. Push — CI builds and caches it automatically.
