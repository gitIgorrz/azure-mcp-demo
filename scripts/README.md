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
| 3 | [`manual-github-oidc-setup.sh`](manual-github-oidc-setup.sh) | CI app registration + 3 scoped federated credentials | ADR-005, ADR-008, ADR-013 |
| 4 | [`manual-hcp-workspace-setup.sh`](manual-hcp-workspace-setup.sh) | HCP workspace + DPC/OIDC (default) or SP-federated (toggle) variable set | ADR-005, ADR-007 |
| 5 | [`manual-uami-rbac.sh`](manual-uami-rbac.sh) | User-Assigned MI + Reader @ RG scope | ADR-005, ADR-009 |
| 6 | [`manual-pim-setup.sh`](manual-pim-setup.sh) | Entra group + Contributor @ RG (PIM-eligible, or permanent fallback if no P2) | ADR-013, ADR-014 |

> **RG dependency (steps 5–6).** The resource group `rg-mcp-demo-lab` is created by
> **Terraform**, not by these scripts. Steps 5 and 6 reference the RG scope by its resolved
> resource ID, so run them **after** the first `terraform apply` creates the RG (each script
> aborts cleanly if the RG is absent — the chicken-and-egg note is in the script). Steps 1–4
> have no RG dependency and run first. So the real sequence is: 1→2→3→4 → first `terraform
> apply` → 5 → 6 → second `terraform apply`.

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
