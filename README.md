# support-siemens-upgrade-automation

Scripts that automate the manual pre- and post-upgrade tasks the Support team performs during Siemens PCD upgrades.

Siemens upgrades run across many regions and namespaces, and several steps were being done by hand per namespace or per host: recording service resource settings, reapplying them after the upgrade, and patching vGPU host configuration. Done manually, these steps are slow and easy to get wrong at scale. Each tool in this repo takes one of those tasks, adds a dry run and a report, and makes it repeatable across a whole region.

## Tools

| Directory | Task it automates | When to run |
|---|---|---|
| [`resource-guard/`](resource-guard/README.md) | Captures CPU/memory requests and limits of all Deployments, StatefulSets and DaemonSets per namespace, and after the upgrade restores any value the upgrade lowered | Capture before the upgrade, restore after |
| [`vgu/`](vgu/README.md) | Finds vGPU hosts that need the August 2026 "Patch vGPU pf9-ostackhost-neutron Config" step, derives the PF addresses from the resmgr API, and runs the patch | After the DU and each GPU host are upgraded to 2026.8 |

Each directory has its own README with prerequisites, steps and expected output.

## Typical upgrade flow

1. **Before the upgrade:** capture resource settings for every region namespace with `resource-guard capture`.
2. **Upgrade** the DU and hosts through PCD Manager, as per the upgrade doc.
3. **After the upgrade:**
   1. Run `resource-guard restore` as a dry run, review it, then apply.
   2. For vGPU regions, identify the hosts that need the vGPU patch and run it per host (`vgu`).
4. **Verify:** re-run each tool's dry run. It should report nothing left to change.

## Common prerequisites

| Requirement | Used by |
|---|---|
| bash 3.2 or newer (macOS default works), jq, awk, curl | all |
| kubectl with access to the management cluster hosting the region namespaces | resource-guard |
| Region admin token and `openstack` CLI configured for the region | vgu |

## Conventions

- **Dry run by default.** Nothing is changed unless `--apply` is given (or, for the official vGPU script, confirmed at its prompt).
- **Every run writes a report** (plan, before/after values, backups) to a local output directory.
- **Output directories are never committed.** They contain customer environment data and are excluded in `.gitignore` (`resource-guard-data/`, `restore_*/`, `vgpu_pf_patch_*/`).
- **Run in the approved change window** for production regions. Test on a non-production region first.

## Adding a new tool

1. Create a directory named after the task.
2. Add the script and a `README.md` covering purpose, prerequisites, steps, expected output and limitations.
3. Default to a dry run, and write output to a directory that is listed in `.gitignore`.
4. Add a row to the Tools table above.

## References

- [Support Team - August Release Upgrade Doc](https://platform9.atlassian.net/wiki/spaces/SUP/pages/6356697118/Support+Team+-+August+Release+Upgrade+Doc)
- [Siemens Jan/April → August (Flamingo) Upgrade: Post-Upgrade CM / Customization Checklist](https://platform9.atlassian.net/wiki/spaces/SUP/pages/6200492049/Siemens+Jan+April+August+Flamingo+Upgrade+Post-Upgrade+CM+Customization+Checklist)