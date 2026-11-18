#!/usr/bin/env python3
"""
pcd_resource_guard.py
Detect CPU/memory request/limit regressions across a PCD upgrade and generate
kubectl patch commands to restore pre-upgrade values.

One namespace per run. Repeat for each namespace being upgraded.

  1) Before the upgrade:
       python3 pcd_resource_guard.py pre <ns>
     -> pcd-resources-pre-<ns>-<ts>.json   (baseline; keep this file)
        pcd-resources-pre-<ns>-<ts>.csv    (human-readable)

  2) After the upgrade:
       python3 pcd_resource_guard.py post --baseline pcd-resources-pre-<ns>-<ts>.json
     -> pcd-resource-compare-<ns>-<ts>/
          post_snapshot_<ns>.json / .csv
          diff_<ns>.csv            every change, with action taken
                                   (POD_DIFFERS_FROM_TEMPLATE rows: pre=template value, post=pod value)
          patch_commands_<ns>.sh   generated, NOT executed - review then run
          summary_<ns>.txt
        pcd-resource-compare-<ns>-<ts>.tar.gz

Scope:
  Templates  Deployment, StatefulSet, DaemonSet, CronJob (init, sidecar, main containers)
             -> lowered values are patched back.
  Other pods pods not owned by the above (standalone pods, standalone Jobs, orphan
             ReplicaSets, operator CRs) -> compared by owner+container; lowered values
             flagged REVIEW (no template to patch).
  Live pods  post-upgrade, every running pod is checked against its template
             (catches OnDelete/not-yet-rolled pods and LimitRange-injected values).

Policy:
  PATCH      value lowered | request removed | limit newly added (was unbounded)
             -> restored to pre-upgrade state
  REVIEW     same as PATCH but on pods with no patchable template
  HIGHLIGHT  value increased | limit removed | request newly added |
             live pod's resources differ from its template
  Only CPU/memory requests and limits are reported. Workloads/containers present on
  only one side (added, removed, renamed) are not compared.

Exit code: 0 = no regressions, 2 = patch commands generated.
Requirements: kubectl, python3 (stdlib only).
"""
import argparse
import copy
import csv
import json
import os
import subprocess
import sys
import tarfile
from collections import Counter, defaultdict
from datetime import datetime, timezone

KINDS = "deployments,statefulsets,daemonsets,cronjobs"
RES_NAME = {"Deployment": "deployment", "StatefulSet": "statefulset",
            "DaemonSet": "daemonset", "CronJob": "cronjob"}
FIELDS = [("requests", "cpu"), ("requests", "memory"), ("limits", "cpu"), ("limits", "memory")]

# --------------------------------------------------------------------------- #
# Quantities
# --------------------------------------------------------------------------- #
CPU_SUFFIX = {"n": 1e-6, "u": 1e-3, "m": 1.0}
MEM_BIN = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "Pi": 2**50, "Ei": 2**60}
MEM_DEC = {"k": 1e3, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "P": 1e15, "E": 1e18, "m": 1e-3}


def cpu_m(q):
    if q in (None, ""):
        return None
    q = str(q)
    if q[-1] in CPU_SUFFIX:
        return float(q[:-1]) * CPU_SUFFIX[q[-1]]
    return float(q) * 1000.0


def mem_b(q):
    if q in (None, ""):
        return None
    q = str(q)
    if q[-2:] in MEM_BIN:
        return float(q[:-2]) * MEM_BIN[q[-2:]]
    if q[-1] in MEM_DEC:
        return float(q[:-1]) * MEM_DEC[q[-1]]
    return float(q)


def qty(resource, q):
    return cpu_m(q) if resource == "cpu" else mem_b(q)


def lt(a, b):
    return a < b - 1e-9


