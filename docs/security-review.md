# Security Review — Phase 8 (final gate)

**Date:** 2026-06-05
**Reviewer model:** Opus (`claude-opus-4-8`) — per CLAUDE.md model strategy (security review = Opus).
**Scope:** Static / artifact review of the whole repository against the CLAUDE.md security
guardrails, plus a tool pass (pytest, ruff, gitleaks, trivy, checkov).

> **Nature of this review — read this first.** Nothing has been deployed. No Azure resources,
> no GitHub repo, no HCP TF workspace, and no CI run exist yet. The Phase 2 (identity fabric)
> and Phase 6 (repo + branch protection) **manual** steps have **not** been executed. This is
> therefore a **pre-deployment artifact review**: it certifies that the code, IaC, scripts, and
> workflows are correct and secure *as written*. Several of the strongest controls
> (no-wildcard federated subjects, Reader-at-RG, PIM-eligible-only Contributor, branch
> protection + environment approval) are **enforced at provisioning time** by the verification
> blocks inside the `scripts/manual-*.sh` files. This review confirms those scripts *will*
> enforce them; **running them is what makes the posture real.** See the pre-flight checklist
> at the end.

---

## Verdict

**APPROVED for provisioning.** No critical or high-severity security findings. All
CLAUDE.md non-negotiable guardrails are satisfied in the artifacts. Two CI-blocking
lint issues and one documentation-accuracy issue were found **and fixed** during the review
(see *Findings → Fixed*). Remaining items are low-severity hardening recommendations.

---

## Tooling results

| Tool | Version | Target | Result |
|------|---------|--------|--------|
| pytest | (3.12 venv) | `tests/` | **35 passed**, 1 benign warning¹ |
| ruff format | 0.9.7 (CI-pinned) | `app/` | **clean** (after fix) |
| ruff check | 0.9.7 (CI-pinned) | `app/` | **clean** (after fix) |
| gitleaks | 8.30.1 | `app/ scripts/ terraform/ .github/ tests/ docs/` | **no leaks found**⁴ |
| trivy config | 0.71.0 | `terraform/` | **0 misconfigurations** (HIGH/CRITICAL) |
| trivy config | 0.71.0 | `Dockerfile` | **0 misconfigurations** |
| trivy fs (secret) | 0.71.0 | repo (excl. `.venv`) | **clean** |
| checkov | 3.2.250 (CI-pinned) | `Dockerfile` | 81 passed / 1 failed² |
| checkov | 3.2.250 (CI-pinned) | `terraform/` | inconclusive locally³ |

¹ `InsecureKeyLengthWarning` is emitted by the test *fixture* while it builds the short-key
HS256 token that `test_hs256_confusion_rejected` then correctly rejects. Not production code.

² `CKV_DOCKER_7` ("base image uses a non-latest tag") is a **false positive**: the Dockerfile
uses `FROM ${PYTHON_IMAGE}` and checkov cannot resolve the ARG. The deployed image is
digest-pinned by CI (`build-push.yml` resolves `python:3.12-slim@sha256:…`). `trivy config`
on the same Dockerfile reports **0** issues, confirming the false positive.

³ checkov's Terraform scan rendered an empty result table on this Windows host (banner only,
even single-file). `trivy config terraform/` provides equivalent IaC coverage (0 findings) and
CI runs checkov on Linux. The local-gate note is documented in CONTRIBUTING.md §6.

⁴ The committed source dirs are clean. A naïve `gitleaks dir .` over the repo root reports 38
hits — **all 38 are inside `.venv/`** (third-party package test fixtures), which is gitignored
and never committed. CI uses git-mode gitleaks (tracked files only), so `.venv` is never in
scope. CONTRIBUTING.md §6 documents scanning source dirs instead of the repo root.

---

## Guardrail audit (CLAUDE.md § Security guardrails)

