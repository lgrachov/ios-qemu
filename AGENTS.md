# Working on ios-qemu

- Goal (since 2026-10-22): iOS 16.7 userland in QEMU (hvf) on an Apple
  Silicon Mac. The Redmi Note 10 Pro (`sweet`) is no longer a target; its code
  (`shim/`, Qualcomm drivers in the patches, phone tools) stays but is not
  maintained. Do not run fastboot or other device steps unless the user asks.
- Read `NOTES.md` before starting; it contains the current state, local
  artifact locations, the roadmap and the next concrete action.
- The user switches agents frequently. Update the active handoff in `NOTES.md`
  after each milestone and before stopping. Record commits, CI run IDs, exact
  build/boot results and unfinished work. Distinguish observations from guesses.
- Commit completed changes. Use `gh` for GitHub Actions kernel builds and logs
  (the fork `lgrachov/ios-sweet`; pushes to `xnu/patches/**` build).
- `research/iosroot/disk.img` is the working guest disk: make an APFS clone
  (`cp -c`) before changes that are hard to undo.
- Keep downloaded Apple artifacts (IPSWs, root images, shared caches) out of git.
