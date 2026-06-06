# Contributing to azure-mcp-demo

Thank you for contributing. This document explains the branch, commit, PR, and review
conventions for this repository.

---

## Ground rules

1. **No direct push to `main`** — all changes via PR.
2. **GPG-signed commits required** — unsigned commits will be rejected.
3. **No secrets** — do not commit credentials, tokens, connection strings, or API keys.
   Use GitHub Secrets or HCP workspace variables. `gitleaks` runs on every PR.
4. **Read-only tools only** — no destructive MCP tool may be merged into `app/`.
5. **IaC must pass `fmt`, `validate`, `tflint`, `checkov`** before merge.
6. **Python must pass `ruff check` and `ruff format --check`** before merge.

---

## Local development environment

The MCP server targets **Python 3.12** (pinned to match the `python:3.12-slim` container base —
[ADR-010](docs/decisions/ADR-010-python-mcp-sdk-defaultazurecredential.md)). Use a virtual
environment so dependencies stay isolated from the system interpreter.

### 1. Install Python 3.12

| OS | Command |
|----|---------|
| Windows | `winget install --id Python.Python.3.12 --scope user` |
| macOS | `brew install python@3.12` |
| Linux (Debian/Ubuntu) | `sudo apt install python3.12 python3.12-venv` |

> Windows note: a fresh terminal picks up the new `PATH` automatically; an already-open
> shell needs to be reopened (or the `PATH` refreshed) before `python` resolves.

### 2. Create and activate a virtual environment

```powershell
# Windows (PowerShell) — from the repo root
python -m venv .venv
.\.venv\Scripts\Activate.ps1
```

```bash
# macOS / Linux
python3.12 -m venv .venv
source .venv/bin/activate
```

`.venv/` is gitignored — never commit it.

### 3. Install dependencies

```bash
# Dev deps also pull in the runtime deps via `-r app/requirements.txt`
python -m pip install --upgrade pip
python -m pip install -r requirements-dev.txt
```

`app/requirements.txt` is the **runtime** dependency set (what ships in the container);
`requirements-dev.txt` adds the test/lint tooling on top.

### 4. Run the tests

```bash
python -m pytest
```

The auth test suite is hermetic — it generates a local RSA keypair and injects the signing
key, so no Azure tenant, network, or secret is required.

### 5. Install the security scanners (to reproduce the CI gate locally)

CI enforces `ruff`, `checkov`, `gitleaks`, and `trivy`. Install them locally so you catch
findings before pushing. **Pin `ruff` and `checkov` to the CI versions** — newer releases add
rules that would make local results diverge from the pipeline.

```powershell
# ruff + checkov — pinned to the versions used in CI (.github/workflows + .pre-commit-config.yaml)
python -m pip install "ruff==0.9.7" "checkov==3.2.250"

# gitleaks + trivy — standalone binaries (Windows: winget; reopen the shell afterwards for PATH)
winget install --id Gitleaks.Gitleaks --exact
winget install --id AquaSecurity.Trivy --exact
```

```bash
# macOS / Linux equivalents
python -m pip install "ruff==0.9.7" "checkov==3.2.250"
brew install gitleaks trivy            # macOS (Homebrew)
# Linux: see the gitleaks / trivy release pages for your distro's package
```

> `checkov`'s CLI entry point is the `checkov` script (added to your Python `Scripts`/`bin`
> dir). If it is not on `PATH`, invoke it as `python -m checkov.main`.

### 6. Run the full local gate

```powershell
# from the repo root, with .venv active
python -m pytest -q                                  # unit tests (hermetic)
ruff format --check app/ ; ruff check app/           # Python lint + format
terraform -chdir=terraform fmt -check -recursive     # Terraform format
checkov -d terraform/ --framework terraform --compact # IaC (runs in CI on Linux)
trivy config --severity HIGH,CRITICAL terraform/     # IaC misconfig (tfsec engine)
trivy config Dockerfile                              # Dockerfile misconfig
# Scan the committed source dirs, NOT the repo root — `gitleaks dir .` walks .venv and
# reports ~38 false positives from third-party package test fixtures. CI uses git-mode
# (`gitleaks git`), which only scans tracked files, so .venv is never in scope there.
gitleaks dir app --no-banner ; gitleaks dir scripts --no-banner ; gitleaks dir terraform --no-banner
```