| # | Guardrail | Status | Evidence |
|---|-----------|--------|----------|
| 1 | No committed secrets | ✅ | gitleaks clean; all IDs passed as non-secret env/vars; `ARM_CLIENT_SECRET` explicitly forbidden in HCP script |
| 2 | No long-lived credentials | ✅ | OIDC/federated creds only; both identity scripts assert **zero** password credentials |
| 3 | No destructive MCP tools | ✅ | `app/tools/` exposes only `health`, `get_subscription`, `list_resource_groups`, `list_resources` — all reads |
| 4 | Entra JWT validation mandatory | ✅ | `EntraAuthMiddleware` is the outermost ASGI layer; only exact-match `/health` is exempt; tool code runs after validation |
| 5 | Least privilege | ✅ | UAMI = Reader @ RG scope; `manual-uami-rbac.sh` asserts no subscription-scope grant. (CI SP has subscription **Reader** — read-only, see hardening H2) |
| 6 | HTTPS only | ✅ | `allow_insecure_connections = false` now **explicit** in ingress (was relying on default) |
| 7 | Non-root container | ✅ | Dockerfile creates uid/gid 65532 and `USER appuser` before CMD |
| 8 | Image pinned by digest | ✅ | CI passes `PYTHON_IMAGE=…@sha256:…`; TF `container_image` var requires `@sha256` digest |
| 9 | gitleaks in CI + pre-commit | ✅ | `.pre-commit-config.yaml` + lint gate; verified clean locally |
| 10 | No wildcard federated subjects | ✅ | Both scripts refuse `*` in subjects (defence-in-depth) and assert none exist post-run |

### JWT validator — deep review (the security core)

`app/auth/validator.py` is correct and fail-closed:

- **`algorithms=["RS256"]` pinned** → blocks `alg:none` and HS256-confusion (verified by
  `test_alg_none_rejected`, `test_hs256_confusion_rejected`).
- **Issuer pinned** to tenant-specific v2.0 (`…/{tenant}/v2.0`); v1.0 issuer and other tenants
  rejected. JWKS URL is likewise tenant-pinned. Config GUID-validates `tenant_id`/`app_ids`
  before they ever reach a URL → no injection into the issuer/JWKS endpoints.
- **`aud`, `exp`/`nbf` (with bounded leeway), `tid` (cross-tenant replay), `oid`/`sub` presence**
  all enforced; optional `azp`/`appid` allow-list.
- **Token never logged**; `WWW-Authenticate` reasons are fixed, quote-free constants → no
  response-header injection. 401 vs 503 split is correct (bad token vs JWKS outage, both
  fail-closed).

### KQL injection — `list_resources`

`_RG_NAME_RE = ^[a-zA-Z0-9._\-()]{1,90}$` validates the caller-supplied `resource_group`
**before** interpolation into the `=~ '…'` literal. Single quotes, backticks, semicolons, and
backslashes are excluded, so the value cannot break out of the string literal. Unfiltered
queries are capped at `take 200`. RBAC scoping is enforced server-side by the UAMI's Reader
assignment.

### Identity scripts — secretless chain

`manual-github-oidc-setup.sh`, `manual-hcp-workspace-setup.sh`, `manual-uami-rbac.sh`, and
`manual-pim-setup.sh` are least-privilege, idempotent, and each ends with a **verification
block that asserts the negative** (no wildcard subject, no password credential, no
subscription-scope grant, no *permanent* Contributor). Separation of duties is preserved: the
deploy identity never receives `roleAssignments/write`.

---

## Findings

### Fixed during this review

| ID | Sev | Finding | Fix |
|----|-----|---------|-----|
| F1 | CI-blocking | `app/` did not pass its own pinned `ruff format --check` (3 files) and `ruff check` (RUF022, UP037×2). CI lint job would have been red on the first PR. | `ruff format app/` + `ruff check --fix app/`; re-verified clean; 35/35 tests still pass |
| F2 | Low | `tf-validate.yml` justified the `CKV_AZURE_140` soft-fail by citing `allow_insecure_connections = false`, but that attribute was **not set** in `main.tf` (relied on the secure default) — a misleading comment. | Added `allow_insecure_connections = false` explicitly to the ingress block; corrected the workflow comment |

### Open — hardening recommendations (non-blocking)

