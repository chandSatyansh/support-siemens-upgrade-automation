Overview
ovn_wait_apply.sh sets one OVS value, external_ids:ovn-ofctrl-wait-before-clear=180000, on every hypervisor of a PCD region and proves it took effect. Run it after the management plane upgrade and before triggering host upgrades.

One command per region. ./ovn_wait_apply.sh check <namespace> reports status; ./ovn_wait_apply.sh <namespace> applies the change.

No host IDs or host lists needed. Hosts come from the region's resmgr database; the jump host is chosen automatically.

Only hosts that still need it are changed. Hosts already at "180000" receive no write command.

Every run ends with a verdict: PREREQUISITE MET, or NOT MET plus a list of exactly which hosts need manual attention and how to fix them.

Why this change
On large OVN regions [regions with high count of hosts] every hypervisor must have ovn-ofctrl-wait-before-clear set to 180000 before its host upgrade starts. 

What it does: when ovn-controller restarts (as it does during a host upgrade), it waits up to 180000 ms (3 minutes) before clearing the existing OpenFlow flows. The old flows keep forwarding traffic while the new ones are computed.

Why large regions need it: on regions with hundreds of hosts, recomputing flows can take long enough that clearing them immediately causes a dataplane gap for VMs on that host.

Where it lives: the OVS database (external_ids of the Open_vSwitch table). It persists across OVS and ovn-controller restarts and reboots; no service restart is needed when setting it.

Manual equivalent, per host:



sudo ovs-vsctl set open . external_ids:ovn-ofctrl-wait-before-clear=180000
sudo ovs-vsctl get open . external_ids:ovn-ofctrl-wait-before-clear     # "180000"
Prerequisites
You need kubectl access to the region's management-plane namespace and at least one responding ARS host in that region. Everything else is checked by the script.

Requirement

How to confirm

Notes

Workstation with bash, kubectl, base64, awk, sed, mktemp

bash --version

macOS default bash 3.2 works; Linux works

kube context pointing at the PCD management plane

kubectl -n <namespace> get deploy forwarder mysql

Both deployments must be listed

Read access to the mysql secret and exec into deploy/mysql and deploy/forwarder

kubectl -n <namespace> get secret mysql

Used to read hostnames from resmgr and to reach hosts

At least one ARS host (pf9-support role) that is responding

Script prints ARS jump candidates: N

The script tries ARS hosts in order and skips unusable ones

pf9 on the jump host can ssh to other hosts by FQDN only

All Siemens regions hosts' are able to connect via SSH with their FQDNs

No key setup needed

pf9 has passwordless sudo for ovs-vsctl on every host

A check run with fail=0 proves get; set uses the same sudo

Failures show as GET-FAILED / SET-FAILED

Management plane already upgraded

Upgrade plan

This is a host-upgrade prerequisite

The script reads the MySQL password from the secret and passes it on stdin, so it never appears on a command line or in logs.

How it works
The script reads the region's host list from resmgr, opens one forwarder session to an ARS host, and from there reaches every hypervisor by ssh. Non-ARS hosts are covered the same way.

ovn_wait_apply_how_it_works.png
Safety built into every run:

Nothing changes before you confirm. Apply lists the hosts it will change; you must type the namespace.

Identity check before any write. Each host must answer with the hostname resmgr has; otherwise it is reported as MISMATCH and left alone.

Only pending hosts are written. Hosts already at "180000" get no set; a host that became set in the meantime shows SKIP.

Every write is read back. A value that does not read "180000" afterwards is VERIFY-FAILED.

Stops on the first failure during apply; remaining hosts are listed as not attempted.

Jump host failover. An ARS host the forwarder cannot reach is skipped (nothing ran on it); for apply, one with swap above 90% is also skipped.

No hangs. sudo -n never prompts; ovs-vsctl has a 15 s timeout; ssh has a 10 s connect timeout.

Usage
Run check to see where a region stands, then run the script with just the namespace to apply. Both are safe to repeat.