# --------------------------------------------------------------------------- #
# kubectl
# --------------------------------------------------------------------------- #
class Kube:
    def __init__(self, kubeconfig=None):
        self.kubeconfig = kubeconfig
        self.base = ["kubectl"] + (["--kubeconfig", kubeconfig] if kubeconfig else [])

    def run(self, args, fatal=True):
        p = subprocess.run(self.base + args, capture_output=True, text=True)
        if p.returncode != 0:
            msg = f"[!] {' '.join(self.base + args)} failed: {p.stderr.strip()}"
            if fatal:
                sys.exit(msg)
            print(msg, file=sys.stderr)
            return None
        return p.stdout

    def get(self, what, ns, fatal=True):
        out = self.run(["get", what, "-n", ns, "-o", "json"], fatal)
        return json.loads(out)["items"] if out else []

    def server(self):
        out = self.run(["config", "view", "--minify", "-o",
                        "jsonpath={.clusters[0].cluster.server}"], fatal=False)
        return (out or "").strip()

    def cmd_prefix(self):
        return "kubectl" + (f" --kubeconfig {self.kubeconfig}" if self.kubeconfig else "")


# --------------------------------------------------------------------------- #
# Snapshot
# --------------------------------------------------------------------------- #
def pod_spec(o):
    s = o["spec"]
    return s["jobTemplate"]["spec"]["template"]["spec"] if o["kind"] == "CronJob" else s["template"]["spec"]


def strategy(o):
    s = o["spec"]
    if o["kind"] == "Deployment":
        return (s.get("strategy") or {}).get("type", "RollingUpdate")
    if o["kind"] in ("StatefulSet", "DaemonSet"):
        return (s.get("updateStrategy") or {}).get("type", "RollingUpdate")
    return ""


def replicas(o):
    if o["kind"] == "DaemonSet":
        return (o.get("status") or {}).get("desiredNumberScheduled", 0)
    if o["kind"] == "CronJob":
        return o["spec"]["jobTemplate"]["spec"].get("parallelism", 1)
    return o["spec"].get("replicas", 1)


def containers_of(ps):
    out = {}
    items = [("sidecar" if c.get("restartPolicy") == "Always" else "init", c)
             for c in ps.get("initContainers") or []] + [("main", c) for c in ps.get("containers") or []]
    for t, c in items:
        r = c.get("resources") or {}
        out[f"{t}/{c['name']}"] = {"type": t, "name": c["name"], "image": c.get("image", ""),
                                   "requests": r.get("requests") or {}, "limits": r.get("limits") or {}}
    return out


def uncovered(snap):
    """Owners of live pods that are not template-managed workloads -> one representative pod each."""
    out = {}
    for key in sorted(snap["pods"]):
        p = snap["pods"][key]
        if p["owner"] in snap["workloads"] or p["owner"] in out:
            continue
        out[p["owner"]] = {"namespace": p["namespace"], "kind": p["owner_kind"], "name": p["owner_name"],
                           "replicas": sum(1 for q in snap["pods"].values() if q["owner"] == p["owner"]),
                           "update_strategy": "", "containers": p["containers"]}
    return out


def snapshot(kube, namespaces, phase):
    snap = {"meta": {"phase": phase,
                     "taken_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                     "cluster_server": kube.server(),
                     "kubeconfig": kube.kubeconfig,
                     "namespaces": namespaces},
            "workloads": {}, "pods": {}, "limitranges": {}, "resourcequotas": {}}
    for ns in namespaces:
        print(f"[*] {phase}: {ns}")
        for o in kube.get(KINDS, ns):
            key = f"{ns}/{o['kind']}/{o['metadata']['name']}"
            snap["workloads"][key] = {
                "namespace": ns, "kind": o["kind"], "name": o["metadata"]["name"],
                "replicas": replicas(o), "update_strategy": strategy(o),
                "containers": containers_of(pod_spec(o))}
        # live pods, resolved to top-level owner (RS -> Deployment, Job -> CronJob)
        parent = {}
        for o in kube.get("replicasets,jobs", ns):
            refs = o["metadata"].get("ownerReferences") or []
            if refs:
                parent[(o["kind"], o["metadata"]["name"])] = (refs[0]["kind"], refs[0]["name"])
        for p in kube.get("pods", ns):
            md, st = p["metadata"], p.get("status") or {}
            if st.get("phase") in ("Succeeded", "Failed"):
                continue
            refs = md.get("ownerReferences") or []
            ok, on = (refs[0]["kind"], refs[0]["name"]) if refs else ("Pod", md["name"])
            while (ok, on) in parent:
                ok, on = parent[(ok, on)]
            snap["pods"][f"{ns}/{md['name']}"] = {
                "namespace": ns, "pod": md["name"], "owner": f"{ns}/{ok}/{on}",
                "owner_kind": ok, "owner_name": on, "phase": st.get("phase", ""),
                "containers": containers_of(p["spec"])}
        snap["limitranges"][ns] = {o["metadata"]["name"]: o.get("spec", {})
                                   for o in kube.get("limitranges", ns, fatal=False)}
        snap["resourcequotas"][ns] = {o["metadata"]["name"]: (o.get("spec") or {}).get("hard", {})
                                      for o in kube.get("resourcequotas", ns, fatal=False)}
    return snap


