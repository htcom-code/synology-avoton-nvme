# Roadmap

Non-binding. The point of this project is narrow: keep a working, verified `nvme.ko` for every
DSM release a DS1517+ can run.

## Planned

- Track every new DSM release on the avoton platform automatically (weekly detection workflow)
  and verify each on hardware.
- Collect hardware reports from other SSDs, especially models with power-loss protection, and
  document their flush timings.
- Confirm or rule out other avoton models that accept an M2D18 (for example the DS1817+).
  Until someone reports, they stay unsupported.

## Not planned

| Will not do | Why |
|---|---|
| DSM Storage Manager integration (storage pool, volume, SSD cache on the NVMe) | Requires changing DSM itself, not the kernel. The SSD stays a plain mounted filesystem. |
| Loading the module or starting containers automatically at boot | A silent failure at boot would let services start on the wrong disk. Start-up stays a checked, manual step. |
| Signing the module | DSM does not enforce signatures, and signing with a private key would not tell you more than the reproducible sha256 does. |
| Other platforms (apollolake, geminilake, …) | Newer platforms have newer kernels and, often, official M2D18 NVMe support. Different problem. |
| Distributing Synology's source or toolchain | They are on Synology's public archive; this repository pins URLs and hashes. |
| RAID across NVMe drives or a write cache in front of the HDD volume | Out of scope for a driver repository. |
