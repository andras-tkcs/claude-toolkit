# Migrating PrivacyFence to the toolkit

Exact steps to switch `privacyfence/privacyfence` from its own `.claude/commands/{make-plan,implement,dod}.md`
and `.claude/skills/steward` to this toolkit. Run them as one PR on a `chore/` branch (they are a separate
`/make-plan` job; this repository does not open that PR). Nothing about behaviour changes: the commands
are the same, with the PrivacyFence facts moved into the profile below.

Prerequisite: the toolkit is tagged `v0.1.0` (this PR merged, tag pushed).

## 1. Add `.claude/toolkit.yaml`

Create the file with exactly this content. It is also the test fixture
(`tests/fixtures/privacyfence-toolkit.yaml`), validated in this repository's CI.

```yaml
# The profile PrivacyFence would use (see docs/migrating-privacyfence.md).
toolkit:
  ref: v0.1.0

project:
  name: PrivacyFence

docs:
  must_read:
    - CLAUDE.md
    - CONTRIBUTING.md
    - docs/releasing.md
    - docs/coding-and-testing-guidelines.md
    - docs/testing-policy.md
    - docs/adr/README.md
  plan_dir: docs/
  adr_dir: docs/adr
  adr_index: docs/adr/README.md
  adr_bar: CONTRIBUTING.md#decisions-plans-and-adrs
  changelog:
    file: CHANGELOG.md
    section: "## [Unreleased]"

git:
  main_branch: main
  branch_pattern: "<type>/<kebab-case>"
  branch_types: [feature, fix, chore, tests]
  merge_style: merge-commit

verify:
  fast:
    - ruff check .
    - python3 -m pytest tests/unit -q
  dod:
    - run: pytest -v --cov=src/privacyfence --cov-branch --cov-report=term-missing --cov-report=json:coverage.json
      narrow: pytest -v {args}
    - run: python3 scripts/check_coverage_floor.py coverage.json
      skip_when_narrowed: true
    - ruff check .
    - bandit -c pyproject.toml -r src
    - python3 scripts/mypy_strict_modules.py
    - run: npm test
      cwd: mcpb/shim
    - run: npm run typecheck
      cwd: mcpb/shim
  dod_conditional:
    - when: ["src/privacyfence/*_client.py", "src/privacyfence/connectors/**"]
      do: >-
        A `scripts/qa_fixture_recorder.py --check <connector>` report against a dedicated QA account per
        docs/connector-qa.md is owed. No live credentials in a session: dispatch connector-live-check.yml
        (see ci.dispatchable) instead of marking the row done.
    - when: ["src/privacyfence/web/mcp_dispatch.py", "src/privacyfence/web/routes_mcp.py", "src/privacyfence/connector.py", "src/privacyfence/web/server.py"]
      do: >-
        If the change is to ToolSpec/ToolParam in connector.py, or to web/server.py's socket-binding or
        lifecycle: `pytest tests/integration -v`, and test_mcp_daemon_contract.py must pass.
    - when: ["src/privacyfence/web/mcp_auth.py", "src/privacyfence/web/server.py", "mcpb/shim/src/**"]
      do: >-
        If the change is to web/mcp_auth.py, to web/server.py's mcp_url discovery-file writing, or to
        mcpb/shim/src/: `pytest tests/integration -v`, and test_shim_mcp_contract.py must pass.
    - when: ["pyproject.toml"]
      do: >-
        If a dependency changed: run scripts/update_dependency_locks.sh (needs uv) and commit the resulting
        requirements/*.lock.txt.
    - when: ["cloudflare/downloads/**"]
      do: "In cloudflare/downloads/: `npm test`, `npm run typecheck` and `npm run dry-run` must pass."
  dod_manual:
    - >-
      Is there a user-visible change? It needs a line under CHANGELOG.md's `## [Unreleased]`, never under a
      concrete version heading. Internal-only changes don't need one.
    - >-
      A decision that is hard to reverse, moves a trust boundary, changes the build/release/distribution
      path, or rejects a non-obvious alternative needs an ADR in docs/adr/. A deleted plan document needs its
      decisions extracted into ADRs first, or a PR description saying it made none (docs/adr/README.md).
    - >-
      Every new or changed tool call still resolves through `gated_call` or an explicit always-auto-approve
      connector, and leaves an audit trail either way.
    - No preview dict carries full content; no log line carries a credential or a message/document body.
    - >-
      New client code has a matching `<Name>ClientError`; new connector code catches it and re-raises as
      `RuntimeError`.
    - New module-level state has a reset added to tests/conftest.py.
    - Comments only where the *why* is non-obvious; no restated-*what* comments.
  dod_doc: docs/coding-and-testing-guidelines.md#27-definition-of-done-for-a-pr-touching-this-repo

