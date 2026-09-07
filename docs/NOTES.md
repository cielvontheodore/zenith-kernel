# Maintenance notes

## Re-syncing `customization.cfg` with upstream linux-tkg

linux-tkg's option names are not a stable API. Before bumping `TKG_REV` to a
newer commit:

1. Diff the pinned rev's `customization.cfg` against the new one:
   ```
   git -C /path/to/linux-tkg diff <old-rev> <new-rev> -- customization.cfg
   ```
2. For every renamed/removed/added `_variable`, mirror the change in this
   repo's `customization.cfg`, re-reading the surrounding comment in
   upstream's file so you're not carrying forward a stale rationale.
3. Re-check `_cpusched="bore"` and `_compiler="llvm"` are still valid values
   — these are the two options most likely to gain/lose choices across
   kernel-version support boundaries.
4. Re-check the two `.myfrag` files still reference real `CONFIG_*` symbols
   for whatever kernel version you're pinning — Kconfig symbols do get
   renamed/split occasionally (e.g. preemption model symbols have moved
   around across kernel versions in the past).

## If `scripts/build-tkg.sh` can't find the build directory

The script searches for a directory (up to 2 levels deep inside the
linux-tkg checkout) containing a kernel `Makefile` and a `.config` with our
`CONFIG_LOCALVERSION="-zenith-t480"` marker. If that search comes up empty:

1. Run the clone + `./install.sh install` steps manually (or via `act`/a
   throwaway VM) and inspect the linux-tkg checkout's contents afterward —
   `find . -maxdepth 3 -name .config` is the fastest way to see what
   directory it actually used.
2. Update the `find`/`grep` logic in `scripts/build-tkg.sh` to match.
3. Consider pinning to a specific linux-tkg *tag* instead of an arbitrary
   commit once you've confirmed the layout, so this doesn't shift under you
   again without you choosing to move the pin.

## Bumping the kernel version

1. Update `ZENITH_KERNEL_VERSION` in
   `.github/workflows/build-kernel.yml`.
2. Confirm linux-tkg actually supports that version/tag for your chosen
   `_cpusched` (`bore`) — check the table in linux-tkg's README, it varies
   per kernel branch.
3. Re-check the `_lto_mode`/LTO caveats and the `.myfrag` Kconfig symbols as
   above — both are exactly the kind of thing that silently stops applying
   across a major kernel version bump (a fragment line setting a symbol that
   no longer exists is usually silently ignored, not an error, so it's worth
   deliberately re-verifying rather than assuming it still works).
