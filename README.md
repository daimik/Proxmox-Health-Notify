# 📡 Proxmox-Health-Notify

> Gotify push notifications for **Proxmox VE** and **Proxmox Backup Server** — disk temperatures, SMART health, ZFS pool topology, storage usage and PBS task status.

![Shell](https://img.shields.io/badge/shell-bash-89e051?logo=gnu-bash&logoColor=white)
![Proxmox](https://img.shields.io/badge/Proxmox-VE%20%26%20PBS-E57000?logo=proxmox&logoColor=white)
![Gotify](https://img.shields.io/badge/notifications-Gotify-0060A0)
![License](https://img.shields.io/badge/license-MIT-green)

---

## ✨ Features

### 🖥️ Proxmox VE — `gotify_disk_status.sh`

| | Feature |
|---|---|
| 🌡️ | Disk temperatures via `hddtemp` with `smartctl` fallback (SSD/NVMe) |
| 💾 | SMART health — pass/fail per disk, auto-discovered |
| 🗄️ | ZFS pool topology — health, used/free, mirror/vdev layout with member disks |
| 📦 | PVE storage status — all datastores with usage % (local, NFS, ZFS, PBS) |
| ⚡ | Auto-escalation — priority bumps to urgent on failure or storage >90% |

### 💽 Proxmox Backup Server — `gotify_disk_status_pbs.sh`

| | Feature |
|---|---|
| 🌡️ | Disk temperatures with `smartctl` fallback |
| 💾 | SMART health per disk |
| 💽 | Disk usage — maps physical disks to mountpoints, supports LVM |
| 🗃️ | Datastore usage with % fill |
| 🗑️ | GC status — last run, duration, freed bytes |
| ✂️ | Prune jobs — schedule and retention policy |
| 🔍 | Verify jobs — schedule, re-verify interval, live % progress if running |

---

## 📱 Example Notifications

### ✅ Proxmox VE — all healthy
```
✅ home1 — Disk Status OK

🌡️ Temperatures
  🟢 sda  37°C  (INTEL SSDSC2BB080G4)
  🟢 sdb  37°C  (INTEL SSDSC2BB080G4)
  🟢 sdc  33°C  (CT1000MX500SSD1)
  🟢 sdd  33°C  (CT1000MX500SSD1)

💾 SMART Health
  sda✅ sdb✅ sdc✅ sdd✅

🗄️ ZFS Pools
  🟢 rpool  used: 7.01G  free: 67.0G
    🔷 mirror-0
      💿 …080KGN-part3  (ONLINE)
      💿 …080KGN-part3  (ONLINE)
  🟢 quick  used: 100G  free: 828G
    🔷 mirror-0
      💿 …E2A9F520  (ONLINE)
      💿 …E66E795B  (ONLINE)

📦 Storage
  🟢 PBS (pbs)        13%
  🟢 SyNAS (nfs)      40%
  🟢 quick (zfspool)  30%
  ⚫ local (dir)      disabled
```

### ✅ Proxmox Backup Server — all healthy
```
✅ pbs — PBS Status OK

🌡️ Temperatures
  🟢 sda  38°C  (KINGSTON SA400M8120G)
  🟢 sdb  35°C  (ST4000LM024-2AN17V)

💾 SMART Health
  sda✅ sdb✅

💽 Disk Usage
  🟢 sda → /                        8.9G/89G   (11%)
  🟢 sdb → /mnt/datastore/storage  496G/3.6T  (15%)

🗃️ Datastores
  🟢 storage  496G/3.6T (15%)

🔧 PBS Tasks
  🗑️ GC [storage]      ✅ OK  Mar 7  took: 8m 32s  freed: 273.347 GiB
  ✂️  Prune [storage]   🕐 sat 18:15  keep: last:2
  🔍 Verify [storage]  🕐 sat 05:00  (re-verify after: 30d)
```

### ⚠️ Action required
```
⚠️ home1 — Disk Status (ACTION REQUIRED)

🗄️ ZFS Pools
  🟠 storage  used: 890G  free: 38G
    🔷 mirror-0
      💿 …ABC123  (ONLINE)
      ❌ …DEF456  (FAULTED)
```

---

## ⚡ Priority Escalation

Gotify priority is automatically raised to **urgent (10)** when:

| Condition | Threshold |
|---|---|
| 🌡️ Disk temperature | ≥ 55°C |
| 💾 SMART health | FAILED |
| 🗄️ ZFS pool state | DEGRADED / FAULTED |
| 📦 Storage usage | ≥ 90% |
| 🔧 PBS task result | ERROR / WARN |

Normal priority is **5**. Title also changes to `⚠️ ... ACTION REQUIRED`.

---

## 📋 Requirements

| Tool | PVE | PBS |
|---|---|---|
| `hddtemp` | ✅ | ✅ |
| `smartmontools` | ✅ | ✅ |
| `curl` | ✅ | ✅ |
| `python3` | ✅ | ✅ |
| `zfsutils-linux` | ✅ | optional |
| `proxmox-backup-manager` | ❌ | ✅ |

```bash
apt install hddtemp smartmontools curl
```

---

## 🚀 Setup

**1. Clone**
```bash
git clone https://github.com/daimik/Proxmox-Health-Notify.git
cd Proxmox-Health-Notify
```

**2. Set your Gotify credentials** at the top of the script:
```bash
GOTIFY_URL="http://your-gotify-server:8080"
GOTIFY_TOKEN="your-app-token-here"
```

**3. Test**
```bash
chmod +x gotify_disk_status.sh gotify_disk_status_pbs.sh
bash gotify_disk_status.sh
bash gotify_disk_status_pbs.sh
```

**4. Schedule via cron** (daily at 07:00):
```bash
crontab -e
0 7 * * * /root/gotify_disk_status.sh        # on PVE node
0 7 * * * /root/gotify_disk_status_pbs.sh    # on PBS node
```

---

## 📁 Repository Structure

```
Proxmox-Health-Notify/
├── gotify_disk_status.sh       # Proxmox VE script
├── gotify_disk_status_pbs.sh   # Proxmox Backup Server script
└── README.md
```

---

## 📄 License

MIT
