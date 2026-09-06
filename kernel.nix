/*
  Zenith Kernel — Linux 6.6.x, BORE scheduler, Clang/LLVM + ThinLTO,
  x86-64-v3 tuned, trimmed with a real modprobed.db from the target T480.

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

  * `GENERIC_CPU3` does not exist, in mainline or in the current
    graysky2/kernel_compiler_patch. Stock upstream Linux has NO x86-64-v2
    /v3/v4 Kconfig option at all -- that's exclusively provided by the
    out-of-tree graysky2 patch, and that patch was itself refactored to
    replace the old `GENERIC_CPU2/3/4` booleans with a single
    `CONFIG_X86_64_VERSION` int (range 1-3) symbol. We apply that patch
    and set `CONFIG_X86_64_VERSION=3` in config/zenith.config.

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

  # IMPORTANT: this must be a point release for which a matching BORE patch
  # actually exists. BORE patches are versioned per exact kernel point
  # release (e.g. firelzrd/bore-scheduler tags like "6.6.3-bore4.1.1"), or
  # per-branch via CachyOS/kernel-patches ("6.6/sched/0001-bore-cachy.patch",
  # which tracks the 6.6 branch rather than one exact point release and is
  # what this file uses by default). Before bumping kernelPatchVersion,
  # confirm the CachyOS 6.6 patch still applies (CI will fail loudly with a
  # patch-rejection error if it doesn't), or pin to a specific firelzrd tag
  # instead. See patches/README.md.
  kernelPatchVersion = "80";
  kernelVersion = "${kernelMajorMinor}.${kernelPatchVersion}";

  zenithSuffix = "zenith";
  fullVersion = "${kernelVersion}-${zenithSuffix}";

  kernelSrc = fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${kernelVersion}.tar.xz";
    # Placeholder. `nix build` will fail on the first run and print the
    # correct hash to paste in here -- see README.md "First build" section.
    hash = "sha256-bPkR0BMk9Fyd0vRM8G9VvaDs84O8SY8TKgxUl2hTEyc=";
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
  # 3. Patches
  #############################################################################

  borePatch = fetchpatch {
    url = "https://raw.githubusercontent.com/CachyOS/kernel-patches/master/6.6/sched/0001-bore-cachy.patch";
    hash = "sha256-Tz7yxrwo3kzd2J/BvX3HEQmVcMD2ILxFXvY/d46iB7I="; # fill in after first `nix build` failure
  };

  isaLevelPatch = fetchpatch {
    # graysky2/kernel_compiler_patch: adds CONFIG_X86_64_VERSION.
    url = "https://raw.githubusercontent.com/graysky2/kernel_compiler_patch/master/more-uarches-for-kernel-6.1.79-6.8-rc3.patch";
    hash = "sha256-Gjglt5BBPQmAbJohFfZ5vijkNM/MacAdwGm2NNHoAHo="; # fill in after first `nix build` failure
  };

  kernelPatches = [
    { name = "bore-scheduler"; patch = borePatch; }
    { name = "x86-64-isa-levels"; patch = isaLevelPatch; }
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

  zenithKernel = linuxManualConfig {
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

in
lib.recurseIntoAttrs (linuxPackagesFor zenithKernel)
