#!/usr/bin/env bash
# =============================================================================
# manual-gpg-setup.sh                                            # RUN MANUALLY
# -----------------------------------------------------------------------------
# WHAT:  Configures GPG-signed commits/tags for this repo (CONTRIBUTING.md). It
#        **detects and reuses** an existing GPG key (e.g. the one from the prior
#        SRE-Hackathon / igor-mcp-lab work) — it does NOT generate one.
#
# WHY MANUAL:  CLAUDE.md § Destructive-command rules forbid automatic GPG key
#        generation. Key material is sensitive and a human must own its creation.
#        This script is read-mostly: it inspects the keyring and sets local git
#        config; it never creates or exports private key material.
#
# WHO RUNS IT:  gitIgorrz, on the workstation holding the GPG private key.
#
# RELATED:  CONTRIBUTING.md (signed commits), design Q5 (detect + reuse, don't generate).
#
# DESIGN RULE:  If no usable secret key is found, this script STOPS with manual
#        generation instructions. It will not run `gpg --full-generate-key`.
# =============================================================================
set -euo pipefail

# Git Bash / MINGW on Windows rewrites args that look like Unix paths into Windows
# paths. Harmless on Linux/macOS; safe guard on Windows.
export MSYS_NO_PATHCONV=1

EMAIL="${GPG_EMAIL:-igor_111@hotmail.com}"   # identity to match; override via env
REPO_LOCAL_ONLY="${REPO_LOCAL_ONLY:-true}"   # true: set git config --local (this repo)

echo "Looking for an existing GPG secret key for: ${EMAIL}"
echo

# -----------------------------------------------------------------------------
# STEP 1 — Detect a usable secret key. Prefer one matching EMAIL; else list all.
#          We extract the long key ID of the primary key (the 'sec' line).
# -----------------------------------------------------------------------------
if ! command -v gpg >/dev/null 2>&1; then
  echo "gpg not found on PATH. Install Gpg4win (Windows) / gnupg, then re-run." >&2
  exit 1
fi

# Long key IDs of secret keys matching the email.
mapfile -t KEY_IDS < <(gpg --list-secret-keys --keyid-format=long --with-colons "${EMAIL}" 2>/dev/null \
  | awk -F: '$1=="sec"{print $5}')

if [[ "${#KEY_IDS[@]}" -eq 0 ]]; then
  echo "No secret key found for ${EMAIL}. Existing secret keys on this machine:"
  gpg --list-secret-keys --keyid-format=long || true
  cat <<'EOF'

NO MATCHING KEY — STOPPING (this script never generates keys).

If you already have a key under a different identity, re-run with:
    GPG_EMAIL="that-address@example.com" ./manual-gpg-setup.sh

To CREATE a new key (run MANUALLY, then re-run this script):
    gpg --full-generate-key       # choose RSA 4096 or ed25519, set your email
    # then add the email as a verified address on GitHub before uploading the key
EOF
  exit 1
fi

if [[ "${#KEY_IDS[@]}" -gt 1 ]]; then
  echo "Multiple secret keys match ${EMAIL}:"
  printf '  %s\n' "${KEY_IDS[@]}"
  echo "Using the first. To pick another, set GPG_SIGNING_KEY=<longid> and re-run."
fi
SIGNING_KEY="${GPG_SIGNING_KEY:-${KEY_IDS[0]}}"
echo "Selected signing key: ${SIGNING_KEY}"
echo

# -----------------------------------------------------------------------------
# STEP 2 — Point git at the gpg binary and configure signing.
#          --local scopes config to THIS repo by default (safer than --global).
# -----------------------------------------------------------------------------
SCOPE_FLAG="--local"
[[ "${REPO_LOCAL_ONLY}" == "true" ]] || SCOPE_FLAG="--global"

GPG_BIN="$(command -v gpg)"
git config ${SCOPE_FLAG} gpg.program "${GPG_BIN}"
git config ${SCOPE_FLAG} user.signingkey "${SIGNING_KEY}"
git config ${SCOPE_FLAG} commit.gpgsign true
git config ${SCOPE_FLAG} tag.gpgsign true
# Ensure the configured git user.email matches the key identity for verified status.
git config ${SCOPE_FLAG} user.email "${EMAIL}"

echo "git signing config (${SCOPE_FLAG}):"
git config ${SCOPE_FLAG} --get-regexp 'gpg|signingkey|user\.email' || true
echo

# -----------------------------------------------------------------------------
# STEP 3 — Export the PUBLIC key for GitHub. (Public only — never the private key.)
# -----------------------------------------------------------------------------
echo "Public key block to register on GitHub (Settings > SSH and GPG keys):"
echo "-----------------------------------------------------------------------"
gpg --armor --export "${SIGNING_KEY}"
echo "-----------------------------------------------------------------------"
echo
cat <<EOF
Upload it via the GitHub UI, or with the GitHub CLI:
    gpg --armor --export ${SIGNING_KEY} | gh gpg-key add -

GitHub shows a commit as "Verified" only when the key's email is a VERIFIED
email on your GitHub account and matches the commit author email (${EMAIL}).
EOF
echo

# -----------------------------------------------------------------------------
# VERIFY — make a throwaway signed object to confirm signing actually works.
# -----------------------------------------------------------------------------
echo "==== VERIFICATION ===="
if echo "azure-mcp-demo signing test" | gpg --local-user "${SIGNING_KEY}" --clearsign >/dev/null 2>&1; then
  echo "PASS: gpg can sign with key ${SIGNING_KEY}."
else
  echo "FAIL: signing test failed. Check the key has a private part and no passphrase issue." >&2
  exit 1
fi
echo "Next commit in this repo will be signed. Verify with: git log --show-signature -1"
