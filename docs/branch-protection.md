# Branch protection — manual setup guide

Configure these settings in **GitHub → Settings → Branches → Add rule → `main`** after
the repository is created (Phase 6 / Phase 2 manual steps). All rules apply to the `main`
branch. No automation sets these; they must be enabled by an owner.

---

## 1. Branch protection rule for `main`

| Setting | Value | Why |
|---------|-------|-----|
| Require a pull request before merging | ✅ enabled | No direct pushes to main |
| Required approvals | 1 | At least one reviewer |
| Dismiss stale reviews when new commits are pushed | ✅ enabled | Review stays current |
| Require status checks to pass before merging | ✅ enabled | CI gates the merge |
| Require branches to be up to date | ✅ enabled | No stale-branch bypasses |
| Require signed commits | ✅ enabled | GPG signing per CONTRIBUTING.md |
| Do not allow bypassing the above settings | ✅ enabled | Applies to admins too |
| Allow force pushes | ❌ disabled | History is immutable |
| Allow deletions | ❌ disabled | Protect branch |

### Required status checks

Add each of these check names exactly as they appear in GitHub Actions:

```
Python (ruff)                   ← lint.yml
Terraform fmt                   ← lint.yml
YAML (yamllint)                 ← lint.yml
Markdown (markdownlint)         ← lint.yml
pytest (Python 3.12)            ← unit-tests.yml
terraform validate + checkov    ← tf-validate.yml  (only if terraform/** changed)
terraform plan                  ← tf-plan.yml      (only if terraform/** changed)
```

> **Note**: `tf-validate` and `tf-plan` only run when `terraform/**` files change.
> Mark them as "optional" status checks or accept that PRs touching only app code will
> skip those checks — GitHub will show them as not required when not triggered.

---

## 2. GitHub Environment: `lab`

In **Settings → Environments → New environment → `lab`**:

| Setting | Value |
|---------|-------|
| Required reviewers | `@gitIgorrz` |
| Prevent self-review | ✅ (if GitHub Plan supports it; otherwise accept self-review for lab) |
| Deployment branches | Selected branches → `main` only |

This environment gate is the approval step before `terraform apply` runs.
The `tf-apply.yml` workflow declares `environment: lab`, so GitHub will pause
and request approval from the listed reviewers.

---

## 3. GitHub Actions secrets and variables

Set these in **Settings → Secrets and variables → Actions**.

### Repository secrets

| Secret name | Description |
|-------------|-------------|
| `HCP_TF_TOKEN` | HCP Terraform API token for org `gitIgorrz` / workspace `az-mcp-demo`. Create at: app.terraform.io → User Settings → Tokens |

### Repository variables (not secrets — these are identifiers)

| Variable name | Description |
|---------------|-------------|
| `AZURE_TENANT_ID` | Entra tenant GUID |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription GUID |
| `AZURE_CLIENT_ID` | Client ID of the CI app registration (from `scripts/manual-github-oidc-setup.sh`) |

> These were surfaced as non-secret variables by `manual-github-oidc-setup.sh` (Phase 2).

---

## 4. Action SHA verification

All workflows pin GitHub Actions to a commit SHA. Before the first workflow run, verify
each SHA with:

```bash
# Verify a SHA for a given action + version tag
gh api /repos/{owner}/{repo}/git/ref/tags/{vX.Y.Z} \
  --jq '.object.sha'
```

SHA pins used in this repo:

| Action | Version | SHA |
|--------|---------|-----|
| `actions/checkout` | v4.2.2 | `11bd71901bbe5b1630ceea73d27597364c9af683` |
| `actions/setup-python` | v5.3.0 | `0b93645e9fea7318ecaed2b359559ac225c90a2b` |
| `actions/upload-artifact` | v4.6.0 | `65c4c4a1ddee5b72f698fdd19549f0f0fb45cf08` |
| `actions/download-artifact` | v4.1.8 | `fa0a91b85d4f404e444e00e005971372dc801d16` |
| `actions/github-script` | v7.0.1 | `60a0d83039c74a4aee543508d2ffcb1c3799cdea` |
| `hashicorp/setup-terraform` | v3.1.2 | `b9cd54531c595c8e1b3c0ed0a7a1dad3b6bb94ec` |
| `docker/login-action` | v3.3.0 | `9780b0c442fbb1117ed29e0efdff1e18412f7567` |
| `docker/metadata-action` | v5.6.1 | `369eb591f429131d6889c46b94e711f089e6ca96` |
| `docker/build-push-action` | v5.4.0 | `ca052bb54ab0790a636c9b5f226502c73d547a25` |

Run the gh command above for each action before enabling workflows.
Update SHAs here and in the workflow files when you bump action versions.

---

## 5. CODEOWNERS enforcement

`CODEOWNERS` already lists `@gitIgorrz` as owner of all paths. For CODEOWNERS to
enforce reviews, enable **"Require review from Code Owners"** in the branch protection
rule (under the required reviewers section).