> Known cross-platform notes: `checkov`'s Terraform scan can render an empty result table on
> some Windows setups — `trivy config terraform/` provides equivalent IaC coverage there, and
> CI runs `checkov` on Linux regardless. `trivy fs --scanners vuln` only reports CVEs once
> dependencies are pinned (the runtime set uses version ranges; see ADR notes). `gitleaks dir .`
> over the repo root will flag third-party fixtures under `.venv/` — scan source dirs instead.

---

## Branch naming

```
<type>/<short-description>
```

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`

Examples:
- `feat/resource-graph-tool`
- `fix/jwt-audience-validation`
- `docs/connecting-agents`
- `chore/pin-action-shas`

---

## Commit style (Conventional Commits)

```
<type>(<scope>): <short imperative description>

[optional body — why, not what]

[optional footer: Breaking change, Fixes #N]
```

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`, `build`

Examples:
```
feat(app): add list_resources tool via Resource Graph
fix(auth): validate aud claim before tool dispatch
chore(terraform): pin azurerm provider to 4.x
```

Commits must be **GPG-signed**. See below.

---

## GPG commit signing

### Check for an existing key (do this first)

```bash
gpg --list-secret-keys --keyid-format=long
```

If you have a key from another project (e.g. the SRE-Hackathon reference lab), reuse it.

### Configure git to sign (per-repo or global)

```bash
# Get your key ID from the list above (16-char hex after 'rsa4096/')
git config --global user.signingkey <YOUR_KEY_ID>
git config --global commit.gpgsign true
git config --global gpg.program gpg
```

> **Windows gotcha (multiple gpg installs).** Windows machines often have **two** gpg binaries
> with **separate keyrings**: Gpg4win (`C:\Program Files\GnuPG\bin\gpg.exe`) and Git's bundled
> gpg (`C:\Program Files\Git\usr\bin\gpg.exe`). Your key usually lives in the one your
> PowerShell/VS Code terminal uses (Gpg4win). Point git at *that* one explicitly, or signing
> fails with "No secret key":
> ```powershell
> git config --global gpg.program "$((Get-Command gpg).Source -replace '\\','/')"
> gpg --list-secret-keys --keyid-format=long   # confirm your key is in THIS keyring
> ```
> Note this also means `scripts/manual-gpg-setup.sh` (a bash script) should be run from a shell
> whose `gpg` is the keyring holding your key — and only after `git init` if you keep its
> default `--local` scope.

### Upload public key to GitHub

1. Export: `gpg --armor --export <YOUR_KEY_ID>`
2. GitHub → Settings → SSH and GPG keys → New GPG key → paste.
3. Commits on `main`/PRs will show a "Verified" badge.

### Generate a new key (MANUAL — do not run via Claude Code)

> Only if you have no existing key. See `scripts/manual-gpg-setup.sh` for the exact
> command, configuration, and verification steps.

---

## Pre-commit hooks

Install hooks after cloning (with your virtual environment active — see
[Local development environment](#local-development-environment)):

```bash
python -m pip install pre-commit
pre-commit install
```

Hooks run: `gitleaks`, `terraform fmt`, `checkov` (quick), `ruff format --check`, `ruff check`.

---

## Pull request process

1. Branch off `main`: `git checkout -b feat/my-change`.
2. Make changes; sign commits (`git commit -S -m "feat(scope): ..."` or via `commit.gpgsign = true`).
3. Push branch and open a PR.
4. Fill in the PR template completely.
5. CI must pass: fmt/validate/tflint/checkov/trivy/gitleaks/ruff + tests.
6. At least **1 reviewer approval** required (lab: self-approval documented as a RISK in ADR-013).
7. Merge via **squash merge** to keep `main` history clean.

### Terraform changes

PRs touching `terraform/` get an **HCP speculative plan** as a status check (plus `tf-validate`).
Review it before approving. On merge to `main`, HCP queues a run; **apply is approved in HCP**
(auto-apply is off).

---

## Code review focus areas

- Security: no secrets, least-privilege RBAC, JWT validation correctness, no destructive tools
- Terraform: standard tags present, version pins, no hardcoded values
- Python: `ruff` clean, type hints, `DefaultAzureCredential` used correctly
- Actions: SHA-pinned actions, minimal OIDC token permissions
- Docs: ADR written for significant decisions

---

## Reporting issues

Open a GitHub Issue. For security concerns, see [SECURITY.md](SECURITY.md).