ci:
  dispatchable:
    - workflow: qa-record-fixture.yml
      use_when: A fixture for a newly added connector
      notes: >-
        Input `connector` names one of CONNECTOR_CHECKS in scripts/qa_fixture_recorder.py. Runs on the
        self-hosted runner and commits the recorded fixture back to the dispatched branch: pull before continuing.
    - workflow: connector-live-check.yml
      use_when: "`qa_fixture_recorder.py --check` for the definition-of-done QA row"
      notes: No inputs. The report lands as the `connector-live-check-report` artifact; link the run in the PR.
    - workflow: windows-graphical-session.yml
      use_when: Windows autostart / Task Scheduler behaviour
      notes: No inputs.
    - workflow: linux-graphical-session.yml
      use_when: Linux systemd --user / XDG autostart behaviour
      notes: No inputs.
    - workflow: macos-graphical-session.yml
      use_when: macOS LaunchAgent autostart, .pkg install
      notes: No inputs.
    - workflow: build.yml
      use_when: A real DMG, .pkg, .mcpb, Windows installer or .deb
      notes: No inputs. Each platform job runs its own packaged-artifact smoke test before upload.
    - workflow: release.yml
      use_when: Cutting a release tag (never from a session without the maintainer's say-so)
      notes: Inputs `version` and `dry_run` (default true). Dispatch the dry run, report it, wait to be told.

stacks: [python]

models:
  planner: opus
  orchestrator: sonnet
  worker: sonnet
  reviewer: opus

project_steward: .claude/skills/steward/SKILL.md
```

Check it: `python3 plugins/devflow/scripts/validate_profile.py .claude/toolkit.yaml --root .` (from a
checkout of this toolkit; it also verifies that every listed file exists). Because the profile now
carries the definition of done, `docs/coding-and-testing-guidelines.md` §2.7 stays the human-readable
copy: keep the two in step.

## 2. SessionStart hook: install the toolkit

`.claude/settings.json` keeps its existing `permissions` block. In `hooks.SessionStart`, add a second
entry next to the existing one (independent hooks; the toolkit install takes about a second):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh" }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "curl -fsSL https://raw.githubusercontent.com/andras-tkcs/claude-toolkit/v0.1.0/install/session-start.sh | bash"
          }
        ]
      }
    ]
  }
}
```

The URL pins the installer script to the same tag as `toolkit.ref`; bump both together to upgrade
(`docs/delivery.md` has a vendored alternative that needs no network for the script itself). The
installer does nothing outside `CLAUDE_CODE_REMOTE=true`, and installs under `~/.claude/` of the cloud
container, so nothing can be committed. `.claude/hooks/session-start.sh` itself does not change.

If you use the Claude Project plugins route instead, skip this step and see `docs/delivery.md`; the
two routes should not both be on.

## 3. Delete

```
git rm .claude/commands/make-plan.md .claude/commands/implement.md .claude/commands/dod.md
```

(`dod.md`'s command list, conditional rows and manual rows are now `verify.dod`, `verify.dod_conditional`
and `verify.dod_manual`; `make-plan.md` and `implement.md` are the toolkit's.)

## 4. Keep

| File | Why |
|---|---|
| `.claude/commands/cut-release.md` | PrivacyFence only |
| `.claude/commands/qa-record.md` | PrivacyFence only |
| `.claude/hooks/session-start.sh` | project environment setup (venv, Node, Chromium); unchanged |
| `.claude/settings.json` | add the hook above, keep `permissions` |
| `.claude/skills/steward/SKILL.md` | **trimmed** to the project part, step 5 |

## 5. Replace `.claude/skills/steward/SKILL.md`

The generic half (dispatch instead of skip, "workflow must be on the default branch", which PRs to
follow, how to treat a red check) is the toolkit's `pr-steward` skill; the dispatch **table** is
`ci.dispatchable`. What stays is the project half. New content, in full:

````markdown
---
name: steward
description: PrivacyFence-specific policy for an agent session — container facts that matter here, which pull requests not to follow, and the repo conventions that are easy to get wrong. The generic policy (dispatching to CI instead of skipping, how to treat a red check) is the devflow `pr-steward` skill; the table of dispatchable workflows is `ci.dispatchable` in `.claude/toolkit.yaml`. Read before acting on a CI failure or a review comment.
---

# Stewarding a PrivacyFence pull request

This is repo-specific policy and sits on top of the `pr-steward` skill. It sits alongside
`CONTRIBUTING.md` and `docs/releasing.md` (branch hygiene and release mechanics),
`docs/coding-and-testing-guidelines.md` (code and test conventions, and §2.7's definition of done) and
`docs/testing-policy.md` (which tier runs where) — none of which it replaces.

## Why live connector checks leave this machine

`docs/testing-policy.md` is explicit that the real QA OAuth grants never reach a GitHub-hosted runner
or a `pull_request`-triggered workflow, and a cloud session is neither trusted nor persistent enough to
be an exception. Hence `qa-record-fixture.yml` and `connector-live-check.yml` in `ci.dispatchable`.

- **`qa-record-fixture.yml` and `connector-live-check.yml` share a concurrency group**
  (`group: connector-live-check`, `cancel-in-progress: false`). They copy the runner's single
  persistent credential store into their checkout and copy refreshed tokens back out, so overlapping
  runs could write a stale token over a fresh one. A queued run is correct behaviour, not a hang.
- **A recorded fixture is still a diff to read.** `docs/connector-qa.md` ("Reviewing recorded
  fixtures") says to review fixture diffs before committing them regardless of how they were produced:
  no real account identifier, tenant URL, token or private content may enter the repository.
- **`.github/workflows/qa-record-fixture.yml`'s own header** documents the "workflow must already be on
  `main`" limit.
- Cross-platform `pytest` is not dispatched: `tests.yml` already runs `platform-windows` and
  `platform-macos` on every PR; read the failing job's log instead of guessing.
- To cut a release tag, see `/cut-release`; cutting for real is the maintainer's decision.

## Two things that look local-only but may not be, in this container

- `scripts/qa_web_smoke.py` needs a real browser, which is why `docs/testing-policy.md`
  ("`qa_web_smoke.py` (layer 4, by hand)") lists it as local-only. The web container ships Chromium and
  Playwright already (see the `PLAYWRIGHT_BROWSERS_PATH` note in `.claude/hooks/session-start.sh`), so
  try it before declaring it impossible — with `--chromium-path "$PRIVACYFENCE_TEST_CHROMIUM"` when the
  hook exported that variable, because the container's Chromium is not the build the locked
  `playwright` expects.
- The browser tests themselves (`test_browser_smoke.py`, the website tests) run here too, through the
  same `PRIVACYFENCE_TEST_CHROMIUM` the hook exports. Read the hook's `==>` Chromium line: a `WARNING`
  there means every browser test will report SKIPPED, and a green run is then not a pass.

## Which pull requests not to follow

Do not follow Dependabot PRs or the fixture-drift PR that `connector-live-check.yml` opens, unless the
maintainer asks. A dependency bump is a supply-chain decision, and a fixture diff is a privacy review.

## Red checks, specifically

- The suite is a 100%-pass, ratcheted-coverage gate (`scripts/check_coverage_floor.py`); a hole in it
  does not show up again until it matters. A coverage-floor failure means the new code needs tests, not
  that the floor needs lowering.
- A `bandit` finding that is genuinely a false positive gets `# nosec BXXX  # <reason>` at the call
  site — never a suppression in `pyproject.toml` (§2.7).
- `scripts/check_graphical_session_coverage.py` states the rule: *"A second red run on the same commit
  is real and must not be re-run away."*

## Conventions worth restating because they are easy to get wrong

- **Never open a concrete `## [X.Y.Z]` heading in `CHANGELOG.md` on a feature branch.** Entries go under
  `## [Unreleased]`. `docs/releasing.md` traces this to a real incident (`d929510`) and the release
  build fails loudly on a duplicated or still-populated section.
- **PRs merge with a real merge commit, not a squash.** Every commit message on the branch survives into
  `main`'s history individually.
- **Branch names.** `CONTRIBUTING.md` specifies `<type>/<kebab-case-description>` (`feature/`, `fix/`,
  `chore/`, `tests/` — never `feat/`). A Claude Code on the web session is assigned a
  `claude/<generated-name>` branch it cannot rename; use it and put the `<type>` in the PR title.
- **`releases/*` is protected like `main`.** If work is targeting one, branch from it and PR back into it.
- **Pushing a release tag directly is not possible here** — the container can push branches but not
  `refs/tags/*`. A failed push can leave a local tag behind that makes `tag_release.py`'s later checks
  lie. Dispatch `release.yml` (dry run first) instead.
````

`project_steward: .claude/skills/steward/SKILL.md` in the profile makes every command read it.

## 6. Update references to the deleted files

| File | Change |
|---|---|
| `CLAUDE.md`, "Commands and skills" | Replace the `/make-plan`, `/implement` and `/dod` bullets' paths: "`/make-plan`, `/implement` and `/dod` come from the devflow toolkit (`andras-tkcs/claude-toolkit`, pinned by `toolkit.ref` in `.claude/toolkit.yaml`); the behaviour described here is unchanged." Keep the prose about plan branches, manifests and `manual_before`/`manual_after`. Keep the steward bullet, as "PrivacyFence-specific steward policy". |
| `docs/coding-and-testing-guidelines.md` line 338 | "The `/dod` command (`.claude/commands/dod.md`) runs its commands and checks the conditional rows" → "The `/dod` command runs the commands and rows in the `verify` section of `.claude/toolkit.yaml`, which must be kept in step with this section, and checks the conditional rows". |
| `docs/testing-policy.md` line 268 | "**`/dod`** (`.claude/commands/dod.md`)" → "**`/dod`** (from the devflow toolkit; its rows are `verify` in `.claude/toolkit.yaml`)". |
| `.github/pull_request_template.md` line 66, `docs/adr/0008-…md` line 185, `.claude/hooks/session-start.sh` line 138 | No change: `.claude/skills/steward/SKILL.md` still exists. |

## 7. Verify in a real session

Start a new cloud session on the branch and check, in order:

1. The hook output shows `==> Installing devflow v0.1.0` (second session start: `already installed`).
2. `/dod` runs the seven gate commands from the profile and walks the conditional and manual rows.
   On a docs-only diff the conditional rows report `n/a`.
3. `/make-plan` with a small request returns a single-session prompt that names `CLAUDE.md`,
   `CONTRIBUTING.md`, `docs/releasing.md`, `docs/coding-and-testing-guidelines.md`,
   `docs/testing-policy.md`, `docs/adr/README.md`, the ADR bar in `CONTRIBUTING.md`, and the `CHANGELOG.md`
   `[Unreleased]` line; `/make-plan` for a large one produces a manifest that
   `validate_manifest.py` accepts (the two real manifests from `plan/atlassian-user-names` and
   `plan/plugin-framework` do, in this repository's tests).
4. `/implement <plan URL>` is unchanged: the same ledger, `Plan-Phase:` trailers and `PHASE-REPORT` lines.

## Differences you may notice

- Generic wording where the originals named PrivacyFence things ("live external-service credentials"
  instead of "live connector credentials"); the rules are the same.
- `/implement` treats a `verify_after_merge` entry written as `dispatch <workflow>` as a CI dispatch
  against the feature branch (new, used by the Swift stack); PrivacyFence manifests have none.
- Manifest validation is `validate_manifest.py` rather than inline Python, and also checks
  `feature_branch` against `git.branch_types`.
- Commands read the profile first and stop with a message naming a missing key.
