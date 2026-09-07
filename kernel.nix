/*
  Zenith Kernel — Linux 6.6.3, BORE scheduler, Clang/LLVM + ThinLTO,
  x86-64-v3 tuned, trimmed with a real modprobed.db from the target T480.

  Pinned to 6.6.3, not a later 6.6.x, because that's the one point release
  in the whole 6.6 line with a BORE patch that applies cleanly -- see the
  kernelPatchVersion comment below for the full story (upstream backported
  EEVDF changes into kernel/sched/fair.c mid-series, and even firelzrd,
  BORE's own maintainer, never got a confirmed-working patch past 6.6.30).

  Design notes (see README.md for the full rationale):

  * There is no `buildLinux` attribute like `modprobed-db = ./modprobed.db;`.
    modprobed.db is consumed the way the kernel itself supports it:
    `make LSMOD=<db> localmodconfig`. That happens in `zenithConfig` below,
    a plain derivation that produces a finished `.config` file, which is
    then handed to `linuxManualConfig` (NOT `buildLinux`) as `configfile`.
    `buildLinux`'s `structuredExtraConfig` mechanism operates on individual
    Kconfig symbols and has no equivalent of `make localmodconfig`'s
    "diff against a list of actually-loaded modules" behavior, so it can't
    do this job on its own.

  * `GENERIC_CPU3` does not exist, in mainline or anywhere else, and we do
    NOT carry an out-of-tree Kconfig patch for x86-64-v3 tuning (the
    graysky2/kernel_compiler_patch URLs this repo previously used went 404
    upstream, and chasing a moving third-party mirror for something this
    build-critical is exactly the kind of hidden fragility reproducibility
    is supposed to rule out). Instead, x86-64-v3 targeting is done purely
    through `KCFLAGS`, an officially documented, in-mainline Kbuild
    override point -- see `kcflags` below and README.md for why the
    `-mno-sse`/`-mno-avx`/... flags after `-march=x86-64-v3` are not
    optional decoration.

  * `-O3` is deliberately NOT used. The kernel build system only supports
    `-O2` (CC_OPTIMIZE_FOR_PERFORMANCE) or `-Os` upstream; there is no
    supported `-O3` Kconfig path, and forcing it via KCFLAGS fights
    assumptions baked into kernel code (see README.md). We leave the
    kernel's default optimization level untouched.
*/
{ lib
, fetchurl
, fetchpatch
, linuxManualConfig
, linuxPackagesFor
, overrideCC
, llvmPackages_latest
, perl
, bc
, bison
, flex
, pahole
, python3
, rsync
, elfutils
, ncurses
, openssl
, ...
}:

