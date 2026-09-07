# Zenith Kernel

A CI-built, Cachix-distributed custom Linux 6.6.3 kernel for the ThinkPad
T480: BORE scheduler, Clang/LLVM + ThinLTO, x86-64-v3 tuning, and a module
set trimmed against a real `modprobed.db` from the machine — with the
entire build reproducible from this repository plus `flake.lock`, on
GitHub Actions, with no dependency on any local machine state.

Pinned to **6.6.3** specifically, not a later 6.6.x — see item 4 below and
`patches/README.md`.

```text
zenith-kernel/
├── flake.nix                     # exposes zenithKernel / linuxPackages_zenith
├── flake.lock                    # generate with `nix flake lock`
├── kernel.nix                    # the actual derivation logic
├── patches/
│   └── README.md                 # BORE patch sourcing notes
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
   any patch currently reachable. Mainline Linux has *no* x86-64
   microarchitecture-level Kconfig option at all, and the out-of-tree patch
   that used to provide one
   ([graysky2/kernel_compiler_patch](https://github.com/graysky2/kernel_compiler_patch))
   currently 404s on its documented download paths. Rather than depend on a
   moving third-party mirror for something this build-critical, this repo
   carries **no Kconfig patch for CPU tuning at all**. x86-64-v3 targeting
   is applied purely through `KCFLAGS` — an officially documented,
   in-mainline Kbuild override point — in `kernel.nix`:

   ```
   KCFLAGS = -march=x86-64-v3 -mno-sse -mno-sse2 -mno-sse3 -mno-ssse3 \
             -mno-sse4.1 -mno-sse4.2 -mno-sse4a -mno-avx -mno-avx2 \
             -mno-fma -mno-mmx -mno-3dnow
   ```

   The `-mno-*` flags after `-march=x86-64-v3` are load-bearing, not
   decoration: mainline's own `arch/x86/Makefile` unconditionally appends
   `-mno-sse -mno-mmx -mno-sse2 -mno-3dnow -mno-avx -mno-sse4a` early in the
   flag pipeline, specifically so the compiler never emits FPU/vector
   register code in general kernel context (the kernel doesn't save/restore
   extended xmm/ymm state on every entry/exit, so vector codegen leaking
   into the wrong place is a correctness bug). `KCFLAGS` is appended *after*
   that line by design — it's meant to be the user's final word — so a bare
   `-march=x86-64-v3` would silently re-enable AVX and undo that invariant.
   Re-asserting the `-mno-*` flags restores it while keeping the scalar,
   integer-register ISA-v3 additions we actually want (BMI1/BMI2/LZCNT/
   MOVBE/POPCNT/CMPXCHG16B) and the associated codegen/scheduling
   improvements. The T480's 8th-gen "Kaby Lake R" CPUs are well above the
   x86-64-v3 baseline (AVX2/BMI1/BMI2/FMA/MOVBE, present since Haswell,
   2013), so there's no compatibility concern in targeting it — we're just
   never letting the compiler *use* the vector half of what it implies.

   This is applied via `.overrideAttrs` on the kernel derivation rather than
   `extraMakeFlags`, because `extraMakeFlags` list entries get word-split
   unquoted by the generic builder — a single entry containing embedded
   spaces would be torn into separate argv tokens, and `make` would choke on
   a bare `-mno-sse` as an invalid command-line flag. A derivation attribute
   is passed through as one intact environment variable instead, which
   Kbuild's top-level Makefile reads directly.

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

4. **The kernel is pinned to 6.6.3, not 6.6.80.** An earlier version of this
   repo tried to apply a BORE patch to 6.6.80 and it failed with rejected
   hunks in `kernel/sched/fair.c`. That's not a bad patch pick — it's
   because BORE genuinely isn't maintained per arbitrary late 6.6.x point
   release. Upstream backported EEVDF-related changes into
   `kernel/sched/fair.c` partway through the 6.6 stable series, and
   firelzrd (BORE's maintainer) documented in his own issue tracker that he
   never got a *confirmed*-working patch past 6.6.30 — only an explicitly
   untested WIP. His repository still carries a commit labeled
   "BORE 6.6.3 (stable) patch," even though his own development has moved
   on to far newer kernels: that's his designated stable reference point
   for the 6.6 branch, not an abandoned tag. This repo pins to it for that
   reason, and uses the exact patch URL + hash combination that another
   user already confirmed working against `linuxManualConfig`
   ([nixpkgs issue #307014](https://github.com/NixOS/nixpkgs/issues/307014))
   rather than a fresh guess. See `patches/README.md` for the full account.

## First build

The `kernelSrc` `fetchurl` call in `kernel.nix` still uses an `lib.fakeHash`
placeholder — Nix's normal, safe way of pinning a hash you don't have yet.
The BORE `fetchpatch` already has a real hash (carried over from a
previously-confirmed-working build, see `patches/README.md`), but treat it
as provisional too: if it's ever stale, Nix will fail loudly with a hash
mismatch rather than silently building the wrong thing. Fill in the kernel
hash like this:

```bash
git clone https://github.com/<you>/zenith-kernel
cd zenith-kernel

# 1. Get your real modprobed.db onto disk first (see config/modprobed.db).
cp /path/to/your/real/modprobed.db config/modprobed.db

# 2. Run the build once; it will fail on a hash mismatch for the kernel
#    tarball and print the correct hash to paste into kernel.nix.
nix build .#zenithKernel -L
# Copy the reported "got: sha256-..." value into kernelSrc's `hash = ...`
# field in kernel.nix, then re-run.

nix build .#zenithKernel -L
```

If the BORE patch hash ever mismatches too (firelzrd edited the file on
`main`), the same failure mode applies — paste in the newly reported hash.

## Testing the build locally

```bash
# Full kernelPackages set (kernel + modules + headers):
nix build .#linuxPackages_zenith.kernel -L

# Just the bare kernel image + config it was built from:
nix build .#zenithKernel -L
nix run nixpkgs#file -- result/bzImage
zcat result/config.gz | grep -E 'SCHED_BORE|LTO_CLANG_THIN|HZ_1000|PREEMPT_DYNAMIC'

# Confirm the x86-64-v3 KCFLAGS override actually made it into the build
# environment (config.gz won't show it -- it's a compiler flag, not a
# Kconfig symbol):
nix show-derivation .#zenithKernel | grep -A1 '"KCFLAGS"'

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

Bumping `kernelPatchVersion` past `3` is **not** a routine version bump for
this repo — see `patches/README.md` for why 6.6.3 is specifically pinned
(BORE's own maintainer never confirmed a working patch for anything past
6.6.30 in the 6.6 line, due to mid-series EEVDF backports into
`kernel/sched/fair.c`). If you want a later kernel with BORE:

1. Check https://github.com/firelzrd/bore-scheduler for a patch that
   actually targets your desired version (a later major line — 6.11, 6.12,
   etc. — not just a later 6.6.x — is far more likely to have one; BORE
   tracks the kernels people are actively packaging, not old LTS tails).
2. Update `kernelMajorMinor`/`kernelPatchVersion` in `kernel.nix` and the
   `borePatch` URL together — they have to refer to the same target.
3. Reset the two `hash`/`lib.fakeHash` values (kernel tarball, BORE patch)
   and re-run the "First build" steps above to get fresh hashes.
4. Push — CI builds and caches it automatically, but expect to actually
   watch the patch-apply step succeed before trusting it; don't assume a
   version bump "just works" the way `-march`/Kconfig-only changes do.
4. Push — CI builds and caches it automatically.