./ovn_wait_apply.sh check <namespace>     # read-only: status of every host + verdict
./ovn_wait_apply.sh <namespace>           # apply (same as: ./ovn_wait_apply.sh apply disw-eu-snn-lab)
FOR REGIONS WITH HIGH HYPERVISOR COUNT, USE PARALLEL OPTION TO MAKE THE SCRIPT EXECUTION FASTER:
PARALLEL=10 ./ovn_wait_apply.sh <namespace>
Mode

Changes anything?

Prompts?

What it does

check

No

No

Reads the value on every host and prints the verdict

apply (default)

Only hosts not yet at "180000"

Yes, type the namespace to confirm

Survey, confirm, set and verify pending hosts, re-read every host, verdict

Optional settings (not needed for normal use):

Setting

Default

Use

PARALLEL=N

1 (one host at a time)

Hosts handled at once, 1 to 20. PARALLEL=10 cuts a 400-host region from minutes to under a minute per stage

MATCH='regex'

all hosts

Limit to matching hostnames, e.g. MATCH='^snnhv0064\.' for a single host

MAX_JUMP=N

5

How many ARS hosts to try before giving up

Exit code is 0 when the prerequisite is met and 1 otherwise. Each run writes its logs to ./ovn-wait-logs/ (survey log, apply+validate log, and the resmgr inventory as a TSV).

Example outputs
The outputs below are from real runs. The ssh-keygen art and Ubuntu login banner that the forwarder prints are left out; seeing them in your terminal is normal.

1. check on a region that still needs the change (disw-eu-snn-lab, 13 Oct 2026)
All 27 hosts were read in 2 s; all are UNSET, so the verdict is NOT MET and the report lists every host. What to do next: run ./ovn_wait_apply.sh disw-eu-snn-lab.



PARALLEL=10 ./ovn_wait_apply.sh check disw-eu-snn-lab
REGION: disw-eu-snn-lab | mode: check | value: 180000 | parallel: 10 | match: <all> | 20261013-082442
resmgr hosts: 27 | selected: 27 | excluded (responding=0): 0
Jump host candidates (ARS, in order; next is used if one fails): 3 | will try up to 5
  1. snnhv0064.ies.mentorg.com (76c3a659-d25f-4cd1-8ccb-ffd2c006b679)
  2. snnhv0070.ies.mentorg.com (b4128a09-2408-4b67-8438-bbcc26088924)
  3. snnhv0071.ies.mentorg.com (86d56718-c287-4f3d-9da4-6ac80d2111ee)
--- forwarder session via snnhv0064.ies.mentorg.com (76c3a659-...) [jump host try 1/5] ---
Jump host: snnhv0064.ies.mentorg.com | user: pf9 | load: 14.03 13.78 14.53 | swap used: 0% | nproc: 128
======================== 1/3 SURVEY (read-only, all hosts) ========================
[  1/27 ] snnhv0064.ies.mentorg.com            local UNSET          <unset>
[  4/27 ] snnhv0069.ies.mentorg.com            ssh   UNSET          <unset>
...                                            (25 more lines, all UNSET)
RESULT phase=survey total=27 set=0 unset=27 other=0 fail=0
>>> disw-eu-snn-lab: CHECK not clean — not every host reads "180000"
>>> PREREQUISITE NOT MET — do not start host upgrades. To fix: ./ovn_wait_apply.sh apply disw-eu-snn-lab
====================== NEEDS MANUAL ATTENTION ======================
Hosts not at "180000" (27) — by status: UNSET=27
  HOST                                 STATUS         DETAIL
  snnhv0064.ies.mentorg.com            UNSET          <unset>
  ...                                  (all 27 listed)
Fix one host by hand:
  kubectl -n disw-eu-snn-lab exec -it deploy/forwarder -- /opt/pf9/forwarder/utils/ssh_to_host_as_pf9_with_key.sh 76c3a659-d25f-4cd1-8ccb-ffd2c006b679
  ssh <host FQDN from the list above>
  sudo ovs-vsctl set open . external_ids:ovn-ofctrl-wait-before-clear=180000
  sudo ovs-vsctl get open . external_ids:ovn-ofctrl-wait-before-clear        # expect "180000"
