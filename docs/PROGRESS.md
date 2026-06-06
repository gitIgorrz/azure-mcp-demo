# PROGRESS.md — azure-mcp-demo session handoff

> Keep this file current. It is the cheapest way to resume work in a new session.
> Update at every CHECKPOINT before `/clear`.

---

## Current status

**Phase:** 8 — Security review ✅ COMPLETE — **all build phases done**
**Last completed step:** Phase 8 security review (OPUS, 2026-06-05) — see `docs/security-review.md`
**Next step:** **Provisioning** — operator runs the Phase 2 + Phase 6 manual steps
(pre-flight checklist in `docs/security-review.md` / `docs/runbook.md`). Nothing deployed yet.

---

## Phase completion log

### Phase 0 — Design pass ✅
- Architecture summary, decisions D1–D14, risks, phased plan produced and approved by Igor.
- Key decisions: Container Apps, GHCR not ACR, public HTTPS ingress (lab), secretless
  end-to-end, read-only tools only, Entra JWT validation, HCP DPC toggle, GitHub OIDC
  tightly scoped, UAMI Reader at RG scope, Python + MCP SDK + DefaultAzureCredential,
  multi-stage non-root digest-pinned image, min Log Analytics + Budget alert, GitHub
  Environment gate for apply, PIM for apply access.

### Phase 1 — Foundations ✅
Completed steps (all files created, no cloud mutations):
- [x] Repo directory tree created: `terraform/`, `app/`, `.github/workflows/`, `docs/background/`, `docs/decisions/`, `tests/`, `scripts/`
- [x] Pitch file copied to `docs/background/MCP_Enabling_Capability_Pitch.txt`
- [x] `.claudeignore` written (excludes pitch, `.terraform/`, `__pycache__/`, build artifacts)
- [x] `docs/background/architecture-intent.md` — ≤1-page enterprise vision distillation
- [x] `CLAUDE.md` — full source of truth (purpose, architecture, standards, guardrails, naming, model strategy, destructive-command rules, token discipline)
- [x] `README.md` — project overview, quick links, tools, cost profile
- [x] `CONTRIBUTING.md` — branch naming, GPG signing, conventional commits, pre-commit, PR process
- [x] `SECURITY.md` — security model, lab limitations, reporting, dependency scanning
- [x] `.gitignore` — Terraform, Python, Docker, OS/editor noise
- [x] `CODEOWNERS` — `@gitIgorrz` owns all paths
- [x] `.github/pull_request_template.md` — comprehensive PR checklist
- [x] `docs/decisions/ADR-001` through `ADR-014` — all 14 design decisions documented
- [x] `docs/PROGRESS.md` — this file

### Phase 2 — Identity / Auth core ✅
**Model used: OPUS.** All deliverables are RUN-MANUALLY scripts (no cloud mutations from
the session — per CLAUDE.md § Destructive-command rules). All `bash -n` syntax-checked.
- [x] `scripts/README.md` — run order, operator prerequisites, Azure/Entra permissions,
      safety model (no hardcoded identifiers, no secrets, idempotent, least privilege)
- [x] `scripts/manual-github-oidc-setup.sh` — CI app registration + **3 tightly-scoped**
      federated credentials per ADR-008 (`ref:refs/heads/main` ×2 use, `environment:lab`
      for apply; `pull_request` left commented). Defence-in-depth wildcard refusal; asserts
      zero password credentials. Surfaces `AZURE_*` as non-secret GH **variables**.
- [x] `scripts/manual-uami-rbac.sh` — UAMI `id-mcp-demo-lab` + built-in **Reader @ RG scope**
      (ADR-009). Manual because role-assignment write ≠ Contributor (separation of duties,
      same pattern proven in igor-mcp-lab). Verifies no subscription-scope grant.
