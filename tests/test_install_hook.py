import os
import shutil
import subprocess

import pytest

from conftest import ROOT

HOOK = ROOT / "install" / "session-start.sh"


def git(cwd, *args):
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", *args], cwd=cwd, check=True,
                   capture_output=True)


@pytest.fixture()
def toolkit_remote(tmp_path):
    """A local repo standing in for the toolkit on GitHub, with tag v1.0.0."""
    remote = tmp_path / "remote"
    shutil.copytree(ROOT / "plugins", remote / "plugins")
    git(remote, "init", "-q")
    git(remote, "add", "-A")
    git(remote, "commit", "-qm", "x")
    git(remote, "tag", "v1.0.0")
    return remote


@pytest.fixture()
def project(tmp_path):
    proj = tmp_path / "proj"
    (proj / ".claude").mkdir(parents=True)
    (proj / ".claude" / "toolkit.yaml").write_text("toolkit:\n  ref: v1.0.0   # pinned\nstacks: [python]\n")
    git(proj, "init", "-q")
    return proj


def run(tmp_path, project, remote, remote_flag="true", **extra):
    env = {**os.environ, "HOME": str(tmp_path / "home"), "CLAUDE_PROJECT_DIR": str(project),
           "DEVFLOW_REPO": str(remote), "CLAUDE_CODE_REMOTE": remote_flag, **extra}
    (tmp_path / "home").mkdir(exist_ok=True)
    return subprocess.run(["bash", str(HOOK)], env=env, capture_output=True, text=True, timeout=60)


def test_syntax():
    assert subprocess.run(["bash", "-n", str(HOOK)]).returncode == 0


def test_does_nothing_outside_a_remote_session(tmp_path, project, toolkit_remote):
    out = run(tmp_path, project, toolkit_remote, remote_flag="false")
    assert out.returncode == 0 and out.stdout == "" and out.stderr == ""
    assert not (tmp_path / "home" / ".claude").exists()


def test_user_scope_install(tmp_path, project, toolkit_remote):
    out = run(tmp_path, project, toolkit_remote)
    assert out.returncode == 0, out.stderr
    base = tmp_path / "home" / ".claude"
    for cmd in ("make-plan", "implement", "dod"):
        assert (base / "commands" / f"{cmd}.md").is_file()
    for skill in ("project-profile", "pr-steward", "stack-python", "stack-swift"):
        assert (base / "skills" / skill / "SKILL.md").is_file()
    assert (base / "devflow" / "scripts" / "validate_profile.py").is_file()
    assert (base / "devflow" / "schema" / "profile.schema.json").is_file()
    # nothing was written into the repository
    assert not (project / ".claude" / "commands").exists()
    status = subprocess.run(["git", "status", "--short", "-uall"], cwd=project, capture_output=True, text=True).stdout
    assert ".claude/commands" not in status and ".claude/skills" not in status


def test_idempotent_second_run_is_a_noop(tmp_path, project, toolkit_remote):
    run(tmp_path, project, toolkit_remote)
    marker = tmp_path / "home" / ".claude" / "devflow" / ".installed"
    before = marker.stat().st_mtime_ns
    out = run(tmp_path, project, toolkit_remote)
    assert out.returncode == 0 and "already installed" in out.stdout
    assert marker.stat().st_mtime_ns == before


def test_ref_change_reinstalls_and_removes_stale_files(tmp_path, project, toolkit_remote):
    run(tmp_path, project, toolkit_remote)
    stale = tmp_path / "home" / ".claude" / "commands" / "dod.md"
    (toolkit_remote / "plugins" / "devflow" / "commands" / "dod.md").unlink()
    (toolkit_remote / "plugins" / "devflow" / "commands" / "extra.md").write_text("---\ndescription: x\n---\nx\n")
    git(toolkit_remote, "add", "-A")
    git(toolkit_remote, "commit", "-qm", "y")
    git(toolkit_remote, "tag", "v1.1.0")
    (project / ".claude" / "toolkit.yaml").write_text("toolkit:\n  ref: v1.1.0\nstacks: []\n")
    out = run(tmp_path, project, toolkit_remote)
    assert out.returncode == 0, out.stderr
    assert not stale.exists()
    assert (stale.parent / "extra.md").is_file()


def test_project_scope_writes_exclude(tmp_path, project, toolkit_remote):
    out = run(tmp_path, project, toolkit_remote, DEVFLOW_SCOPE="project")
    assert out.returncode == 0, out.stderr
    assert (project / ".claude" / "commands" / "make-plan.md").is_file()
    exclude = (project / ".git" / "info" / "exclude").read_text()
    for line in ("/.claude/commands/make-plan.md", "/.claude/skills/project-profile", "/.claude/devflow"):
        assert line in exclude.splitlines()
    status = subprocess.run(["git", "status", "--short", "-uall"], cwd=project, capture_output=True, text=True).stdout
    assert "commands" not in status and "skills" not in status and "devflow" not in status
    again = run(tmp_path, project, toolkit_remote, DEVFLOW_SCOPE="project")
    assert "already installed" in again.stdout
    assert (project / ".git" / "info" / "exclude").read_text() == exclude


def test_missing_ref_warns_and_exits_zero(tmp_path, project, toolkit_remote):
    (project / ".claude" / "toolkit.yaml").write_text("stacks: []\n")
    out = run(tmp_path, project, toolkit_remote)
    assert out.returncode == 0
    assert "no toolkit.ref" in out.stderr and "NOT installed" in out.stderr


def test_unknown_ref_warns_and_exits_zero(tmp_path, project, toolkit_remote):
    out = run(tmp_path, project, toolkit_remote, DEVFLOW_REF="v404")
    assert out.returncode == 0
    assert "could not fetch" in out.stderr


def test_rejects_odd_ref(tmp_path, project, toolkit_remote):
    out = run(tmp_path, project, toolkit_remote, DEVFLOW_REF="--upload-pack=x")
    assert out.returncode == 0 and "not a plain tag name" in out.stderr


def test_does_not_overwrite_a_project_command_in_project_scope(tmp_path, project, toolkit_remote):
    (project / ".claude" / "commands").mkdir()
    (project / ".claude" / "commands" / "dod.md").write_text("mine\n")
    out = run(tmp_path, project, toolkit_remote, DEVFLOW_SCOPE="project")
    assert out.returncode == 0
    assert (project / ".claude" / "commands" / "dod.md").read_text() == "mine\n"
    assert "left alone" in out.stderr
    assert "/.claude/commands/dod.md" not in (project / ".git" / "info" / "exclude").read_text()


def test_warns_when_a_project_command_shadows_in_user_scope(tmp_path, project, toolkit_remote):
    (project / ".claude" / "commands").mkdir()
    (project / ".claude" / "commands" / "dod.md").write_text("mine\n")
    out = run(tmp_path, project, toolkit_remote)
    assert "may shadow" in out.stderr
