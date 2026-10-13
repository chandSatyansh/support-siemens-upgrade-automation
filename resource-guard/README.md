# resource-guard

Preserves container CPU/memory requests and limits across a PCD upgrade.

Before the upgrade it captures the requests and limits of every Deployment, StatefulSet and DaemonSet in each target namespace. After the upgrade it compares the current values against that snapshot and restores only the values the upgrade lowered. Values the upgrade raised are left alone.

Everything is stored per namespace, so each namespace can be captured, reviewed, applied and verified on its own.

## Prerequisites

| Requirement | Check |
|---|---|
| bash 3.2 or newer (macOS default works) | `bash --version` |
| kubectl, pointed at the management cluster that hosts the region namespaces | `kubectl config current-context` |
| jq 1.6 or newer | `jq --version` |
| awk (BSD or GNU) | `awk --version` or `awk -W version` |
| RBAC: `get` on deployments, statefulsets, daemonsets in every target namespace | `kubectl auth can-i get deployments -n <ns>` |
| RBAC: `patch` on the same kinds (only needed for `--apply`) | `kubectl auth can-i patch deployments -n <ns>` |

Make the script executable once:

```bash
chmod +x resource-guard.sh
```

## Usage

```
./resource-guard.sh capture <ns-list> [--dir DIR] [--force]
./resource-guard.sh restore <ns-list|all> [--dir DIR] [--apply]
```

| Argument | Meaning |
|---|---|
| `<ns-list>` | One namespace (`disw-eu-snn-lab`), a comma-separated list (`ns1,ns2`), or `@file` with one namespace per line (`#` comments allowed) |
| `all` | Restore only: every namespace directory under `DIR` that has a snapshot |
| `--dir DIR` | Base directory. Default `./resource-guard-data` |
| `--force` | Capture only: replace an existing snapshot. Without it, capture refuses to overwrite |
| `--apply` | Restore only: patch the workloads. Without it, restore is a dry run |

## Directory layout

```
resource-guard-data/
  disw-eu-snn-lab/
    snapshot.tsv                  current pre-upgrade snapshot, used by restore
    snapshot.meta                 kube context and capture time
    snapshot_<ts>.tsv             copy of every capture
    restore_<ts>/
      pre.tsv                     snapshot used for this run
      post.tsv                    values found at restore time
      plan.tsv                    decision per field
      patches.jsonl               one patch per workload
      backup/<kind>_<name>.yaml   workload YAML before patching (--apply only)
  disw-eu-snn/
    ...
```

Snapshot columns (tab-separated): `namespace  kind  name  container  field  value`.

## Decision rules

Each container field (`requests.cpu`, `requests.memory`, `limits.cpu`, `limits.memory`) is compared on its own:

| Pre-upgrade | Post-upgrade | Action |
|---|---|---|
| value | equal or higher | SKIP, upgrade value kept |
| value | lower | APPLY, pre-upgrade value restored |
| value | request missing | APPLY, a missing request counts as 0 |
| value | limit missing | SKIP, a missing limit means unlimited |
| not set | anything | SKIP, nothing to restore |
| value | workload or container no longer exists | MISSING, reported only |

Units are normalised before comparison (`500m` = `0.5`, `1Gi` vs `1G` vs bytes), so equivalent values are not patched. Every field ends up as max(pre, post), so a request can never exceed its limit.

## Safety checks built in

| Check | Behaviour |
|---|---|
| Snapshot already exists | Capture skips that namespace unless `--force`, so a post-upgrade capture cannot overwrite the pre-upgrade values |
| Kube context changed | Restore skips a namespace if the current context differs from the one stored in `snapshot.meta` |
| Namespace unreadable (typo, RBAC, timeout) | Capture reports `FAILED`, restore skips it. Other namespaces continue |
| Dry run by default | Nothing is patched without `--apply` |

## Steps

### 1. Prepare the namespace list

```
# siemens_eu_ns.txt
disw-eu-snn-lab
disw-eu-snn
```

### 2. Capture before the upgrade

Confirm the context first, then capture while the region is in its normal state:

```bash
kubectl config current-context
./resource-guard.sh capture @siemens_eu_ns.txt
```

Example output:

```
Context: mgmt-eu   base dir: ./resource-guard-data   mode: capture

disw-eu-snn-lab                  OK       5 containers -> ./resource-guard-data/disw-eu-snn-lab/snapshot.tsv
disw-eu-snn                      OK       5 containers -> ./resource-guard-data/disw-eu-snn/snapshot.tsv
```

Keep the `resource-guard-data` directory (or attach the `snapshot.tsv` files to the CM ticket).

### 3. Dry run after the upgrade

```bash
./resource-guard.sh restore all                     # every captured namespace
./resource-guard.sh restore disw-eu-snn-lab         # one namespace
```

For each namespace the output shows only the APPLY and MISSING rows, a summary, and where the full plan is saved:

```
================ disw-eu-snn-lab
KIND         RESOURCE   CONTAINER  FIELD            PRE   POST   ACTION   REASON
Deployment   resmgr     resmgr     limits.memory    2Gi   600Mi  APPLY    post < pre
StatefulSet  ovn-sb     ovsdb      requests.memory  2G    1.5Gi  APPLY    post < pre
Deployment   old-svc    old        requests.cpu     100m  absent MISSING  not found post-upgrade
Summary: APPLY=5 MISSING=1 SKIP=14   (full table: ./resource-guard-data/disw-eu-snn-lab/restore_<ts>/plan.tsv)
Workloads to patch: 2
  dry run, patches in ./resource-guard-data/disw-eu-snn-lab/restore_<ts>/patches.jsonl
```

Review every APPLY and MISSING row. MISSING usually means a workload was renamed or removed by the upgrade and needs a manual look.

### 4. Apply in the change window, one namespace at a time

```bash
./resource-guard.sh restore disw-eu-snn-lab --apply
```

For each workload with at least one APPLY row the script saves the current YAML to `restore_<ts>/backup/`, then sends one strategic-merge patch with all of that workload's changed containers.

Patching the pod template triggers a rolling restart. Watch the rollouts before moving to the next namespace:

```bash
kubectl -n disw-eu-snn-lab rollout status deployment/<name>
kubectl -n disw-eu-snn-lab get pods -w
```

### 5. Verify

```bash
./resource-guard.sh restore disw-eu-snn-lab
```

Expect `Summary:` with no APPLY count. Run it again later (after the next reconcile cycle). If APPLY rows come back, the workload is being reset by Helm, kdu or an operator (see Limitations).

### 6. Rollback (if needed)

```bash
kubectl -n <ns> rollout undo deployment/<name>
kubectl -n <ns> rollout undo statefulset/<name>
kubectl -n <ns> rollout undo daemonset/<name>
```

The pre-patch YAML is in `resource-guard-data/<ns>/restore_<ts>/backup/` for reference.

### Re-capturing a namespace

Only when you deliberately want a new baseline (for example before the next upgrade):

```bash
./resource-guard.sh capture disw-eu-snn-lab --force
```

Older captures stay in `snapshot_<ts>.tsv`.

## Limitations

- Covers `containers` only. `initContainers` and CronJobs are not captured or restored.
- `--apply` patches the workloads in a namespace back to back without waiting for each rollout. Apply one namespace at a time.
- Workloads reconciled by Helm, kdu or an operator can be reset to the upgraded values on the next reconcile. In that case the change has to go into the chart or override values instead.