#!/bin/bash
# gotify_disk_status_pbs.sh — PBS disk health notification

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ── Gotify Configuration ──────────────────────────────────────────────────────
GOTIFY_URL="https://gotify.com/"
GOTIFY_TOKEN="api_key"
GOTIFY_TITLE="PBS Disk Status"
GOTIFY_PRIORITY=5
# ─────────────────────────────────────────────────────────────────────────────

HOSTNAME=$(hostname)
MSG=""
HAS_WARNING=false

# ── Auto-discover physical disks ──────────────────────────────────────────────
DISKS=$(lsblk -dn -o NAME,TYPE 2>/dev/null \
    | awk '$2 == "disk" {print $1}' \
    | grep -vE '^(zd|dm-|md|nbd|ram|loop)' \
    | sed 's|^|/dev/|' \
    | sort)

if [ -z "$DISKS" ]; then
    echo "ERROR: No disks discovered" >&2
    exit 1
fi

# ── HDD Temperatures ─────────────────────────────────────────────────────────
MSG+="🌡️ Temperatures\n"
while IFS= read -r DEV; do
    DEVNAME=$(basename "$DEV")
    TEMP_OUT=$(hddtemp "$DEV" 2>/dev/null)
    if [ -z "$TEMP_OUT" ]; then
        TEMP_VAL=$(smartctl -A "$DEV" 2>/dev/null \
            | grep -iE "Temperature_Celsius|Airflow_Temperature|^194 " \
            | awk '{print $10}' | head -1)
        [ -z "$TEMP_VAL" ] && TEMP_VAL=$(smartctl -A "$DEV" 2>/dev/null \
            | grep -i "Temperature:" | awk '{print $2}' | head -1)
        MODEL=$(smartctl -i "$DEV" 2>/dev/null \
            | grep -iE "Device Model|Product:" | awk -F': ' '{print $2}' | xargs)
        TEMP="${TEMP_VAL}°C"
    else
        MODEL=$(echo "$TEMP_OUT" | awk -F': ' '{print $2}')
        TEMP=$(echo "$TEMP_OUT"  | awk -F': ' '{print $3}')
        TEMP_VAL=$(echo "$TEMP"  | grep -oP '\d+' | head -1)
    fi

    if [ -z "$TEMP_VAL" ] || [ "$TEMP_VAL" = "0" ]; then ICON="⚪"
    elif [ "$TEMP_VAL" -ge 55 ]; then ICON="🔴"; HAS_WARNING=true
    elif [ "$TEMP_VAL" -ge 45 ]; then ICON="🟡"
    else ICON="🟢"
    fi
    MSG+="  $ICON $DEVNAME  ${TEMP}  (${MODEL})\n"
done <<< "$DISKS"
MSG+="\n"

# ── SMART Status ──────────────────────────────────────────────────────────────
MSG+="💾 SMART Health\n"
SMART_LINE=""
while IFS= read -r DEV; do
    DEVNAME=$(basename "$DEV")
    SMART_OUT=$(smartctl -H "$DEV" 2>&1)
    if echo "$SMART_OUT" | grep -qi "passed\|OK"; then
        SMART_LINE+="${DEVNAME}✅ "
    elif echo "$SMART_OUT" | grep -qi "failed"; then
        SMART_LINE+="${DEVNAME}❌ "
        HAS_WARNING=true
    else
        SMART_LINE+="${DEVNAME}❓ "
    fi
done <<< "$DISKS"
MSG+="  $SMART_LINE\n\n"

# ── Disk Usage ────────────────────────────────────────────────────────────────
# Walk all descendants of each physical disk, find mounted filesystems
MSG+="💽 Disk Usage\n"
USAGE_FOUND=false
while IFS= read -r DEV; do
    DEVNAME=$(basename "$DEV")
    # lsblk -ln (no -r) lists all children including LVM mapper devices
    # columns: NAME, MOUNTPOINT — skip SWAP and empty mountpoints
    while IFS= read -r mp_line; do
        CHILD=$(echo "$mp_line" | awk '{print $1}')
        MP=$(echo "$mp_line"    | awk '{print $2}')
        [ -z "$MP" ] || [ "$MP" = "[SWAP]" ] && continue
        # try by mountpoint (works for LVM/mapper too)
        DF=$(df -h "$MP" 2>/dev/null | tail -1)
        USED=$(echo "$DF"    | awk '{print $3}')
        SIZE=$(echo "$DF"    | awk '{print $2}')
        PCT_VAL=$(echo "$DF" | awk '{print $5}' | tr -d '%')
        [ -z "$PCT_VAL" ] && continue
        if   [ "$PCT_VAL" -ge 90 ]; then D_ICON="🔴"; HAS_WARNING=true
        elif [ "$PCT_VAL" -ge 75 ]; then D_ICON="🟡"
        else D_ICON="🟢"
        fi
        MSG+="  $D_ICON $DEVNAME → $MP  ${USED}/${SIZE} (${PCT_VAL}%)\n"
        USAGE_FOUND=true
    done <<< "$(lsblk -ln -o NAME,MOUNTPOINT "$DEV" 2>/dev/null | awk 'NR>1 && $2!="" && $2!="[SWAP]"')"
