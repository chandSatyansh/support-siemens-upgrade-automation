Overview
pcd_resource_guard.py captures the CPU and memory requests and limits of everything in one PCD management-plane namespace before an upgrade, compares them after the upgrade, and generates kubectl patch commands that restore any value the upgrade lowered.

One namespace per run. pre <namespace> captures the baseline; post --baseline <file> compares and generates the patches. Repeat per namespace being upgraded.

Covers every container that runs. Deployment, StatefulSet, DaemonSet and CronJob templates (init, sidecar and main containers), plus pods with no such owner, plus a live check of every running pod against its template.

Only lowered values are patched. Raised values and removed limits are highlighted, not touched.

Nothing is changed by the script. It writes a patch script per namespace; you review and run it.

Why this is needed
A PCD upgrade re-renders the management-plane workloads. Any request or limit tuned for a specific environment, by hand or by an earlier fix, can come back at the upgrade's default value.

Lowered limits cause CPU throttling or OOM kills on services that needed the higher value.

Lowered requests let the scheduler pack more pods on a node than it can actually serve.

Silent. Nothing in the upgrade output reports the change; it shows up later as slow APIs, restarts or OOMKilled pods.

Prerequisites
You need python3 and kubectl access to the management-plane namespace. The script uses only the Python standard library.

Requirement

How to confirm

Notes

Workstation or host with python3 3.7 or later

python3 --version

No extra packages

kube context pointing at the PCD management plane

kubectl get ns lists the namespace

--kubeconfig <path> if not the default

Read access to deployments, statefulsets, daemonsets, cronjobs, replicasets, jobs, pods in the namespace

kubectl -n <namespace> get deploy,sts,ds,cronjob,rs,job,pod

Used for the snapshot

Read access to limitranges and resourcequotas

kubectl -n <namespace> get limitrange,resourcequota

Optional; a failure is logged and the run continues

Patch access to deployments, statefulsets, daemonsets, cronjobs

kubectl auth can-i patch deployments -n <namespace>

Only needed to run the generated patch script

The same cluster for pre and post

API server URL is recorded in the baseline

post refuses on a mismatch unless --force

The pre run must happen before the upgrade starts. A baseline taken after the upgrade has already lowered values cannot detect them.

How it works
The script snapshots the namespace twice, compares the two snapshots field by field, and turns every lowered value into a patch on the owning workload.

pre reads every Deployment, StatefulSet, DaemonSet and CronJob template and every live pod, and writes them to a baseline JSON file.

The upgrade runs.

post takes a fresh snapshot of the same namespace and compares it to the baseline, container by container, for requests.cpu, requests.memory, limits.cpu and limits.memory.

Patch generation. All changes for one workload go into one kubectl patch, so each workload restarts once.

You run the patch script, then run post again with the same baseline to confirm PATCH=0.

What each change leads to:

Change after upgrade

Action

What happens

Value lowered (e.g. 500m to 400m)

PATCH

Restored to the pre-upgrade value

Request removed

PATCH

Restored

Limit added where there was none

PATCH

Removed again (null), back to unbounded

Value raised

HIGHLIGHT

Reported only

Limit removed (now unbounded)

HIGHLIGHT

Reported only

Request added where there was none

HIGHLIGHT

Reported only

Lowered value on a pod with no Deployment/StatefulSet/DaemonSet/CronJob owner

REVIEW

Reported only; fix on its owner by hand

Running pod differs from its template

HIGHLIGHT

Pod not restarted yet, or a LimitRange default applied

Safety built into every run:

Read-only. pre and post only run kubectl get. The patch script is written to disk, never executed.

Same notation is not a change. 4Gi and 4096Mi compare as equal.

Patches are always valid. If a restored request would exceed the current limit, the limit is raised to match and the row is flagged LIMIT_RAISED_FOR_VALIDITY.

Wrong cluster is refused. post exits if the API server URL differs from the baseline.

Wrong namespace is refused. pre writes no baseline if the namespace has no workloads.

Hardcoded names. Every patch command carries the literal namespace, kind, workload and container name.

Usage
Run pre before the upgrade and post after it, once per namespace. Both are read-only and safe to repeat.



