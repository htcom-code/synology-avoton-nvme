<!--
Title in Conventional Commits form, e.g. `fix(nas): refuse to start when the UUID does not match`.
Delete sections that do not apply. PRs are squash-merged: this description becomes the commit body.
-->

## What & why

## Type of change

- [ ] `fix` — bug fix
- [ ] `feat` — new capability (scripts, checks, build)
- [ ] `chore(versions)` — add or update a DSM release
- [ ] `docs` — documentation only
- [ ] `ci` / `refactor` / `chore` — no behaviour change

## Invariants (CONTRIBUTING.md)

- [ ] Every kernel series still gets the flush fix, and `EXPECT_IMPORTS` proves it.
- [ ] No check was weakened into a warning; build and NAS scripts still fail closed.
- [ ] New or changed `versions/*.env` pin `KERNEL_SHA256` and `TOOLCHAIN_SHA256`.
- [ ] `VERIFIED_*` is set only with a hardware report (link it below).
- [ ] No Synology files committed.

## Verification

- [ ] shellcheck v0.11.0 (command in CONTRIBUTING.md)
- [ ] `./build.sh <dsm>` for every release touched (paste the sha256)
- [ ] For NAS script changes: run on a NAS, paste the output

## Related

<!-- Closes #123, hardware report #45 -->
