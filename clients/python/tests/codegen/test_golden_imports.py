"""Golden sanity test for the generated Python typed client (dating fixture).

Imports the generated `zbase_gen.py` (Task 5's data half: select enums,
record + expand models, Create/Update payloads) and exercises
`from_record`/`to_map` against canned record dicts — the Python counterpart
of the `dart format`-clean Dart golden's own spot-checks, minus the fluent
field builders / typed services (Task 6, not generated yet).

Not marked `integration` (no server binary needed): a pure in-memory
exercise of the generated module, so it runs under the default
`pytest -m "not integration"` unit pass.
"""

from __future__ import annotations

from tests.codegen.dating.zbase_gen import (
    Profile,
    ProfileGender,
    Subscription,
    SubscriptionCreate,
    SubscriptionPlan,
)

PROFILE_RECORD = {
    "id": "prof123",
    "email": "alice@example.com",
    "username": "alice",
    "verified": True,
    "name": "Alice",
    "bio": "Hi there",
    "website": "https://example.com",
    "age": 29,
    "gender": "female",
    "avatar": "avatar.png",
    "created": "2024-01-01T00:00:00Z",
    "updated": "2024-01-02T00:00:00Z",
}

SUBSCRIPTION_RECORD = {
    "id": "sub1",
    "profile": "prof123",
    "plan": "plus",
    "price": "19.99",  # decimal-string wire form for a fixed(scale=2)-mode field
    "renewsAt": "2025-01-01",
    "active": True,
    "metadata": {"tier": "gold"},
    "created": "2024-01-01T00:00:00Z",
    "updated": "2024-01-02T00:00:00Z",
}


def test_profile_from_record_coerces_int_and_select_enum() -> None:
    profile = Profile.from_record(PROFILE_RECORD)
    assert isinstance(profile, Profile)
    assert isinstance(profile.age, int)
    assert profile.age == 29
    assert profile.gender is ProfileGender.FEMALE
    assert profile.email == "alice@example.com"
    assert profile.verified is True


def test_subscription_from_record_coerces_fixed_to_float() -> None:
    sub = Subscription.from_record(SUBSCRIPTION_RECORD)
    assert isinstance(sub, Subscription)
    assert isinstance(sub.price, float)
    assert sub.price == 19.99
    assert sub.plan is SubscriptionPlan.PLUS
    assert sub.metadata == {"tier": "gold"}


def test_subscription_create_to_map_renders_fixed_scale_and_omits_unset() -> None:
    # 0.125 at scale=2 is the exact case documented on `encode_fixed`
    # (round-half-up on the binary value, not round-half-to-even): "0.13".
    create = SubscriptionCreate(price=0.125, active=True)
    body = create.to_map()
    assert body == {"price": "0.13", "active": True}

    empty = SubscriptionCreate()
    assert empty.to_map() == {}
