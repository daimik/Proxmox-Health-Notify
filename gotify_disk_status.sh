#!/bin/bash
# gotify_disk_status.sh — Proxmox disk & ZFS health notification
# Sends HDD temps, SMART status, ZFS pool health, and PVE storage status to Gotify

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ── Gotify Configuration ──────────────────────────────────────────────────────
GOTIFY_URL="https://gotify.com/"     # e.g. http://192.168.1.10:8080
GOTIFY_TOKEN="api_key"
GOTIFY_TITLE="Disk & ZFS Status"
GOTIFY_PRIORITY=5                               # auto-escalates to 10 on failures

# ─────────────────────────────────────────────────────────────────────────────

HOSTNAME=$(hostname)
MSG=""
HAS_WARNING=false

# ── Auto-discover physical disks (excludes partitions, CD-ROMs, loop, ZFS zvols)
discover_disks() {
    lsblk -dn -o NAME,TYPE 2>/dev/null \
        | awk '$2 == "disk" {print $1}' \
        | grep -vE '^(zd|dm-|md|nbd|ram|loop)' \
        | sed 's|^|/dev/|' \
        | sort
}

DISKS=$(discover_disks)

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
        # fallback: try smartctl for NVMe or drives hddtemp can't read
        TEMP_VAL=$(smartctl -A "$DEV" 2>/dev/null \
            | grep -iE "Temperature_Celsius|Airflow_Temperature|194 " \
            | awk '{print $10}' | head -1)
        [ -z "$TEMP_VAL" ] && TEMP_VAL=$(smartctl -A "$DEV" 2>/dev/null \
            | grep -i "Temperature:" | awk '{print $2}' | head -1)
        MODEL=$(smartctl -i "$DEV" 2>/dev/null \
            | grep -iE "Device Model|Product:" | awk -F': ' '{print $2}' | xargs)
        TEMP="${TEMP_VAL}°C"
    else
        MODEL=$(echo "$TEMP_OUT" | awk -F': ' '{print $2}')
        TEMP=$(echo "$TEMP_OUT" | awk -F': ' '{print $3}')
        TEMP_VAL=$(echo "$TEMP" | grep -oP '\d+' | head -1)
    fi

    if [ -z "$TEMP_VAL" ] || [ "$TEMP_VAL" = "0" ]; then
        ICON="⚪"
    elif [ "$TEMP_VAL" -ge 55 ]; then
        ICON="🔴"; HAS_WARNING=true
    elif [ "$TEMP_VAL" -ge 45 ]; then
        ICON="🟡"
    else
        ICON="🟢"
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

