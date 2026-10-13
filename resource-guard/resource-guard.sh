#!/usr/bin/env bash
# resource-guard.sh
# Pre-upgrade:  capture container requests/limits (Deployments, StatefulSets, DaemonSets) per namespace.
# Post-upgrade: per field, restore the pre-upgrade value only if the upgrade lowered it.
#                 post >= pre          -> SKIP
#                 post <  pre          -> APPLY  (restore pre value)
#                 post request missing -> APPLY  (missing request = 0)
#                 post limit missing   -> SKIP   (missing limit = unlimited)
#
# Usage:
#   ./resource-guard.sh capture <ns-list> [--dir DIR] [--force]
#   ./resource-guard.sh restore <ns-list|all> [--dir DIR] [--apply]
#
#   <ns-list>  ns | ns1,ns2 | @file (one namespace per line, # comments allowed)
#   all        every namespace directory under DIR that has a snapshot
#   --dir      base directory (default: ./resource-guard-data)
#   --force    allow capture to replace an existing snapshot (otherwise refused)
#   --apply    patch workloads (default is dry run); backs up each workload's YAML first
#
# Layout:
#   DIR/<ns>/snapshot.tsv            current pre-upgrade snapshot used by restore
#   DIR/<ns>/snapshot.meta           kube context + capture time
#   DIR/<ns>/snapshot_<ts>.tsv       every capture, kept
#   DIR/<ns>/restore_<ts>/           pre.tsv post.tsv plan.tsv patches.jsonl backup/
set -euo pipefail

usage() { sed -n '2,25p' "$0"; exit 1; }
KINDS="deployment,statefulset,daemonset"
DIR="./resource-guard-data"; FORCE=0; APPLY=0

MODE="${1:-}"; NSARG="${2:-}"
[[ -z "$MODE" || -z "$NSARG" ]] && usage
shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift ;;
    --force) FORCE=1 ;;
    --apply) APPLY=1 ;;
    *) usage ;;
  esac; shift
done

CTX=$(kubectl config current-context 2>/dev/null || echo unknown)
TS=$(date +%Y%m%d-%H%M%S)

