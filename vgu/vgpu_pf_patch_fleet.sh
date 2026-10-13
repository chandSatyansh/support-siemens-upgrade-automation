#!/usr/bin/env bash
# vgpu_pf_patch_fleet.sh
# Fleet version of the Aug-2026 post-upgrade step "Patch vGPU pf9-ostackhost-neutron Config".
# For every host in the region:
#   1. GET resmgr role pf9-ostackhost-neutron, skip if no mdev_config or already PF-aware
#   2. Gate: resmgr role_status == ok AND pf9-ostackhost package on host is 2026.8.x
#   3. SSH to host, enumerate NVIDIA PFs (skip VFs, skip vfio-pci passthrough GPUs),
#      map every defined mdev back to its PF (VF -> physfn, or PF itself on Turing)
#   4. Profile per PF = profile of its existing mdevs; empty PF inherits the profile only
#      if the host has exactly one configured profile; anything else -> UNRESOLVED (manual)
#   5. Rebuild mdev_config [{name,max_instances,pf_address}], PUT (only with --apply), re-GET verify
#
# Usage:
#   export AUTH_TOKEN=$(openstack token issue -f value -c id)   # admin, region-scoped
#   ./vgpu_pf_patch_fleet.sh <du-fqdn> [--apply] [--host <host-uuid>] [--ssh-user pf9] [--orig ./ubuntu22_vgpu_configure.sh]
#   --orig: delegate the PUT to the Confluence script (single-profile hosts only)
#
# Requires: curl, jq, passwordless ssh to hypervisors (hostname from resmgr must resolve).
set -euo pipefail

FQDN="${1:?du fqdn required}"; shift
APPLY=0; ONLY_HOST=""; ORIG=""; SSH_USER="${SSH_USER:-pf9}"; TARGET_VER="${TARGET_VER:-2026.8}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --host) ONLY_HOST="$2"; shift ;;
    --ssh-user) SSH_USER="$2"; shift ;;
    --orig) ORIG="$2"; shift ;;
    *) echo "unknown arg $1"; exit 1 ;;
  esac; shift
done
: "${AUTH_TOKEN:?export AUTH_TOKEN first}"

API="https://${FQDN}/resmgr/v1"
ROLE="pf9-ostackhost-neutron"
TS=$(date +%Y%m%d-%H%M%S)
OUT="vgpu_pf_patch_${FQDN}_${TS}"; mkdir -p "$OUT"
REPORT="$OUT/report.csv"
echo "host_id,hostname,status,detail" > "$REPORT"

api() { curl -sk -H "X-Auth-Token: $AUTH_TOKEN" -H "Content-Type: application/json" "$@"; }
log() { echo "[$(date +%H:%M:%S)] $*"; }
rep() { local d="${4//\"/\"\"}"; echo "$1,$2,$3,\"$d\"" >> "$REPORT"; log "$2: $3 $4"; }

