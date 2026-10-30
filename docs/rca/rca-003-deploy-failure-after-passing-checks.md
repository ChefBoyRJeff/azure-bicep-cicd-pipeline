# RCA-003: A Change Passed Every PR Check, Then Failed at Deployment (Overlapping Subnets)

| Field | Value |
|---|---|
| Milestone | M4b (controlled failure), with M4a (validation gate) for comparison |
| Date | 2026-10-29, times Eastern (UTC−4) |
| Impact | Dev deployment failed; **no change applied** to dev; prod never started. `main` held broken code for about 6 minutes until the revert merged |
| Status | Recovered by a revert PR; prevented by a new required pre-merge check |

## Summary

A deliberate copy-paste error gave `snet-data` the same prefix as `snet-app` (`10.40.1.0/24`) in `infra/params/dev.bicepparam`. Lint, type checks, and what-if **all passed**. What-if even displayed the change, but nothing checked it against the other subnet. The network provider rejected the deployment with `NetcfgSubnetRangesOverlap` (HTTP 400). Azure rejected the whole VNet update, so dev was unchanged. Recovery was a revert PR. Prevention is `scripts/Test-SubnetLayout.ps1`, now part of the required Lint check, which catches the error before merge without Azure access.

## Exercise Design

| | M4a | M4b |
|---|---|---|
| Change | Unused parameter `enableDebug` in `main.bicep` | `snet-data` prefix = `snet-app`'s |
| Expected to be caught by | Lint (`no-unused-params`, configured as error) | Nothing before deployment (the hypothesis being tested) |
| Variables changed | One | One (the NSG rule's prefix deliberately left unchanged) |

## M4a: the Validation Gate (PR #4, not merged)

| Evidence | Result |
|---|---|
| Local lint | `Error no-unused-params: Parameter "enableDebug" is declared but never used`, exit 1 (`m4a-01`) |
| PR checks | Lint ❌ (Required); Guardrail and What-if **skipped** (`needs: lint`); Azure never contacted |
| Direct push of the PR's commit to `main` | `GH013 … 3 of 4 required status checks have not succeeded: 2 expected and 1 failing` (`m4a-02`) |

**Findings from M4a:**
1. **A skipped required check counts as satisfied.** GitHub counted 4 required checks but only 3 blocked; Guardrail (skipped) passed. The PR was held because **Lint itself is required**. The first gate in a `needs` chain must always be a required check.
2. **A skipped matrix job never expands.** GitHub reported one check literally named `What-if (${{ matrix.environment }})`, so the required `What-if (dev)` and `What-if (prod)` stayed "Expected" forever. Here that fails **closed** (blocks the merge), which is the safe direction.
3. For a commit already in a PR, GitHub didn't report "Changes must be made through a pull request". The **status checks** were the rule that held.

## M4b Timeline (Eastern)

| Time | Event | Evidence |
|---|---|---|
| 18:34 | Local: build-params exit 0; what-if `~ snet-data addressPrefix "10.40.2.0/24" => "10.40.1.0/24"`, 1 to modify | `m4b-01` |
| ~18:37 | PR #5: **all 4 checks pass**; merged (approved as a controlled failure) | |
| 18:39 | Deploy run #3: dev **fails**; prod **skipped** | Run 40967383328 |
| 18:40 | Diagnosis from nested deployment operations; dev subnets unchanged | `m4b-02` |
| ~18:45 | Revert PR #6 (GitHub "Revert" button) merged | |
| 18:52 | Prevention verified locally (positive and negative) | `m4-03` |
| ~18:55 | PR #7 (prevention) merged; run #5: dev and prod `4 no change` → PASS | `m4-04` |

## Symptom and Diagnosis

The deploy step's top-level error only said `DeploymentFailed … At least one resource deployment operation failed`. The real cause sits on the failed **operation** inside the nested module deployment `network-dev`:

```
resource: vnet-dev  (Microsoft.Network/virtualNetworks)
status:   BadRequest
error:    NetcfgSubnetRangesOverlap: Subnet 'snet-data' is not valid because its IP address range
          overlaps with that of an existing subnet in virtual network 'vnet-dev'.
```

Command: `az deployment operation group list -g rg-cicd-dev -n network-dev`, filtered to `provisioningState = Failed`.

State check after the failure: `snet-app 10.40.1.0/24`, `snet-data 10.40.2.0/24`. **Unchanged.** The provider rejected the VNet PUT as a whole; nothing was partially applied.

## Root Cause

**Direct cause:** a subnet prefix collided with another subnet in the same VNet.

**Why it got through:** the pre-merge checks validate **syntax** (lint), **shape** (user-defined types), and **what the change would do** (what-if). None of them validated **relationships between values**. What-if's preflight for `Microsoft.Network` doesn't evaluate subnet overlap; only the actual write does. The overlap was **visible** in the what-if output, but the only "check" for it was a human reviewer noticing.

## Remediation

1. **Service:** revert PR #6 restored `10.40.2.0/24`. Following the same rule as every change (no direct pushes to `main`), recovery went through review and the same checks.
2. **Detection gap:** `scripts/Test-SubnetLayout.ps1`, added to the required **Lint and build** job:
   - Compiles each `.bicepparam` and checks that every subnet is inside the VNet and that no two overlap. It also rejects CIDRs with host bits set (`10.40.2.5/24`).
   - No Azure access; same result on Windows PowerShell 7 and on the Ubuntu runner.
3. **Diagnosability:** on deployment failure, the deploy action now prints the failed nested operation (`vnet-dev: NetcfgSubnetRangesOverlap: …`) to the log and job summary, and redacts the error text (it had printed a correlation ID).

## Verification

| Test | Result |
|---|---|
| Real dev and prod files | PASS, exit 0 (`m4-03`, and in CI on PR #7) |
| M4b error replayed in a temporary file | `FAIL snet-app 10.40.1.0/24 overlaps snet-data 10.40.1.0/24`, exit 1 (`m4-03`) |
| Outside-VNet and host-bits cases | FAIL (tested in Claude's workspace with Bicep 0.48.1 and PowerShell 7.4 during development, not on the local machine) |
| Pipeline after the changes | Run #5: dev and prod `4 no change`, Succeeded, idempotency PASS (`m4-04`) |

## Lesson: a Negative Test Must Fail for the Intended Reason

The first local negative test used PowerShell `-replace`, which is **case-insensitive**. The pattern `addressPrefix: '10.40.2.0/24'` also matched the end of `destinationAddressPrefix: '10.40.2.0/24'` and rewrote it as `destinationaddressPrefix`. The test then failed on a **type error** (BCP089/BCP035), never reaching the overlap logic. `exit=1` looked like success.

Caught by reading the failure text rather than the exit code; redone with `-creplace` anchored to line start (`(?m)^(\s+)addressPrefix:`). This is the same principle as the M2 guardrail: assert **why** something failed, not only **that** it failed.

## Blast Radius Controls That Worked

| Control | Effect here |
|---|---|
| Dev before prod (`needs: dev`) | Prod never started, so there was no approval request for a broken change |
| Provider-side atomic validation | Dev unchanged; no partial update to roll back |
| Branch protection | The fix also went through a PR and the same four checks |

## Prevention

| Control | Status |
|---|---|
| Pre-merge subnet layout check (required) | ✅ |
| Root cause printed automatically on deploy failure | ✅ |
| Deploy only when `infra/**` changes (avoids approval fatigue from docs-only merges) | Proposed for M5 |
| Broader pre-merge tests (e.g. NSG rule priorities unique, rule prefixes inside their subnet) | Future improvement |