def write_snapshot_csv(snap, path):
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["namespace", "kind", "name", "replicas", "update_strategy", "container_type",
                    "container", "image", "cpu_request", "cpu_limit", "mem_request", "mem_limit"])
        for key in sorted(snap["workloads"]):
            wl = snap["workloads"][key]
            for c in wl["containers"].values():
                w.writerow([wl["namespace"], wl["kind"], wl["name"], wl["replicas"], wl["update_strategy"],
                            c["type"], c["name"], c["image"],
                            c["requests"].get("cpu", ""), c["limits"].get("cpu", ""),
                            c["requests"].get("memory", ""), c["limits"].get("memory", "")])


# --------------------------------------------------------------------------- #
# Compare
# --------------------------------------------------------------------------- #
LOWERED = ("DECREASED", "REQUEST_REMOVED", "LIMIT_ADDED")


def compare_set(pw, qw, patchable, rows, patches):
    """
    rows:    [ns, kind, name, ctype, container, field, pre, post, change, action]
    patches: wl_key -> {ckey: {"requests":{}, "limits":{}}}  (only when patchable)
    """
    lowered_action = "PATCH" if patchable else "REVIEW"

    def row(wl, ckey, field, a, b, change):
        ctype, cname = ckey.split("/", 1) if ckey else ("", "")
        act = lowered_action if change in LOWERED else "HIGHLIGHT"
        rows.append([wl["namespace"], wl["kind"], wl["name"], ctype, cname, field,
                     "" if a is None else a, "" if b is None else b, change, act])

    for key in sorted(set(pw) | set(qw)):
        a, b = pw.get(key), qw.get(key)
        if not (a and b):
            continue  # workload only on one side: no resource comparison possible
        for ckey in sorted(set(a["containers"]) & set(b["containers"])):
            ca, cb = a["containers"][ckey], b["containers"][ckey]

            fix = {"requests": {}, "limits": {}}
            for sect, r in FIELDS:
                va, vb = ca[sect].get(r), cb[sect].get(r)
                field = f"{sect}.{r}"
                if va == vb:
                    continue
                if va is not None and vb is not None:
                    qa, qb = qty(r, va), qty(r, vb)
                    if lt(qb, qa):
                        row(b, ckey, field, va, vb, "DECREASED")
                        fix[sect][r] = va
                    elif lt(qa, qb):
                        row(b, ckey, field, va, vb, "INCREASED")
                    # same quantity, different notation (4Gi vs 4096Mi) -> not a change
                elif va is not None:
                    if sect == "requests":
                        row(b, ckey, field, va, None, "REQUEST_REMOVED")
                        fix[sect][r] = va
                    else:
                        row(b, ckey, field, va, None, "LIMIT_REMOVED")
                else:
                    if sect == "limits":
                        row(b, ckey, field, None, vb, "LIMIT_ADDED")
                        fix[sect][r] = None          # null deletes the field (strategic merge)
                    else:
                        row(b, ckey, field, None, vb, "REQUEST_ADDED")

            # safety guard: resulting request must not exceed resulting limit
            for r in ("cpu", "memory"):
                req = fix["requests"].get(r)
                if req is None:
                    continue
                lim = fix["limits"][r] if r in fix["limits"] else cb["limits"].get(r)
                if lim is not None and lt(qty(r, lim), qty(r, req)):
                    fix["limits"][r] = req
                    rows.append([b["namespace"], b["kind"], b["name"], *ckey.split("/", 1), f"limits.{r}",
                                 ca["limits"].get(r) or "", cb["limits"].get(r) or "",
                                 "LIMIT_RAISED_FOR_VALIDITY", lowered_action])

            fix = {s: v for s, v in fix.items() if v}
            if fix and patchable:
                patches.setdefault(key, {})[ckey] = fix