read -r -d '' REMOTE <<'EOF' || true
for d in /sys/bus/pci/devices/*; do
  [ "$(cat $d/vendor 2>/dev/null)" = "0x10de" ] || continue
  case "$(cat $d/class)" in 0x030000|0x030200) ;; *) continue ;; esac
  [ -e "$d/physfn" ] && continue
  drv=none; [ -e "$d/driver" ] && drv=$(basename "$(readlink -f $d/driver)")
  echo "PF $(basename $d) $drv"
done
( mdevctl list 2>/dev/null || sudo -n mdevctl list 2>/dev/null ) | while read -r uuid parent type rest; do
  [ -n "$parent" ] || continue
  pf=$parent
  [ -e /sys/bus/pci/devices/$parent/physfn ] && pf=$(basename "$(readlink -f /sys/bus/pci/devices/$parent/physfn)")
  echo "MDEV $pf $type"
done
echo "VER $(dpkg-query -W -f='${Version}' pf9-ostackhost 2>/dev/null || rpm -q --qf '%{VERSION}' pf9-ostackhost 2>/dev/null || echo unknown)"
EOF

if [[ -n "$ONLY_HOST" ]]; then
  HOSTS=$(api "$API/hosts/$ONLY_HOST" | jq -c '[.]')
else
  HOSTS=$(api "$API/hosts" | jq -c '[.[] | select((.roles // []) | index("'"$ROLE"'"))]')
fi
log "hosts with $ROLE: $(echo "$HOSTS" | jq length)"

echo "$HOSTS" | jq -c '.[]' | while read -r h; do
  HID=$(jq -r .id <<<"$h"); HN=$(jq -r '.info.hostname // .id' <<<"$h")
  RSTAT=$(jq -r '.role_status // "unknown"' <<<"$h")

  ROLECFG=$(api "$API/hosts/$HID/roles/$ROLE")
  echo "$ROLECFG" > "$OUT/${HN}.before.json"
  CFG=$(jq -c '.mdev_config | if type=="string" then (if .=="" then [] else fromjson end) elif .==null then [] else . end' <<<"$ROLECFG")

  if [[ $(jq length <<<"$CFG") -eq 0 ]]; then rep "$HID" "$HN" SKIP "no mdev_config (not vGPU)"; continue; fi
  if jq -e 'all(.[]; has("pf_address"))' <<<"$CFG" >/dev/null; then rep "$HID" "$HN" SKIP "already PF-aware"; continue; fi
  if [[ "$RSTAT" != "ok" ]]; then rep "$HID" "$HN" BLOCKED "role_status=$RSTAT"; continue; fi

  if ! RAW=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${HN}" "bash -s" <<<"$REMOTE" 2>"$OUT/${HN}.ssh.err"); then
    rep "$HID" "$HN" BLOCKED "ssh failed"; continue
  fi
  echo "$RAW" > "$OUT/${HN}.host.txt"
  VER=$(awk '/^VER /{print $2}' <<<"$RAW")
  if [[ "$VER" != *"$TARGET_VER"* ]]; then rep "$HID" "$HN" BLOCKED "pf9-ostackhost=$VER not $TARGET_VER"; continue; fi

  CONF_TYPES=$(jq -r '[.[].name] | unique | .[]' <<<"$CFG")
  NCONF=$(wc -l <<<"$CONF_TYPES")
  NEW="[]"; UNRES=""; SKIPPED_PT=""
  while read -r _ pf drv; do
    [[ -z "$pf" ]] && continue
    if [[ "$drv" == "vfio-pci" ]]; then SKIPPED_PT+="$pf "; continue; fi
    TYPES=$(awk -v p="$pf" '$1=="MDEV" && $2==p {print $3}' <<<"$RAW" | sort -u)
    N=$(grep -c . <<<"$TYPES" || true)
    if [[ $N -eq 1 ]]; then NAME="mdev_${TYPES}"
    elif [[ $N -eq 0 && $NCONF -eq 1 ]]; then NAME="$CONF_TYPES"
    else UNRES+="$pf(types:${TYPES//$'\n'/+}) "; continue; fi
    MAX=$(jq -r --arg n "$NAME" 'map(select(.name==$n)) | .[0].max_instances // empty' <<<"$CFG")
    if [[ -z "$MAX" ]]; then UNRES+="$pf($NAME not in mdev_config) "; continue; fi
    NEW=$(jq -c --arg n "$NAME" --arg m "$MAX" --arg p "$pf" '. + [{name:$n,max_instances:$m,pf_address:$p}]' <<<"$NEW")
  done < <(grep '^PF ' <<<"$RAW")

  echo "$NEW" | jq . > "$OUT/${HN}.proposed_mdev_config.json"
  if [[ -n "$UNRES" ]]; then rep "$HID" "$HN" MANUAL "unresolved PFs: $UNRES"; continue; fi
  if [[ $(jq length <<<"$NEW") -eq 0 ]]; then rep "$HID" "$HN" MANUAL "no vGPU PFs found on host"; continue; fi

  if [[ $APPLY -eq 0 ]]; then
    rep "$HID" "$HN" DRYRUN "$(jq -c . <<<"$NEW") passthrough_skipped:[${SKIPPED_PT}]"; continue
  fi

  if [[ -n "$ORIG" ]]; then
    # Delegate to the Confluence script. It applies .[0].name/.[0].max_instances to every PF,
    # so only safe when the whole host resolves to one profile.
    if [[ $(jq '[.[].name] | unique | length' <<<"$NEW") -ne 1 ]]; then
      rep "$HID" "$HN" MANUAL "multi-profile host, original script would collapse to one profile"; continue
    fi
    PFS=$(jq -r '[.[].pf_address] | join(",")' <<<"$NEW")
    if ! echo yes | "$ORIG" "$FQDN" "$AUTH_TOKEN" "$HID" "$PFS" > "$OUT/${HN}.orig.log" 2>&1; then
      rep "$HID" "$HN" FAILED "original script exit non-zero, see ${HN}.orig.log"; continue
    fi
  else
    # Same payload as ubuntu22_vgpu_configure.sh: full role body, mdev_config as compact JSON string
    BODY=$(jq -c --arg mc "$(jq -c . <<<"$NEW")" '.mdev_config = $mc' <<<"$ROLECFG")
    CODE=$(api -o "$OUT/${HN}.put.resp" -w '%{http_code}' -X PUT "$API/hosts/$HID/roles/$ROLE" -d "$BODY")
    if [[ "$CODE" != 2* ]]; then rep "$HID" "$HN" FAILED "PUT http $CODE"; continue; fi
  fi

  AFTER=$(api "$API/hosts/$HID/roles/$ROLE"); echo "$AFTER" > "$OUT/${HN}.after.json"
  if jq -e '.mdev_config | (if type=="string" then fromjson else . end) | all(.[]; has("pf_address"))' <<<"$AFTER" >/dev/null; then
    rep "$HID" "$HN" PATCHED "$(jq -c . <<<"$NEW")"
  else
    rep "$HID" "$HN" FAILED "verify: pf_address missing after PUT"
  fi
done

log "done. report: $REPORT  per-host artifacts: $OUT/"
