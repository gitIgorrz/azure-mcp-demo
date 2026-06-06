# ADR-008: GitHub OIDC federated credentials — tightly scoped subjects

**Date:** 2026-06-04
**Status:** Accepted

## Context

GitHub Actions needs to authenticate to Azure to push container images to GHCR and to run
Terraform plan/apply. The standard mechanism is GitHub OIDC → Azure federated credential on
an app registration. The subject claim of the federated credential determines which GitHub
Actions runs are trusted.

## Decision

**Every federated credential subject must be tightly scoped to a specific repo AND a
specific branch or environment. Wildcard subjects are never permitted.**

### Federated credentials to create (manual — see `scripts/`)

| Purpose | Subject claim | Used by |
|---------|--------------|---------|
| Terraform plan (PR) | `repo:gitIgorrz/azure-mcp-demo:ref:refs/heads/main` | Plan workflow on PR targeting main |
| Terraform apply (main) | `repo:gitIgorrz/azure-mcp-demo:environment:lab` | Apply workflow via GitHub Environment `lab` |
| Build + push image | `repo:gitIgorrz/azure-mcp-demo:ref:refs/heads/main` | Build workflow on main |

> For PRs from non-main branches, the plan workflow runs with the `pull_request` event;
> the subject becomes `repo:gitIgorrz/azure-mcp-demo:pull_request`. Add a separate
> federated credential for this if plan-on-PR against feature branches is required.

## Rationale

A wildcard subject (`repo:gitIgorrz/azure-mcp-demo:*`) would allow **any** GitHub Actions
run in the repo — including runs on attacker-controlled fork PRs — to obtain an Azure access
token. This is the most common misconfiguration in GitHub OIDC + Azure setups.

Tight scoping (per-repo + per-branch/environment) means:
- Only `main` branch runs (or `lab` environment runs) can obtain Azure tokens.
- A compromised PR workflow from a fork cannot escalate to Azure access.
- The environment-scoped subject for apply (`environment:lab`) requires the GitHub
  Environment gate to be passed before the token can be requested — adding a manual
  approval checkpoint at the OIDC layer, not just at the workflow level.

## Subject claim format reference

```
repo:{owner}/{repo}:ref:refs/heads/{branch}      # specific branch
repo:{owner}/{repo}:environment:{env-name}        # GitHub Environment
repo:{owner}/{repo}:pull_request                  # any PR (use sparingly)
```

Never: `repo:{owner}/{repo}:*` or omitting the repo entirely.

## Consequences

- Multiple federated credentials are needed (one per subject scope) — manual setup, but
  one-time.
- If a new branch needs Azure access (e.g. a release branch), a new federated credential
  must be explicitly created — this is a feature, not a limitation.
- The Terraform apply federated credential's `environment:lab` subject ties the Azure
  access grant to the GitHub Environment approval gate (ADR-013).

## Enterprise target

Same model per environment (lab/INT/prod), with environment-scoped subjects encoding the
env name. An INT federated credential subject contains `environment:int`; it physically
cannot produce a prod token. Federation subjects as environment-isolation boundary.
