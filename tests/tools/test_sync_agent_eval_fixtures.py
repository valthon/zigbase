from pathlib import Path

from tools import sync_agent_eval_fixtures


def test_sync_detects_and_repairs_vendored_tool_drift(tmp_path, monkeypatch):
    source = tmp_path / "source.py"
    destination = tmp_path / "fixture/source.py"
    source.write_text("canonical\n")
    destination.parent.mkdir()
    destination.write_text("stale\n")
    copies = {"source.py": ("fixture/source.py",)}
    monkeypatch.setattr(sync_agent_eval_fixtures, "COPIES", copies)
    assert sync_agent_eval_fixtures.synchronize(tmp_path, check=True) == [
        "fixture/source.py"
    ]
    assert sync_agent_eval_fixtures.synchronize(tmp_path, check=False) == [
        "fixture/source.py"
    ]
    assert destination.read_text() == "canonical\n"
    assert sync_agent_eval_fixtures.synchronize(tmp_path, check=True) == []


def test_repository_vendored_tools_are_synchronized():
    repo = Path(__file__).resolve().parents[2]
    assert sync_agent_eval_fixtures.synchronize(repo, check=True) == []
