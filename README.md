# 📡 Proxmox-Health-Notify

> Push notifications for **Proxmox VE** and **Proxmox Backup Server** via [Gotify](https://gotify.net/) — disk temperatures, SMART health, ZFS pool topology, storage usage, and PBS task status.

---

## ✨ Features

### 🖥️ Proxmox VE (`gotify_disk_status.sh`)
- 🌡️ **Disk temperatures** — via `hddtemp` with `smartctl` fallback for SSDs/NVMe
- 💾 **SMART health** — pass/fail per disk with auto-discovery
- 🗄️ **ZFS pool topology** — pool health, used/free, mirror/vdev layout with member disks
- 📦 **PVE storage status** — all datastores with usage % (local, NFS, ZFS, PBS)
- 🔴 **Auto-escalation** — Gotify priority bumps to urgent on SMART failure, ZFS degraded, or storage >90%

### 💽 Proxmox Backup Server (`gotify_disk_status_pbs.sh`)
- 🌡️ **Disk temperatures** with SMART fallback
- 💾 **SMART health** per disk
- 💽 **Disk usage** — maps physical disks to mountpoints, supports LVM (e.g. `pbs-root`)
- 🗃️ **Datastore usage** — parsed from `/etc/proxmox-backup/datastore.cfg`
- 🔧 **PBS task status**:
  - 🗑️ GC — last run time, duration, freed bytes
  - ✂️ Prune — schedule and retention policy
  - 🔍 Verify — schedule, re-verify interval, live progress if running

---

## 📋 Requirements

| Tool | PVE | PBS |
|------|-----|-----|
| `hddtemp` | ✅ | ✅ |
| `smartmontools` | ✅ | ✅ |
| `curl` | ✅ | ✅ |
| `python3` | ✅ | ✅ |
| `zfsutils-linux` | ✅ | optional |
| `proxmox-backup-manager` | ❌ | ✅ |

Install missing tools:
```bash
apt install hddtemp smartmontools curl
```

---

## 🚀 Setup

**1. Clone the repo**
```bash
git clone https://github.com/daimik/proxmox-gotify-notify.git
cd proxmox-gotify-notify
```

**2. Configure Gotify credentials** at the top of the script:
```bash
GOTIFY_URL="http://your-gotify-server:8080"
GOTIFY_TOKEN="your-app-token-here"
```

**3. Make executable and test**
```bash
chmod +x gotify_disk_status.sh
bash gotify_disk_status.sh
```

**4. Add to cron** (daily at 07:00):
```bash
crontab -e
0 7 * * * /root/gotify_disk_status.sh
```

---

## 📱 Example Notifications

### ✅ All healthy
```
✅ home1 — Disk Status OK

🌡️ Temperatures
  🟢 sda  37°C  (INTEL SSDSC2BB080G4)
  🟢 sdb  37°C  (INTEL SSDSC2BB080G4)
  🟢 sdc  33°C  (CT1000MX500SSD1)

💾 SMART Health
  sda✅ sdb✅ sdc✅

🗄️ ZFS Pools
  🟢 rpool  used: 7.01G  free: 67.0G
    🔷 mirror-0
      💿 …080KGN-part3  (ONLINE)
      💿 …080KGN-part3  (ONLINE)

📦 Storage
  🟢 PBS (pbs)       13%
  🟢 SyNAS (nfs)     40%
  🟢 quick (zfspool) 30%
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

## 🔧 Priority Escalation

| Condition | Priority |
|-----------|----------|
| All healthy | 5 (normal) |
| Disk temp ≥ 55°C | 10 (urgent) |
| SMART failed | 10 (urgent) |
| ZFS DEGRADED / FAULTED | 10 (urgent) |
| Storage ≥ 90% | 10 (urgent) |
| PBS task ERROR | 10 (urgent) |

---

## 📁 Files

```
proxmox-gotify-notify/
├── gotify_disk_status.sh       # Proxmox VE
├── gotify_disk_status_pbs.sh   # Proxmox Backup Server
└── README.md
```

---

## 📄 License

MIT
