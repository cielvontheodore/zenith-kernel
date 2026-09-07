{
  description = "Zenith Kernel — a BORE/Clang/ThinLTO linux-tkg gaming kernel for the ThinkPad T480, built by GitHub Actions and distributed via Cachix";

  inputs = {
    # Pinned, not "unstable" bare — flake.lock is what makes this an actual
    # pin rather than a moving target. Run `nix flake lock` once after
    # cloning (needs network) to generate flake.lock; CI does this itself.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  # Lets `nixos-rebuild switch` (and plain `nix build` against this flake)
  # substitute straight from Cachix without the user having to hand-edit
  # nix.conf. Fill in <your-cache-name> / <your-cache-public-key> after you
  # create the Cachix cache — see README.md "Setup" step 1.
  nixConfig = {
    extra-substituters = [ "https://<your-cache-name>.cachix.org" ];
    extra-trusted-public-keys = [ "<your-cache-name>.cachix.org-1:<your-cache-public-key>" ];
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux"; # the only target: the T480 itself.
      pkgs = import nixpkgs { inherit system; };
      pin = import ./nix/pin.nix { inherit (pkgs) lib; };

      zenithKernel = pkgs.callPackage ./nix/kernel.nix { inherit pin; };
      linuxPackages = pkgs.linuxPackagesFor zenithKernel;
    in
    {
      packages.${system} = {
        zenithKernel = zenithKernel;
        inherit linuxPackages;
        default = zenithKernel;
      };

      overlays.default = final: prev: {
        zenithKernel = final.callPackage ./nix/kernel.nix { inherit pin; };
        zenithLinuxPackages = final.linuxPackagesFor final.zenithKernel;
      };

      nixosModules.default = import ./nix/nixos-module.nix;

      # `nix flake check` sanity check: does the derivation even evaluate
      # (not build — building needs the real pin, not the placeholder one)
      # without throwing? Catches "someone broke kernel.nix" before CI spends
      # an hour compiling anything.
      checks.${system}.evaluates = pkgs.runCommand "zenith-kernel-evaluates" { } ''
        echo ${zenithKernel.drvPath} > $out
      '';
    };
}
