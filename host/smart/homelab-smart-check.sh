#!/usr/bin/env bash
# Weekly disk-health check: reads SMART data and reports the result to the Gatus
# external endpoint 'Disk health' (see README). Never fails because Gatus is
# unreachable. Config in /etc/default/homelab-smart-check (0600): DISK_HEALTH_TOKEN,
# optional GATUS_URL, GATUS_ENDPOINT_KEY, SMART_DEVICE.
set -uo pipefail

SMART_DEVICE=${SMART_DEVICE:-/dev/sda}
GATUS_URL=${GATUS_URL:-https://gatus.beaners.club}
GATUS_ENDPOINT_KEY=${GATUS_ENDPOINT_KEY:-host_disk-health}   # <group>_<name>, lowercased, spaces -> '-'
DISK_HEALTH_TOKEN=${DISK_HEALTH_TOKEN:-}
STATE_DIR=${STATE_DIR:-/var/lib/homelab-smart}
SMART_TEST_FORCE_FAIL=${SMART_TEST_FORCE_FAIL:-}   # testing hook: report success=false error=forced-test, keep state
# shellcheck disable=SC1091
[ -f /etc/default/homelab-smart-check ] && . /etc/default/homelab-smart-check

WEAR_MIN=20     # normalized Wear_Leveling_Count below this alerts
TEMP_MAX=60     # degrees C above this alerts

# Report to Gatus; token goes to curl via stdin, not argv. Never fails the unit.
report() {
  local ok=$1 err=${2:-} i
  if [ -z "$DISK_HEALTH_TOKEN" ]; then
    echo "no DISK_HEALTH_TOKEN set; result not reported (success=$ok error=$err)" >&2
    return 0
  fi
  for i in 1 2 3 4; do
    if printf 'header = "Authorization: Bearer %s"\n' "$DISK_HEALTH_TOKEN" |
       curl -fsS -m 15 -K - -X POST -G --data-urlencode "success=$ok" --data-urlencode "error=$err" \
         -o /dev/null "$GATUS_URL/api/v1/endpoints/$GATUS_ENDPOINT_KEY/external" 2>/dev/null; then
      echo "reported to Gatus (success=$ok)"
      return 0
    fi
    [ "$i" -lt 4 ] && sleep 10
  done
  echo "Gatus unreachable; result not delivered (success=$ok error=$err)" >&2
  return 0
}

if [ -n "$SMART_TEST_FORCE_FAIL" ]; then
  echo "forced failure test (state untouched)"
  report false forced-test
  exit 0
fi

mkdir -p "$STATE_DIR"
last="$STATE_DIR/last.json"
raw=$(smartctl -H -A "$SMART_DEVICE" 2>&1)   # exit code is a bitmask; judge by the output instead

result=$(printf '%s\n' "$raw" | python3 -c '
import json, re, sys
last_path, wear_min, temp_max = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
text = sys.stdin.read()
try:
    last = json.load(open(last_path))
except Exception:
    last = {}
m = re.search(r"(?:overall-health self-assessment test result|SMART Health Status):\s*(\S+)", text)
health = m.group(1) if m else "UNKNOWN"
alias = {
    "Reallocated_Sector_Ct": "reallocated", "Current_Pending_Sector": "pending",
    "Offline_Uncorrectable": "offline_unc", "UDMA_CRC_Error_Count": "crc",
    "CRC_Error_Count": "crc", "Runtime_Bad_Block": "bad_block",
    "Uncorrectable_Error_Cnt": "uncorrectable", "Wear_Leveling_Count": "wear",
    "Temperature_Celsius": "temp", "Airflow_Temperature_Cel": "temp",
}
vals = {}
for line in text.splitlines():
    f = line.split()
    if len(f) >= 10 and f[0].isdigit() and f[1] in alias:
        key = alias[f[1]]
        if key in vals and key == "temp":
            continue
        n = re.match(r"\d+", f[9])
        if key == "wear":
            vals[key] = int(f[3])          # normalized value
            vals["wear_raw"] = int(n.group()) if n else None
        elif n:
            vals[key] = int(n.group())
errs = []
if health not in ("PASSED", "OK"):
    errs.append("smart-failed" if m else "smart-unreadable")
def chk(key, name):
    if key in vals and vals[key] > 0:
        errs.append(name + ("-increased" if vals[key] > last.get(key, 0) else "-nonzero"))
chk("reallocated", "reallocated"); chk("pending", "pending-sectors")
chk("offline_unc", "offline-uncorrectable"); chk("uncorrectable", "uncorrectable-errors")
if vals.get("crc", 0) > last.get("crc", vals.get("crc", 0)):
    errs.append("crc-errors-increased")
if "wear" in vals and vals["wear"] < wear_min:
    errs.append("wear-below-%d" % wear_min)
if vals.get("temp", 0) > temp_max:
    errs.append("temp-%d" % vals["temp"])
summary = "health=%s " % health + " ".join("%s=%s" % (k, v) for k, v in sorted(vals.items()))
print(json.dumps({"ok": not errs, "error": ",".join(errs), "summary": summary, "values": vals}))
' "$last" "$WEAR_MIN" "$TEMP_MAX")

if [ -z "$result" ]; then
  echo "SMART parsing failed" >&2
  report false smart-parse-failed
  exit 0
fi

ok=$(printf '%s' "$result" | python3 -c 'import json,sys; print("true" if json.load(sys.stdin)["ok"] else "false")')
err=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error"])')
summary=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["summary"])')
echo "$SMART_DEVICE: $summary result=$ok${err:+ error=$err}"

# Keep this run's values for the next comparison (only when SMART was readable).
if printf '%s' "$result" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["values"] else 1)'; then
  printf '%s' "$result" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["values"]))' > "$last.tmp" &&
    mv "$last.tmp" "$last"
fi

report "$ok" "$err"
exit 0