done <<< "$DISKS"
$USAGE_FOUND || MSG+="  ⚪ No mounted filesystems found\n"
MSG+="\n"

# ── PBS Datastore Usage ───────────────────────────────────────────────────────
MSG+="🗃️ Datastores\n"
DS_FOUND=false
if [ -f /etc/proxmox-backup/datastore.cfg ]; then
    while IFS= read -r cfgline; do
        if [[ "$cfgline" =~ ^datastore:[[:space:]]*(.+) ]]; then
            DS_NAME="${BASH_REMATCH[1]}"
        elif [[ "$cfgline" =~ ^[[:space:]]*path[[:space:]]+(.+) ]]; then
            DS_PATH="${BASH_REMATCH[1]}"
            DF=$(df -h "$DS_PATH" 2>/dev/null | tail -1)
            USED=$(echo "$DF"    | awk '{print $3}')
            SIZE=$(echo "$DF"    | awk '{print $2}')
            PCT_VAL=$(echo "$DF" | awk '{print $5}' | tr -d '%')
            if [ -n "$PCT_VAL" ]; then
                if   [ "$PCT_VAL" -ge 90 ]; then DS_ICON="🔴"; HAS_WARNING=true
                elif [ "$PCT_VAL" -ge 75 ]; then DS_ICON="🟡"
                else DS_ICON="🟢"
                fi
                MSG+="  $DS_ICON $DS_NAME  ${USED}/${SIZE} (${PCT_VAL}%)\n"
                DS_FOUND=true
            fi
        fi
    done < /etc/proxmox-backup/datastore.cfg
fi
$DS_FOUND || MSG+="  ⚪ No datastores found\n"
MSG+="\n"

# ── PBS Tasks ─────────────────────────────────────────────────────────────────
# Helper: strip box-drawing chars and get clean TSV from PBS table output
strip_table() {
    grep -v '^\(┌\|├\|╞\|└\|│ store\|│ id\|│ last\)' \
    | grep '│' \
    | sed 's/│/|/g' \
    | sed 's/[[:space:]]*|[[:space:]]*/|/g' \
    | sed 's/^|//;s/|$//'
}

MSG+="🔧 PBS Tasks\n"

# ── Garbage Collection ────────────────────────────────────────────────────────
GC_RAW=$(proxmox-backup-manager garbage-collection list 2>/dev/null | strip_table)
if [ -n "$GC_RAW" ]; then
    while IFS='|' read -r store last_end duration removed pending state schedule next; do
        [ -z "$store" ] && continue
        # Trim date to "Mar 7 02:08"
        SHORT_DATE=$(echo "$last_end" | awk '{print $2,$3}' | xargs)
        case "$state" in
            OK)    G_ICON="✅" ;;
            ERROR) G_ICON="❌"; HAS_WARNING=true ;;
            *)     G_ICON="⚠️ "; HAS_WARNING=true ;;
        esac
        MSG+="  🗑️ GC [$store]  $G_ICON $state  ${SHORT_DATE}  took: ${duration}  freed: ${removed}\n"
    done <<< "$GC_RAW"
else
    MSG+="  🗑️ GC  ⚪ no record\n"
fi

