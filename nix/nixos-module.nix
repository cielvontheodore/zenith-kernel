# =============================================================================
# nix/nixos-module.nix
#
# Purely a convenience wrapper — `boot.kernelPackages =
# inputs.zenith-kernel.packages.${system}.linuxPackages;` (from the task
# spec) works perfectly well on its own without importing this module at
# all. This module exists only for people who'd rather flip
# `services.zenith-kernel.enable = true;` and not repeat the
# `${system}`/flake-input plumbing in every config.
#
# Rollback: NixOS's own generation rollback already covers "Zenith fails to
# boot" — every `nixos-rebuild switch` creates a new bootloader entry
# alongside the old one(s), so if Zenith fails to boot you select the
# previous generation (which still has the stock kernel) at the
# systemd-boot menu, or run `sudo nixos-rebuild switch --rollback` once
# booted into a working generation. This module doesn't (and can't, from in
# here) change that mechanism — it's a systemd-boot/NixOS-generations
# feature, not something a kernel package needs to opt into.
#
# For a *guaranteed* one-keypress fallback entry even before you've booted
# Zenith once, add a specialisation to your own system config (see
# README.md's "Rollback" section for the exact snippet) — that's a top-level
# nixosSystem construct this module intentionally doesn't try to inject for
# you, since it depends on the rest of your config.
# =============================================================================
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.zenith-kernel;
in
{
  options.services.zenith-kernel = {
    enable = lib.mkEnableOption "the Zenith TKG gaming kernel as boot.kernelPackages";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        The `linuxPackages`-shaped attribute set to use, i.e. the flake's
        `packages.${system}.linuxPackages` output. Left as a required option
        (no default) so this module never silently pulls in a kernel from
        somewhere unexpected.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelPackages = cfg.package;
  };
}
