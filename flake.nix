{
  description = "Zenith Kernel — CI-built, Cachix-distributed custom Linux 6.6 for the ThinkPad T480";

  inputs = {
    # Pin exactly. The consuming NixOS flake MUST use the same nixpkgs
    # revision (via `inputs.zenith.inputs.nixpkgs.follows = "nixpkgs"` or an
    # identical pin) or the kernel derivation's hash will differ and the
    # Cachix cache will miss, forcing a full local rebuild. See README.md.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = false;
      };

      # kernel.nix returns a full `linuxPackagesFor` set (kernel + dev +
      # headers + the ability to build extraModulePackages against it).
      zenithPackages = pkgs.callPackage ./kernel.nix { };
    in
    {
      packages.${system} = {
        # `nix build .#zenithKernel` — bare kernel derivation only.
        zenithKernel = zenithPackages.kernel;

        # This is what `boot.kernelPackages` should be pointed at from a
        # consuming NixOS configuration.
        linuxPackages_zenith = zenithPackages;

        default = zenithPackages.kernel;
      };

      # Lets a consumer do:
      #   nixpkgs.overlays = [ zenith.overlays.default ];
      #   boot.kernelPackages = pkgs.linuxPackages_zenith;
      # instead of reaching into the flake's `packages` output directly.
      overlays.default = final: prev: {
        linuxPackages_zenith = final.callPackage ./kernel.nix { };
      };

      devShells.${system}.default = pkgs.mkShell {
        name = "zenith-kernel-dev";
        packages = with pkgs; [ nix cachix git ];
        shellHook = ''
          echo "Zenith Kernel dev shell."
          echo "  nix build .#zenithKernel -L     # build the bare kernel"
          echo "  nix build .#linuxPackages_zenith.kernel -L"
        '';
      };
    };
}