- [x] `scripts/manual-hcp-workspace-setup.sh` — dedicated TF identity + HCP-trusting
      federated creds (plan/apply run phases). Both ADR-007 paths documented: **DPC/OIDC
      (default)** and **SP+federated (toggle)** — both secretless; `ARM_CLIENT_SECRET`
      explicitly disallowed (the prior lab's client-secret fallback is forbidden here).
      Optional TFE-API workspace+var automation gated on a runtime `TFE_TOKEN` (never stored).
- [x] `scripts/manual-pim-setup.sh` — Entra group `grp-mcp-demo-tf-apply` + **PIM-eligible
      (not permanent) Contributor @ RG scope** via ARM `roleEligibilityScheduleRequests`
      (ADR-014). Activation-policy portal steps, self-activation risk noted, P2-unavailable
      fallback left commented. Verifies no standing Contributor.
- [x] `scripts/manual-gpg-setup.sh` — **detect + reuse** existing key (design Q5); never
      generates (CLAUDE.md rule). Sets `--local` signing config, exports public key for
      GitHub, signing self-test.
- [x] ADR review: ADR-005, ADR-007, ADR-008, ADR-009, ADR-013, ADR-014 confirmed complete
      and consistent with the scripts.

**These scripts have NOT been executed.** Igor runs them manually (see `scripts/README.md`
run order) once he is ready to provision identities. No GitHub repo / HCP workspace exists
yet (repo creation is Phase 6); the scripts are the canonical reference for that provisioning.

---

### Phase 3 — MCP server token validation ✅
**Model used: OPUS** (security-critical). Implements ADR-006/ADR-005. Delivered the inbound
Entra JWT auth core as a transport-agnostic, hermetically-testable module:
- [x] `app/auth/config.py` — `AuthSettings`, env-var only (no hardcoded ids); validates
      tenant/audience/app-id GUIDs; derives **tenant-pinned v2.0** issuer + JWKS URLs.
      Env: `MCP_TENANT_ID`, `MCP_AUDIENCE` (comma-sep), `MCP_ALLOWED_APP_IDS` (optional
      allow-list), `MCP_JWKS_CACHE_TTL_SECONDS` (def 3600), `MCP_JWT_LEEWAY_SECONDS` (def 60).
- [x] `app/auth/errors.py` — `AuthConfigError` (startup) vs `AuthError` (per-request, 401);
      `SigningKeyUnavailableError` → 503 (fail-closed on JWKS outage). Reasons are
      token-free / safe to log + return.
- [x] `app/auth/validator.py` — `EntraTokenValidator`: **RS256-pinned** (blocks `alg:none`
      + HS256 confusion), validates iss/aud/exp/nbf + `tid` (cross-tenant replay), `oid`/`sub`
      presence, optional `azp`/`appid` allow-list, `ver==2.0`. PyJWT[crypto] + `PyJWKClient`
      (JWKS caching, TTL). Injectable `signing_key_resolver` for hermetic tests. Returns
      `ValidatedClaims` (never holds the raw token).
- [x] `app/auth/middleware.py` — `EntraAuthMiddleware` (pure ASGI, framework-free): gates the
      HTTP transport, 401/503 + RFC 6750 `WWW-Authenticate`, attaches claims to
      `request.state.auth`, WARN-logs failures **without** the token. `exempt_paths` for the
      Phase-4 health-probe path.
- [x] `app/requirements.txt` — `PyJWT[crypto]` only (Phase 4 appends mcp + azure SDKs).
      `requirements-dev.txt` — pytest + starlette + httpx (test harness).
- [x] `tests/` — `test_auth_validator.py` (20 cases incl. alg-none/HS256 confusion, wrong
      key, cross-tenant, expiry+leeway, allow-list), `test_auth_config.py`, `test_auth_middleware.py`
      (Starlette TestClient), `conftest.py` (local RSA keypair + token factory).
- [x] `docs/auth-contract.md` — caller-facing contract (token acquisition, validated claims
      table, 401/503 responses, operator env vars). Phase 7 `connecting-agents.md` references it.

**✅ Tests executed and passing: 35/35** (Python 3.12.10 installed via winget 2026-06-05;
venv at `.venv/`, gitignored). Run hermetically (no network/tenant):
`python -m venv .venv; .venv\Scripts\python -m pip install -r requirements-dev.txt; .venv\Scripts\python -m pytest`.
One benign warning (PyJWT InsecureKeyLengthWarning) is emitted by the test harness while it
*builds* the HS256-confusion token that the validator then correctly rejects — not prod code.

**CHECKPOINT:** Phase 3 done. `/clear` and resume in a new session for Phase 4
(App + container — **SONNET**, mechanical scaffolding). Phase 4 wires `EntraAuthMiddleware`
as the outermost HTTP layer and sets its `exempt_paths` to the container probe path.

---

### Phase 4 — App + container ✅
**Model: SONNET** (2026-06-05). Delivers the MCP server implementation and container image definition.

- [x] `app/tools/__init__.py` — `register_all(mcp)` entry point
- [x] `app/tools/health.py` — `health` MCP tool (server liveness for MCP clients)
- [x] `app/tools/azure_tools.py` — `get_subscription`, `list_resource_groups`, `list_resources`
      (Resource Graph). `DefaultAzureCredential` lazy singleton. KQL injection prevention via
      `_RG_NAME_RE` regex on the caller-supplied `resource_group` parameter before interpolation.
      All reads are RBAC-scoped by the UAMI's Reader assignment at RG level (ADR-009).
- [x] `app/server.py` — FastMCP instance + `register_all` + `create_app()` ASGI factory.
      Stack: `EntraAuthMiddleware` → Starlette router → `/health` probe + `Mount(/)` MCP app.
      `/health` is exempt from auth for container liveness probes. stdio transport available via
      `MCP_TRANSPORT=stdio` or `--stdio` flag (local dev only; no auth enforced in that mode).
- [x] `app/requirements.txt` — appended: `mcp`, `azure-identity`, `azure-mgmt-resource`,
      `azure-mgmt-subscription`, `azure-mgmt-resourcegraph`, `uvicorn[standard]`.
- [x] `pyproject.toml` — project metadata, setuptools build, ruff (formatter + linter),
      pytest config (`testpaths`, `pythonpath`).
- [x] `Dockerfile` — two-stage (builder/final), non-root UID 65532, `HEALTHCHECK` via
      `urllib.request`, `CMD` uses `uvicorn --factory`. Base image digest pinning via
      `--build-arg PYTHON_IMAGE=python:3.12-slim@sha256:<digest>` (Phase 6 CI resolves).
- [x] `.dockerignore` — excludes `.venv`, `__pycache__`, `tests/`, `terraform/`, `docs/`,
      `scripts/`, `.github/`, dev config.

**✅ Tests: 35/35 passing** (Phase 3 suite; Phase 4 tool tests deferred to Phase 6 with mocks).
One benign InsecureKeyLengthWarning from the HS256 confusion test fixture — unchanged from Phase 3.

**CHECKPOINT:** Phase 4 done. `/clear` and resume in a new session for Phase 5
(Terraform — **SONNET**, mechanical IaC scaffolding).

---

### Phase 5 — Terraform ✅
**Model: SONNET** (2026-06-05). All IaC files written; `terraform fmt` clean.

**Ownership model:** Terraform owns RG, UAMI, Log Analytics, Container App env + app,
diagnostics, and budget. The Reader role assignment (UAMI → RG) is the only out-of-band
step (`scripts/manual-uami-rbac.sh`) because it needs User Access Admin rights beyond the
CI identity's Contributor scope.

**First-apply order** (documented in `terraform/main.tf` header comment):
1. `terraform apply` → creates RG + UAMI + Log Analytics + CAE
2. `scripts/manual-uami-rbac.sh` → assigns Reader to UAMI at RG scope
3. `terraform apply` (again) → creates the Container App

- [x] `terraform/versions.tf` — `required_version = "~> 1.9"`, `azurerm ~> 4.0`,
      `cloud {}` block (HCP TF org `gitIgorrz` / workspace `azure-mcp-demo`, ADR-007).
- [x] `terraform/variables.tf` — `subscription_id`, `environment` (lab/int/prod validation),
      `location` (default `australiaeast`), `mcp_tenant_id` (GUID validation), `mcp_audience`,
      `mcp_allowed_app_ids` (optional, default ""), `container_image`, `budget_amount_usd`
      (default 10), `budget_notification_email`, `budget_start_date`.
- [x] `terraform/main.tf` — locals (naming + tags), `azurerm_resource_group`,
      `azurerm_user_assigned_identity`, `azurerm_log_analytics_workspace` (30-day PerGB2018),
      `azurerm_container_app_environment`, `azurerm_container_app` (0.25 CPU / 0.5 Gi,
      min=0 / max=1, UAMI attached, `AZURE_CLIENT_ID` set for unambiguous credential pickup,
      `/health` liveness + readiness probes, HTTP ingress external, dynamic env for
      `MCP_ALLOWED_APP_IDS`), `azurerm_monitor_diagnostic_setting` ×2 (CA + CAE → LAW),
      `azurerm_consumption_budget_resource_group` (80% actual + 100% forecast alerts).
- [x] `terraform/outputs.tf` — `container_app_fqdn`, `container_app_health_url`,
      `log_analytics_workspace_id`, `uami_client_id`, `uami_principal_id`,
      `resource_group_name`, `resource_group_id`.

**`terraform.lock.hcl`**: not yet generated — run `terraform init` (with HCP TF auth or
`-backend=false` override) to produce it. Phase 6 CI commits it after `tf-validate` workflow
first run. `terraform fmt` passed cleanly on all files.

**CHECKPOINT:** Phase 5 done. `/clear` and resume in a new session for Phase 6
(CI/CD + governance — **SONNET**, mechanical workflow scaffolding).

---

### Phase 6 — CI/CD + governance ✅
**Model: SONNET** (2026-06-05).

- [x] `.github/workflows/lint.yml` — ruff (format + lint), terraform fmt, yamllint, markdownlint; triggers on PR + push to main.
- [x] `.github/workflows/unit-tests.yml` — pytest (Python 3.12), triggers on PR + push to main. Uses pyproject.toml pythonpath config.
- [x] `.github/workflows/tf-validate.yml` — `terraform init -backend=false` + `terraform validate` + checkov (no HCP TF auth needed); path filter: `terraform/**`, PR only.
- [x] `.github/workflows/tf-plan.yml` — full plan via HCP TF (needs `HCP_TF_TOKEN`); posts plan as PR comment (deletes stale, posts fresh); path filter: `terraform/**`, PR only.
- [x] `.github/workflows/build-push.yml` — resolves Python base image digest, builds + pushes to GHCR (`ghcr.io/gitigorrz/azure-mcp-demo@sha256:<digest>`); uploads `image-ref` artifact; triggers on app/Dockerfile changes on main.
- [x] `.github/workflows/tf-apply.yml` — `workflow_run` on Build & Push success + `workflow_dispatch` fallback; downloads `image-ref` artifact; `environment: lab` gate (human approval); apply via HCP TF; uploads `health-url` artifact.
- [x] `.github/workflows/smoke-test.yml` — `workflow_run` on Terraform Apply success; downloads `health-url` artifact; GETs `/health`, asserts `status == "ok"`.
- [x] `.pre-commit-config.yaml` — gitleaks v8.21.2, ruff v0.9.7, terraform_fmt (pre-commit-terraform v1.96.1), checkov 3.2.250.
- [x] `.yamllint.yml` — allows `on:` trigger key; 120-char line limit warning.
- [x] `docs/branch-protection.md` — manual setup guide: branch rule, required status checks, GitHub Environment `lab`, Actions secrets/variables, SHA verification commands, CODEOWNERS enforcement.

**Cross-workflow data flow:**
- `build-push` → `tf-apply`: `image-ref` artifact (`ghcr.io/gitigorrz/azure-mcp-demo@sha256:<digest>`)
- `tf-apply` → `smoke-test`: `health-url` artifact (`https://<fqdn>/health`)

**GitHub secrets and variables needed before first run** (see `docs/branch-protection.md`):
- Secret: `HCP_TF_TOKEN`
- Variables: `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID`

**Action SHAs need verification** before first run — use `gh api` commands in `docs/branch-protection.md §4`.

**CHECKPOINT:** Phase 6 done. `/clear` and resume in a new session for Phase 7
(Docs, cost, teardown — **SONNET**, mechanical doc scaffolding).

---

### Phase 7 — Docs, cost, teardown ✅
**Model: SONNET** (2026-06-05).

- [x] `docs/cost.md` — cost by service (table), monthly estimate, budget alert ref, optimization levers, decommission checklist (terraform destroy → identity cleanup → repo delete → HCP workspace delete).
- [x] `docs/connecting-agents.md` — token acquisition, SRE Agent (Azure AI Foundry preview), Claude Code (`.claude/mcp.json`), VS Code/Copilot Chat (`.vscode/mcp.json` with input prompt), custom Python MCP client + raw curl, troubleshooting table.
- [x] `docs/runbook.md` — end-to-end operator guide: prerequisites, Phase A (identity fabric scripts), Phase B (GitHub repo + branch protection), Phase C (first TF apply 2-step), Phase D (first deploy), Phase E (connect a client), day-to-day ops, decommission checklist.
- [x] `scripts/teardown/README.md` — run order (5 steps), what each removes, verify commands.
- [x] `scripts/teardown/manual-teardown-identities.sh` — removes CI app reg + fed creds, PIM group + eligible role, GitHub Actions env + secrets/vars, GPG key from GitHub (optional, step only). Pre-checks TF destroy completed.

**CHECKPOINT:** Phase 7 done. `/clear` and resume in a new session for Phase 8
(Security review — **OPUS**, final gate before "done").

---

### Phase 8 — Security review ✅
**Model: OPUS** (2026-06-05) — final gate. Full report: `docs/security-review.md`.

**Verdict: APPROVED for provisioning.** No critical/high findings. All 10 CLAUDE.md
guardrails satisfied. This was a **pre-deployment artifact review** (nothing deployed; Phase 2 +
Phase 6 manual steps not yet run — that is by design, they are the operator's provisioning runbook).

- [x] Audited auth core (RS256-pinned, iss/aud/tid/exp, no header injection, fail-closed),
      tools (KQL injection blocked, read-only), server wiring (middleware outermost), Dockerfile
      (non-root, digest pin), terraform (RBAC, tags, no secrets), workflows (SHA-pinned, minimal
      perms, `pull_request` not `pull_request_target`), identity scripts (secretless, verify blocks).
- [x] Tool gate (scanners installed **globally**, pinned to CI versions): pytest **35/35**;
      gitleaks **no leaks**; trivy config terraform/Dockerfile **0**; trivy fs secret **clean**;
      checkov Dockerfile 81/1 (1 = false-positive ARG); ruff clean after fix.
- [x] **Fixed F1** (CI-blocking): `app/` failed its own pinned ruff format+lint → auto-fixed,
      tests still 35/35. **Fixed F2** (low): added explicit `allow_insecure_connections = false`
      to ingress + corrected the misleading tf-validate.yml comment.
- [x] Logged H1–H5 hardening recs (dep pinning/lockfile, ADR for CI SP sub-Reader, websocket
      scope note, optional `ver` check, checkov skip comment) — all non-blocking.
- [x] Scanner install steps + full local-gate added to CONTRIBUTING.md §5–6.

**Scanners now installed globally on this host:** gitleaks 8.30.1 + trivy 0.71.0 (winget),
ruff 0.9.7 + checkov 3.2.250 (pip, pinned to CI). Reproducible local gate documented.

**NEXT (operator):** provisioning via the pre-flight checklist in `docs/security-review.md`.

### Provisioning-readiness pass ✅ (OPUS, 2026-06-05)
Verified the operator workstation + identity readiness and closed two gaps before go-live.

**Workstation verified:** Python 3.12.10, Terraform 1.15.5, Azure CLI 2.86, GitHub CLI 2.93,
GPG 2.5.19, git 2.54, ruff 0.9.7 all present. `az` logged in (Pay-As-You-Go, correct
subscription + tenant ✓), `gh` logged in (gitIgorrz).
Missing: Docker (optional — CI builds the image), pre-commit (pip install when needed).

**Permissions verified (read-only checks):** operator is **Global Administrator** (Entra) +
**Owner @ subscription** → covers App Admin, Priv Role Admin, User Access Admin, Contributor.
**No Entra ID P2** (tenant has zero license SKUs) → PIM unavailable → fallback path chosen.

**Gaps closed:**
- **Added `scripts/manual-server-app-registration.sh`** — the missing resource/audience app reg.
  Creates `api://<appId>`, pins v2.0 tokens (`requestedAccessTokenVersion=2`), exposes delegated
  scope `access_as_user` + app role `mcp.access`, asserts zero credentials. **This is the source
  of `MCP_AUDIENCE`** — without it no client token can pass the `aud` check. Wired into run order
  as step 2 (no RG dependency; runs before first apply). `bash -n` clean.
- **Reworked `scripts/manual-pim-setup.sh`** — added `PIM_MODE` (`fallback` default, `pim` opt-in).
  Fallback = permanent Contributor @ RG with ADR-014 compensating controls; verify block branches
  per mode (fallback asserts the RG grant exists + no subscription-scope grant). `bash -n` clean.
- **Fixed `scripts/teardown/manual-teardown-identities.sh`** — it looked for a non-existent
  `sp-mcp-demo-ci-lab` and would have **orphaned** the real app regs. Now deletes all three by
  their actual names (github-oidc, hcp-tf, api). `bash -n` clean.

**Real run order (interleaved):** gpg → server-app-reg → github-oidc → hcp-workspace → [repo +
branch-protection] → first `terraform apply` (RG+UAMI) → uami-rbac → pim-setup (PIM_MODE=fallback)
→ second `terraform apply` (Container App) → smoke test → connect client (audience `api://<appId>`).

Docs updated: scripts/README.md, runbook.md, security-review.md (H6 + addendum). All 7 scripts `bash -n` clean.

**Additional prep (non-destructive):**
- Added `terraform/terraform.tfvars.example` — documents every TF input with placeholders
  (sub/tenant/audience/container_image). For the HCP-driven workspace these go in as workspace vars.
- Hardened `.gitignore` — now ignores `*.tfvars` (allows only `*.tfvars.example`) so real values
  can't be committed.
- Installed `pre-commit` 4.6.0 globally; `.pre-commit-config.yaml` validates clean.

**GPG signing — RESOLVED ✅ (2026-06-06):** the previously configured signing key was lost (no
private key on this machine), so a new RSA-4096 key was generated, git was repointed at the
correct gpg (see the Windows two-gpg-keyrings gotcha in CONTRIBUTING.md), signing was verified,
and the public key was uploaded to GitHub. The detailed execution journal (with the real
resource/identity IDs) is kept **local-only** in `docs/provisioning-log.md`, which is gitignored.

**Provisioning readiness verdict:** workstation + permissions ready; GPG signing ready. Only
external dependency remaining is an HCP Terraform account (org gitIgorrz / project igor-lab +
API token). Execution is tracked in the local-only `docs/provisioning-log.md`.

---

## Open questions (from design pass §4)

| # | Question | Status |
|---|----------|--------|
| Q1 | Public ingress + SRE Agent auth: server-side JWT as primary control — acceptable for lab? | **Accepted** (ADR-003, ADR-006) |
| Q2 | Custom role vs built-in Reader | **Built-in Reader at RG scope** (ADR-009) |
| Q3 | Resource Graph scope: RG (not subscription) | **Confirmed** (ADR-009) |
| Q4 | HCP execution mode: VCS-driven default | **VCS-driven recommended** (ADR-007, Phase 2 script) |
| Q5 | GPG key reuse: detect existing, don't generate | **Detect and reuse** (Phase 2 script) |
| Q6 | Lab self-approval | **Documented as RISK** (ADR-013, ADR-014) |

---

## Useful commands (session start)

```powershell
# Verify no API key set (must be empty)
echo $env:ANTHROPIC_API_KEY

# Check context size
# /context

# Check usage
# /usage
```

---

## Repo location

`c:\Users\Igor_\Desktop\REPOS\azure-mcp-demo\`

GitHub: `github.com/gitIgorrz/azure-mcp-demo` *(repo not yet created — Phase 6 / manual)*
HCP TF: org `gitIgorrz` / project `igor-lab` / workspace `azure-mcp-demo` *(not yet created — Phase 2 manual)*
