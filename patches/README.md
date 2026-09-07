# Patches

`kernel.nix` fetches the BORE patch below via `fetchpatch`. Nothing under
this directory is applied automatically by itself; it exists as
documentation and as a place to vendor the patch locally if you'd rather
not depend on fetching it at build time.

## BORE scheduler — why pinned to 6.6.3

Source: https://github.com/firelzrd/bore-scheduler

BORE is **not** maintained per arbitrary 6.6.x point release. Upstream
backported EEVDF-related changes into `kernel/sched/fair.c` partway through
the 6.6 stable series. firelzrd's own issue tracker
([#39](https://github.com/firelzrd/bore-scheduler/issues/39)) documents
that even the maintainer could not get a confirmed-working patch past
6.6.30, and only ever published an explicitly untested "WIP" for it:

> "I couldn't manage to build linux 6.6.30, cannot guarantee a success of
> build or boot (yet). It hasn't gone through ANY test."

firelzrd's repository still carries a commit explicitly labeled
"BORE 6.6.3 (stable) patch," even while their own development has moved on
to far newer kernel bases. That makes 6.6.3 their designated stable
reference point for the 6.6 branch — not an abandoned tag, and not a guess.
This repo pins `kernelPatchVersion` to `"3"` for exactly that reason.

**Patch used:**
`https://raw.githubusercontent.com/firelzrd/bore-scheduler/main/patches/stable/linux-6.6-bore/0001-linux6.6.y-bore5.1.0.patch`

This exact URL+content combination was previously confirmed working
against `linuxManualConfig` by another user
([nixpkgs issue #307014](https://github.com/NixOS/nixpkgs/issues/307014)) —
`kernel.nix` carries over their reported hash rather than a fresh guess.
Because this points at the mutable `main` branch rather than an immutable
tag, if firelzrd ever edits this specific file, `nix build` will fail
loudly with a hash mismatch (never a silent wrong build) — paste in the
newly reported hash if that happens.

## x86-64-v3 CPU tuning — no patch

There used to be a second patch here (graysky2/kernel_compiler_patch,
adding an x86-64 ISA-level Kconfig symbol). Its upstream URLs are no longer
reachable (404), and mainline Linux has no built-in equivalent Kconfig
option, so this repo does not carry any out-of-tree patch for CPU tuning at
all.

Instead, x86-64-v3 targeting is applied purely through `KCFLAGS`, an
officially documented, in-mainline Kbuild override point — see the "2b"
section of `kernel.nix` and the main README for the full rationale,
including why the `-mno-sse`/`-mno-avx`/`-mno-fma` flags that follow
`-march=x86-64-v3` are load-bearing and not optional decoration.