# ── Prune Jobs ────────────────────────────────────────────────────────────────
PRUNE_RAW=$(proxmox-backup-manager prune-job list 2>/dev/null | strip_table)
if [ -n "$PRUNE_RAW" ]; then
    while IFS='|' read -r id disable store ns schedule maxdepth keeplast keephr keepday keepwk keepmo keepyr; do
        [ -z "$id" ] && continue
        DISABLED_TAG=""
        [ "$(echo "$disable" | tr -d ' ')" = "1" ] && DISABLED_TAG=" (disabled)"
        # Build retention summary — trim whitespace from each field first
        RETENTION=""
        keeplast=$(echo "$keeplast" | tr -d ' ')
        keephr=$(echo "$keephr"     | tr -d ' ')
        keepday=$(echo "$keepday"   | tr -d ' ')
        keepwk=$(echo "$keepwk"     | tr -d ' ')
        keepmo=$(echo "$keepmo"     | tr -d ' ')
        keepyr=$(echo "$keepyr"     | tr -d ' ')
        [ -n "$keeplast" ] && [ "$keeplast" != "0" ] && RETENTION+="last:$keeplast "
        [ -n "$keephr"   ] && [ "$keephr"   != "0" ] && RETENTION+="hourly:$keephr "
        [ -n "$keepday"  ] && [ "$keepday"  != "0" ] && RETENTION+="daily:$keepday "
        [ -n "$keepwk"   ] && [ "$keepwk"   != "0" ] && RETENTION+="weekly:$keepwk "
        [ -n "$keepmo"   ] && [ "$keepmo"   != "0" ] && RETENTION+="monthly:$keepmo "
        [ -n "$keepyr"   ] && [ "$keepyr"   != "0" ] && RETENTION+="yearly:$keepyr "
        MSG+="  ✂️  Prune [$store]$DISABLED_TAG  🕐 $schedule  keep: ${RETENTION}\n"
    done <<< "$PRUNE_RAW"
else
    MSG+="  ✂️  Prune  ⚪ no jobs configured\n"
fi

# ── Verify Jobs ───────────────────────────────────────────────────────────────
VERIFY_RAW=$(proxmox-backup-manager verify-job list 2>/dev/null | strip_table)
if [ -n "$VERIFY_RAW" ]; then
    while IFS='|' read -r id store schedule ignore_verified outdated comment; do
        [ -z "$id" ] && continue
        MSG+="  🔍 Verify [$store]  🕐 $schedule  (re-verify after: ${outdated}d)\n"
    done <<< "$VERIFY_RAW"
else
    MSG+="  🔍 Verify  ⚪ no jobs configured\n"
fi
MSG+="\n"

# ── Check if verify is currently running ─────────────────────────────────────
VERIFY_RUNNING=$(proxmox-backup-manager task list --limit 20 2>/dev/null     | grep "verificationjob" | grep "running" | head -1)
if [ -n "$VERIFY_RUNNING" ]; then
    # Extract progress from log file if available
    VERIFY_PCT=$(tail -20 /tmp/verify.log 2>/dev/null         | grep "percentage done" | tail -1         | grep -oP '\d+\.\d+(?=%)' | head -1)
    if [ -n "$VERIFY_PCT" ]; then
        MSG+="  🔄 Verify running: ${VERIFY_PCT}% complete
"
    else
        MSG+="  🔄 Verify currently running
"
    fi
fi
MSG+="
"

# ── Build title ───────────────────────────────────────────────────────────────
if $HAS_WARNING; then
    GOTIFY_PRIORITY=10
    TITLE="⚠️ ${HOSTNAME} — PBS Status (ACTION REQUIRED)"
else
    TITLE="✅ ${HOSTNAME} — PBS Status OK"
fi

# ── Send to Gotify ────────────────────────────────────────────────────────────
JSON_MSG=$(printf '%b' "$MSG" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")

HTTP_CODE=$(curl -s -o /tmp/gotify_response -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Gotify-Key: $GOTIFY_TOKEN" \
    -d "{\"title\":\"${TITLE}\",\"message\":${JSON_MSG},\"priority\":${GOTIFY_PRIORITY}}" \
    "${GOTIFY_URL}/message")

if [ "$HTTP_CODE" -eq 200 ]; then
    echo "$(date '+%F %T') Gotify notification sent — disks: $(echo "$DISKS" | wc -l), priority: $GOTIFY_PRIORITY"
else
    echo "$(date '+%F %T') ERROR: Gotify returned HTTP $HTTP_CODE" >&2
    cat /tmp/gotify_response >&2
    logger -t gotify_disk_status_pbs "Failed to notify Gotify (HTTP $HTTP_CODE) on $HOSTNAME"
    rm -f /tmp/gotify_response
    exit 1
fi

rm -f /tmp/gotify_response
exit 0
