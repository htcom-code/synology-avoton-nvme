# Contributing

Thanks for helping. The most valuable contribution is a **hardware report** for a DSM release
that is built but not yet verified — see [Hardware reports](#hardware-reports).

## Code map

| Path | What it is |
|---|---|
| `build.sh` | The only build entry point, used locally and in CI |
| `scripts/build-in-container.sh` | Runs in `debian:bookworm` (linux/amd64): patch, config, compile, facts |
| `versions/<dsm>.env` | Everything that differs per DSM release |
| `patches/linux-<series>/` | Kernel patches, one directory per kernel series |
| `config/<platform>.fragment` | Config changes on top of Synology's platform config |
| `scripts/package.sh` | Release archive |
| `scripts/detect-dsm-releases.sh` | New-release detection |
| `nas/` | Scripts and guide that run on the NAS |
| `tools/modsize.py` | struct module size of a `.ko` |

## Invariants — do not break these

1. **No module without the flush fix.** Every kernel series must either carry a patch that
   makes the driver advertise flush, or be shown to do it upstream. `EXPECT_IMPORTS` must name
   a symbol that proves it.
2. **Fail closed.** `build.sh` and the NAS scripts stop at the first failed check. Do not turn a
   check into a warning to get a build through.
3. **struct module size is checked on both sides.** The vermagic cannot detect a config
   mismatch; the size can. Keep `EXPECT_MODSIZE` in the env file and the check in `nvme-start.sh`.
4. **Inputs are pinned.** Every `versions/*.env` that is merged has `KERNEL_SHA256` and
   `TOOLCHAIN_SHA256`. `VERIFIED_SHA256` is set only after the NAS checks passed on real hardware.
5. **Synology's files are never committed.** They are downloaded from Synology's archive; this
   repository only holds URLs and hashes.
6. **Patches apply to clean source.** The kernel tree is re-extracted for every build.
7. **Nothing starts automatically on the NAS.** Containers on the SSD must not have a restart
   policy, and the scripts must never start them before the SSD is mounted and flush is checked.

## Check locally — the same as CI

```sh
docker run --rm -v "$PWD":/mnt -w /mnt koalaman/shellcheck:v0.11.0 -x build.sh scripts/*.sh nas/*.sh
./build.sh <dsm>            # for every release you touched
```

CI runs shellcheck and builds every `versions/*.env`. A build of a hardware-verified release
must reproduce `VERIFIED_SHA256` byte for byte; that is how CI proves nothing drifted.

## Hardware reports

Use the *Hardware report* issue form. It asks for the DSM build, the outputs of the checks in
[nas/README.md](nas/README.md), and the flush check result. A release is marked verified after a
report with all checks passing; the maintainer then sets `VERIFIED_*` in its env file.

## Commits, branches, pull requests

- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`fix(patch): …`, `feat(nas): …`, `chore(versions): add DSM 7.4-90080`).
- Branches: `<type>/<short-description>`, lowercase with hyphens (`fix/flush-check-parsing`).
- `main` is protected: changes go through a pull request with a green `ci-complete` check.
  Pull requests are squash-merged, so write the PR description as the commit body.