# ── ZFS Pool Status ───────────────────────────────────────────────────────────
MSG+="🗄️ ZFS Pools\n"
if command -v zpool &>/dev/null; then
    POOLS=$(zpool list -H -o name 2>/dev/null)
    if [ -n "$POOLS" ]; then
        while IFS= read -r pool; do
            STATE=$(zpool list -H -o health "$pool" 2>/dev/null)
            IOSTAT_OUT=$(zpool iostat "$pool" -v 2>/dev/null)
            ALLOC=$(echo "$IOSTAT_OUT" | awk "NR==3 && \$1==\"$pool\" {print \$2}")
            FREE=$(echo  "$IOSTAT_OUT" | awk "NR==3 && \$1==\"$pool\" {print \$3}")
            # fallback if awk misses due to spacing
            [ -z "$ALLOC" ] && ALLOC=$(zpool list -H -o alloc "$pool" 2>/dev/null)
            [ -z "$FREE"  ] && FREE=$(zpool list  -H -o free  "$pool" 2>/dev/null)

            case "$STATE" in
                ONLINE)   STATE_ICON="🟢" ;;
                DEGRADED) STATE_ICON="🟠"; HAS_WARNING=true ;;
                FAULTED)  STATE_ICON="🔴"; HAS_WARNING=true ;;
                REMOVED)  STATE_ICON="🔴"; HAS_WARNING=true ;;
                UNAVAIL)  STATE_ICON="🔴"; HAS_WARNING=true ;;
                *)        STATE_ICON="⚪" ;;
            esac
            MSG+="  $STATE_ICON $pool  used: $ALLOC  free: $FREE\n"

            # Parse vdevs and member disks from zpool status
            # Use awk to measure actual indent depth — works with tabs or spaces
            STATUS_OUT=$(zpool status "$pool" 2>/dev/null)
            # Structure: TAB+pool, TAB+2sp+vdev, TAB+4sp+disk
            # expand -t 1 converts each tab to 1 space so indent levels become:
            #   1 = pool, 3 = vdev group, 5 = member disk
            TOPO=$(echo "$STATUS_OUT" | expand -t 1 | awk '
                /config:/               { in_config=1; next }
                /errors:/               { in_config=0 }
                !in_config              { next }
                /NAME[[:space:]]+STATE/ { next }
                {
                    match($0, /^[[:space:]]*/);
                    indent = RLENGTH
                    name  = $1
                    state = $2
                    if (indent <= 1) next
                    if (indent <= 3) {
                        if (name ~ /^(mirror|raidz|stripe|spare|log|cache|replacing)/)
                            print "VDEV " name " " state
                        next
                    }
                    print "DISK " name " " state
                }
            ')

            while IFS= read -r tline; do
                TYPE=$(echo "$tline" | awk '{print $1}')
                TNAME=$(echo "$tline" | awk '{print $2}')
                TSTATE=$(echo "$tline" | awk '{print $3}')

                if [ "$TYPE" = "VDEV" ]; then
                    case "$TSTATE" in
                        ONLINE)   V_ICON="🔷" ;;
                        DEGRADED) V_ICON="🟠"; HAS_WARNING=true ;;
                        FAULTED)  V_ICON="🔴"; HAS_WARNING=true ;;
                        *)        V_ICON="⚪" ;;
                    esac
                    MSG+="    $V_ICON $TNAME\n"

                elif [ "$TYPE" = "DISK" ]; then
                    # Trim long ata-MODEL_SERIAL-partN to last segment only
                    SHORT=$(echo "$TNAME" | awk -F'_' '{print $NF}' | cut -c-16)
                    [ ${#SHORT} -lt ${#TNAME} ] && SHORT="…$SHORT"
                    case "$TSTATE" in
                        ONLINE)   D_ICON="💿" ;;
                        DEGRADED) D_ICON="⚠️ "; HAS_WARNING=true ;;
                        FAULTED)  D_ICON="❌"; HAS_WARNING=true ;;
                        REMOVED)  D_ICON="❌"; HAS_WARNING=true ;;
                        *)        D_ICON="💿" ;;
                    esac
                    MSG+="      $D_ICON $SHORT  ($TSTATE)\n"
                fi
            done <<< "$TOPO"
            MSG+="\n"
        done <<< "$POOLS"
    else
        MSG+="  ⚪ No pools found\n\n"
    fi
fi

# ── PVE Storage ───────────────────────────────────────────────────────────────
MSG+="📦 Storage\n"
if command -v pvesm &>/dev/null; then
    while IFS= read -r line; do
        [[ "$line" =~ ^Name ]] && continue
        NAME=$(echo "$line"   | awk '{print $1}')
        TYPE=$(echo "$line"   | awk '{print $2}')
        STATUS=$(echo "$line" | awk '{print $3}')
        PCT=$(echo "$line"    | awk '{print $7}')
        PCT_VAL=$(echo "$PCT" | grep -oP '\d+' | head -1)

        case "$STATUS" in
            active)   S_ICON="🟢" ;;
            disabled) S_ICON="⚫" ;;
            *)        S_ICON="🔴" ;;
        esac

        if [ "$STATUS" = "active" ] && [ -n "$PCT_VAL" ]; then
            [ "$PCT_VAL" -ge 90 ] && { S_ICON="🔴"; HAS_WARNING=true; }
            [ "$PCT_VAL" -ge 75 ] && [ "$PCT_VAL" -lt 90 ] && S_ICON="🟡"
            MSG+="  $S_ICON $NAME ($TYPE)  ${PCT_VAL}%\n"
        else
            MSG+="  $S_ICON $NAME ($TYPE)  $STATUS\n"
        fi
    done <<< "$(pvesm status 2>/dev/null)"
fi
MSG+="\n"

# ── Build title ───────────────────────────────────────────────────────────────
if $HAS_WARNING; then
    GOTIFY_PRIORITY=10
    TITLE="⚠️ ${HOSTNAME} — Disk Status (ACTION REQUIRED)"
else
    TITLE="✅ ${HOSTNAME} — Disk Status OK"
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
    echo "$(date '+%F %T') Gotify notification sent — disks found: $(echo "$DISKS" | wc -l), priority: $GOTIFY_PRIORITY"
else
    echo "$(date '+%F %T') ERROR: Gotify returned HTTP $HTTP_CODE" >&2
    cat /tmp/gotify_response >&2
    logger -t gotify_disk_status "Failed to notify Gotify (HTTP $HTTP_CODE) on $HOSTNAME"
    rm -f /tmp/gotify_response
    exit 1
fi

rm -f /tmp/gotify_response
exit 0
