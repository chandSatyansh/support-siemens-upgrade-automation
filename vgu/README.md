# vgu: vGPU PF-aware patch after the August 2026 upgrade

Tooling and procedure for the post-upgrade step **"Patch vGPU pf9-ostackhost-neutron Config (Required)"** from the [Support Team - August Release Upgrade Doc](https://platform9.atlassian.net/wiki/spaces/SUP/pages/6356697118/Support+Team+-+August+Release+Upgrade+Doc).

## Why the patch is needed

- Before 2026.8, a vGPU host's resmgr `mdev_config` held only the profile and `max_instances`, for example `[{"name":"mdev_nvidia-1148","max_instances":"24"}]`.
- From 2026.8, nova builds `device_addresses` per physical GPU (PF) and needs a `pf_address` on each entry. The upgrade cannot work out which profile belongs to which card, so it does not add it (PCD-9882).
- Without `pf_address`:
  - Multi-card hosts lose vGPU capacity in Placement, and VMs on the other cards become unmanaged.
  - Single-card hosts keep their capacity but the UI does not show the per-PF configuration.
- The patch adds `pf_address` to the existing `mdev_config` through the resmgr API. It touches no other host config.

## Which hosts need it

Only hosts where **all** of these are true:

1. The host is on 2026.8 (DU upgrade and host upgrade both complete).
2. resmgr `pf9-ostackhost-neutron` role has a non-empty `mdev_config`.
3. That `mdev_config` has no `pf_address`.

Hosts that do **not** need it:

| Host type | Why |
|---|---|
| GPU passthrough only | No `mdev_config` |
| GPU host with no vGPU profile assigned (`mdev_config` empty, 0 vGPU RPs in Placement) | Nothing to patch. A profile assigned later from the 2026.8 UI is PF-aware already |
| `mdev_config` already has `pf_address` | Already patched or configured from the 2026.8 UI |

## Files

| File | Purpose |
|---|---|
| `ubuntu22_vgpu_configure.sh` | Official patch script from the Confluence page. Patches one host |
| `vgpu_pf_patch_fleet.sh` | Optional fleet wrapper. Discovers hosts, derives PFs over SSH, dry-runs by default |

## Prerequisites

| Requirement | Check |
|---|---|
| bash, curl, jq on the machine you run from | `jq --version` |
| Network access to the region DU (`https://<du-fqdn>`) | `curl -sk https://$FQDN/keystone/v3` |
| Admin keystone token for the region | see Step 1 |
| `openstack` CLI configured for the region (Placement check) | `openstack resource provider list -f value -c name \| head` |
| kubectl access to the management cluster (only to read the admin password) | `kubectl -n $NS get secret keystone-keystone-admin` |
| SSH to hypervisors (only for host verification or the fleet wrapper) | `ssh pf9@<host> hostname` |

zsh note: interactive zsh does not treat `#` as a comment. Run `setopt interactivecomments` first, or do not paste comment lines.

## Procedure (API only, no host access needed)

All discovery steps are read-only.

### 1. Set the region and get a token

```bash
setopt interactivecomments 2>/dev/null
export FQDN=<du-fqdn>
export NS=<region-namespace>
export AUTH_TOKEN=$(openstack token issue -f value -c id)
curl -sk -H "X-Auth-Token: $AUTH_TOKEN" "https://$FQDN/resmgr/v1/hosts" | jq length
```

The last command must print a number. A 401 or empty output means the token or FQDN is wrong.

### 2. List GPU hosts and their PF

resmgr gets GPU inventory from the hostagent `gpu_info` extension. In `extensions.gpu_info.data.gpu_pci[]` the entry with `is_virtualfunction == true` is the **PF** (the flag is inverted: the VFs are the entries marked `false`).

```bash
curl -sk -H "X-Auth-Token: $AUTH_TOKEN" "https://$FQDN/resmgr/v1/hosts" \
| jq -r '.[] | select(.extensions.gpu_info.data.gpu_pci // [] | length > 0)
  | [.id, .info.hostname,
     ([.extensions.gpu_info.data.gpu_pci[].Model]|unique|join("/")),
     "total=\(.extensions.gpu_info.data.gpu_pci|length)",
     "pf=\([.extensions.gpu_info.data.gpu_pci[]|select(.is_virtualfunction==true)|.pcd_bus_id]|join(","))"]
  | @tsv' | sort -k2
```

`total` is 1 PF plus its VFs per card (for example 33 for one L40S, 49 for one RTX PRO 6000 Blackwell). More than one `pf` value means a multi-card host.

### 3. Check resmgr vGPU config per host

```bash
curl -sk -H "X-Auth-Token: $AUTH_TOKEN" "https://$FQDN/resmgr/v1/hosts" \
| jq -r '.[] | select((.roles // []) | index("pf9-ostackhost-neutron")) | "\(.id) \(.info.hostname)"' \
| while read id hn; do
    r=$(curl -sk -H "X-Auth-Token: $AUTH_TOKEN" "https://$FQDN/resmgr/v1/hosts/$id/roles/pf9-ostackhost-neutron")
    echo "$hn | mdev_config=$(jq -c '.mdev_config // null' <<<"$r") | enabled_mdev_types=$(jq -c '.enabled_mdev_types // null' <<<"$r")"
  done
```

### 4. Check vGPU inventory in Placement

```bash
openstack --os-placement-api-version 1.14 resource provider list -f json > /tmp/rp.json
for hn in <host1> <host2> <host3>; do
  echo "$hn  vgpu_rps=$(jq --arg h "$hn" '[.[]|select((.name|startswith($h)) and (.name|test("_pci_")))]|length' /tmp/rp.json)"
done
```

Use short hostnames as they appear in Placement (for example `snnhv0064`).

### 5. Decide per host

| Step 3 `mdev_config` | Step 4 vGPU RPs | Action |
|---|---|---|
| set, no `pf_address` | > 0 | **Patch** |
| set, has `pf_address` | any | Nothing to do |
| empty | 0 | Nothing to do (no profile assigned) |
| empty | > 0 | **Stop.** vGPU configured outside resmgr. Raise with Engineering (PCD-9882 owners) before upgrading |

### 6. Generate the patch commands

Prints one `ubuntu22_vgpu_configure.sh` command per host that needs the patch, with the PF from Step 2:

```bash
curl -sk -H "X-Auth-Token: $AUTH_TOKEN" "https://$FQDN/resmgr/v1/hosts" \
| jq -c '.[] | select((.roles//[])|index("pf9-ostackhost-neutron"))
  | {id, hn:.info.hostname, pf:([.extensions.gpu_info.data.gpu_pci[]?|select(.is_virtualfunction==true)|.pcd_bus_id]|join(","))}' \
| while read -r h; do
    id=$(jq -r .id <<<"$h"); hn=$(jq -r .hn <<<"$h"); pf=$(jq -r .pf <<<"$h")
    mc=$(curl -sk -H "X-Auth-Token: $AUTH_TOKEN" "https://$FQDN/resmgr/v1/hosts/$id/roles/pf9-ostackhost-neutron" | jq -r '.mdev_config // ""')
    [[ -z "$mc" || "$mc" == "[]" ]] && continue
    grep -q pf_address <<<"$mc" && { echo "# $hn already PF-aware"; continue; }
    echo "# $hn  current: $mc"
    echo "./ubuntu22_vgpu_configure.sh $FQDN \"\$AUTH_TOKEN\" $id \"$pf\""
  done
```

Review the output before running anything:

- A host with more than one PF and more than one profile in `mdev_config` cannot be patched with this script (it applies the first profile to every PF). Handle it manually.
- A host that also has passthrough GPUs: remove the passthrough PF from the list.

### 7. (Optional) Verify on the host, read-only

```bash
ssh pf9@<host>
nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv
cat /sys/bus/pci/devices/<pf>/sriov_numvfs
sudo mdevctl list
grep -n -A3 '^\[devices\]' /opt/pf9/etc/nova/conf.d/nova.conf
grep -n '^\[mdev_\|mdev_config\|device_addresses' /opt/pf9/etc/nova/conf.d/nova.conf
dpkg -l | grep -E 'pf9-ostackhost|pf9-hostagent'
```

Confirm the GPU Bus-Id matches the PF from Step 2, every mdev parent VF belongs to that PF, and `max_instances` in `mdev_config` matches the per-card maximum for the profile (`cat /sys/bus/pci/devices/<vf>/mdev_supported_types/<type>/description`).

### 8. Patch (change window, only after the host is on 2026.8)

Run the commands from Step 6 one host at a time. The script asks for a yes/no confirmation that the host is upgraded.

```bash
./ubuntu22_vgpu_configure.sh $FQDN "$AUTH_TOKEN" <host-uuid> "<pf>"
```

Expected `mdev_config AFTER PUT` for a single-card host:

```json
[
  {
    "name": "mdev_nvidia-1148",
    "max_instances": "24",
    "pf_address": "0000:21:00.0"
  }
]
```

### 9. Verify

```bash
curl -sk -H "X-Auth-Token: $AUTH_TOKEN" "https://$FQDN/resmgr/v1/hosts/<host-uuid>/roles/pf9-ostackhost-neutron" | jq -r '.mdev_config'
```

Re-run Step 4 for the patched hosts once hostagent has converged. The vGPU RP count must not drop. If it drops, stop and investigate before patching the next host.

## Fleet wrapper (optional, needs SSH)

`vgpu_pf_patch_fleet.sh` automates discovery and patching across a region. It derives PFs and per-PF profiles from the host over SSH (sysfs and `mdevctl`), so it can handle multi-profile hosts the official script cannot.

```bash
export AUTH_TOKEN=$(openstack token issue -f value -c id)
./vgpu_pf_patch_fleet.sh <du-fqdn>
./vgpu_pf_patch_fleet.sh <du-fqdn> --host <host-uuid>
./vgpu_pf_patch_fleet.sh <du-fqdn> --host <host-uuid> --apply --orig ./ubuntu22_vgpu_configure.sh
```

The first two are dry runs (whole region, one host). The third patches one host through the official script.

Options: `--apply` (write), `--host <uuid>` (one host), `--ssh-user <user>` (default `pf9`), `--orig <path>` (send the PUT through the official script, single-profile hosts only). Env: `TARGET_VER` (default `2026.8`).

Output: `vgpu_pf_patch_<fqdn>_<ts>/report.csv` plus per-host `before.json`, `host.txt`, `proposed_mdev_config.json`, `after.json`.

| Status | Meaning |
|---|---|
| SKIP | No `mdev_config`, or already PF-aware |
| BLOCKED | `role_status` not ok, SSH failed, or pf9-ostackhost not on `TARGET_VER` |
| MANUAL | A PF cannot be mapped to exactly one profile |
| DRYRUN | Proposed `mdev_config` shown, nothing written |
| PATCHED | PUT done and re-GET confirms `pf_address` on every entry |
| FAILED | PUT non-2xx or verification failed |

## Example: disw-eu-snn-lab

| Hosts | GPU | PF | vGPU RPs | `mdev_config` | Action |
|---|---|---|---|---|---|
| snnhv0064, 0068, 0069 | L40S | 0000:21:00.0 | 24 | `mdev_nvidia-1148` / 24, no `pf_address` | Patch |
| snnhv0067 | L40S | 0000:21:00.0 | 0 | empty | None |
| snnhv0356 to 0375 (20 hosts) | RTX PRO 6000 Blackwell | 0000:ed:00.0 | 0 | empty | None |

## References

- PCD-9882: root cause, before/after `nova.conf` from the patch test
- Slack `#-siemens` thread with Shweta Chavan confirming the patch is still required after the 2026.AUG fix
- pf9-nova #512 / #515: honour `pf_address` on Ubuntu 22 SR-IOV hosts