# before the upgrade
python3 pcd_resource_guard.py pre <namespace>
# after the upgrade
python3 pcd_resource_guard.py post --baseline pcd-resources-pre-<namespace>-<UTC timestamp>.json
# restore lowered values (review first)
bash pcd-resource-compare-<namespace>-<UTC timestamp>/patch_commands_<namespace>.sh
# verify: same baseline, expect PATCH=0
python3 pcd_resource_guard.py post --baseline pcd-resources-pre-<namespace>-<UTC timestamp>.json
Mode

Changes anything?

What it does

pre <namespace>

No

Captures the baseline JSON and a readable CSV

post --baseline <file>

No

Captures the current state, compares, writes the diff, summary and patch script

patch_commands_<namespace>.sh

Yes

Patches each workload with lowered values and waits for its rollout

Optional settings (not needed for normal use):

Option

Applies to

Use

--kubeconfig <path>

pre, post

Use a kubeconfig other than the default. post reuses the one recorded in the baseline

--out <basename>

pre

Name the baseline file yourself

--outdir <dir>

post

Name the output directory yourself

--force

post

Compare even if the cluster URL differs from the baseline

Exit code of post is 0 when nothing was lowered and 2 when the patch script has work to do.

Output files
Every file name carries the namespace, so files from different namespaces never mix. Read summary_<namespace>.txt first.

File

Written by

Use

pcd-resources-pre-<namespace>-<ts>.json

pre

The baseline. Keep it; post cannot run without it

pcd-resources-pre-<namespace>-<ts>.csv

pre

Readable copy of the baseline, one row per container

pcd-resource-compare-<namespace>-<ts>/summary_<namespace>.txt

post

Counts line, then every PATCH, REVIEW and HIGHLIGHT item

.../diff_<namespace>.csv

post

Every request/limit change with its action, for filtering or attaching

.../patch_commands_<namespace>.sh

post

Generated patch commands, not executed

.../post_snapshot_<namespace>.json / .csv

post

The post-upgrade state

pcd-resource-compare-<namespace>-<ts>.tar.gz

post

The whole output directory, ready to attach to a ticket or change record

In diff_<namespace>.csv, rows marked POD_DIFFERS_FROM_TEMPLATE hold the template value in pre and the running pod's value in post.

Example output
The outputs below are from a real test on support-july-test-r1 (13 Oct 2026). To simulate an upgrade lowering a value, the CPU limit of container socat18774 in nova-api-osapi was edited by hand from 500m to 400m between pre and post.

1. pre: baseline capture
64 workloads, 148 template containers and 69 live pods were captured. What to do next: keep the .json file and start the upgrade.



python3 pcd_resource_guard.py pre support-july-test-r1
[*] pre: support-july-test-r1
[+] Namespace: support-july-test-r1
[+] Cluster:   https://2374A1EBF7B12A7669C2EBB6C0BEBE99.gr7.us-west-2.eks.amazonaws.com
[+] Captured:  workloads=64  template_containers=148  live_pods=69  non_template_owners=0
[+] Baseline:  pcd-resources-pre-support-july-test-r1-20261013T100839Z.json
[+] Readable:  pcd-resources-pre-support-july-test-r1-20261013T100839Z.csv
    Keep the .json file; it is required for the post-upgrade run.
2. post: one lowered value found
The lowered CPU limit was the only change across all 148 containers. Exit code was 2. What to do next: review and run the patch script.



python3 pcd_resource_guard.py post --baseline pcd-resources-pre-support-july-test-r1-20261013T100839Z.json
[*] post: support-july-test-r1
PCD resource guard - post-upgrade comparison
Namespace: support-july-test-r1
Baseline:  pcd-resources-pre-support-july-test-r1-20261013T100839Z.json  (2026-10-13T10:08:39Z)
Post:      2026-10-13T10:12:27Z
Cluster:   https://2374A1EBF7B12A7669C2EBB6C0BEBE99.gr7.us-west-2.eks.amazonaws.com
PATCH=1  REVIEW=0  HIGHLIGHT=0  workloads_to_patch=1
--- PATCH (1)
  Deployment/nova-api-osapi main/socat18774 limits.cpu: 500m -> 400m  (DECREASED)