2. apply on a partly done region, with jump-host failover (disw-qa-pune, 12 Oct 2026)
8 of 9 hosts were already set, so only punhvqa05 was changed. The first jump host (punhvqa01) refused the second session and the script moved to punhvqa02 on its own. Validation read all 9 hosts at "180000". What to do next: nothing; host upgrades can proceed.



./ovn_wait_apply.sh disw-qa-pune
REGION: disw-qa-pune | mode: apply | value: 180000 | parallel: 1 | match: <all>
resmgr hosts: 9 | selected: 9 | excluded (responding=0): 0
--- forwarder session via punhvqa01.net.plm.eds.com [jump host try 1/5] ---
======================== 1/3 SURVEY (read-only, all hosts) ========================
[  1/9  ] punhvqa01.net.plm.eds.com            local SET            "180000"
...
[  6/9  ] punhvqa05.net.plm.eds.com            ssh   UNSET          <unset>
...
RESULT phase=survey total=9 set=8 unset=1 other=0 fail=0
Path for every host below: forwarder pod -> ARS jump host -> ssh <host> -> ovs-vsctl
Hosts to be changed (1 of 9); all others will NOT be touched:
  punhvqa05.net.plm.eds.com   current: <unset>
Type the namespace (disw-qa-pune) to apply on these 1 host(s): disw-qa-pune
--- forwarder session via punhvqa01.net.plm.eds.com [jump host try 1/5] ---
kex_exchange_identification: Connection closed by remote host
>>> could not reach punhvqa01.net.plm.eds.com (forwarder exit 255) — nothing ran remotely. Trying next ARS host.
--- forwarder session via punhvqa02.net.plm.eds.com [jump host try 2/5] ---
======================== 2/3 APPLY (set + verify, pending hosts only) ========================
[  1/1  ] punhvqa05.net.plm.eds.com            ssh   APPLIED        <unset> -> "180000"
RESULT phase=apply total=1 applied=1 skip=0 fail=0 not_attempted=0
======================== 3/3 VALIDATE (read-only, all hosts) ========================
...                                            (9 lines, all SET "180000")
RESULT phase=validate total=9 set=9 unset=0 other=0 fail=0
APPLY:    total=1 applied=1 skip=0 fail=0 not_attempted=0
VALIDATE: total=9 set=9 unset=0 other=0 fail=0
>>> disw-qa-pune: PREREQUISITE MET — all 9 hosts read "180000". Host upgrade can proceed.
3. check at scale (disw-na-wiv, 414 hosts)
PARALLEL=10 ./ovn_wait_apply.sh check disw-na-wiv read all 414 hosts in 46 s (about 1 minute total), fail=0, all UNSET. Expect an apply on this region to take roughly 3 minutes at PARALLEL=10, plus the time to confirm.

Reading results and troubleshooting
Start at the last lines: the verdict says MET or NOT MET, and a NOT MET run prints a NEEDS MANUAL ATTENTION block that lists every host to look at, its status and the error text. Fix those hosts, then re-run; hosts already done are skipped.

Status

Meaning

Where to look / what to do

SET

Host reads "180000"

Nothing

APPLIED

Changed in this run and read back as "180000"

Nothing

SKIP

Already "180000" when apply reached it

Nothing

UNSET

Key not present

Run apply, or set by hand (below)

OTHER

Key holds a different value (shown)

Confirm it is not intentional; apply overwrites it with 180000

UNREACHABLE

Jump host could not ssh to it

Host down, sshd, or DNS for the FQDN

GET-FAILED / SET-FAILED / VERIFY-FAILED

ovs-vsctl failed on the host

sudo for pf9, or OVS not running: sudo ovs-vsctl show on the host

MISMATCH

The FQDN reached a different host

DNS vs resmgr hostname; nothing was changed

NOT ATTEMPTED

Apply stopped after an earlier failure

Fix that failure, re-run apply

excluded (responding=0)

Host not reporting to resmgr; not covered

Check the host and hostagent; set by hand once reachable

jump host unusable

Forwarder could not open a session to that ARS host, or its swap was above 90% (apply only)

Not a blocker if another ARS host worked; the script tries the next one

Verdict lines you may see:

