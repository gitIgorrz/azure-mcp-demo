# scripts/ — RUN-MANUALLY identity & auth setup

> **These scripts are never executed automatically by Claude or by CI.**
> They mutate cloud, identity, and repository state (Azure app registrations,
> federated credentials, RBAC role assignments, HCP workspaces, Entra PIM, GPG/Git
> config). Each must be **read, understood, and run manually** by the operator
> (`gitIgorrz`) from an authenticated shell. See [CLAUDE.md](../CLAUDE.md)
> § *Destructive-command rules*.

> **⚠️ Run these in a BASH shell — not PowerShell.** Every `manual-*.sh` here is a Bash script
> (uses `mapfile`, heredocs, `awk`, `/proc`…). On Windows, open **Git Bash / MINGW64** (right-click
> in the repo → "Git Bash Here", or run `bash scripts/<name>.sh`). Running them in PowerShell or
> CMD will fail. `az` login, `python`, and `gpg` are all available inside Git Bash — but note the
> **GPG keyring gotcha** in CONTRIBUTING.md (Git's bundled gpg ≠ your Gpg4win keyring).
>
> **Two Windows/Git-Bash gotchas these scripts already handle for you:**
> - **Path mangling.** Git Bash rewrites any argument that looks like a Unix path (e.g. an ARM
>   scope `/subscriptions/...`) into a Windows path, which corrupts `az role assignment --scope`
>   and yields a confusing `MissingSubscription` error. Each script now sets
>   `export MSYS_NO_PATHCONV=1` to disable that (no-op on Linux/macOS). If you ever run an ad-hoc
>   `az role assignment` command yourself in Git Bash, prefix it with `MSYS_NO_PATHCONV=1`.
> - **Wrong gpg.** `manual-gpg-setup.sh`'s `command -v gpg` resolves to Git's bundled gpg (a
>   different, often empty keyring) — point `git config gpg.program` at your real gpg instead
>   (CONTRIBUTING.md → GPG signing → Windows gotcha).

These scripts establish the **secretless identity fabric** (ADR-005) for
`azure-mcp-demo`. Phase 2 of the build. Nothing here stores a secret; every trust
relationship is OIDC / federated / managed-identity based.

---

## Safety model

- **No identifiers are hardcoded.** Subscription ID, tenant ID, object IDs, and
  client IDs are derived at runtime (`az account show`, `az ad …`) or passed as
  shell variables you set at the top of each run. Nothing sensitive is committed.
- **No `--client-secret`, no passwords, no `ARM_CLIENT_SECRET`** appears anywhere.
  If a step appears to need one, stop — it is the wrong path (ADR-005, ADR-007).
- **Idempotency:** each script checks for existing resources before creating and is
  safe to re-run. Creation commands are guarded; verification commands are read-only.
- **Least privilege:** the runtime identity gets `Reader` at resource-group scope
  only (ADR-009). Elevation for `terraform apply` is time-bound via PIM (ADR-014).

---

## Prerequisites (operator workstation)

| Tool | Purpose | Check |
|------|---------|-------|
| Azure CLI ≥ 2.60 | app regs, federated creds, RBAC, PIM | `az version` |
| `az login` (interactive) | authenticated as a user with the rights below | `az account show` |
| GitHub CLI ≥ 2.40 (optional) | set repo/environment secrets/vars | `gh auth status` |
| HCP Terraform access | workspace + variable-set creation | login at app.terraform.io |
| `gpg` ≥ 2.2 + `git` ≥ 2.34 | commit signing | `gpg --version` |

### Azure permissions the operator needs

- **Application Administrator** (or Owner of the app registrations) — to create app
  registrations and federated credentials.
- **User Access Administrator / Owner at the target RG scope** — to create role
  assignments (`manual-uami-rbac.sh`) and the PIM-eligible assignment.
- **Privileged Role Administrator** + **Entra ID P2 / Governance licence** — for PIM
  (`manual-pim-setup.sh`). If P2 is unavailable, see the fallback noted in that script
  and ADR-014.

---

## Run order

Run top-to-bottom; later steps consume identifiers produced by earlier ones.

| # | Script | Creates | ADR |
|---|--------|---------|-----|
| 1 | [`manual-gpg-setup.sh`](manual-gpg-setup.sh) | signed-commit config (detect + reuse key) | CONTRIBUTING.md |
| 2 | [`manual-server-app-registration.sh`](manual-server-app-registration.sh) | resource/audience app reg (`api://<appId>`, v2.0 tokens, scope + app role) → `MCP_AUDIENCE` | ADR-006 |
| 3 | [`manual-hcp-workspace-setup.sh`](manual-hcp-workspace-setup.sh) | HCP TF identity + HCP-trusting federated creds (DPC); workspace + variable set | ADR-005, ADR-007 |
| 4 | [`manual-register-resource-providers.sh`](manual-register-resource-providers.sh) | registers `Microsoft.App` / `Microsoft.Insights` / … on the subscription (else the first apply 409s `MissingSubscriptionRegistration`) | — |
| 5 | [`manual-hcp-tf-bootstrap-rbac.sh`](manual-hcp-tf-bootstrap-rbac.sh) | Contributor @ **subscription** for the HCP TF identity, so the first apply can create the RG | ADR-014 |
| 6 | [`manual-uami-rbac.sh`](manual-uami-rbac.sh) | User-Assigned MI + Reader @ RG scope | ADR-005, ADR-009 |
| 7 | [`manual-pim-setup.sh`](manual-pim-setup.sh) | Entra group + Contributor @ RG (optional: tighten the step-5 grant to RG scope) | ADR-014 |

> **No GitHub→Azure CI identity.** This is the **VCS-driven** model (ADR-007): HCP runs
> Terraform and authenticates to Azure via the DPC federated credentials (step 3). GitHub
> Actions never authenticates to Azure, so there is no `manual-github-oidc-setup.sh` step.

> **RG dependency (steps 6–7).** The resource group `rg-mcp-demo-lab` is created by the first
> Terraform apply, not by these scripts. Steps 6 and 7 reference the RG scope, so run them
> **after** the first apply (each aborts cleanly if the RG is absent). Steps 1–5 have no RG
> dependency. So the real sequence is: 1→2→3→4→5 → first apply (HCP) → 6 → 7. Step 5 grants
> Contributor at **subscription** scope (the RG can't be the scope before it exists); step 7
> can optionally narrow that to RG scope afterward.

> **No Entra ID P2?** `manual-pim-setup.sh` defaults to `PIM_MODE=fallback` (permanent
> Contributor @ RG with compensating controls, ADR-014). The target lab tenant has no P2
> (verified 2026-06-05). Where P2 exists, run it with `PIM_MODE=pim` for eligible-only elevation.

---

## After running

1. Record the produced client IDs / object IDs in your password manager or HCP
   workspace variables — **not** in this repo.
2. Confirm each script's verification block passed.
3. Update [docs/PROGRESS.md](../docs/PROGRESS.md) if any decision changed.
4. Teardown counterparts live in `scripts/teardown/` (Phase 7). Per
   [feedback], resources are destroyed via `terraform destroy` and the documented
   manual-removal steps — never ad-hoc `az … delete`.
