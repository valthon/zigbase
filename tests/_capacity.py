"""Launch the capacity tool with cheap password setup for its live regression tests."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools"))
import application_capacity as capacity

# The measurement tool deliberately strips ZIGBASE_* from its child environment.
# Restore only the password-cost seam for tests; keep its production defaults intact.
clean_environment = capacity.clean_environment
capacity.clean_environment = lambda: {**clean_environment(), "ZIGBASE_FAKE_HASH": "1"}

if __name__ == "__main__":
    sys.exit(capacity.main())
