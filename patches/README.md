# Patches

Both patches used by this flake are fetched by `kernel.nix` via `fetchpatch`
(with `lib.fakeHash` placeholders you must fill in — see the repo README's
"First build" section). Nothing under this directory is applied automatically
by itself; it exists as documentation and as a place to vendor the patches
locally if you'd rather not depend on fetching them at build time.

## BORE scheduler

Source: https://github.com/firelzrd/bore-scheduler and its CachyOS mirror
https://github.com/CachyOS/kernel-patches

BORE patches are versioned **per exact kernel point release** upstream
(firelzrd tags things like `6.6.3-bore4.1.1`), while CachyOS additionally
maintains a per-branch patch (`6.6/sched/0001-bore-cachy.patch`) that tends
to apply across an entire `6.6.x` line without needing an exact point-release
match. `kernel.nix` defaults to the CachyOS per-branch patch for that reason.

**If you change `kernelPatchVersion` in `kernel.nix`:** re-check that the
CachyOS `6.6` patch still applies to the new point release before pushing —
CI will fail with a clear patch-rejection error if it doesn't, at which point
either wait for CachyOS to update it, or switch to pinning a specific
firelzrd tag that matches your exact `6.6.x` version.

## x86-64-v3 ISA level (`CONFIG_X86_64_VERSION`)

Source: https://github.com/graysky2/kernel_compiler_patch

This is the **only** way to get an x86-64-v3-wide kernel build — mainline
Linux has no built-in Kconfig option for x86-64 microarchitecture levels.
Older versions of this patch exposed `GENERIC_CPU2` / `GENERIC_CPU3` /
`GENERIC_CPU4` booleans; the patch was later refactored to a single
`CONFIG_X86_64_VERSION` int (range 1-3) symbol instead, which is what
`config/zenith.config` sets (`CONFIG_X86_64_VERSION=3`). If you fetch a
newer version of the patch and it reintroduces different symbol names,
update `config/zenith.config` to match — `merge_config.sh` will warn (not
fail) if a symbol from the fragment doesn't exist in the tree.
