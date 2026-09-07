# Zenith Kernel

A BORE-scheduled, Clang/Thin-LTO, `skylake`-targeted [linux-tkg](https://github.com/Frogging-Family/linux-tkg)
gaming kernel for a ThinkPad T480 (i5-8250U / i915 / NVMe / BTRFS / NixOS /
systemd-boot), compiled on GitHub Actions and shipped to the laptop entirely
through [Cachix](https://www.cachix.org/) — the T480 itself never compiles
anything.

```
linux-tkg (pinned rev)  →  GitHub Actions (plain Ubuntu runner)  →  tar.zst
                                                                       │
                                                          Nix derivation
                                                        (repackage only,
                                                          no compiling)
                                                                       │
                                                                  Cachix
                                                                       │
                                              T480: nixos-rebuild switch
                                                  (substitute, no build)
```

## Why it's built this way

nixpkgs' kernel-building primitives (`pkgs.buildLinux` / `pkgs.linuxManualConfig`)
always compile from source inside the Nix sandbox — that's the "fighting
linux-tkg inside NixOS" this project exists to avoid. So instead:

1. **`scripts/build-tkg.sh`** runs on a normal Ubuntu GitHub Actions runner
   and does exactly what you'd do by hand on any non-NixOS box: clone
   linux-tkg, drop in `customization.cfg` + the `.myfrag` fragments, run
   `./install.sh install`.
2. **`scripts/package-tarball.sh`** tars up the resulting `bzImage` +
   `System.map` + installed modules + (best-effort) headers.
3. That tarball is published as a GitHub Release asset, and
   **`nix/pin.nix`** is rewritten with its exact URL + sha256.
4. **`nix/kernel.nix`** is a small `stdenvNoCC.mkDerivation` that
   `fetchurl`s that pinned, hash-verified tarball and re-lays it out into the
   shape `pkgs.linuxPackagesFor` expects. No kernel compiling happens inside
   Nix at any point — it's a repackage step, which is why it's fast and
   why the T480 never needs to build it.
5. CI `nix build`s that derivation and pushes the result to Cachix.

## Repo layout

```
customization.cfg              # pinned, non-interactive linux-tkg config
zenith-t480-essential.myfrag   # forces essential T480 hardware to survive
                                # modprobed-db trimming
zenith-t480-latency.myfrag     # pins preemption/tick/RCU behavior
flake.nix                      # packages.zenithKernel / .linuxPackages
nix/kernel.nix                 # wraps the prebuilt tarball for Nix
nix/pin.nix                    # CI-written: exact URLs + sha256 pins
nix/nixos-module.nix           # optional services.zenith-kernel.enable
scripts/build-tkg.sh           # runs on the GitHub Actions runner
scripts/package-tarball.sh     # tars up the build output
.github/workflows/build-kernel.yml
```

## Setup

### 1. Create a Cachix cache

```
cachix create <your-cache-name>
```

Copy its public key into `flake.nix`'s `nixConfig` block (replacing
`<your-cache-name>` / `<your-cache-public-key>` in both places), and add a
**write** auth token as the `CACHIX_AUTH_TOKEN` repo secret in GitHub
Settings → Secrets → Actions. Set `CACHIX_CACHE_NAME` in
`.github/workflows/build-kernel.yml`'s `env:` block to match.

### 2. Pin a real linux-tkg revision

`TKG_REV` in the workflow's `env:` block is a placeholder. Pick a commit SHA
from [Frogging-Family/linux-tkg](https://github.com/Frogging-Family/linux-tkg/commits/master)
and set it there — don't track `master`, or your "pinned, reproducible"
build silently stops being either.

Double check at the same time that `customization.cfg` still matches
upstream's current option names (see `docs/NOTES.md`) — linux-tkg is a
community project and does occasionally rename/retire options across
revisions.

### 3. (Recommended) Add your modprobed-db

On the T480 itself, following the [modprobed-db](https://wiki.archlinux.org/title/Modprobed-db)
workflow (`modprobed-db store` after a normal boot+play session, ideally a
few times over a week of real use), then copy the resulting
`~/.config/modprobed.db` to this repo's root as `modprobed.db`.

This file reveals exactly what hardware/software modules load on your
machine — **commit it to a private repo**, or keep it out of git entirely
and inject it as a workflow step instead (e.g. from a repo secret) if this
repo is public. If it's absent, the build still works — it just includes
the full module set instead of a trimmed one.

### 4. Run it

Push, then trigger `Build Zenith Kernel` from the Actions tab (or wait for
the weekly schedule). First run needs `nix flake lock` to have real network
access to actually resolve `nixpkgs`, which the workflow does for you; it
also commits the resulting `flake.lock` alongside `nix/pin.nix`.

## NixOS integration

```nix
{
  inputs.zenith-kernel.url = "github:<you>/zenith-kernel";

  outputs = { self, nixpkgs, zenith-kernel, ... }: {
    nixosConfigurations.t480 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        {
          nix.settings = {
            substituters = [ "https://<your-cache-name>.cachix.org" ];
            trusted-public-keys = [ "<your-cache-name>.cachix.org-1:<your-cache-public-key>" ];
          };
          boot.kernelPackages = zenith-kernel.packages.${pkgs.system}.linuxPackages;
        }
        ./configuration.nix
      ];
    };
  };
}
```

Then:

```
sudo nixos-rebuild switch --flake .#t480
```

`nix.settings.substituters` above (or the `nixConfig` already baked into
this flake, if your Nix has `accept-flake-config = true`) is what makes this
a pure substitute from Cachix instead of a local build — if `linuxPackages`
tries to compile anything locally, that's the signal something's
misconfigured (check that `nix/pin.nix` isn't still full of placeholder
`REPLACE_ME`/`fakeSha256` values, and that the Cachix cache actually has the
paths pushed).

## Rollback

NixOS's own generation mechanism already gives you a safety net: every
`nixos-rebuild switch` adds a new systemd-boot entry *alongside* the
previous ones, so if Zenith fails to boot, pick the older generation at the
boot menu (or `sudo nixos-rebuild switch --rollback` once you're back in a
working generation).

For a guaranteed always-available stock-kernel entry even on the very first
boot of a new generation, add a specialisation:

```nix
specialisation.stock-kernel.configuration = {
  boot.kernelPackages = pkgs.linuxPackages_latest;
};
```

This shows up as its own systemd-boot entry ("...-specialisation-stock-kernel")
on every generation, so you always have a one-keypress fallback that doesn't
depend on Zenith having ever booted successfully.

## Known limitations / things to verify on your first real build

I don't have a way to actually execute a multi-hour kernel build or run Nix
in the environment this project was written in, so a few things here are
"correct per current documentation, but unverified end-to-end":

- **linux-tkg's internal build-directory naming.** `scripts/build-tkg.sh`
  searches for it rather than hardcoding a path, but if it can't find it,
  that's the first thing to inspect (see `docs/NOTES.md`).
- **Out-of-tree module headers** (`dev` output) are a best-effort copy of
  the subset of the build tree that's typically sufficient — if you need to
  build a DKMS-style module against this kernel and it fails, that's the
  place to look.
- **`pkgs.linuxPackagesFor`** is the documented, supported way to wrap a
  custom kernel derivation, but it pulls in nixpkgs' *entire* linux-package
  set (extra modules like `zfs`, `virtualbox`, etc.) — most of it evaluates
  fine against any correctly-shaped kernel derivation, but if a specific
  submodule build breaks (it would show up as a `nix build` error naming
  that specific package, not as a Zenith Kernel failure), the pragmatic fix
  is `boot.kernelPackages = (zenith-kernel.packages.${system}.linuxPackages) // { <broken-thing> = null; };`
  or just referencing `.kernel` directly in your NixOS config instead of the
  whole set.

Rebuilding after fixing any of the above just means re-running the GitHub
Actions workflow — nothing here requires touching the T480.