NSL=()
if [[ "$NSARG" == "all" ]]; then
  for d in "$DIR"/*/; do [[ -f "$d/snapshot.tsv" ]] && NSL+=("$(basename "$d")"); done
elif [[ "$NSARG" == @* ]]; then
  while IFS= read -r l; do l=$(tr -d ' \r' <<<"$l"); [[ -n "$l" && "$l" != \#* ]] && NSL+=("$l"); done < "${NSARG#@}"
else
  while IFS= read -r l; do [[ -n "$l" ]] && NSL+=("$l"); done < <(tr ',' '\n' <<<"$NSARG" | tr -d ' ')
fi
[[ ${#NSL[@]} -eq 0 ]] && { echo "no namespaces to process"; exit 1; }

collect() {    # ns -> rows: ns kind name container field value ; non-zero if unreadable
  local ns=$1 json
  json=$(kubectl get "$KINDS" -n "$ns" -o json --request-timeout=60s 2>/dev/null) || return 1
  jq -r --arg ns "$ns" '
    .items[]
    | .kind as $k | .metadata.name as $n
    | .spec.template.spec.containers[]
    | .name as $c | (.resources // {}) as $r
    | ("requests.cpu","requests.memory","limits.cpu","limits.memory") as $f
    | [$ns, $k, $n, $c, $f, (($r | getpath($f | split("."))) // "-")]
    | @tsv' <<<"$json"
}

echo "Context: $CTX   base dir: $DIR   mode: $MODE$([[ $MODE == restore ]] && { [[ $APPLY -eq 1 ]] && echo " (APPLY)" || echo " (DRY-RUN)"; })"
echo

case "$MODE" in
capture)
  for ns in "${NSL[@]}"; do
    d="$DIR/$ns"; mkdir -p "$d"
    if [[ -f "$d/snapshot.tsv" && $FORCE -eq 0 ]]; then
      printf '%-32s SKIPPED  snapshot exists (%s), use --force to replace\n' "$ns" "$(grep '^captured=' "$d/snapshot.meta" 2>/dev/null | cut -d= -f2)"
      continue
    fi
    if ! collect "$ns" > "$d/snapshot_$TS.tsv"; then
      rm -f "$d/snapshot_$TS.tsv"; printf '%-32s FAILED   cannot read namespace\n' "$ns"; continue
    fi
    cp "$d/snapshot_$TS.tsv" "$d/snapshot.tsv"
    printf 'context=%s\ncaptured=%s\n' "$CTX" "$TS" > "$d/snapshot.meta"
    printf '%-32s OK       %s containers -> %s\n' "$ns" \
      "$(cut -f2-4 "$d/snapshot.tsv" | sort -u | grep -c . || true)" "$d/snapshot.tsv"
  done
  ;;

restore)
  TOTAL_PATCH=0
  for ns in "${NSL[@]}"; do
    d="$DIR/$ns"; SNAP="$d/snapshot.tsv"
    echo "================ $ns"
    [[ -f "$SNAP" ]] || { echo "no snapshot at $SNAP, skipping"; echo; continue; }
    SCTX=$(grep '^context=' "$d/snapshot.meta" 2>/dev/null | cut -d= -f2)
    if [[ -n "$SCTX" && "$SCTX" != "$CTX" ]]; then
      echo "context mismatch: snapshot=$SCTX current=$CTX, skipping"; echo; continue
    fi
    W="$d/restore_$TS"; mkdir -p "$W"
    cp "$SNAP" "$W/pre.tsv"
    if ! collect "$ns" > "$W/post.tsv"; then echo "cannot read namespace, skipping"; echo; continue; fi

    awk -F'\t' -v OFS='\t' '
      function cpu(v) { if (v ~ /m$/) return substr(v,1,length(v)-1)+0; return (v+0)*1000 }
      function mem(v,   n,s,f) {
        if (match(v, /(Ki|Mi|Gi|Ti|Pi|Ei|k|K|M|G|T|P|E|m)$/)) {
          n = substr(v,1,RSTART-1)+0; s = substr(v,RSTART)
          f = (s=="Ki")?1024:(s=="Mi")?1048576:(s=="Gi")?1073741824:(s=="Ti")?1099511627776: \
              (s=="Pi")?1125899906842624:(s=="Ei")?1152921504606846976: \
              (s=="k"||s=="K")?1e3:(s=="M")?1e6:(s=="G")?1e9:(s=="T")?1e12:(s=="P")?1e15:(s=="E")?1e18:0.001
          return n*f
        }
        return v+0
      }
      function val(f,v) { return (f ~ /cpu$/) ? cpu(v) : mem(v) }
      NR==FNR { post[$1 FS $2 FS $3 FS $4 FS $5]=$6; next }
      {
        k=$1 FS $2 FS $3 FS $4 FS $5; pre=$6
        if (pre=="-")             { act="SKIP";    why="no pre value"; p=(k in post)?post[k]:"absent" }
        else if (!(k in post))    { act="MISSING"; why="not found post-upgrade"; p="absent" }
        else {
          p=post[k]
          if (p=="-" && $5 ~ /^limits/)        { act="SKIP";  why="post has no limit" }
          else if (p=="-")                      { act="APPLY"; why="post request missing" }
          else if (val($5,p) >= val($5,pre))    { act="SKIP";  why="post >= pre" }
          else                                  { act="APPLY"; why="post < pre" }
        }
        print $1,$2,$3,$4,$5,pre,p,act,why
      }' "$W/post.tsv" "$W/pre.tsv" > "$W/plan.tsv"

    awk -F'\t' '$8!="SKIP"' "$W/plan.tsv" \
    | awk -F'\t' 'BEGIN{printf "%-12s %-36s %-22s %-16s %-10s %-10s %-8s %s\n","KIND","RESOURCE","CONTAINER","FIELD","PRE","POST","ACTION","REASON"}
                  {printf "%-12s %-36s %-22s %-16s %-10s %-10s %-8s %s\n",$2,$3,$4,$5,$6,$7,$8,$9}'
    echo "Summary: $(cut -f8 "$W/plan.tsv" | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')  (full table: $W/plan.tsv)"

    awk -F'\t' -v OFS='\t' '$8=="APPLY"{print $2,$3,$4,$5,$6}' "$W/plan.tsv" \
    | jq -Rsc 'split("\n") | map(select(length>0) | split("\t"))
        | group_by(.[0] + "/" + .[1])[]
        | { ref: ((.[0][0] | ascii_downcase) + "/" + .[0][1]),
            patch: { spec: { template: { spec: { containers:
              ( group_by(.[2]) | map({ name: .[0][2],
                  resources: (reduce .[] as $r ({}; setpath($r[3] | split("."); $r[4]))) }) ) } } } } }' \
    > "$W/patches.jsonl"

    N=$(grep -c . "$W/patches.jsonl" || true)
    echo "Workloads to patch: $N"
    if [[ $N -gt 0 && $APPLY -eq 1 ]]; then
      mkdir -p "$W/backup"
      while read -r line; do
        ref=$(jq -r .ref <<<"$line"); patch=$(jq -c .patch <<<"$line")
        kubectl get "$ref" -n "$ns" -o yaml > "$W/backup/${ref//\//_}.yaml"
        if kubectl patch "$ref" -n "$ns" --type=strategic -p "$patch" >/dev/null; then
          echo "  PATCHED $ref"
        else
          echo "  FAILED  $ref"
        fi
      done < "$W/patches.jsonl"
      TOTAL_PATCH=$((TOTAL_PATCH + N))
    elif [[ $N -gt 0 ]]; then
      echo "  dry run, patches in $W/patches.jsonl"
    fi
    echo
  done
  [[ $APPLY -eq 1 ]] && echo "Patched $TOTAL_PATCH workload(s). Re-run without --apply to verify (expect APPLY=0)."
  ;;

*) usage ;;
esac