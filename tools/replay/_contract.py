"""Shared wire semantics for replay captures and their consumers."""

EVIDENCE_CONTROLS = frozenset({"allowed", "denied", "journey", "validation"})


def allowed_controls_for_status(status: int) -> frozenset[str]:
    if 200 <= status < 300:
        return frozenset({"allowed"})
    if 300 <= status < 400:
        return frozenset({"allowed", "journey"})
    if status == 400:
        return frozenset({"denied", "validation"})
    if status in {401, 403, 404}:
        return frozenset({"denied"})
    if status in {409, 422}:
        return frozenset({"validation"})
    return frozenset()
