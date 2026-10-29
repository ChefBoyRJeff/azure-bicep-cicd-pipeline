# RCA-001: Pipeline Sign-in Failed (AADSTS700213, OIDC Subject Mismatch)

| Field | Value |
|---|---|
| Milestone | M2 (real failure, not staged) |
| Date | 2026-10-29, times Eastern (UTC−4) |
| Impact | The first run of the PR workflow could not sign in to Azure. No resources were affected |
| Duration | About 7 minutes (17:19 first failure → 17:26 fix applied), plus one replication-delay retry |
| Status | Resolved; root cause fixed in the setup script so it can't recur |

## Summary

The three Azure jobs of the first PR run (PR #1, run 40956675691) failed in `azure/login` with `AADSTS700213: No matching federated identity record found`. GitHub presented an OIDC subject in the **immutable format** (`repo:ChefBoyRJeff@156028335/azure-bicep-cicd-pipeline@1435132927:pull_request`), while the federated credentials created in M1 used the **name-based format** (`repo:ChefBoyRJeff/azure-bicep-cicd-pipeline:pull_request`). Entra ID requires an exact match. GitHub applies the immutable format automatically to repositories created after 2026-07-15; this one was created 2026-10-26.

## Timeline (Eastern)

| Time | Event | Evidence |
|---|---|---|
| 2026-10-27 | M1 creates federated credentials with name-based subjects (from Microsoft Learn's GitHub Actions examples) | `m1-04`, `m1-06` |
| 10-29 17:19 | PR #1 opened. Lint passes; What-if (dev), What-if (prod), Guardrail fail after 8–11 s | Run 40956675691 |
| 17:20 | Hypothesis 1 (missing or misnamed secrets) ruled out: all three repository secrets exist with exact names | Settings page |
| 17:21 | Job log shows the presented subject and `AADSTS700213` | Job log (deleted later, see below) |
| 17:22 | Format confirmed in Microsoft Learn ("Migrate GitHub Actions federated credentials to immutable subjects") and the GitHub Changelog (2026-04-23) | Sources below |
| 17:24 | Script fixed; step 4 reconciles credentials: 3 name-based **removed**, 3 immutable **created** (approved) | `m2-01`, `m2-02` |
| ~17:26 | Re-run: What-if (prod) and Guardrail sign in; **What-if (dev) still `AADSTS700213`** | Run 40956675691, attempt 2 |
| 17:29 | After a new push: all four checks pass | Run 40958023819, `m2-03` |

## Symptom

```
subject claim - repo:ChefBoyRJeff@156028335/azure-bicep-cicd-pipeline@1435132927:pull_request
Error: AADSTS700213: No matching federated identity record found for presented assertion subject '...'
```

The issuer (`https://token.actions.githubusercontent.com`) and audience (`api://AzureADTokenExchange`) matched; only the subject differed.

## Hypotheses and Diagnosis

| Hypothesis | Test | Result |
|---|---|---|
| Secrets missing or misnamed (empty client or tenant ID) | Repository secrets page | **Ruled out:** all three present, names exact, created before the run |
| Trailing newline from `Set-Clipboard` corrupted an ID | Error type | **Ruled out:** that would give "tenant not found" or "invalid client", not a subject mismatch |
| Subject mismatch | Compare the presented subject (printed by `azure/login`) with `m1-06` | **Confirmed:** `@156028335` and `@1435132927` present in the token, absent in the credential |

The most useful diagnostic was in the failing step itself: `azure/login` prints the **federated token details** (issuer, subject, audience) before attempting sign-in.

## Root Cause

GitHub changed the default OIDC subject format for new repositories (2026-07-15) to include immutable owner and repository IDs. The M1 setup script built subjects from names only, following documentation examples written for the old format. The script was never tested against a real token before the credentials were created.

## Remediation

`scripts/Initialize-PipelineIdentity.ps1`:
- Builds every subject from `-OwnerId` and `-RepoId` (public, non-secret numbers) in the immutable format.
- Step 4 now **reconciles**: it removes any federated credential whose subject isn't the expected one, then creates missing ones. This is Microsoft's recommended migration, and it closes the **subject-recycling** risk of name-based subjects (a deleted or renamed repository's name could be reused by someone else).

## Verification

- `m2-02`: only the three immutable subjects remain; zero secrets; roles unchanged.
- Run 40958023819: all four checks pass, signing in as `gh-cicd-plan`.

## Secondary Findings

1. **Replication delay.** On the re-run, What-if (prod) and Guardrail signed in with the new credential while What-if (dev), seconds earlier, still got `AADSTS700213`. New federated credentials take roughly a minute to replicate. A re-run resolves it.
2. **Guardrail matcher was wrong.** On attempt 2, the guardrail job reported failure even though Azure **had refused** the deployment. The refusal arrived during preflight as `InvalidTemplateDeployment` with "Authorization failed for template resource … `Microsoft.Resources/deployments/write`", not the code `AuthorizationFailed` the script required. The matcher now accepts both forms and **also requires** the `deployments/write` text, so an unrelated error can't pass as a refusal.
3. **ID leak in a public log.** That error text printed the plan identity's **object ID** unmasked (logs mask only secrets). All az output is now passed through a GUID redaction, and deletion of run 40956675691's logs was requested in the GitHub UI (confirm the run shows its logs as deleted).

## Prevention

| Control | Status |
|---|---|
| Subjects built in the immutable format, reconciled by the setup script | ✅ |
| Before creating credentials for a new repo: read the subject from a real token (the `azure/login` log prints it) | ✅ Documented practice |
| Guardrail matcher requires the specific missing permission | ✅ |
| All CLI output GUID-redacted in a public repo | ✅ |

## Sources

- [Microsoft Learn: Migrate GitHub Actions federated credentials to immutable subjects](https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-github-immutable-subjects)
- [GitHub Changelog: Immutable subject claims for GitHub Actions OIDC tokens](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/)
