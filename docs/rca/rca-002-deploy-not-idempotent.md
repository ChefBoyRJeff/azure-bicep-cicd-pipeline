# RCA-002: First Deployment Succeeded but Was Not Idempotent (What-if Noise)

| Field | Value |
|---|---|
| Milestone | M3 (real failure, caught by the pipeline's own check) |
| Date | 2026-10-29, times Eastern (UTC−4) |
| Impact | Dev deployed correctly, but the run failed and **prod was not deployed** (`needs: dev`). No incorrect state anywhere |
| Status | Resolved in code; verified on a second dev deployment and on prod's first |

## Summary

The first deploy run (run 40961598636, after PR #2) created dev successfully, but the post-deploy **idempotency check** failed: what-if, run immediately after deploying the same code, still reported one change. The VNet had a property Azure sets by default on create, `privateEndpointVNetPolicies: "Disabled"`, which the template didn't declare, so what-if reported it as a removal on every run. Declaring the default explicitly made what-if report **NoChange**.

## Why the Check Exists

A deployment pipeline should be safe to run any number of times. If what-if after a successful deploy still shows changes, either every run rewrites something (real drift), or what-if output can't be trusted for review (noise). Both need fixing, so the deploy action fails when anything other than `NoChange` or `Ignore` remains.

## Timeline (Eastern)

| Time | Event | Evidence |
|---|---|---|
| ~17:54 | PR #2 merged → deploy run #1 | Run 40961598636 |
| 17:56 | Dev: what-if `4 to create`, deployment `Succeeded`, resources correct, **Idempotency: FAIL** (1 resource). Prod: skipped | Run summary |
| 17:59 | Local what-if against dev isolates the property | `m3-01` |
| 18:06 | Fix applied locally; what-if `4 no change` | `m3-02` |
| 18:10 | PR #3: all checks pass; merged | |
| 18:14 | Run #2: dev `4 no change` → Succeeded → **PASS**; prod (approved) `4 to create` → Succeeded → **PASS** | `m3-03` |

## Diagnosis

The pipeline's idempotency step reports **which** resources differ but not **which property**. A local what-if (read-only, same template and parameters) showed it:

```
~ Microsoft.Network/virtualNetworks/vnet-dev [2024-05-01]
  - properties.privateEndpointVNetPolicies: "Disabled"
Resource changes: 1 to modify, 3 no change.
```

| Hypothesis | Assessment |
|---|---|
| What-if noise: a provider-set default absent from the template | **Confirmed.** `-` means "present in Azure, absent in code"; the value is the documented default; what-if itself warns that results "may contain false positive predictions" |
| Real drift: the template sets a value that differs from Azure's | Ruled out. The template didn't set the property at all |

## Root Cause

The Microsoft.Network provider adds `privateEndpointVNetPolicies: "Disabled"` to a VNet on create (API 2024-05-01). Because the Bicep template omitted it, what-if treated the stored value as something the next deployment would remove.

## Remediation

Declared the default in `infra/modules/vnet.bicep`:

```bicep
privateEndpointVNetPolicies: 'Disabled'
```

**Rejected alternative:** filtering this property out of the idempotency check. That would hide a whole class of differences behind an exceptions list. Declaring the value makes the code describe what Azure actually stores, and it documents a setting that was previously invisible.

Verified before merging: Bicep compiled with no BCP037 (unknown property) warning. Note that Bicep's type data treats the property as a free string, so the value isn't validated at build time (allowed values are `Disabled` and `Basic`).

## Verification

- `m3-02`: local what-if `4 no change`.
- `m3-03`: second dev deployment `4 no change` → **PASS**; prod's **first** deployment → **PASS**, so the fix holds for a fresh resource as well as an existing one.
- Run #5 (`m4-04`): both environments still **PASS**.

## Secondary Findings

1. **The check works as a gate.** Prod never started, because `needs: dev` treats a failed idempotency check as a failed dev deployment.
2. **Local disk drift.** The first local re-test still showed the noise. The fix wasn't on disk: VS Code had the file open with an older copy and saved it over the update. Detected by comparing file size on disk (2,048 vs. 2,323 bytes). Practice since then: close the folder in VS Code before files are written by tooling, and verify on disk.
3. `az -o table` silently drops a column named `type`; renamed to `resourceType` in the verification output.

## Prevention

| Control | Status |
|---|---|
| Post-deploy idempotency check in every environment | ✅ Already existed; it caught this |
| Declare provider defaults that what-if reports, instead of filtering | ✅ Practice |
| Evaluate deployment stacks what-if (Microsoft's lower-noise option, per the what-if banner) | Future improvement |
