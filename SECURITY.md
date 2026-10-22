# Security policy

## Reporting

Report privately through
[GitHub's private vulnerability reporting](https://github.com/htcom-code/synology-avoton-nvme/security/advisories/new),
or by email to htjulia1@gmail.com. Please do not open a public issue for a vulnerability.
Expect a first answer within a week.

## What this software controls

This project ships a **kernel module**. Once loaded with `insmod`, `nvme.ko` runs in kernel
mode with full control of the NAS, outside any DSM permission model. It is unsigned (DSM does
not enforce signatures and marks the kernel as tainted). The NAS scripts run as root and mount,
unmount and start or stop containers.

What can go wrong, and what guards against it:

| Risk | Guard |
|---|---|
| A tampered or substituted module | Reproducible builds in public CI; the release sha256 must equal `VERIFIED_SHA256` in `versions/<dsm>.env`; `nvme-start.sh` checks the sha256 before loading |
| Tampered build inputs | Synology's kernel and toolchain archives are pinned by sha256 |
| A module for the wrong kernel | vermagic and struct module size checked at build time and again on the NAS before `insmod` |
| Data loss from non-durable writes | Flush patch, `EXPECT_IMPORTS` check, and a dsync timing check before any container starts |
| Writing to the wrong disk | `nvme-start.sh` mounts only the partition whose UUID is in `nvme.conf` |
| Containers starting on an unmounted path | Mount point outside `/volumeN`, made immutable while unmounted; containers have no restart policy |

## In scope

- Anything that makes the published `nvme.ko` differ from what the repository builds.
- Patches or config that weaken durability (for example losing the flush fix) or crash the kernel.
- Script behaviour that can destroy data: mounting, writing or unmounting the wrong device,
  starting services before the checks pass, or bypassing a check.
- Supply-chain issues in the workflows (injection, over-broad permissions, unpinned inputs).

## Out of scope

- Vulnerabilities in DSM, Synology's kernel or the upstream 2013 NVMe driver itself, unless this
  project makes them worse. Report those to Synology or upstream.
- Running the module on a DSM build or model it was not built and verified for.
- Hardware faults, SSD firmware bugs, and data loss on an SSD without a backup.
- Power loss on SSDs without power-loss protection beyond what flush semantics guarantee.

## Supported versions

Only the newest build of each `dsm-*` release, and only releases marked hardware-verified, are
supported. Pre-releases ("built only") are provided for testing.