def expected(tmpl_c, sect, r):
    """Value the API server would put on the pod: request defaults to limit if unset."""
    v = tmpl_c[sect].get(r)
    if v is None and sect == "requests":
        v = tmpl_c["limits"].get(r)
    return v


def drift(snap, rows):
    """Live pods whose container resources differ from their controller's current template."""
    grp = defaultdict(list)
    for key in sorted(snap["pods"]):
        p = snap["pods"][key]
        wl = snap["workloads"].get(p["owner"])
        if not wl:
            continue
        for ckey, tc in wl["containers"].items():
            pc = p["containers"].get(ckey)
            if not pc:
                continue
            for sect, r in FIELDS:
                tv, pv = expected(tc, sect, r), pc[sect].get(r)
                same = (tv == pv) or (tv is not None and pv is not None and
                                      not lt(qty(r, tv), qty(r, pv)) and not lt(qty(r, pv), qty(r, tv)))
                if not same:
                    grp[(p["owner"], ckey, f"{sect}.{r}", tv or "", pv or "")].append(p["pod"])
    for (owner, ckey, field, tv, pv), pods in sorted(grp.items()):
        wl = snap["workloads"][owner]
        ctype, cname = ckey.split("/", 1)
        rows.append([wl["namespace"], wl["kind"], wl["name"], ctype, cname, field, tv, pv,
                     "POD_DIFFERS_FROM_TEMPLATE",
                     f"HIGHLIGHT ({len(pods)} pod(s): {' '.join(pods)})"])


def compare(pre, post):
    rows, patches = [], {}
    compare_set(pre["workloads"], post["workloads"], True, rows, patches)
    compare_set(uncovered(pre), uncovered(post), False, rows, patches)
    drift(post, rows)
    return rows, patches


def patch_body(kind, cmap):
    spec = defaultdict(list)
    for ckey, resources in cmap.items():
        ctype, cname = ckey.split("/", 1)
        spec["containers" if ctype == "main" else "initContainers"].append(
            {"name": cname, "resources": resources})
    tmpl = {"spec": dict(spec)}
    if kind == "CronJob":
        return {"spec": {"jobTemplate": {"spec": {"template": tmpl}}}}
    return {"spec": {"template": tmpl}}


