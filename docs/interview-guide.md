# Interview Guide: Azure Bicep CI/CD Pipeline

Talking points for this project. Everything happened in a **personal lab subscription**. Describe it as hands-on lab work, not production experience.

> **Framing line:** "I built a CI/CD pipeline for Bicep while studying for AZ-104. It deploys a small network to dev and prod with no stored secrets, and I documented the real failures I hit while building it."

## 1. Three-to-Five-Minute Walkthrough

**Problem (30 s).** In my monitoring project, I deleted an NSG rule in the portal to simulate a human error, and the alert I'd built for exactly that case didn't fire. Detection is a backstop. The stronger control is that nobody changes infrastructure by hand: every change goes through a pull request, gets validated and previewed, and is deployed by a pipeline.

**What I built (75 s).**
- A GitHub Actions pipeline for Bicep. **On every pull request:** lint with rules raised to errors, typed parameters, a subnet layout test, and **what-if against dev and prod**, so a reviewer sees what would change in Azure, not just the diff.
- **On merge:** dev deploys automatically; prod waits for a person to approve. After each deployment, the pipeline runs what-if again and **fails if anything still differs**. That's my idempotency check.
- **Sign-in uses OIDC.** There are no client secrets anywhere; I verified zero secrets on all three app registrations.
- **Three identities.** The pull request identity has a **custom role** that can read and run what-if but **can't write**, and a guardrail job on every PR proves that by attempting a real deployment and requiring Azure to refuse it. Dev's identity can only touch dev; prod's only prod.

**What went wrong (90 s).** Two real failures, both caught by the pipeline:
1. The first run couldn't sign in: `AADSTS700213`. The log showed the subject GitHub sent had **numeric IDs** in it. GitHub moved new repos to immutable OIDC subjects in July 2026, and my credentials used the old name-based format from documentation examples. I fixed the setup script to build the new format and remove the stale credentials. That also closes a subject-recycling risk.
2. The first deployment **succeeded**, but my idempotency check failed. What-if reported a property Azure sets by default that my code didn't declare. I declared it rather than filtering it out, and prod never deployed until it was fixed.

Then a controlled test: I made a copy-paste error that gave two subnets the same range. **It passed lint, type checks, and what-if**, and failed at deployment with `NetcfgSubnetRangesOverlap`. Azure rejected the whole update, so dev was unchanged, and prod never started. I recovered with a revert PR and added a pre-merge test that would have caught it.

**Close (15 s).** "The lesson I'd highlight: every check has a blind spot. What-if couldn't see the overlap, so I documented where each control stops and added a test for the gap I found."

## 2. Ten-Minute Deep Dive (Outline)

| Minutes | Topic | Show |
|---|---|---|
| 0–2 | Architecture: PR checks → ruleset → dev → approval → prod | README diagram |
| 2–4 | OIDC: issuer, audience, subject; why three identities; the custom role | `identity/bicep-whatif-reader.role.json`, `m1-06` |
| 4–6 | RCA-001: reading the subject from the log, immutable format, reconcile | RCA-001 |
| 6–7 | Idempotency check and RCA-002 | `action.yml` step 4, RCA-002 |
| 7–9 | M4b: what passed, what failed, atomic rejection, revert, prevention | RCA-003, `m4b-02`, `m4-03` |
| 9–10 | What I'd change for production | README limitations table |

**Live demo (if a laptop and the repo are available):** open a PR that changes an NSG rule's port and show the what-if summary on the PR's checks. Then show the ruleset blocking a direct push to `main`.

## 3. Likely Questions and Answers

**Q: Why OIDC instead of a service principal secret?**
A secret is a long-lived credential: it can leak through a log, a commit, or a laptop, and it has to be rotated. With OIDC, GitHub issues a short-lived signed token per job, and Entra ID only accepts it for an exact subject: this repository plus this trigger. There's nothing stored to steal. I verified zero secrets and zero certificates on all three app registrations.

**Q: Why three identities and not one?**
So a compromise or mistake at one stage can't reach the next. The pull request identity can read and run what-if, but it **can't** write; that's enforced by a custom role and proven on every PR by the guardrail job. Dev's identity has Contributor on dev's resource group only, prod's on prod's only. No identity has anything at subscription scope.

