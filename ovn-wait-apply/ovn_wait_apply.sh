#!/bin/bash
# ovn-ofctrl-wait-before-clear — host-upgrade prerequisite (safe to re-run on partially done regions)
#
# MODES
#   check  : STAGE 1 only — read-only survey of every host + verdict. Changes nothing, no prompt.
#   apply  : (default)
#     STAGE 1  SURVEY    (read-only)   : read the value on every host -> build the PENDING list
#                                        (PENDING = UNSET or any value other than "180000")
#     STAGE 2  APPLY     (pending only): set + verify ONLY on PENDING hosts; hosts already at
#                                        "180000" receive no write command at all
#     STAGE 3  VALIDATE  (read-only)   : re-read the value on every host
#
# Path: resmgr DB (hostnames) -> forwarder pod -> ARS jump host (pf9-support) -> ssh <FQDN> per host
#
# Usage:
#   ./ovn_wait_apply.sh check <namespace> [jump_host_id]
#   ./ovn_wait_apply.sh apply <namespace> [jump_host_id]
#   ./ovn_wait_apply.sh <namespace> [jump_host_id]          (same as apply)
#
# Env knobs (optional):
#   PARALLEL=1      hosts processed concurrently from the jump host (1..20, default 1)
#   MATCH='regex'   limit to matching FQDNs (canary), e.g. MATCH='^punhvqa05\.'
#   FORCE_JUMP=0    refuse a jump host with swap >90% for APPLY unless FORCE_JUMP=1
#   MAX_JUMP=5      ARS jump hosts to try (in order) if one can't be reached; [jump_host_id] is tried first
#
# Examples:
#   ./ovn_wait_apply.sh check disw-qa-pune
#   ./ovn_wait_apply.sh apply disw-qa-pune
#   PARALLEL=10 ./ovn_wait_apply.sh check disw-na-wiv 4872b448-8b16-45f0-8e10-d51ef6a40e29

set -uo pipefail

USAGE="usage: $0 [check|apply] <namespace> [jump_host_id]"
case "${1:-}" in
    check|apply) RUN_MODE=$1; shift ;;
    *)           RUN_MODE=apply ;;
esac
NS="${1:-}"; JUMP_OVERRIDE="${2:-}"
[ -n "$NS" ] || { echo "$USAGE"; exit 1; }
case "$NS" in -*|check|apply) echo "$USAGE"; exit 1 ;; esac