let
  #############################################################################
  # 1. Kernel identity
  #############################################################################

  kernelMajorMinor = "6.6";

  # BORE is not maintained per arbitrary 6.6.x point release. Upstream
  # backported EEVDF-related changes into kernel/sched/fair.c partway
  # through the 6.6 stable series (see firelzrd/bore-scheduler issue #39:
  # the maintainer himself could not get a working patch past 6.6.30 and
  # published only an untested WIP for it). firelzrd's repo still carries
  # a commit explicitly labeled "BORE 6.6.3 (stable) patch" even while
  # their own development has moved on to far newer kernels -- 6.6.3 is
  # their designated stable reference point for the 6.6 branch, not an
  # abandoned tag. This repo pins to that exact point release for that
  # reason: it's the one version in the whole 6.6.x line with a patch that
  # actually applies cleanly, not a guess.
  kernelPatchVersion = "3";
  kernelVersion = "${kernelMajorMinor}.${kernelPatchVersion}";

  zenithSuffix = "zenith";
  fullVersion = "${kernelVersion}-${zenithSuffix}";

  kernelSrc = fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${kernelVersion}.tar.xz";
    # Placeholder. `nix build` will fail on the first run and print the
    # correct hash to paste in here -- see README.md "First build" section.
    hash = lib.fakeHash;
  };

  #############################################################################
  # 2. LLVM/Clang + ThinLTO toolchain
  #############################################################################

  llvm = llvmPackages_latest;

  # Confirmed pattern (nixpkgs LLVM wiki page + nixpkgs issue #438900):
  # override the C compiler with Clang, and make sure it uses the matching
  # LLVM bintools (lld etc.) rather than falling back to GNU binutils.
  zenithStdenv = overrideCC llvm.stdenv (llvm.stdenv.cc.override {
    bintools = llvm.bintools;
  });

  # Tells the kernel's own Makefile to use Clang/LLVM tooling end to end,
  # including the integrated assembler (LLVM_IAS=1).
  clangMakeFlags = [ "LLVM=1" "LLVM_IAS=1" "ARCH=x86_64" ];

  #############################################################################
  # 2b. x86-64-v3 targeting via KCFLAGS (no out-of-tree Kconfig patch)
  #
  # `-march=x86-64-v3` on its own would also imply AVX/AVX2/FMA. Mainline's
  # own arch/x86/Makefile unconditionally appends
  # `-mno-sse -mno-mmx -mno-sse2 -mno-3dnow -mno-avx -mno-sse4a` early in
  # the flag pipeline, specifically so the compiler never emits FPU/vector
  # register code in general kernel context -- the kernel does not save or
  # restore extended (xmm/ymm) register state on every entry/exit, so
  # vector codegen leaking into the wrong place is a correctness bug, not
  # a style question. KCFLAGS is appended *after* that line by Kbuild
  # (that's the whole point of KCFLAGS -- it's the user's final word), so
  # a bare `-march=x86-64-v3` would silently re-enable AVX and undo that
  # invariant. Re-asserting the `-mno-*` flags after `-march` restores it
  # while keeping the scalar, integer-register ISA-v3 additions we
  # actually want (BMI1/BMI2/LZCNT/MOVBE/POPCNT/CMPXCHG16B) and the
  # associated instruction-scheduling improvements.
  #
  # The T480 (8th-gen "Kaby Lake R", i5-8250U/i7-8650U-class) is well
  # above the x86-64-v3 baseline (that baseline requires AVX2/BMI1/BMI2/
  # FMA/MOVBE, all present since Haswell, 2013), so there's no
  # compatibility risk in targeting it.
  #
  # Applied via `.overrideAttrs` below rather than `extraMakeFlags`,
  # because `extraMakeFlags` list elements get word-split unquoted by the
  # generic builder -- a single list entry containing embedded spaces
  # (multiple `-mno-*` flags) would be torn into separate argv tokens and
  # make would choke on bare `-mno-sse` as an invalid command-line option.
  # A plain derivation attribute is passed through as a single intact
  # environment variable instead, which Kbuild's top-level Makefile reads
  # directly (`KBUILD_CFLAGS += $(KCFLAGS)`).
  #############################################################################

  zenithKcflags = lib.concatStringsSep " " [
    "-march=x86-64-v3"
    "-mno-sse" "-mno-sse2" "-mno-sse3" "-mno-ssse3"
    "-mno-sse4.1" "-mno-sse4.2" "-mno-sse4a"
    "-mno-avx" "-mno-avx2" "-mno-fma"
    "-mno-mmx" "-mno-3dnow"
  ];

  #############################################################################
  # 3. Patches
  #############################################################################

  borePatch = fetchpatch {
    # firelzrd's own "stable" reference patch for the 6.6 branch, pinned to
    # 6.6.3 specifically (see the kernelPatchVersion comment above for why).
    # This exact URL+version combination has previously been confirmed
    # working against `linuxManualConfig` by another user
    # (nixpkgs issue #307014) -- the hash below is theirs, carried over
    # rather than re-guessed. Since this points at the mutable `main`
    # branch, `nix build` will fail loudly with a hash mismatch (not a
    # silent wrong build) if firelzrd ever touches this file; if that
    # happens, paste in the new hash it reports.
    url = "https://raw.githubusercontent.com/firelzrd/bore-scheduler/main/patches/stable/linux-6.6-bore/0001-linux6.6.y-bore5.1.0.patch";
    hash = "sha256-iLydPGZZSkEQhSj6Ah0Xq0zf7YUPwcpyKt8t0BeHYz8=";
  };

  kernelPatches = [
    { name = "bore-scheduler"; patch = borePatch; }
  ];

  #############################################################################
  # 4. modprobed.db and the Kconfig safety-net fragment
  #############################################################################

  # Replace this with the real modprobed.db generated on the actual T480
  # (see README.md "Generating modprobed.db"). The placeholder here is
  # intentionally tiny so a fresh checkout fails safe (produces an
  # extremely trimmed kernel) rather than silently building something that
  # looks plausible but boots nothing.
  modprobedDb = ./config/modprobed.db;

  zenithConfigFragment = ./config/zenith.config;

  #############################################################################
  # 5. Generate .config: defconfig -> localmodconfig(modprobed.db) ->
  #    force-merge the safety-net fragment -> olddefconfig
  #
  #    Order matters: localmodconfig runs BEFORE the fragment merge, so that
  #    our explicit "must survive" hardware/scheduler/tuning options in
  #    config/zenith.config always win, even if modprobed.db is incomplete
  #    or stale relative to the machine.
  #############################################################################

  zenithConfig = zenithStdenv.mkDerivation {
    pname = "zenith-kernel-config";
    version = fullVersion;

    src = kernelSrc;
    patches = map (kp: kp.patch) kernelPatches;

    nativeBuildInputs = [
      perl bc bison flex pahole python3 rsync elfutils ncurses openssl
    ];

    makeFlags = clangMakeFlags;

    dontBuild = true;
    dontFixup = true;

    configurePhase = ''
      runHook preConfigure

      make $makeFlags defconfig
      make $makeFlags LSMOD=${modprobedDb} localmodconfig
      ./scripts/kconfig/merge_config.sh -m .config ${zenithConfigFragment}
      make $makeFlags olddefconfig

      runHook postConfigure
    '';

    installPhase = ''
      runHook preInstall
      cp .config "$out"
      runHook postInstall
    '';
  };

  #############################################################################
  # 6. The kernel itself, via linuxManualConfig (NOT buildLinux — we already
  #    have a fully-resolved .config from step 5, buildLinux would want to
  #    regenerate one from structuredExtraConfig instead).
  #############################################################################

  zenithKernelBase = linuxManualConfig {
    inherit lib;
    stdenv = zenithStdenv;

    version = fullVersion;
    modDirVersion = fullVersion;

    src = kernelSrc;
    configfile = zenithConfig;
    inherit kernelPatches;

    extraMakeFlags = clangMakeFlags;

    # Needed because parts of nixpkgs' kernel machinery (e.g. determining
    # whether CONFIG_MODULES is set) read the configfile at eval time.
    allowImportFromDerivation = true;
  };

  # x86-64-v3 targeting, applied as a genuine environment variable (see the
  # "2b" comment above for why this can't just be another extraMakeFlags
  # list entry).
  zenithKernel = zenithKernelBase.overrideAttrs (old: {
    KCFLAGS = (old.KCFLAGS or "") + " " + zenithKcflags;
  });

in
lib.recurseIntoAttrs (linuxPackagesFor zenithKernel)
