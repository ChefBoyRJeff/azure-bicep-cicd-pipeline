# Project 3 Plan: Automated Bicep Deployment Pipeline

**Status:** Plan approved 2026-10-26. Nothing deployed yet.

## Business Problem

In Project 2, an NSG rule was deleted by hand in the portal. Nothing stopped it, and the alert built for it missed it ([RCA-001](https://github.com/ChefBoyRJeff/azure-monitoring-incident-response/blob/main/docs/rca/rca-001-nsg-rule-deleted-ssh-outage.md)). Teams prevent this class of problem by making **every change go through code review and an automated pipeline**:

- Every proposed change is **validated and previewed** (lint, build, what-if) before anyone approves it.
- Approved changes deploy **automatically and repeatably**, to dev first, then to prod after a human approval.
- The pipeline authenticates **without stored secrets**, and each stage can do **only what it needs**.

## Scope

| In scope | Out of scope (unless approved) |
|---|---|
| A small, free network workload: VNet, subnets, NSG, route table (Bicep modules) | VMs or any compute; paid network services (firewall, gateways, Bastion) |
| Two environments: `rg-cicd-dev`, `rg-cicd-prod` (eastus) | Subscription-scope deployments |
| GitHub Actions: PR validation, deploy on merge, prod approval gate | Self-hosted runners; Azure DevOps; Terraform (after the exam) |
| OIDC (workload identity federation), three least-privilege identities | Client secrets or certificates |
| Two controlled failures with RCAs | Deployment stacks (possible improvement) |

**Address plan:** dev `10.40.0.0/16`, prod `10.41.0.0/16`. These don't overlap P1 (`10.0–10.2`) or Lab 2 (`10.20–10.21`), so they could be peered later.

## Architecture

```
Developer ── branch ── Pull request ──► Workflow: validate (PR)
                                          • bicep build + lint (bicepconfig.json rules)
                                          • what-if vs. dev and prod (identity: gh-cicd-plan, read-only)
                                          • result written to the job summary
                                         Branch protection: merge blocked unless "validate" passes
                         merge to main ─► Workflow: deploy
                                          • job "dev"  (environment: dev,  identity: gh-cicd-deploy-dev)
                                          • job "prod" (environment: prod, required reviewer → approval,
                                                        identity: gh-cicd-deploy-prod)
                                          • post-deploy check: query the deployed state
```

### Identities (Microsoft Entra ID app registrations, no secrets)

| Identity | Federated credential subject | Azure role and scope | Can change resources? |
|---|---|---|---|
| `gh-cicd-plan` | `repo:ChefBoyRJeff@156028335/azure-bicep-cicd-pipeline@1435132927:pull_request` | **Custom role** "Bicep What-If Reader": Reader actions + `Microsoft.Resources/deployments/whatIf/action` + `.../validate/action`, on both RGs. What-if runs with `--validation-level ProviderNoRbac` | **No** |
| `gh-cicd-deploy-dev` | `repo:ChefBoyRJeff@156028335/azure-bicep-cicd-pipeline@1435132927:environment:dev` | Contributor on `rg-cicd-dev` only | Dev only |
| `gh-cicd-deploy-prod` | `repo:ChefBoyRJeff@156028335/azure-bicep-cicd-pipeline@1435132927:environment:prod` | Contributor on `rg-cicd-prod` only | Prod only |

**How OIDC works here:** GitHub issues the job a short-lived signed token (issuer `https://token.actions.githubusercontent.com`) whose *subject* names the repo and the trigger (PR or environment). Entra ID trusts that issuer only for the exact subject in the federated credential, and exchanges it for an Azure access token. Nothing long-lived is stored. **Subject format:** GitHub repositories created after 2026-07-15 use the *immutable* subject format, which adds the permanent owner and repository IDs (`repo:<owner>@<ownerId>/<repo>@<repoId>:...`). The credential must match it exactly. Found the hard way in M2 (RCA-001). A workflow in another repo, a fork, or a different trigger gets a different subject and is refused.

**Why a custom role:** Microsoft documents that what-if needs the same permissions as a deployment, so built-in Reader can't run it. With `ProviderNoRbac`, the permission check is reduced to read access, so a role with Reader plus the two `deployments` actions should be enough. **To verify in M1/M2:** a test that the plan identity can run what-if but **can't** deploy (expect 403).

## Milestones

| # | Milestone | Acceptance criteria | Est. |
|---|---|---|---|
| M0 | Repo scaffold, Bicep modules, `bicepconfig.json` | `az bicep build` and lint pass locally with zero warnings; `.gitignore` excludes compiled JSON and local params; Jeff commits | 45 min |
| M1 | RGs, identities, custom role, role assignments, federated credentials (**approval required: Entra ID + RBAC change**) | 3 app registrations with **no secrets**; role assignments only at RG scope (verified by listing them); custom role definition in code | 45–60 min |
| M2 | PR workflow: lint, build, what-if | A PR shows what-if for dev and prod in the job summary; **negative test:** the plan identity's deploy attempt returns 403; branch protection requires the check | 60 min |
| M3 | Deploy workflow: dev on merge, prod after approval | Merge → dev deploys → prod waits → approve → prod deploys; post-deploy query matches the code; second run is idempotent (no changes) | 60 min |
| M4 | Controlled failures + RCAs | **(a)** A PR with a lint error is blocked from merging. **(b)** A change that passes PR checks but **fails during deployment** (candidate: overlapping subnet prefixes, which may only be rejected by the network provider at deploy time). Each has symptom, diagnosis from logs, root cause, fix through a new PR, and prevention | 60–90 min |
| M5 | README, architecture diagram, interview guide, teardown | Same standard as Project 2 | 45 min |

**Total: about 5–7 hours over about 3 sessions.**

## Security

- **No secrets.** OIDC only. No client secret is ever created; verified with `az ad app credential list` (expect empty).
- **Public logs.** Actions logs in a public repo are public. The tenant, subscription, and client IDs are stored as **GitHub secrets** (not variables), so GitHub masks them as `***` in logs. They're identifiers, not credentials, but this keeps them out of public output. Verified by reading the logs after the first run.
- **Least privilege:** no subscription-scope role for any pipeline identity; the PR identity can't write.
- **Forks:** PRs from forks don't receive OIDC tokens with access to these secrets, so outside contributors can't trigger an Azure login.
- **Branch protection on `main`:** a PR is required, the `validate` check must pass, no force-pushes.
- **Evidence:** sanitized (GUIDs and emails) before every commit, as in Project 2.

## Cost

| Item | Cost |
|---|---|
| VNet, subnets, NSG, route table | $0 (no charge for these resources) |
| Entra ID app registrations, custom role, role assignments | $0 |
| GitHub Actions on a public repo (GitHub-hosted runners) | $0 |
| **Target** | **$0/month.** Anything billable needs approval first |

## Teardown

1. Delete `rg-cicd-dev` and `rg-cicd-prod`.
2. Delete the three app registrations (this also removes their federated credentials and service principals).
3. Delete the custom role definition (only after its assignments are gone).
4. Optionally archive the repo. The workflows will fail harmlessly without the identities.

## AZ-104 Coverage

| Objective | Milestones |
|---|---|
| Manage Microsoft Entra users and groups / app registrations and service principals (identity concepts) | M1 |
| Manage access to Azure resources: assign roles at different scopes, interpret access assignments, custom roles | M1, M2 (403 test) |
| Automate deployment of resources by using ARM templates or Bicep files (interpret, modify, deploy) | M0, M2, M3 |
| Configure virtual networks, subnets, NSGs, route tables | M0 (workload) |

CI/CD itself isn't an AZ-104 objective. It's included because Azure administrator and cloud engineer roles increasingly expect it.