| ID | Sev | Recommendation |
|----|-----|----------------|
| H1 | Low | **Pin runtime dependencies / add a lockfile.** `app/requirements.txt` uses version *ranges*, so `trivy fs --scanners vuln` cannot resolve CVEs and builds are not byte-reproducible. Consider a hash-pinned `requirements.lock` (or `pip-tools`/`uv`) so the image is scannable and reproducible. |
| H2 | Low | **Document the CI SP's subscription-scope Reader.** `manual-github-oidc-setup.sh` grants the CI service principal **Reader at subscription scope** (read-only, justified for `terraform plan` state refresh before the RG exists). This exceeds RG scope; capture the justification in an ADR for parity with ADR-009 (which covers the UAMI). |
| H3 | Info | **Auth middleware passes non-HTTP scopes through.** `websocket` ASGI scopes bypass `EntraAuthMiddleware`. No websocket routes exist (MCP Streamable-HTTP is all `http` scope), so there is no current exposure; note it so a future transport addition does not silently skip auth. |
| H4 | Info | **`ver` claim is only checked when present.** A token lacking `ver` passes the v2.0 marker check. The tenant-pinned v2.0 issuer already rejects v1.0 tokens, so this is defence-in-depth only; optionally require `ver == "2.0"`. |
| H5 | Info | **checkov `CKV_DOCKER_7` false positive** (base-image ARG). Optionally add a `# checkov:skip=CKV_DOCKER_7: digest pinned by CI` comment in the Dockerfile to keep the report clean. |
| H6 | Med | **No Entra ID P2 in the lab tenant** (verified 2026-06-05 — tenant has zero license SKUs), so PIM (ADR-014 preferred path) is unavailable. `manual-pim-setup.sh` now defaults to `PIM_MODE=fallback`: **permanent** Contributor at **RG scope** with the ADR-014 compensating controls (RG-scope only, GitHub Environment approval gate, tight federated subjects, audit logging, quarterly access review). Re-run with `PIM_MODE=pim` if P2 is later added. |

### Addendum (post-review readiness pass, 2026-06-05)

A readiness check before provisioning surfaced — and closed — a gap not visible in the original
artifact set: **no manual step created the server's API/resource app registration**, so
`MCP_AUDIENCE` had no source and no client token could ever satisfy the `aud` check. Added
`scripts/manual-server-app-registration.sh` (creates `api://<appId>`, pins v2.0 tokens, exposes
a delegated scope + an app role, asserts zero credentials) and wired it into the run order as
step 2. Also reworked `manual-pim-setup.sh` for the no-P2 reality (H6). Neither change weakens
the review verdict; both make provisioning executable. All `scripts/*.sh` remain `bash -n` clean.

---

## Pre-flight checklist before going live (Phase 2 + Phase 6 manual steps)

These are **operator** steps (Igor), run in order. Each script self-verifies; treat a FAIL as a
stop. Full detail in `docs/runbook.md` and `scripts/README.md`.

1. `scripts/manual-gpg-setup.sh` — detect/reuse signing key (CONTRIBUTING.md GPG section).
2. `scripts/manual-server-app-registration.sh` — resource/audience app reg (`api://<appId>`,
   v2.0 tokens, scope + app role); asserts no password cred. **Sets `var.mcp_audience` /
   `MCP_AUDIENCE`** — without this no client token can pass the `aud` check.
3. `scripts/manual-github-oidc-setup.sh` — CI app reg + 3 scoped federated creds; asserts no
   wildcard, no password cred.
4. `scripts/manual-hcp-workspace-setup.sh` — HCP TF identity + DPC/OIDC (no `ARM_CLIENT_SECRET`).
5. Create the GitHub repo; apply `docs/branch-protection.md` — required checks, `lab`
   Environment approval gate, CODEOWNERS, **verify action SHAs** (`gh api` commands in §4).
6. First Terraform apply is **2-step** (`main.tf` header): apply (creates RG + UAMI) →
   `scripts/manual-uami-rbac.sh` (Reader @ RG; asserts no subscription-scope grant) →
   `scripts/manual-pim-setup.sh` (Contributor @ RG; **`PIM_MODE=fallback`** — tenant has no
   P2, see H6) → apply again (creates the Container App).

After step 6, `smoke-test.yml` GETs `/health` and asserts `status == "ok"`. Connect a client
per `docs/connecting-agents.md` using audience `api://<appId>` from step 2.

---

## Sign-off

Artifacts reviewed against all 10 CLAUDE.md guardrails and a five-tool static pass. No
critical/high findings; F1/F2 fixed; H1–H5 logged as non-blocking hardening. **The repository
is approved to proceed to provisioning** via the pre-flight checklist above. The runtime
security posture is contingent on those manual steps completing with their verifications green.