**Q: Why a custom role? Isn't Reader enough for what-if?**
No. Microsoft documents that what-if needs the same permissions as a deployment. What-if has a validation level, `ProviderNoRbac`, that checks only read access. So I made a role with read plus the two deployment actions `whatIf` and `validate`, and confirmed it works in the pipeline. It's the narrowest role I found that runs what-if.

**Q: What's the guardrail, and why test a refusal?**
It's a negative test that runs on every PR: the PR identity tries a real deployment, and the check passes only if Azure refuses it, specifically for `deployments/write`. If someone later widens that role, the pipeline catches it. I also learned that the refusal comes during preflight as `InvalidTemplateDeployment`, not as `AuthorizationFailed`, so my first version of the check misread it. Now it checks for the specific missing permission.

**Q: Walk me through `AADSTS700213`.**
All three Azure jobs failed in about ten seconds while the job without Azure access passed, which pointed at sign-in. The secrets were there. The `azure/login` step prints the token's issuer, subject, and audience; the subject had my account ID and the repo ID in it. I confirmed in Microsoft's and GitHub's docs that repos created after July 2026 use this immutable format. I changed the setup script to build it and to remove credentials whose subject doesn't match. Then one more failure: one job still failed while the others passed, which was replication delay on the new credential; a re-run fixed it.

**Q: What does your idempotency check do, and what did it catch?**
After deploying, it runs what-if again with the same code. If anything other than "no change" remains, the job fails, and prod doesn't run. On the first deployment it caught `privateEndpointVNetPolicies`, a default Azure adds to the VNet. What-if saw "Azure has it, my code doesn't" and would have reported it on every run. I declared the value instead of adding an exception, so the code describes exactly what Azure stores.

**Q: What-if passed, so why did the overlap fail?**
What-if predicts the change and runs some provider validation, but the network provider only checks subnet overlap when it actually applies the update. The overlap was visible in the what-if output, so a careful reviewer might have caught it, but nothing automated did. Azure rejected the whole VNet update, so nothing changed. I reverted through a PR and added a test that checks the CIDR math before merge, with no Azure access.

**Q: How do you roll back?**
Revert through a pull request: GitHub's revert button, then the same checks and the same deploy path. I don't allow direct pushes to `main`, even for fixes; the ruleset has no bypass. In this lab, the failed deployment changed nothing, so the revert just restored `main`. For a change that had partly applied, I'd rely on the same principle: the code in `main` is the desired state, and redeploying it converges Azure back.

**Q: How do you stop people from changing things in the portal?**
This pipeline doesn't prevent it by itself; it makes the pipeline the normal path. In production I'd remove write access from people (RBAC), keep only the pipeline identities as writers, and add a nightly what-if job that reports drift. That last one is in my improvements list, and it would have caught my Project 2 incident.

**Q: What would you change for production?**
Separate subscriptions for dev and prod; a second person as the prod approver with self-review prevented; actions pinned to commit SHAs; what-if posted as a PR comment; scheduled drift detection; and more pre-merge tests for NSG rules.

**Q: What does it cost?**
Nothing. VNets, NSGs, and route tables are free; app registrations and roles are free; Actions minutes are free on a public repo. I checked the VNet pricing statement on Microsoft Learn before deploying.

## 4. Follow-Up Challenges to Practice

Answer these out loud, without notes:

1. Someone forks the repo and opens a PR. What happens at the Azure login step, and why?
2. Your prod approval appears for a change that only touched the README. Why did that happen in this project, and how did you fix it?
3. A new subnet is added to `prod.bicepparam` only. Which checks run, and which would catch a mistake in it?
4. The guardrail starts failing with "Deployment succeeded". What does that mean, and what do you check first?
5. What's the difference between a failed required check and a skipped one in a GitHub ruleset? Why does it matter in your workflow?
6. How would you add a storage account to this pipeline without giving the PR identity more permissions?
7. Explain `needs: dev` to a non-technical manager in one sentence.

## 5. Honest Limits to Mention If Asked

- It's a lab: one person wrote, merged, and approved everything.
- Dev and prod are in the same subscription.
- The teardown commands are documented but haven't been run.
- The workload is network-only, and deliberately small.