WANT=180000
PARALLEL="${PARALLEL:-1}"
MATCH="${MATCH:-}"
FORCE_JUMP="${FORCE_JUMP:-0}"
MAX_JUMP="${MAX_JUMP:-5}"
if ! [[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || [ "$PARALLEL" -gt 20 ]; then
    echo "ERROR: PARALLEL must be a whole number from 1 to 20 (got: '$PARALLEL')"; exit 1
fi
if ! [[ "$MAX_JUMP" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: MAX_JUMP must be a whole number >= 1 (got: '$MAX_JUMP')"; exit 1
fi
LOG_DIR=./ovn-wait-logs
FORWARDER_HELPER=/opt/pf9/forwarder/utils/ssh_to_host_as_pf9_with_key.sh

mkdir -p "$LOG_DIR"
TS=$(date +%Y%m%d-%H%M%S)
INV="$LOG_DIR/${NS}_inventory_${TS}.tsv"
SURVEY_LOG="$LOG_DIR/${NS}_${RUN_MODE}_1-survey_${TS}.log"
APPLY_LOG="$LOG_DIR/${NS}_2-apply+3-validate_${TS}.log"

echo "========================================================================"
echo "REGION: $NS | mode: $RUN_MODE | value: $WANT | parallel: $PARALLEL | match: ${MATCH:-<all>} | $TS"
echo "========================================================================"

# ---------------------------------------------------------------- inventory
SQL=$(cat <<'SQL'
SELECT h.hostname,
       h.id,
       COALESCE(h.responding, 0),
       COALESCE(SUM(m.rolename LIKE 'pf9-support\_%'), 0)
FROM hosts h
LEFT JOIN host_role_map m ON m.res_id = h.id
GROUP BY h.id
ORDER BY h.hostname;
SQL
)
RAW=$( { kubectl -n "$NS" get secret mysql -o jsonpath='{.data.pass}' | base64 -d; echo; echo "$SQL"; } \
       | kubectl -n "$NS" exec -i deploy/mysql -c mysql -- \
           sh -c 'read -r MYSQL_PWD; export MYSQL_PWD; exec mysql -u root -N -B resmgr' 2>&1 )
RC=$?
if [ $RC -ne 0 ] || [ -z "$RAW" ]; then echo "ERROR: resmgr query failed (rc=$RC):"; echo "$RAW"; exit 1; fi
echo "$RAW" > "$INV"

ALL_LIST=(); EXCLUDED=(); JUMP_IDS=(); JUMP_NAMES=(); OVR_NAME=""
while IFS=$'\t' read -r name id resp ars; do
    [ -z "${id:-}" ] && continue
    if [ -n "$JUMP_OVERRIDE" ] && [ "$id" = "$JUMP_OVERRIDE" ]; then
        OVR_NAME=$name
    elif [ "$resp" = 1 ] && [ "$ars" -ge 1 ]; then
        JUMP_IDS+=("$id"); JUMP_NAMES+=("$name")       # ARS + responding = jump candidate
    fi
    if [ -n "$MATCH" ] && ! [[ "$name" =~ $MATCH ]]; then continue; fi
    if [ "$resp" != 1 ]; then EXCLUDED+=("$name"); continue; fi
    ALL_LIST+=("$name")
done <<< "$RAW"
if [ -n "$JUMP_OVERRIDE" ]; then
    [ -n "$OVR_NAME" ] || { echo "ERROR: jump host $JUMP_OVERRIDE not found in $NS"; exit 1; }
    JUMP_IDS=("$JUMP_OVERRIDE" ${JUMP_IDS[@]+"${JUMP_IDS[@]}"}); JUMP_NAMES=("$OVR_NAME" ${JUMP_NAMES[@]+"${JUMP_NAMES[@]}"})   # preferred first
fi

echo "resmgr hosts: $(echo "$RAW" | grep -c .) | selected: ${#ALL_LIST[@]} | excluded (responding=0): ${#EXCLUDED[@]}"
[ ${#EXCLUDED[@]} -gt 0 ] && printf '  excluded: %s\n' "${EXCLUDED[@]}"
[ ${#JUMP_IDS[@]} -eq 0 ] && { echo "ERROR: no responding ARS (pf9-support) host in $NS to use as jump host"; exit 1; }
[ ${#ALL_LIST[@]} -eq 0 ] && { echo "Nothing selected."; exit 0; }
JUMP_ID=${JUMP_IDS[0]}; JUMP_NAME=${JUMP_NAMES[0]}
echo "Jump host candidates (ARS, in order; next is used if one fails): ${#JUMP_IDS[@]} | will try up to $MAX_JUMP"
for k in $(seq 0 $(( ${#JUMP_IDS[@]} < MAX_JUMP ? ${#JUMP_IDS[@]}-1 : MAX_JUMP-1 ))); do
    printf '  %d. %s (%s)\n' $((k+1)) "${JUMP_NAMES[$k]}" "${JUMP_IDS[$k]}"
done

# ---------------------------------------------------------------- remote engine
# Emits the script executed on the jump host. Caller sets STAGE, ALL_LIST, APPLY_LIST.
remote_payload() {
    declare -p STAGE ALL_LIST APPLY_LIST WANT PARALLEL FORCE_JUMP
    cat << 'REMOTE'
exec 2>&1   # forwarder wrapper discards stderr; keep errors visible

read -r l1 l5 l15 _ < /proc/loadavg
swap_pct=$(free | awk '/^Swap:/ { if ($2>0) printf "%d", $3*100/$2; else print 0 }')
echo "Jump host: $(hostname -f) | user: $(whoami) | load: $l1 $l5 $l15 | swap used: ${swap_pct}% | nproc: $(nproc)"
if [ "$swap_pct" -gt 90 ]; then
    echo "WARNING: jump host swap ${swap_pct}% — pick a different ARS host via the 2nd argument"
    if [ "$STAGE" = apply ] && [ "$FORCE_JUMP" != 1 ]; then
        echo "RESULT phase=apply total=${#APPLY_LIST[@]} aborted=jump_host_unhealthy fail=1 not_attempted=${#APPLY_LIST[@]}"
        exit
    fi
fi

# -n is mandatory: this script arrives on stdin; ssh without -n would eat it.
SSH_OPTS=(-n -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
LOCAL_NAMES=" $(hostname) $(hostname -s) $(hostname -f 2>/dev/null) "

# Runs ON the target host. POSIX sh. Identity is checked before anything else.
probe() {
    mode=$1; want=$2; expect=$3
    key=external_ids:ovn-ofctrl-wait-before-clear
    h=$(hostname -f)
    if [ "${h%%.*}" != "${expect%%.*}" ]; then echo "$h|MISMATCH|answered as $h — nothing changed"; return 3; fi
    cur=$(sudo -n ovs-vsctl --timeout=15 --if-exists get open . "$key" 2>&1) || { echo "$h|GET-FAILED|$cur"; return 1; }
    [ -z "$cur" ] && cur="<unset>"
    if [ "$mode" = check ]; then
        if   [ "$cur" = "\"$want\"" ]; then echo "$h|SET|$cur"
        elif [ "$cur" = "<unset>" ];    then echo "$h|UNSET|$cur"
        else                                 echo "$h|OTHER|$cur"; fi
        return 0
    fi
    if [ "$cur" = "\"$want\"" ]; then echo "$h|SKIP|already $cur (set since survey)"; return 0; fi
    out=$(sudo -n ovs-vsctl --timeout=15 set open . "$key=$want" 2>&1) || { echo "$h|SET-FAILED|was $cur: $out"; return 1; }
    new=$(sudo -n ovs-vsctl --timeout=15 get open . "$key" 2>&1)
    if [ "$new" = "\"$want\"" ]; then echo "$h|APPLIED|$cur -> $new"; return 0; fi
    echo "$h|VERIFY-FAILED|was $cur, now $new"; return 1
}
PROBE_DEF=$(declare -f probe)

run_one() {
    idx=$1; name=$2
    if [[ "$LOCAL_NAMES" == *" $name "* ]]; then
        via=local; out=$(probe "$MODE" "$WANT" "$name" </dev/null); rc=$?
    else
        via=ssh;   out=$(ssh "${SSH_OPTS[@]}" "$name" "$PROBE_DEF; probe $MODE $WANT $name"); rc=$?
    fi
    out=$(echo "$out" | tr '\n' ' ' | sed 's/ *$//')
    if   [ $rc -eq 255 ];        then status=UNREACHABLE; detail=$out
    elif [[ "$out" == *"|"* ]];  then rest=${out#*|}; status=${rest%%|*}; detail=${rest#*|}
    else                              status="FAIL(rc=$rc)"; detail=$out; fi
    printf '[%3d/%-3d] %-36s %-5s %-14s %s\n' "$idx" "$total" "$name" "$via" "$status" "$detail"
    echo "$status $name" > "$RES/$idx"
    case $status in
        SET|UNSET|OTHER|SKIP|APPLIED) ;;
        *) [ "$MODE" = apply ] && : > "$STOP" ;;   # apply: stop launching new hosts after a failure
    esac
}

# run_phase <apply|check> <survey|apply|validate> <array name>
run_phase() {
    MODE=$1; PHASE=$2; local -n LIST=$3
    total=${#LIST[@]}
    RES=$(mktemp -d /tmp/ovn-wait.XXXXX); STOP="$RES/STOP"
    case $PHASE in
        survey)   label="1/3 SURVEY (read-only, all hosts)" ;;
        apply)    label="2/3 APPLY (set + verify, pending hosts only)" ;;
        validate) label="3/3 VALIDATE (read-only, all hosts)" ;;
    esac
    echo
    echo "======================== $label ========================"
    SECONDS=0; i=0
    for name in "${LIST[@]}"; do
        i=$((i+1))
        [ -e "$STOP" ] && break
        while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do wait -n; done
        [ -e "$STOP" ] && break
        run_one "$i" "$name" &
    done
    wait

    i=0; not_attempted=()
    for name in "${LIST[@]}"; do i=$((i+1)); [ -f "$RES/$i" ] || not_attempted+=("$name"); done
    cat "$RES"/[0-9]* 2>/dev/null > "$RES/all"
    count() { grep -c "^$1 " "$RES/all"; }
    names() { grep -E "^($1) " "$RES/all" | awk '{print $2}' | sort | tr '\n' ' '; }
    fails=$(grep -Evc '^(SET|UNSET|OTHER|SKIP|APPLIED) ' "$RES/all")
    echo "------------------------------------------------------------------------"
    [ "$(count UNSET)" -gt 0 ] && echo "UNSET: $(names UNSET)"
    [ "$(count OTHER)" -gt 0 ] && echo "OTHER: $(names OTHER)"
    [ "$fails" -gt 0 ] && echo "FAILED: $(grep -Ev '^(SET|UNSET|OTHER|SKIP|APPLIED) ' "$RES/all" | sort -k2 | tr '\n' ';')"
    [ ${#not_attempted[@]} -gt 0 ] && echo "NOT ATTEMPTED (stopped after failure): ${not_attempted[*]}"
    echo "elapsed: ${SECONDS}s"
    case $PHASE in
        survey)
            echo "PENDING_HOSTS $(names 'UNSET|OTHER')"
            echo "UNREADABLE_HOSTS $(grep -Ev '^(SET|UNSET|OTHER) ' "$RES/all" | awk '{print $2}' | sort | tr '\n' ' ')"
            echo "RESULT phase=survey total=$total set=$(count SET) unset=$(count UNSET) other=$(count OTHER) fail=$fails" ;;
        apply)
            echo "RESULT phase=apply total=$total applied=$(count APPLIED) skip=$(count SKIP) fail=$fails not_attempted=${#not_attempted[@]}" ;;
        validate)
            echo "RESULT phase=validate total=$total set=$(count SET) unset=$(count UNSET) other=$(count OTHER) fail=$fails" ;;
    esac
    rm -rf "$RES"
}

if [ "$STAGE" = survey ]; then
    run_phase check survey ALL_LIST
else
    run_phase apply apply APPLY_LIST
    run_phase check validate ALL_LIST
fi
exit
REMOTE
}

# run_remote <log>
# Opens a forwarder -> jump-host session and streams the payload. Fails over across ARS candidates:
#   - session never reached the jump host (no "Jump host:" marker; e.g. ssh exit 255 on the
#     forwarder's :8022 tunnel)       -> nothing ran remotely; mark host bad, try next candidate
#   - jump host reached but refused for apply (swap guard) -> nothing applied; try next candidate
#   - jump host reached and payload ran                    -> done (no retry; a mid-run drop is
#     reported by the caller; re-running the script is safe — it surveys first, idempotent)
# Hosts that failed stay skipped for the rest of this run (BAD_JUMP, space-separated ids).
BAD_JUMP=" "
JUMP_FAILED=""
GOOD_JUMP_ID=""; GOOD_JUMP_NAME=""
run_remote() {
    local log=$1 tried=0 k rc tmp reached
    : > "$log"
    for k in "${!JUMP_IDS[@]}"; do
        [ $tried -ge "$MAX_JUMP" ] && break
        case "$BAD_JUMP" in *" ${JUMP_IDS[$k]} "*) continue ;; esac
        tried=$((tried+1))
        JUMP_ID=${JUMP_IDS[$k]}; JUMP_NAME=${JUMP_NAMES[$k]}
        tmp=$(mktemp)
        echo "--- forwarder session via $JUMP_NAME ($JUMP_ID) [jump host try $tried/$MAX_JUMP] ---" | tee -a "$log"
        remote_payload | kubectl -n "$NS" exec -i deploy/forwarder -- \
            bash -c "$FORWARDER_HELPER $JUMP_ID -T" 2>&1 | tee "$tmp"
        rc=${PIPESTATUS[1]}
        if grep -q '^Jump host: ' "$tmp" && ! grep -q 'aborted=jump_host_unhealthy' "$tmp"; then
            cat "$tmp" >> "$log"; rm -f "$tmp"
            echo ">>> using jump host: $JUMP_NAME" | tee -a "$log"
            GOOD_JUMP_ID=$JUMP_ID; GOOD_JUMP_NAME=$JUMP_NAME
            return 0
        fi
        reached=0; grep -q '^Jump host: ' "$tmp" && reached=1
        grep -v '^RESULT ' "$tmp" >> "$log"; rm -f "$tmp"     # keep evidence, drop aborted RESULT lines
        BAD_JUMP="$BAD_JUMP$JUMP_ID "
        JUMP_FAILED="$JUMP_FAILED$JUMP_NAME|$JUMP_ID|$([ $reached = 0 ] && echo "not reachable via forwarder (exit $rc)" || echo "rejected: unhealthy (swap)")
"
        if [ $reached = 0 ]; then
            echo ">>> could not reach $JUMP_NAME (forwarder exit $rc) — nothing ran remotely. Trying next ARS host." | tee -a "$log"
        else
            echo ">>> $JUMP_NAME refused as jump host (unhealthy) — nothing applied. Trying next ARS host." | tee -a "$log"
        fi
        sleep 3
    done
    echo ">>> no usable jump host after $tried attempt(s). Skipped as failed:$BAD_JUMP" | tee -a "$log"
    return 1
}

# result_all_set <log> <phase>  -> true if "RESULT phase=<phase>" has set==total and unset/other/fail == 0
result_all_set() {
    awk -v ph="phase=$2" '$1=="RESULT" && $2==ph {
        for (i=3;i<=NF;i++) { split($i,kv,"="); v[kv[1]]=kv[2] }
        ok = (v["total"]!="" && v["set"]==v["total"] && v["unset"]==0 && v["other"]==0 && v["fail"]==0)
        found=1 }
        END { exit !(found && ok) }' "$1"
}

# final_verdict <apply_ok> <validate_ok> <logs...>
# MET only if apply+validate clean AND the scope was the whole region (no MATCH, no excluded hosts).
final_verdict() {
    local a=$1 v=$2; shift 2
    echo "========================================================================"
    if [ "$a" = 1 ] && [ "$v" = 1 ]; then
        if [ ${#EXCLUDED[@]} -gt 0 ]; then
            echo ">>> $NS: selected hosts OK, but ${#EXCLUDED[@]} host(s) were EXCLUDED (responding=0) and NOT changed:"
            printf '      %s\n' "${EXCLUDED[@]}"
            echo ">>> PREREQUISITE NOT MET for the region — handle these before upgrading them."
            echo ">>> logs: $*"; manual_report; return 1
        fi
        if [ -n "$MATCH" ]; then
            echo ">>> $NS: MET for MATCH subset only ('$MATCH', ${#ALL_LIST[@]} hosts). Run without MATCH to validate the whole region."
            echo ">>> logs: $*"; return 0
        fi
        echo ">>> $NS: PREREQUISITE MET — all ${#ALL_LIST[@]} hosts read \"$WANT\". Host upgrade can proceed."
        echo ">>> logs: $*"; return 0
    fi
    [ "$a" = 1 ] || echo ">>> $NS: APPLY not clean (failures, stopped early, or jump host refused)"
    [ "$v" = 1 ] || echo ">>> $NS: $([ "$RUN_MODE" = check ] && echo CHECK || echo VALIDATION) not clean — not every host reads \"$WANT\""
    if [ "$RUN_MODE" = check ]; then
        echo ">>> PREREQUISITE NOT MET — do not start host upgrades. To fix: $0 apply $NS ${JUMP_OVERRIDE}"
    else
        echo ">>> PREREQUISITE NOT MET — do not start host upgrades. Re-running this script is safe."
    fi
    echo ">>> logs: $*"; manual_report; return 1
}

# ---------------------------------------------------------------- plain failure report
# manual_report: lists every host that is not at the target value, why, and how to fix it by hand.
manual_report() {
    local rows=""
    if [ "$RUN_MODE" = check ] || [ ! -s "${APPLY_LOG:-/nonexistent}" ]; then
        rows=$(awk '/^\[ *[0-9]+\/[0-9]+ *\] / { sub(/^\[[^]]*\] +/, "")
                       if ($3!="SET") { d=""; for(i=4;i<=NF;i++) d=d" "$i; printf "%-36s %-14s%s\n", $1, $3, d } }' "$SURVEY_LOG")
    else
        rows=$(awk '/APPLY \(set \+ verify/ {ph="apply"} /VALIDATE \(read-only/ {ph="validate"}
                   /^\[ *[0-9]+\/[0-9]+ *\] / { sub(/^\[[^]]*\] +/, "")
                       h=$1; st=$3; d=""; for(i=4;i<=NF;i++) d=d" "$i
                       if (ph=="apply" && st!="APPLIED" && st!="SKIP") { printf "%-36s %-14s%s\n", h, st, d; bad[h]=1 }
                       if (ph=="validate" && st!="SET" && !(h in bad)) printf "%-36s %-14s%s\n", h, st, d }' "$APPLY_LOG")
    fi
    local n=0; [ -n "$rows" ] && n=$(echo "$rows" | grep -c .)
    [ $n -eq 0 ] && [ ${#EXCLUDED[@]} -eq 0 ] && [ -z "$JUMP_FAILED" ] && return 0

    echo
    echo "====================== NEEDS MANUAL ATTENTION ======================"
    if [ $n -gt 0 ]; then
        echo "Hosts not at \"$WANT\" ($n) — by status: $(echo "$rows" | awk '{c[$2]++} END{for(k in c) printf "%s=%d ", k, c[k]}')"
        printf '  %-36s %-14s %s\n' HOST STATUS DETAIL
        echo "$rows" | sed 's/^/  /'
    fi
    if [ ${#EXCLUDED[@]} -gt 0 ]; then
        echo "Not covered — responding=0 in resmgr (${#EXCLUDED[@]}):"
        printf '  %s\n' "${EXCLUDED[@]}"
    fi
    if [ -n "$JUMP_FAILED" ]; then
        echo "ARS jump hosts that could not be used:"
        echo "$JUMP_FAILED" | grep . | awk -F'|' '{printf "  %-36s %s  (%s)\n", $1, $3, $2}'
    fi
    echo
    local hid=$GOOD_JUMP_ID hname=$GOOD_JUMP_NAME k
    if [ -z "$hid" ]; then   # no session worked: suggest an ARS host that was not tried yet
        for k in "${!JUMP_IDS[@]}"; do
            case "$BAD_JUMP" in *" ${JUMP_IDS[$k]} "*) ;; *) hid=${JUMP_IDS[$k]}; hname="${JUMP_NAMES[$k]} (not tried yet)"; break ;; esac
        done
    fi
    echo "Fix one host by hand:"
    echo "  kubectl -n $NS exec -it deploy/forwarder -- $FORWARDER_HELPER ${hid:-<id of any ARS host: 4th column = 1 in $INV>}   # ${hname:-ARS host}"
    echo "  ssh <host FQDN from the list above>"
    echo "  sudo ovs-vsctl set open . external_ids:ovn-ofctrl-wait-before-clear=$WANT"
    echo "  sudo ovs-vsctl get open . external_ids:ovn-ofctrl-wait-before-clear        # expect \"$WANT\""
    echo
    echo "Where to look:"
    echo "  UNSET / OTHER        value not $WANT yet (OTHER: check the existing value is not intentional), then set as above"
    echo "  UNREACHABLE          jump host could not ssh to it: host down, sshd, or DNS for the FQDN"
    echo "  GET/SET/VERIFY-FAILED  sudo for pf9, or OVS not running: run 'sudo ovs-vsctl show' on the host"
    echo "  MISMATCH             FQDN reached a different host (DNS vs resmgr hostname). Nothing was changed"
    echo "  responding=0         host not reporting to resmgr: check the host/hostagent, set by hand once reachable"
    echo "  jump host unusable   forwarder could not open a session to that ARS host; any other ARS host works too"
    echo "===================================================================="
}

# ---------------------------------------------------------------- stage 1: survey (read-only)
STAGE=survey; APPLY_LIST=()
if ! run_remote "$SURVEY_LOG"; then
    echo ">>> $NS: no ARS jump host reachable — nothing was read or changed. log: $SURVEY_LOG"; manual_report; exit 1
fi

if ! grep -q '^RESULT phase=survey ' "$SURVEY_LOG"; then
    echo ">>> $NS: survey did not complete (no RESULT line) — log: $SURVEY_LOG"; exit 1
fi
read -r -a APPLY_LIST <<< "$(grep '^PENDING_HOSTS' "$SURVEY_LOG" | cut -d' ' -f2-)"
read -r -a UNREADABLE  <<< "$(grep '^UNREADABLE_HOSTS' "$SURVEY_LOG" | cut -d' ' -f2-)"

echo
echo "========================================================================"
echo "SURVEY: $(grep '^RESULT phase=survey' "$SURVEY_LOG" | cut -d' ' -f3-)"
if [ ${#UNREADABLE[@]} -gt 0 ]; then
    echo "Could not be read (will NOT be changed; fix access and re-run): ${UNREADABLE[*]}"
fi
if [ "$RUN_MODE" = check ]; then
    CHECK_OK=0
    result_all_set "$SURVEY_LOG" survey && CHECK_OK=1
    final_verdict 1 "$CHECK_OK" "$SURVEY_LOG"; exit $?
fi

if [ ${#APPLY_LIST[@]} -eq 0 ]; then
    if [ ${#UNREADABLE[@]} -eq 0 ]; then
        echo ">>> $NS: all ${#ALL_LIST[@]} selected hosts already read \"$WANT\". Nothing to change."
        final_verdict 1 1 "$SURVEY_LOG"; exit $?
    fi
    echo ">>> $NS: nothing to apply, but ${#UNREADABLE[@]} host(s) unreadable — PREREQUISITE NOT MET."
    echo ">>> log: $SURVEY_LOG"; manual_report; exit 1
fi

# ---------------------------------------------------------------- confirm
echo
echo "Path for every host below: forwarder pod -> ARS jump host (survey used $JUMP_NAME; fails over if needed) -> ssh <host> -> ovs-vsctl"
echo "Hosts to be changed (${#APPLY_LIST[@]} of ${#ALL_LIST[@]}); all others will NOT be touched:"
sed -E -n 's/^\[[^]]*\] +([^ ]+) +[^ ]+ +(UNSET|OTHER) +(.*)$/  \1   current: \3/p' "$SURVEY_LOG"
echo
echo "Command per host:  ovs-vsctl set open . external_ids:ovn-ofctrl-wait-before-clear=$WANT"
read -r -p "Type the namespace ($NS) to apply on these ${#APPLY_LIST[@]} host(s): " ans </dev/tty
[ "$ans" = "$NS" ] || { echo "aborted — nothing changed"; exit 1; }

# ---------------------------------------------------------------- stage 2+3: apply pending, validate all
STAGE=apply
if ! run_remote "$APPLY_LOG"; then
    echo ">>> $NS: no ARS jump host reachable — NOTHING WAS APPLIED. Re-run (safe). logs: $SURVEY_LOG $APPLY_LOG"; manual_report; exit 1
fi
if ! grep -q '^RESULT phase=apply ' "$APPLY_LOG"; then
    echo ">>> $NS: session reached the jump host but dropped before APPLY finished — some pending hosts"
    echo ">>> may or may not be changed. Run: $0 check $NS ${JUMP_OVERRIDE}   (read-only) to see the true state."
fi

APPLY_OK=0; VALID_OK=0
grep -Eq '^RESULT phase=apply .* fail=0 not_attempted=0$' "$APPLY_LOG" && APPLY_OK=1
result_all_set "$APPLY_LOG" validate && VALID_OK=1

echo
echo "APPLY:    $(grep '^RESULT phase=apply' "$APPLY_LOG" | cut -d' ' -f3-)"
echo "VALIDATE: $(grep '^RESULT phase=validate' "$APPLY_LOG" | cut -d' ' -f3-)"
final_verdict "$APPLY_OK" "$VALID_OK" "$SURVEY_LOG" "$APPLY_LOG"