[+] Output: pcd-resource-compare-support-july-test-r1-20261013T101227Z/  ->  pcd-resource-compare-support-july-test-r1-20261013T101227Z.tar.gz
[+] Patch script: pcd-resource-compare-support-july-test-r1-20261013T101227Z/patch_commands_support-july-test-r1.sh  (review before running)
3. Generated patch script and its run
The script restored 500m and waited for the rollout. What to do next: run post again with the same baseline and confirm PATCH=0.



# --- support-july-test-r1 Deployment/nova-api-osapi
#     main/socat18774 limits.cpu: pre=500m post=400m (DECREASED)
kubectl -n support-july-test-r1 patch deployment nova-api-osapi --type=strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"socat18774","resources":{"limits":{"cpu":"500m"}}}]}}}}'
kubectl -n support-july-test-r1 rollout status deployment/nova-api-osapi --timeout=15m
echo "[+] support-july-test-r1: 1 workload(s) patched"


./pcd-resource-compare-support-july-test-r1-20261013T101227Z/patch_commands_support-july-test-r1.sh
deployment.apps/nova-api-osapi patched
Waiting for deployment "nova-api-osapi" rollout to finish: 0 of 1 updated replicas are available...
deployment "nova-api-osapi" successfully rolled out
[+] support-july-test-r1: 1 workload(s) patched
The verification post run after the patch has not been captured yet.

Reading results and troubleshooting
Start at the counts line of the summary: PATCH=0 means nothing was lowered. Otherwise read the PATCH, REVIEW and HIGHLIGHT lists below it, then the patch script.

Change

Action

Meaning / what to do

DECREASED

PATCH

Value lower than before. Run the patch script

REQUEST_REMOVED

PATCH

Request present before, gone now. Run the patch script

LIMIT_ADDED

PATCH

New limit where there was none. Patch removes it

LIMIT_RAISED_FOR_VALIDITY

PATCH

Restored request exceeded the current limit; limit set to the request

INCREASED

HIGHLIGHT

Value higher than before. Nothing to do unless unexpected

LIMIT_REMOVED

HIGHLIGHT

Container now unbounded. Confirm it is intended

REQUEST_ADDED

HIGHLIGHT

New request where there was none. Nothing to do

POD_DIFFERS_FROM_TEMPLATE

HIGHLIGHT

Running pod still has old values. Usually OnDelete or a rollout not finished; check kubectl rollout status

Any of the PATCH changes on a non-template owner

REVIEW

Pod owned by an operator custom resource, a standalone Job or no owner. Fix on the owner by hand

Messages you may see:

Message

Cause

What to do

[!] <namespace>: nothing captured - check the namespace name

No workloads in that namespace

Check kubectl get ns; no baseline was written

[!] CLUSTER MISMATCH

kube context points at another cluster

Switch context, or --force if intended

Baseline covers more than one namespace

Baseline from the earlier multi-namespace version

Re-capture with one namespace per pre

[!] kubectl ... failed

RBAC or connectivity

Run the printed command by hand to see the error

NOTE: OnDelete update strategy in the patch script

Workload does not roll pods on change

Delete its pods one at a time after patching

Not detected by design. Only CPU and memory requests and limits are compared. A workload or container that was renamed or removed by the upgrade has nothing to compare against and does not appear in the output.

Upgrade-day runbook (per namespace)
Capture before the management-plane upgrade, compare after it, restore, then verify. Repeat for each namespace being upgraded.

List namespaces. kubectl get ns. Note every namespace the upgrade will touch.

Capture the baseline. python3 pcd_resource_guard.py pre <namespace>. Check the Captured: counts look right; keep the .json file.

Run the upgrade.

Compare. python3 pcd_resource_guard.py post --baseline pcd-resources-pre-<namespace>-<ts>.json. Exit 0 means done; skip to step 7.

Review. Read summary_<namespace>.txt and patch_commands_<namespace>.sh. Pull out database and message-queue blocks (e.g. mysql, broker-cluster-server, ovn-ovsdb-*) to run by hand.

Restore. Run patch_commands_<namespace>.sh, or block by block. For OnDelete workloads, delete their pods one at a time.

Verify. Run post again with the same baseline. It must show PATCH=0 and no POD_DIFFERS_FROM_TEMPLATE rows.

Handle REVIEW items on their owners by hand, if any.

Keep the evidence. Attach the baseline .json and the pcd-resource-compare-*.tar.gz files to the change record
