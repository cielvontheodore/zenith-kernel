## Example flake.nix for the T480's NixOS configuration.
## Copy the relevant pieces into your own system flake — this file is not
## consumed by zenith-kernel itself.
{
  description = "T480 NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    zenith.url = "github:<me>/zenith-kernel";
    # CRITICAL for cache hits: make the kernel flake evaluate against the
    # exact same nixpkgs your system uses. If these diverge, the kernel
    # derivation's hash changes and Cachix will miss, silently falling back
    # to a full local rebuild.
    zenith.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, zenith, ... }: {
    nixosConfigurations.t480 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        ./hardware-configuration.nix

        ({ pkgs, ... }: {
          # 1. Trust the Cachix binary cache so Nix fetches the prebuilt
          #    kernel instead of compiling it locally.
          nix.settings = {
            substituters = [ "https://zenith-kernel.cachix.org" ];
            trusted-public-keys = [
              # Get the real value with: cachix use zenith-kernel
              # (it prints the public key it added to nix.conf)
              "zenith-kernel.cachix.org-1:REPLACE_WITH_REAL_PUBLIC_KEY="
            ];
          };

          # 2. Point boot.kernelPackages at the flake output directly.
          boot.kernelPackages = zenith.packages.${pkgs.stdenv.hostPlatform.system}.linuxPackages_zenith;
        })
      ];
    };
  };
}
