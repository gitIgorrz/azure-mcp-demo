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
```

> **Note**: `tf-validate` only runs when `terraform/**` files change — GitHub shows it as not
> required when not triggered. There is no `tf-plan` workflow: in the VCS-driven model HCP
> Terraform posts its own speculative **plan** as a PR status check (enable it in the workspace
> VCS settings).

---

## 2. Apply approval — HCP Terraform (not a GitHub Environment)

In the **VCS-driven** model (ADR-007) the apply gate lives in **HCP Terraform**, not GitHub
Actions. Configure the workspace `azure-mcp-demo`:

| Setting | Value | Why |
|---------|-------|-----|
| Settings → General → **Auto-apply** | **Off** | Every run waits for manual apply approval |
| Settings → General → Execution mode | Remote | HCP runs Terraform |
| VCS → Automatic speculative plans | On | Plan results posted on PRs |

Every run — whether triggered by a push to `main` or queued by `build-push` after an image
build — produces a plan and **waits for a human to approve the apply** in the HCP UI. That
manual apply approval is the deploy gate (ADR-013). Optionally add HCP **run notifications** so
pending applies are surfaced (Slack/email/webhook).

---

## 3. GitHub Actions secrets and variables

Set these in **Settings → Secrets and variables → Actions**.

### Repository secrets

| Secret name | Description |
|-------------|-------------|
| `HCP_TF_TOKEN` | HCP Terraform API token for org `gitIgorrz` / workspace `azure-mcp-demo`. Used by `build-push.yml` to set the image variable + queue a run, and by `smoke-test.yml` to read the health URL. Create at: app.terraform.io → User Settings → Tokens |

### Repository variables

**None required.** In the VCS-driven model the CI never authenticates to Azure (HCP does, via
DPC federated credentials), so the previous `AZURE_*` variables are not used.

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
| `hashicorp/setup-terraform` | v3.1.2 | `b9cd54a3c349d3f38e8881555d616ced269862dd` |
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
