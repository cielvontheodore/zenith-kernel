## Alternative to referencing zenith.packages.<system>.linuxPackages_zenith
## directly from every module: apply the overlay once at the top level and
## refer to it as a normal pkgs attribute everywhere else.
##
## In your top-level system flake.nix:
##
##   outputs = { self, nixpkgs, zenith, ... }: {
##     nixosConfigurations.t480 = nixpkgs.lib.nixosSystem {
##       system = "x86_64-linux";
##       modules = [
##         { nixpkgs.overlays = [ zenith.overlays.default ]; }
##         ./configuration.nix
##       ];
##     };
##   };
##
## Then, in any module (e.g. this one, imported by configuration.nix):
{ pkgs, ... }:
{
  boot.kernelPackages = pkgs.linuxPackages_zenith;
}
