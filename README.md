# Azure Bicep CI/CD Pipeline

GitHub Actions pipeline for Bicep: lint and what-if on every pull request, deploy to dev on merge, deploy to prod after a manual approval. Azure sign-in uses OIDC (workload identity federation), so there are **no stored secrets**, and three least-privilege identities separate *previewing* a change from *making* it. Built as a hands-on project while studying for **AZ-104: Microsoft Azure Administrator**. This is lab work in a personal subscription, not a production environment.

> **Status:** M0 (scaffold) in progress. See [`docs/plan.md`](docs/plan.md) for the approved plan.

## Why

In [Project 2](https://github.com/ChefBoyRJeff/azure-monitoring-incident-response), an NSG rule was deleted by hand in the portal, and the alert built to catch it missed it ([RCA-001](https://github.com/ChefBoyRJeff/azure-monitoring-incident-response/blob/main/docs/rca/rca-001-nsg-rule-deleted-ssh-outage.md)). Detection helps, but the stronger control is making every change go through review and an automated pipeline.

## Workload

A deliberately small, **free** network per environment (the subject of this project is the pipeline):

| Resource | dev (`rg-cicd-dev`) | prod (`rg-cicd-prod`) |
|---|---|---|
| VNet | `vnet-dev` 10.40.0.0/16 | `vnet-prod` 10.41.0.0/16 |
| Subnets | `snet-app` .1.0/24, `snet-data` .2.0/24 | same layout |
| NSGs (one per subnet) | app: HTTPS from VNet; data: SQL (1433) from app only; both deny other VNet traffic | same |
| Route table | `Drop-Blocked-Range` 10.99.0.0/16 → None | same |

## Repository Structure

```
├── bicepconfig.json          # Linter rules, most raised to "error" so CI fails on them
├── infra/
│   ├── main.bicep            # Resource-group scope entry point
│   ├── types.bicep           # Shared user-defined types (NSG rule, subnet)
│   ├── modules/
│   │   ├── vnet.bicep        # VNet, one NSG per subnet, route table
│   │   └── nsg.bicep         # NSG from a typed rule list
│   └── params/
│       ├── dev.bicepparam    # Committed: network design only, no secrets
│       └── prod.bicepparam
└── docs/
    ├── plan.md
    └── evidence/
```

## Validate Locally

```powershell
az bicep lint --file infra\main.bicep
az bicep build-params --file infra\params\dev.bicepparam --stdout | Out-Null
az bicep build-params --file infra\params\prod.bicepparam --stdout | Out-Null
```

Each command prints nothing and exits 0 when the code is clean.
