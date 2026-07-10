import zigbase


def test_exports_version() -> None:
    assert zigbase.__version__ == "0.1.0"
