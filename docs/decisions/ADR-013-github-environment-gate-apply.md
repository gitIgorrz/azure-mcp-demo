# ADR-013: GitHub Environment gate for Terraform apply

**Date:** 2026-06-04
**Status:** Accepted

## Context

`terraform apply` mutates cloud infrastructure. It must not run automatically on every push
to `main`. A gate is needed between "plan reviewed" and "apply executed."

## Decision

`terraform apply` runs only via a GitHub Actions workflow triggered on `main` merge, gated
by a **GitHub Environment** named `lab` with required reviewers.

Pipeline flow:
```
PR opened
  └── CI: fmt + validate + tflint + checkov + trivy + gitleaks + ruff + tests + tf plan
        └── Plan output posted to PR
              └── PR approved + merged to main
                    └── apply workflow triggered
                          └── GitHub Environment "lab" gate: manual approval required
                                └── terraform apply runs
```

The GitHub Environment `lab` has `gitIgorrz` as a required reviewer.
The OIDC federated credential subject for apply is scoped to `environment:lab` (ADR-008).

## Rationale

- **`terraform apply` is irreversible for some resources** (role assignments, federated
  credentials, resource groups with data). A manual gate between plan and apply is the
  minimum viable control.
- **GitHub Environment** provides a built-in approval workflow with audit log — who approved,
  when, from which run.
- **OIDC subject scoping** ties the Azure token grant to the Environment gate being passed:
  a run that bypasses the Environment cannot obtain the Azure token for apply.
- **Plan on PR, apply on main**: the reviewer sees the plan diff before approving the PR,
  and the same plan's apply is what runs after the gate. No surprise mutations.

## ⚠️ RISK: Lab self-approval

This is a single-maintainer repository. `gitIgorrz` will approve their own PRs and their
own Environment gate. **This is documented as a known risk, not best practice.**

In a production or team setting:
- At least one additional required reviewer on PRs
- Separation of duties: the person who writes the Terraform change is not the same person
  who approves the apply gate
- Consider branch protection rules that prevent the PR author from self-approving

This risk is accepted for the lab because: (a) it is a personal demo, not a shared system,
and (b) the primary goal is demonstrating the *pattern* of gating, not enforcing the
separation that requires a team.

## Consequences

- A GitHub Environment `lab` must be created manually before the first apply (see `scripts/`).
- Required reviewer must be set on the Environment.
- The apply workflow file must reference `environment: lab` to invoke the gate.
- Deployment frequency is limited by the manual approval step — acceptable for a lab.

## Enterprise target

Multiple required reviewers; approval from a separate reviewer than the PR author; time-boxed
deployment windows; integration with change management tooling (ServiceNow / ITSM).
Combined with PIM (ADR-014) for the Azure-side elevation.
