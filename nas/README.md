# On the NAS

This folder is what goes onto the NAS (it is also the content of every release archive,
together with `nvme.ko`, `nvme.ko.sha256`, `nvme.undef.txt`, `modsize.py` and `LICENSE`).

> **Read the whole page first.** This loads an unsigned, self-built kernel module on a
> NAS that holds your data. Keep a backup of anything you put on the NVMe SSD. See
> [SECURITY.md](https://github.com/htcom-code/synology-avoton-nvme/blob/main/SECURITY.md) for what can go wrong.

## Requirements

- Synology **DS1517+** (avoton) with an **M2D18** card, NVMe SSD in one M.2 slot.
- The DSM release the module was built for (the release name, e.g. `dsm-7.2-72806`).
  Check with `cat /etc.defaults/VERSION`; the start script refuses any other kernel.
- SSH access as root.

## One-time setup

```sh
sudo -i
mkdir -p /volume1/nvme-driver && cd /volume1/nvme-driver   # anywhere under /volumeN, not /root
tar -xzf synology-avoton-nvme-<dsm>.tar.gz --strip-components=1

# 1) Does the SSD show up on PCIe at all? Must print a "Class 0108" line.
lspci | grep 'Class 0108'

# 2) Manual first load (the start script does the same checks later)
python3 modsize.py $(ls /lib/modules/*.ko | head -1) nvme.ko     # sizes must be equal
insmod nvme.ko && ls -l /dev/nvme0n1*

# 3) Partition and format if the SSD is new (this ERASES it), or mount an existing ext4
#    fdisk /dev/nvme0n1   ->  one Linux partition
#    mkfs.ext4 /dev/nvme0n1p1
blkid /dev/nvme0n1p1                                             # note the UUID

# 4) Mount point outside /volumeN, immutable while unmounted
mkdir -p /mnt/nvme && chattr +i /mnt/nvme

# 5) Config
cp nvme.conf.example nvme.conf && vi nvme.conf                   # NVME_UUID, SERVICES
```

Why the mount point is outside `/volume1`: DSM unmounts the volume on shutdown and a mount
nested inside it can block that; and if the SSD is not mounted, containers would silently
write to the HDD volume instead. With `chattr +i` on an empty `/mnt/nvme`, a missing mount
makes writes fail instead of filling the system partition.

Move each container's data directory to the SSD (stop it, `rsync -aH --numeric-ids`, change
the bind mount, start it) and remove its restart policy (`docker update --restart=no <name>`)
so nothing starts before the SSD is mounted. The SSD is **not** part of any DSM storage pool:
DSM Storage Manager does not see it, does not monitor it, and DSM's SSD cache does not apply
to it.

## Every boot / every shutdown

| Script | When | What it does (stops at the first failed check) |
|---|---|---|
| `./nvme-start.sh` | after every boot | sha256, vermagic and struct-module-size checks, `insmod`, wait for the device, check the UUID, mount rw, **flush check** (dsync per write ≥ `FLUSH_MIN_MS`), then start `SERVICES` in order, waiting for each |
| `./nvme-stop.sh` | **before** every shutdown or reboot | stop `SERVICES` in reverse, confirm clean PostgreSQL shutdown, refuse while any running container still uses the mount point, then `umount` and `rmmod` |
| `./nvme-stop.sh --keep-mounted` | maintenance | stop the containers only |

Forgetting `nvme-stop.sh` before a reboot is the main operational risk. DSM's Task Scheduler
can run it as a "Shut-down" triggered task.

## After a DSM update

The module only loads on the kernel it was built for. Before updating DSM, check that a
release for the new DSM version exists (and whether it is marked verified on hardware).
After the update, `nvme-start.sh` stops at the vermagic check if the module does not match.

## Known symptoms

| Symptom | Meaning |
|---|---|
| `insmod` OK, but no `/sys/bus/pci/drivers/nvme/` and no `/dev/nvme*` | struct module size mismatch: the module was built without `MODULE_SIG=y`. `rmmod nvme` (safe). |
| `insmod: Invalid module format` | vermagic mismatch: wrong DSM release. |
| `module verification failed ... tainting kernel` in dmesg | Expected. The module is unsigned. |
| dsync about 0.2 ms | Flush does not reach the SSD. Do not run a database on it. |
| `lspci` shows no `Class 0108` | SSD not seated, or not an NVMe SSD. |
