# synology-avoton-nvme

[![ci](https://github.com/htcom-code/synology-avoton-nvme/actions/workflows/ci.yml/badge.svg)](https://github.com/htcom-code/synology-avoton-nvme/actions/workflows/ci.yml)
[![License: GPL-2.0-only](https://img.shields.io/badge/license-GPL--2.0--only-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/htcom-code/synology-avoton-nvme?include_prereleases&sort=date)](https://github.com/htcom-code/synology-avoton-nvme/releases)

An NVMe driver (`nvme.ko`) for the **Synology DS1517+ with an M2D18 card**, built from
Synology's own GPL kernel source for every DSM release on the **avoton** platform, plus the
scripts that mount the SSD and start your containers on it.

Synology lists the M2D18 as SATA-only for the DS1517+, and DSM's avoton kernel is built
without an NVMe driver. The card's NVMe lanes work anyway: with this module an NVMe SSD in
the M2D18 shows up as `/dev/nvme0n1` and can be mounted as a plain ext4 volume. On the
author's NAS that moved PostgreSQL's commit latency (`pg_test_fsync`, fdatasync) from
**81.9 ms on the HDD RAID6 to 0.87 ms**.

> [!WARNING]
> This loads an **unsigned, self-built kernel module** on a NAS that holds your data.
> Synology does not support it. DSM's Storage Manager does not see the SSD, does not monitor
> it, and does not include it in any storage pool or backup. Use only releases marked
> verified for the exact DSM build you run, and keep backups. Read [SECURITY.md](SECURITY.md).

Not affiliated with Synology Inc. "Synology", "DSM" and model names are trademarks of their owners.

## Contents

- [Releases](#releases)
- [Quick start](#quick-start)
- [What this works around](#what-this-works-around)
- [Building it yourself](#building-it-yourself)
- [Adding a DSM release](#adding-a-dsm-release)
- [Repository layout](#repository-layout)
- [Contributing](#contributing) · [Security](#security) · [License](#license)

## Releases

One GitHub release per DSM build, tagged `dsm-<version>`. Each holds `nvme.ko`, its sha256,
and an archive with the NAS scripts. The source of truth is `versions/<dsm>.env`.

| DSM | Kernel | Hardware verified | Notes |
|---|---|---|---|
| 7.2-72806 | 3.10.108 | ✅ 2026-10-22 | DS1517+ + M2D18, Samsung SM961-class SSD |
| 7.3-86009 | 3.10.108 | ❌ built only | module is byte-identical to the verified 7.2-72806 one; still needs a hardware report |
| 7.4-90080 | 3.10.108 | ❌ built only | needs a hardware report |

"Built only" releases are marked as pre-releases. If you run one of those DSM builds, a
[hardware report](https://github.com/htcom-code/synology-avoton-nvme/issues/new?template=hardware_report.yml)
is the most useful contribution you can make.

Builds are reproducible: CI rebuilds every release and fails if the result differs from the
hardware-verified sha256, so you can check that a download is the module that was tested.

## Quick start

On the NAS, as root:

```sh
cat /etc.defaults/VERSION                      # productversion / buildnumber → pick the release
lspci | grep 'Class 0108'                      # the NVMe SSD must be visible on PCIe
mkdir -p /volume1/nvme-driver && cd /volume1/nvme-driver
# download synology-avoton-nvme-<dsm>.tar.gz from the release page, then:
tar -xzf synology-avoton-nvme-<dsm>.tar.gz --strip-components=1
```

Then follow [nas/README.md](nas/README.md): first load, formatting, mount point, config, and
the `nvme-start.sh` / `nvme-stop.sh` scripts you run after every boot and before every
shutdown. Nothing loads automatically.

## What this works around

Three things stand between the hardware and a usable NVMe volume. All three were found on a
DS1517+ running DSM 7.2-72806 (kernel 3.10.108):

1. **The driver is not built.** `synoconfigs/avoton` in Synology's kernel source has
   `# CONFIG_BLK_DEV_NVME is not set`. The driver source (`drivers/block/nvme-core.c`, the
   2013 v0.8 driver) is there, so building it as a module is enough to get `/dev/nvme0n1`.
   The M2D18's PCIe switch (`111d:806e`) exposes the NVMe slots as ordinary downstream ports;
   the SSD enumerates as class `0x010802` without any change.
2. **The published config is not the shipped config.** `synoconfigs/avoton` says
   `CONFIG_MODULE_SIG` is off, but the running kernel has it on (dmesg prints
   `module verification failed`, which only exists under that option). It adds a field to
   `struct module`. Built from the published config, the module loads, but the kernel reads
   its `init()` from the wrong offset and **silently does nothing**. The vermagic is
   identical either way, so only the struct size (`0x220` vs `0x218`) tells them apart.
   `config/avoton.fragment` turns the option on; the build and the NAS script both check
   the size.
3. **The driver never enables flush.** The 3.10 driver handles `REQ_FLUSH`/`REQ_FUA` but
   never calls `blk_queue_flush()`, so the block layer drops every flush before the driver
   sees it and `fsync()` returns once data reaches the SSD's volatile cache. Measured: an
   8 KB `dd oflag=dsync` write took **0.24 ms** (not durable) without the fix and **2.77 ms**
   with it. A database on the unpatched driver can lose committed transactions on power
   loss. `patches/linux-3.10/0001-nvme-advertise-flush-fua.patch` is a one-line fix; the
   build checks that the module imports `blk_queue_flush`, and `nvme-start.sh` refuses to
   start containers if a dsync write is suspiciously fast.

## Building it yourself

```sh
./build.sh                 # newest release in versions/
./build.sh 7.2-72806       # a specific one
scripts/package.sh 7.2-72806   # the release archive
```

Needs Docker (linux/amd64; on Apple Silicon it runs under emulation) and about 200 MB of
downloads per DSM release from Synology's archive, cached under `synology/` and checked
against the sha256 pinned in `versions/<dsm>.env`. The kernel tree is re-extracted on every
run so the patches always apply to clean source. The build stops with `FAIL` unless:

| Check | Why |
|---|---|
| the downloads match the pinned sha256 | the inputs are what was tested |
| every patch applies | a new kernel may already contain the fix or have moved the code |
| every config fragment line survives `olddefconfig` | a dependency can silently drop an option |
| struct module size = `EXPECT_MODSIZE` | catches the `MODULE_SIG` mismatch (item 2 above) |
| vermagic = `EXPECT_VERMAGIC` | otherwise `insmod` refuses the module |
| imports every symbol in `EXPECT_IMPORTS` | proves the patches are compiled in (item 3) |
| sha256 = `VERIFIED_SHA256`, when set | the build reproduces the module that was tested on hardware |

Output: `out/<dsm>/nvme.ko`, `nvme.ko.sha256`, `nvme.undef.txt`, `inputs.env`, `build.log`.

## Adding a DSM release

A scheduled workflow (`.github/workflows/detect-dsm.yml`) checks Synology's archive every week,
writes `versions/<dsm>.env` for each new release that ships an avoton kernel, builds it and
opens a pull request. By hand it is the same:

1. `scripts/detect-dsm-releases.sh` — writes the new `versions/*.env`.
2. `./build.sh <dsm>` — then copy `KERNEL_SHA256` / `TOOLCHAIN_SHA256` from `out/<dsm>/inputs.env`
   into the env file.
3. If the kernel series changed, create `patches/linux-<series>/`. Check whether the new
   driver already enables flush (`blk_queue_flush` or `blk_queue_write_cache`); port the patch
   only if it does not, and set `EXPECT_IMPORTS` to the symbol that proves it.
4. On a NAS running that release, confirm `EXPECT_VERMAGIC` and `EXPECT_MODSIZE`:
   ```sh
   grep -a -o -m1 'vermagic=[^[:cntrl:]]*' $(ls /lib/modules/*.ko | head -1)
   python3 modsize.py $(ls /lib/modules/*.ko | head -1)
   ```
5. After the module passes the checks in [nas/README.md](nas/README.md), including the flush
   check, set `VERIFIED_SHA256`, `VERIFIED_ON` and `VERIFIED_NOTE`, then tag `dsm-<version>`.

## Repository layout

| Path | Content |
|---|---|
| `build.sh` | Build entry point (local and CI) |
| `versions/<dsm>.env` | Per-release inputs: Synology URLs and sha256, kernel series, expected vermagic / struct module size / imported symbols, hardware verification |
| `patches/linux-<series>/*.patch` | Kernel patches for that kernel series, applied in name order |
| `config/<platform>.fragment` | Config lines applied on top of `synoconfigs/<platform>` |
| `scripts/build-in-container.sh` | Runs inside Docker: patch, configure, compile, collect facts |
| `scripts/package.sh` | Builds the release archive |
| `scripts/detect-dsm-releases.sh` | Finds new DSM releases on Synology's archive |
| `tools/modsize.py` | Reads the struct module size from a `.ko` |
| `nas/` | `nvme-start.sh`, `nvme-stop.sh`, `nvme.conf.example` and the NAS guide |
| `synology/`, `out/` | Downloads and build output (git-ignored) |

## Contributing

Hardware reports for unverified DSM releases matter most. See [CONTRIBUTING.md](CONTRIBUTING.md)
and [ROADMAP.md](ROADMAP.md) (including what this project will not do).

## Security

See [SECURITY.md](SECURITY.md). Report vulnerabilities privately, not in public issues.

## License

GPL-2.0-only, the license of the Linux kernel this module is built from. See [LICENSE](LICENSE).
Copyright (C) 2026 htjulia <htjulia1@gmail.com>.

The kernel source and toolchain are not redistributed here; the build downloads them from
Synology's public GPL archive. The corresponding source of every released `nvme.ko` is that
archive (URL and sha256 in `versions/<dsm>.env`) plus the patches and config in this repository.
