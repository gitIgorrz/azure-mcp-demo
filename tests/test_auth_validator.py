"""Validation tests for EntraTokenValidator — the security core (ADR-006)."""

from __future__ import annotations

import time

import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from app.auth.config import AuthSettings
from app.auth.errors import (
    InvalidClaimError,
    InvalidSignatureError,
    MalformedTokenError,
    MissingTokenError,
    SigningKeyUnavailableError,
    TokenExpiredError,
)
from app.auth.validator import EntraTokenValidator

from .conftest import AUDIENCE, ISSUER, OTHER_TENANT, TENANT_ID


def test_valid_token_passes(validator, make_token):
    claims = validator.validate(make_token())
    assert claims.subject == "subject-abc"
    assert claims.object_id == "object-id-123"
    assert claims.tenant_id == TENANT_ID
    assert claims.audience == AUDIENCE
    # The raw token must not leak into the trusted claims object.
    assert "token" not in claims.claims


def test_missing_token_rejected(validator):
    with pytest.raises(MissingTokenError):
        validator.validate("")
    with pytest.raises(MissingTokenError):
        validator.validate("   ")


def test_expired_token_rejected(validator, make_token):
    past = int(time.time()) - 3600
    with pytest.raises(TokenExpiredError):
        validator.validate(make_token(claims={"exp": past, "iat": past, "nbf": past}))


def test_expired_within_leeway_accepted(settings, resolver, make_token):
    # 30s past exp, but leeway is 60s -> still valid.
    lenient = AuthSettings(tenant_id=TENANT_ID, audiences=(AUDIENCE,), leeway_seconds=60)
    v = EntraTokenValidator(lenient, signing_key_resolver=resolver)
    just_expired = int(time.time()) - 30
    claims = v.validate(make_token(claims={"exp": just_expired}))
    assert claims.subject == "subject-abc"


def test_wrong_audience_rejected(validator, make_token):
    with pytest.raises(InvalidClaimError) as exc:
        validator.validate(make_token(claims={"aud": "api://not-this-server"}))
    assert exc.value.claim == "aud"


def test_wrong_issuer_rejected(validator, make_token):
    bad_iss = f"https://login.microsoftonline.com/{OTHER_TENANT}/v2.0"
    with pytest.raises(InvalidClaimError) as exc:
        validator.validate(make_token(claims={"iss": bad_iss}))
    assert exc.value.claim == "iss"


def test_v1_issuer_rejected(validator, make_token):
    # Entra v1.0 issuer (sts.windows.net) must not be accepted.
    v1_iss = f"https://sts.windows.net/{TENANT_ID}/"
    with pytest.raises(InvalidClaimError):
        validator.validate(make_token(claims={"iss": v1_iss}))


def test_wrong_tenant_rejected(validator, make_token):
    # Signature/iss/aud fine, but tid is a different tenant -> cross-tenant replay blocked.
    with pytest.raises(InvalidClaimError) as exc:
        validator.validate(make_token(claims={"tid": OTHER_TENANT}))
    assert exc.value.claim == "tid"


def test_missing_oid_rejected(validator, make_token):
    with pytest.raises(InvalidClaimError) as exc:
        validator.validate(make_token(claims={"oid": None}))
    assert exc.value.claim == "oid"


def test_missing_sub_rejected(validator, make_token):
    with pytest.raises(InvalidClaimError) as exc:
        validator.validate(make_token(include=("exp", "iss", "aud", "oid", "tid", "ver")))
    assert exc.value.claim == "sub"


def test_non_v2_token_rejected(validator, make_token):
    with pytest.raises(InvalidClaimError) as exc:
        validator.validate(make_token(claims={"ver": "1.0"}))
    assert exc.value.claim == "ver"


def test_signature_from_wrong_key_rejected(validator, make_token):
    attacker_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    forged = make_token(key=attacker_key)  # signed by a key the resolver won't return
    with pytest.raises(InvalidSignatureError):
        validator.validate(forged)


def test_alg_none_rejected(validator, make_token):
    # The classic downgrade attack: unsigned token must never be accepted.
    with pytest.raises(InvalidSignatureError):
        validator.validate(make_token(algorithm="none", kid=None))


def test_hs256_confusion_rejected(validator, make_token):
    # alg-confusion: HS256 token must be rejected because only RS256 is allowed.
    with pytest.raises(InvalidSignatureError):
        validator.validate(make_token(algorithm="HS256"))


def test_malformed_token_rejected(validator):
    with pytest.raises(MalformedTokenError):
        validator.validate("not-a-jwt")


def test_signing_key_unavailable_is_503(settings, make_token):
    def failing_resolver(_token):
        raise SigningKeyUnavailableError("jwks down")

    v = EntraTokenValidator(settings, signing_key_resolver=failing_resolver)
    with pytest.raises(SigningKeyUnavailableError) as exc:
        v.validate(make_token())
    assert exc.value.status_code == 503


def test_app_allow_list_blocks_unlisted_caller(resolver, make_token):
    s = AuthSettings(
        tenant_id=TENANT_ID,
        audiences=(AUDIENCE,),
        allowed_app_ids=frozenset({"33333333-3333-3333-3333-333333333333"}),
    )
    v = EntraTokenValidator(s, signing_key_resolver=resolver)
    with pytest.raises(InvalidClaimError) as exc:
        v.validate(make_token(claims={"azp": "44444444-4444-4444-4444-444444444444"}))
    assert exc.value.claim == "azp"


def test_app_allow_list_admits_listed_caller(resolver, make_token):
    allowed = "33333333-3333-3333-3333-333333333333"
    s = AuthSettings(
        tenant_id=TENANT_ID, audiences=(AUDIENCE,), allowed_app_ids=frozenset({allowed})
    )
    v = EntraTokenValidator(s, signing_key_resolver=resolver)
    claims = v.validate(make_token(claims={"azp": allowed}))
    assert claims.app_id == allowed


def test_multiple_audiences_accepted(resolver, make_token):
    bare_guid = "22222222-2222-2222-2222-222222222222"
    s = AuthSettings(tenant_id=TENANT_ID, audiences=(AUDIENCE, bare_guid))
    v = EntraTokenValidator(s, signing_key_resolver=resolver)
    claims = v.validate(make_token(claims={"aud": bare_guid}))
    assert claims.audience == bare_guid