def gen_script(kube, post, rows, patches, path, baseline_name, ns):
    pfx = kube.cmd_prefix()
    wls = post["workloads"]
    patches = {k: v for k, v in patches.items() if wls[k]["namespace"] == ns}
    L = ["#!/usr/bin/env bash",
         f"# Generated by pcd_resource_guard.py  {post['meta']['taken_at']}",
         f"# Namespace: {ns}",
         f"# Baseline: {baseline_name}",
         f"# Cluster:  {post['meta']['cluster_server']}",
         "#",
         "# Restores CPU/memory requests/limits that were lowered by the upgrade.",
         "#  - Each patch triggers a rolling restart (except OnDelete workloads).",
         "#  - StatefulSets (MySQL/Galera, RabbitMQ, ...) are last; confirm",
         "#    cluster health before moving to the next one.",
         "#  - After running, re-run 'post' with the same baseline: PATCH should be 0 and",
         "#    POD_DIFFERS_FROM_TEMPLATE should be empty once all pods have rolled.",
         "set -euo pipefail", ""]
    order = {"Deployment": 0, "DaemonSet": 1, "CronJob": 2, "StatefulSet": 3}
    for key in sorted(patches, key=lambda k: (wls[k]["namespace"], order[wls[k]["kind"]], wls[k]["name"])):
        wl, cmap = wls[key], patches[key]
        res = RES_NAME[wl["kind"]]
        L.append(f"# --- {wl['namespace']} {wl['kind']}/{wl['name']}")
        for r in rows:
            if r[9] == "PATCH" and (r[0], r[1], r[2]) == (wl["namespace"], wl["kind"], wl["name"]):
                L.append(f"#     {r[3]}/{r[4]} {r[5]}: pre={r[6] or 'unset'} post={r[7] or 'unset'} ({r[8]})")
        body = json.dumps(patch_body(wl["kind"], cmap), separators=(",", ":"))
        L.append(f"{pfx} -n {wl['namespace']} patch {res} {wl['name']} --type=strategic -p '{body}'")
        if wl["kind"] != "CronJob":
            if wl["update_strategy"] == "OnDelete":
                L.append(f"# NOTE: OnDelete update strategy - existing pods keep old values until deleted.")
            else:
                L.append(f"{pfx} -n {wl['namespace']} rollout status {res}/{wl['name']} --timeout=15m")
        L.append("")
    if not patches:
        L.append(f"# {ns}: no lowered values on template-managed workloads - nothing to patch.")
    else:
        L.append(f'echo "[+] {ns}: {len(patches)} workload(s) patched"')
    with open(path, "w") as fh:
        fh.write("\n".join(L) + "\n")
    os.chmod(path, 0o755)


def compare_policies(pre, post):
    lines = []
    for kind in ("limitranges", "resourcequotas"):
        for ns in pre["meta"]["namespaces"]:
            a, b = pre[kind].get(ns, {}), post[kind].get(ns, {})
            for name in sorted(set(a) | set(b)):
                if a.get(name) != b.get(name):
                    state = "added" if name not in a else "removed" if name not in b else "changed"
                    lines.append(f"  {ns} {kind[:-1]}/{name}: {state}")
    return lines


# --------------------------------------------------------------------------- #
# Entry points
# --------------------------------------------------------------------------- #
def cmd_pre(a):
    ns = a.namespace
    kube = Kube(a.kubeconfig)
    snap = snapshot(kube, [ns], "pre")
    ts = snap["meta"]["taken_at"].replace("-", "").replace(":", "")
    base = a.out or f"pcd-resources-pre-{ns}-{ts}"
    wl = snap["workloads"].values()
    if not wl:
        sys.exit(f"[!] {ns}: nothing captured - check the namespace name. No baseline written.")
    with open(base + ".json", "w") as fh:
        json.dump(snap, fh, indent=2)
    write_snapshot_csv(snap, base + ".csv")
    print(f"\n[+] Namespace: {ns}")
    print(f"[+] Cluster:   {snap['meta']['cluster_server']}")
    print(f"[+] Captured:  workloads={len(wl)}  template_containers={sum(len(w['containers']) for w in wl)}  "
          f"live_pods={len(snap['pods'])}  non_template_owners={len(uncovered(snap))}")
    print(f"[+] Baseline:  {base}.json")
    print(f"[+] Readable:  {base}.csv")
    print("    Keep the .json file; it is required for the post-upgrade run.")


