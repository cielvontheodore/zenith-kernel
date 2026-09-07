# =============================================================================
# nix/kernel.nix
#
# Deliberately does NOT use pkgs.buildLinux / pkgs.linuxManualConfig. Those
# always compile the kernel from source inside the Nix build sandbox — which
# is exactly the "fight with building linux-tkg directly inside NixOS" this
# project exists to avoid. TKG already did the compiling, on a normal Ubuntu
# GitHub Actions runner; this file's only job is to take that already-built
# output and re-shape it into a derivation that `pkgs.linuxPackagesFor`
# accepts, so the rest of the NixOS kernel-packaging machinery (module
# rebuild support, `boot.kernelPackages`, etc.) works normally.
#
# Both `kernelTarball` and `configFile` are fetched as pinned
# fixed-output-derivation downloads (see nix/pin.nix): Nix verifies the
# sha256 of whatever it downloads against the pin, so this is exactly as
# reproducible as building from source would be — just without spending CPU
# time on the T480 (or inside the Nix sandbox at all) doing it.
# =============================================================================
{
  lib,
  stdenvNoCC,
  fetchurl,
  zstd,
  pin,
}:

let
  inherit (pin) version modDirVersion;

  kernelTarball = fetchurl {
    inherit (pin.kernelTarball) url sha256;
  };

  # A real, evaluation-time source file — this is what lets kernel modules
  # built against this kernel (e.g. via linuxPackagesFor) see a `configfile`
  # that exists *before* anything is built, same as a normal nixpkgs kernel.
  configFile = fetchurl {
    inherit (pin.configFile) url sha256;
  };
in
stdenvNoCC.mkDerivation {
  pname = "zenith-kernel";
  inherit version modDirVersion;

  src = kernelTarball;

  outputs = [
    "out"
    "dev"
  ];

  nativeBuildInputs = [ zstd ];

  dontConfigure = true;
  dontBuild = true;
  dontFixup = false;

  unpackPhase = ''
    runHook preUnpack
    mkdir -p unpacked
    tar --use-compress-program="zstd -d" -xf "$src" -C unpacked
    runHook postUnpack
  '';

  # Expected tarball layout (produced by scripts/package-tarball.sh):
  #   boot/bzImage
  #   boot/System.map
  #   boot/config                        (informational copy; configFile
  #                                        below is the one Nix actually uses)
  #   lib/modules/<modDirVersion>/...
  #   usr/src/linux-headers-<modDirVersion>/...   (best effort, may be absent)
  installPhase = ''
    runHook preInstall

    if [ ! -f unpacked/boot/bzImage ]; then
      echo "error: unpacked/boot/bzImage missing — packaging step in" >&2
      echo "scripts/package-tarball.sh produced an unexpected layout." >&2
      exit 1
    fi

    mkdir -p "$out"
    cp unpacked/boot/bzImage "$out/bzImage"
    cp unpacked/boot/System.map "$out/System.map"
    install -m444 "${configFile}" "$out/config"

    mkdir -p "$out/lib/modules"
    if [ -d "unpacked/lib/modules/${modDirVersion}" ]; then
      cp -r "unpacked/lib/modules/${modDirVersion}" "$out/lib/modules/"
    else
      echo "error: unpacked/lib/modules/${modDirVersion} missing — the" >&2
      echo "modDirVersion in nix/pin.nix doesn't match what CI actually" >&2
      echo "built. Re-run the build workflow." >&2
      exit 1
    fi

    mkdir -p "$dev/lib/modules/${modDirVersion}"
    if [ -d "unpacked/usr/src/linux-headers-${modDirVersion}" ]; then
      cp -r "unpacked/usr/src/linux-headers-${modDirVersion}" \
        "$dev/lib/modules/${modDirVersion}/build"
    else
      # Best effort only: out-of-tree module builds (DKMS-style packages)
      # won't work without this, but the kernel itself still boots fine.
      mkdir -p "$dev/lib/modules/${modDirVersion}/build"
      echo "Zenith kernel: no build headers were captured for this build;" \
        > "$dev/lib/modules/${modDirVersion}/build/README-no-headers.txt"
      echo "out-of-tree kernel modules cannot be built against it." \
        >> "$dev/lib/modules/${modDirVersion}/build/README-no-headers.txt"
    fi

    ln -sfn "$dev/lib/modules/${modDirVersion}/build" \
      "$out/lib/modules/${modDirVersion}/build"

    runHook postInstall
  '';

  passthru = {
    inherit modDirVersion;
    configfile = configFile;

    # Consumed by various NixOS/nixpkgs kernel-feature checks. Kept
    # conservative/accurate rather than copy-pasted from a stock kernel.
    features = {
      efiBootStub = true;
      needsCleanup = false;
      grsecurity = false;
      xen_dom0 = false;
      ia32Emulation = false;
    };
  };

  meta = with lib; {
    description = "Zenith TKG gaming kernel for the ThinkPad T480 (prebuilt by GitHub Actions)";
    homepage = "https://github.com/Frogging-Family/linux-tkg";
    license = licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
  };
}
