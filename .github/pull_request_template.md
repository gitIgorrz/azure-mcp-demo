## Description

<!-- What does this PR do and why? Link to issue if applicable. -->

## Type of change

- [ ] Feature (`feat`)
- [ ] Bug fix (`fix`)
- [ ] Documentation (`docs`)
- [ ] Infrastructure / IaC (`chore`)
- [ ] CI / workflow (`ci`)
- [ ] Refactor
- [ ] Test

## Checklist

### Always

- [ ] Commits are GPG-signed (`git log --show-signature` shows "Good signature")
- [ ] No secrets, credentials, tokens, or connection strings committed
- [ ] `gitleaks` passes locally or in CI
- [ ] Conventional-commit message format used

### Python changes (`app/`)

- [ ] `ruff format --check` passes
- [ ] `ruff check` passes (no linting errors)
- [ ] Unit tests added/updated in `tests/`
- [ ] `DefaultAzureCredential` used (no hardcoded auth)
- [ ] No destructive tools added or modified
- [ ] JWT validation preserved for any new tool endpoints

### Terraform changes (`terraform/`)

- [ ] `terraform fmt` applied
- [ ] `terraform validate` passes
- [ ] `tflint` passes
- [ ] `checkov` passes (or suppressions documented with justification)
- [ ] All new resources carry the standard tag block
- [ ] Terraform plan reviewed (attached to PR or visible in CI)
- [ ] No sensitive values hardcoded (use variables + HCP workspace secrets)
- [ ] `terraform.lock.hcl` committed if providers changed

### GitHub Actions changes (`.github/workflows/`)

- [ ] All actions pinned to commit SHA (not tag only)
- [ ] `permissions:` block is minimal (not `write-all`)
- [ ] OIDC subject claims remain tightly scoped
- [ ] No secrets exposed in logs (`run` steps don't echo secrets)

### Documentation / ADR

- [ ] Significant decisions captured in `docs/decisions/ADR-NNN-*.md`
- [ ] `docs/PROGRESS.md` updated if this closes a phase

## Terraform plan output

<!-- Paste the plan summary here, or link to the CI run showing it. -->
<!-- For no-infra PRs, write "N/A". -->

## Security notes

<!-- Anything the reviewer should pay special attention to from a security perspective. -->
<!-- For routine changes, write "None". -->