PREREQUISITE MET — all N hosts read "180000". Host upgrade can proceed.

MET for MATCH subset only — you limited the run with MATCH; run without it for the whole region.

PREREQUISITE NOT MET — read the NEEDS MANUAL ATTENTION block.

no ARS jump host reachable — nothing was read or changed — no forwarder session worked; the block lists each ARS host tried and why.

session reached the jump host but dropped before APPLY finished — some hosts may be changed; run check to see the real state.

Fix one host by hand (the report prints these lines with your namespace and a working jump host id filled in):



kubectl -n <namespace> exec -it deploy/forwarder -- /opt/pf9/forwarder/utils/ssh_to_host_as_pf9_with_key.sh <ARS host id>
ssh <host FQDN>
sudo ovs-vsctl set open . external_ids:ovn-ofctrl-wait-before-clear=180000
sudo ovs-vsctl get open . external_ids:ovn-ofctrl-wait-before-clear      # expect "180000"
The ARS host ids are in the run's inventory file ./ovn-wait-logs/<namespace>_inventory_<time>.tsv (4th column 1 = ARS).

Upgrade-day runbook (per region)
Apply after the management plane upgrade, confirm just before host upgrades, and recheck the first upgraded host. One person runs the script per region at a time.

Status check (read-only). ./ovn_wait_apply.sh check <namespace> (add PARALLEL=10 for 100+ hosts). Expect fail=0; note any hosts in the report.

Fix access problems first. Anything UNREACHABLE, GET-FAILED, MISMATCH or excluded will not be changed by apply. Sort these out, or plan to set them by hand.

Apply. ./ovn_wait_apply.sh <namespace>. Read the "Hosts to be changed" list, then type the namespace to confirm.

Read the verdict. PREREQUISITE MET means done. Otherwise fix the hosts in NEEDS MANUAL ATTENTION and re-run step 3; only pending hosts are touched.

Gate before host upgrades. Run check again right before host upgrades start. It must say PREREQUISITE MET.

After the first host upgrade. MATCH='^<first-upgraded-host>\.' ./ovn_wait_apply.sh check <namespace> and confirm it still reads "180000" before upgrading the rest.

Keep the logs. Attach the ./ovn-wait-logs/ files for the region to the change record.

Rollback, limitations and FAQ
There is no revert mode; to undo on a host, remove the key by hand:



sudo ovs-vsctl remove open . external_ids ovn-ofctrl-wait-before-clear
Known limitations

No lock between team members. Agree who runs it per region. Two runs at once in the same namespace can collide in the forwarder helper.

Persistence through the host upgrade is not guaranteed by the script. The upgrade re-converges host roles; that is why the runbook rechecks before and after the first host upgrade. On disw-qa-pune, punhvqa05 (whose role was re-converging) was the only host without the value.

Unhealthy jump hosts are only refused for apply. check uses a busy ARS host (e.g. swap above 90%) and prints a warning; apply moves to the next one.

OVN load from parallel changes is not measured. PARALLEL=10 was used for read-only runs at scale; keep the default for apply unless you are comfortable with 10 hosts changing at once.

FAQ

Do I need a host id or a host list? No. Hosts come from resmgr; the jump host is picked from ARS hosts automatically.

Is check really read-only? Yes: one SELECT on resmgr and ovs-vsctl get on each host. The only side effects are ssh/sudo log entries on hosts and local log files.

What if I press Ctrl-C? Each set is a single OVSDB transaction. Run check to see what changed, then re-run apply.

Why do I see ssh-keygen art and an Ubuntu banner? The forwarder helper prints them for every session; they are harmless.

A host is not an ARS host — can it still be changed? Yes. The script reaches every host by ssh from an ARS jump host.

Appendix: script source
The current version of the script is attached here: ovn_wait_apply.sh (21,963 bytes, md5 8657fdc69d220716f503c2816001fc8c). Save it as ovn_wait_apply.sh, run chmod +x ovn_wait_apply.sh, and compare the md5 to make sure everyone runs the same copy.

The script uses only standard tools on the workstation and on the hosts. It changes nothing except the one OVS key, and only after you type the namespace.
