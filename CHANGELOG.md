# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Module releases are tagged per DSM build (`dsm-<version>`), not with SemVer: a module is only
valid for the exact kernel it was built against. A fix to a published release is tagged as a
revision, `dsm-<version>-r<N>`. This file records changes to the build, the
patches and the NAS scripts.

## [Unreleased]

### Added

- `nas/README.md`: "Quick manual loading", a step-by-step guide that loads the module and
  mounts the SSD by hand, with the expected result of every check and what to do when it fails.
- Revision releases: a `dsm-<version>-r<N>` tag (N >= 2) republishes a DSM release with fixes
  instead of moving or reusing the published tag.

- `build.sh`: builds `nvme.ko` for a DSM release on the avoton platform from Synology's GPL
  kernel source and toolchain, inside a pinned Docker image, with fail-closed checks
  (input sha256, patch application, config fragment, struct module size, vermagic, imported
  symbols, reproduction of the hardware-verified sha256).
- `versions/7.2-72806.env` (hardware verified), `7.3-86009.env` and `7.4-90080.env` (built only).
- `patches/linux-3.10/0001-nvme-advertise-flush-fua.patch`.
- `config/avoton.fragment`: `CONFIG_BLK_DEV_NVME=m`, `CONFIG_MODULE_SIG=y`.
- `nas/nvme-start.sh` / `nas/nvme-stop.sh`: load and verify the module, mount the SSD, check
  that flush reaches it, and start or stop a configurable list of containers in order.
- `scripts/detect-dsm-releases.sh` and a weekly workflow that opens a pull request for each
  new DSM release with an avoton kernel.
- Release workflow publishing `nvme.ko`, its sha256 and the NAS archive per `dsm-*` tag;
  releases not verified on hardware are pre-releases.

### Fixed

Defects found while bringing the module up on a DS1517+ (DSM 7.2-72806), before the first
release:

- A module built from the published `synoconfigs/avoton` loaded but never initialised: the
  shipped kernel has `CONFIG_MODULE_SIG=y`, which changes the layout of `struct module`.
  Detected by comparing `.gnu.linkonce.this_module` sizes (`0x218` vs `0x220`).
- The 3.10 driver never advertised flush, so `fsync()` was not durable (0.24 ms per 8 KB dsync
  write instead of 2.77 ms).