def cmd_post(a):
    with open(a.baseline) as fh:
        pre = json.load(fh)
    if len(pre["meta"]["namespaces"]) != 1:
        sys.exit("[!] Baseline covers more than one namespace; re-capture one namespace per baseline.")
    ns = pre["meta"]["namespaces"][0]
    kube = Kube(a.kubeconfig or pre["meta"].get("kubeconfig"))
    post = snapshot(kube, [ns], "post")

    warn = []
    if pre["meta"]["cluster_server"] != post["meta"]["cluster_server"]:
        warn.append(f"CLUSTER MISMATCH: baseline={pre['meta']['cluster_server']} "
                    f"current={post['meta']['cluster_server']}")
        if not a.force:
            sys.exit(f"[!] {warn[0]}\n    Re-run with --force if this is intended.")

    ts = post["meta"]["taken_at"].replace("-", "").replace(":", "")
    outdir = (a.outdir or f"pcd-resource-compare-{ns}-{ts}").rstrip("/")
    os.makedirs(outdir, exist_ok=True)
    out = lambda name: os.path.join(outdir, name)

    with open(out(f"post_snapshot_{ns}.json"), "w") as fh:
        json.dump(post, fh, indent=2)
    write_snapshot_csv(post, out(f"post_snapshot_{ns}.csv"))

    rows, patches = compare(pre, post)
    with open(out(f"diff_{ns}.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["namespace", "kind", "name", "container_type", "container", "field",
                    "pre", "post", "change", "action"])
        w.writerows(rows)
    script = out(f"patch_commands_{ns}.sh")
    gen_script(kube, post, rows, patches, script, os.path.basename(a.baseline), ns)

    c = Counter(r[9].split(" ")[0] for r in rows)
    S = ["PCD resource guard - post-upgrade comparison",
         f"Namespace: {ns}",
         f"Baseline:  {os.path.basename(a.baseline)}  ({pre['meta']['taken_at']})",
         f"Post:      {post['meta']['taken_at']}",
         f"Cluster:   {post['meta']['cluster_server']}"]
    S += [f"WARNING: {x}" for x in warn]
    S += ["", f"PATCH={c['PATCH']}  REVIEW={c['REVIEW']}  HIGHLIGHT={c['HIGHLIGHT']}  "
              f"workloads_to_patch={len(patches)}"]
    if not rows:
        S += ["", "No request/limit changes."]
    for act in ("PATCH", "REVIEW", "HIGHLIGHT"):
        sel = [r for r in rows if r[9].split(" ")[0] == act]
        if not sel:
            continue
        S += ["", f"--- {act} ({len(sel)})"]
        for r in sel:
            extra = r[9][len(act):].strip()
            vals = (f"template={r[6] or 'unset'} pod={r[7] or 'unset'}"
                    if r[8] == "POD_DIFFERS_FROM_TEMPLATE" else f"{r[6] or 'unset'} -> {r[7] or 'unset'}")
            S.append(f"  {r[1]}/{r[2]} {r[3]}/{r[4]} {r[5]}: {vals}  ({r[8]})"
                     f"{'  ' + extra if extra else ''}")
    pol = compare_policies(pre, post)
    if pol:
        S += ["", "--- LimitRange / ResourceQuota changes (affect containers with unset values)"]
        S += ["  " + x.split(" ", 1)[1] for x in pol]
    summary = "\n".join(S)
    with open(out(f"summary_{ns}.txt"), "w") as fh:
        fh.write(summary + "\n")

    with tarfile.open(outdir + ".tar.gz", "w:gz") as t:
        t.add(outdir, arcname=os.path.basename(outdir))

    print("\n" + summary)
    print(f"\n[+] Output: {outdir}/  ->  {outdir}.tar.gz")
    print(f"[+] Patch script: {script}  (review before running)")
    sys.exit(2 if patches else 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pre", help="capture pre-upgrade baseline")
    p.add_argument("namespace", help="namespace to capture (one per run)")
    p.add_argument("--kubeconfig")
    p.add_argument("--out", help="output basename (default pcd-resources-pre-<ns>-<ts>)")
    q = sub.add_parser("post", help="capture post-upgrade state, compare, generate patches")
    q.add_argument("--baseline", required=True, help="pre-upgrade .json")
    q.add_argument("--kubeconfig", help="default: kubeconfig recorded in baseline")
    q.add_argument("--outdir")
    q.add_argument("--force", action="store_true", help="proceed despite cluster URL mismatch")
    a = ap.parse_args()
    cmd_pre(a) if a.cmd == "pre" else cmd_post(a)


if __name__ == "__main__":
    main()
