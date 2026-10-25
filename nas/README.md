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

## Quick manual loading

These are the checks `nvme-start.sh` runs, done one at a time so you can see each result
before you go on. Use them the first time, or whenever you prefer not to use the scripts.

**For every step: run it and compare the output with ✅. If you see ❌ instead, stop there.**
Steps 1 to 6 change nothing on the NAS, step 7 loads the driver, and step 8 is the only one
that erases anything.

### 0. Before you start

- Enable SSH: **Control Panel → Terminal & SNMP → Enable SSH service**.
- Connect from your PC and become root (the password is your DSM admin password):
  ```sh
  ssh <your-admin-user>@<nas-ip>
  sudo -i
  ```
- Back up anything you plan to put on the SSD. DSM does not back it up for you.

### 1. Which DSM build is this?

```sh
grep -E 'productversion|buildnumber' /etc.defaults/VERSION
```

- ✅ Example `productversion="7.2"` and `buildnumber="72806"` → you need the release **dsm-7.2-72806**
  (or its newest revision, `dsm-7.2-72806-r2` etc.). Check the [release table](https://github.com/htcom-code/synology-avoton-nvme#releases):
  prefer a build marked **verified**.
- ❌ No release for your build → stop. Do not use a module built for another DSM build.

### 2. Is the SSD visible?

```sh
lspci | grep 'Class 0108'
```

- ✅ One line containing `Class 0108`.
- ❌ Nothing → the SSD is not seated, or it is not an NVMe SSD. Power off and reseat it.

### 3. Get the files onto the NAS

```sh
mkdir -p /volume1/nvme-driver && cd /volume1/nvme-driver
TAG=dsm-7.2-72806          # the release tag from step 1
VER=7.2-72806              # the DSM build, without "dsm-" and without "-rN"
curl -fLO "https://github.com/htcom-code/synology-avoton-nvme/releases/download/$TAG/synology-avoton-nvme-$VER.tar.gz"
tar -xzf "synology-avoton-nvme-$VER.tar.gz" --strip-components=1
ls
```

- ✅ The list includes `nvme.ko`, `nvme.ko.sha256`, `modsize.py`, `nvme-start.sh`, `nvme-stop.sh`.
- ❌ `curl` fails → download the `.tar.gz` on your PC from the release page, upload it with
  File Station to any shared folder, then `cp` it here and run the `tar` line.

From now on, always `cd /volume1/nvme-driver` first.

### 4. Is the file intact?

```sh
sha256sum -c nvme.ko.sha256
```

- ✅ `nvme.ko: OK`
- ❌ `FAILED` → the download is damaged or not the released file. Download it again.

### 5. Is the module built for this kernel?

```sh
mod=$(ls /lib/modules/*.ko | head -1)
want=$(grep -a -o -m1 'vermagic=[^[:cntrl:]]*' "$mod" | sed 's/ *$//')
have=$(grep -a -o -m1 'vermagic=[^[:cntrl:]]*' nvme.ko | sed 's/ *$//')
echo "kernel: $want"; echo "module: $have"
if [ "$want" = "$have" ]; then echo PASS; else echo FAIL; fi
```

- ✅ `PASS`
- ❌ `FAIL` → the module is for another DSM build. Go back to step 1.

### 6. Does the module match how DSM's kernel was really built?

```sh
python3 modsize.py "$(ls /lib/modules/*.ko | head -1)" nvme.ko
```

- ✅ Two lines, both ending in the **same** value (`0x220` on DSM 7.2-72806).
- ❌ The values differ → **do not load it.** The module would load but silently do nothing.
  Report it in an issue.

### 7. Load the driver

```sh
insmod nvme.ko
sleep 3
ls /sys/bus/pci/drivers/nvme/ | grep 0000:
ls /dev/nvme0n1*
```

- ✅ A line like `0000:07:00.0`, and `/dev/nvme0n1` (plus `/dev/nvme0n1p1` if the SSD already
  has a partition). A `module verification failed ... tainting kernel` line in `dmesg` is
  expected: the module is not signed by Synology.
- ❌ `insmod: Invalid module format` → wrong DSM build (step 5).
- ❌ No `0000:` line and no `/dev/nvme0n1` → run `rmmod nvme` (safe) and report it.

### 8. First time only: partition and format

**Skip this if the SSD already has an ext4 partition you want to keep. This ERASES the SSD.**

```sh
fdisk /dev/nvme0n1
```

Type `g` (new GPT partition table), `n` (new partition), press Enter three times (defaults:
the whole disk), then `w` (write). If fdisk asks whether to remove an existing signature,
answer `Y`.

```sh
mkfs.ext4 /dev/nvme0n1p1
```

Then, for both new and existing SSDs:

```sh
blkid /dev/nvme0n1p1
```

- ✅ The line contains `TYPE="ext4"`. Write down the `UUID="..."` value: `nvme.conf` needs it.
- ❌ No output or another `TYPE` → the partition was not created or not formatted.

### 9. First time only: the mount point

```sh
mkdir -p /mnt/nvme
chattr +i /mnt/nvme
lsattr -d /mnt/nvme
```

- ✅ The letters before `/mnt/nvme` include an `i`.

The mount point must be outside `/volume1`. The `i` (immutable) flag makes writes to the empty folder fail,
so if the SSD is ever not mounted, nothing ends up on the system partition by mistake.

### 10. Mount the SSD

```sh
mount /dev/nvme0n1p1 /mnt/nvme
grep ' /mnt/nvme ' /proc/mounts
df -h /mnt/nvme
```

- ✅ The `grep` line starts with `/dev/nvme0n1p1 /mnt/nvme ext4 rw`, and `df` shows the SSD's size.
- ❌ `mount` fails, or `ro` instead of `rw` → do not use it. Check `dmesg | tail -20`.

### 11. Does a flush really reach the SSD?

This decides whether a database on the SSD survives a power cut.

```sh
dd if=/dev/zero of=/mnt/nvme/.flushtest bs=8k count=200 oflag=dsync
rm -f /mnt/nvme/.flushtest
```

The last line reads like `1638400 bytes (1.6 MB, 1.6 MiB) copied, 0.55 s, 3.0 MB/s`.
**Multiply the seconds by 5** to get milliseconds per write (0.55 s → 2.75 ms).

- ✅ 1 ms or more per write.
- ❌ Less than 1 ms (for example 0.05 s → 0.25 ms) → flushes are not reaching the SSD.
  **Do not put a database on it.** Report it.

The SSD is ready. Now move each container's data onto it as described under
[One-time setup](#one-time-setup), and switch to the scripts below for everyday use.

### Every boot, by hand

Steps 4 to 7, 10 and 11, then start your containers yourself in the right order.

### Before every shutdown, by hand

```sh
docker stop <containers that use /mnt/nvme>     # in reverse start order
umount /mnt/nvme
rmmod nvme
```

- ✅ `umount` and `rmmod` print nothing.
- ❌ `umount: target is busy` → something still uses the SSD: `fuser -vm /mnt/nvme` shows what.

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
