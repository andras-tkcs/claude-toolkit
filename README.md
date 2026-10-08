# claude-toolkit

A plan → implement workflow for Claude Code on the web (claude.ai/code), for any repository in any
language.

- **`/make-plan <what you want>`** (Opus) researches the repo, then writes either a self-contained
  single-session prompt (small scope) or a plan document with a YAML implementation manifest on a
  `plan/<slug>` branch (large scope), plus a step-by-step page for anything only a human can do.
- **`/implement <plan URL>`** (Sonnet) orchestrates a plan: one child cloud session per phase,
  periodic check-ins, merges into one feature branch, verification after every merge, one Opus review
  session, and one PR driven to green.
- **`/dod`** runs the project's definition of done and reports a table.

Everything specific to your project lives in one file, `.claude/toolkit.yaml` (docs to read, branch
rules, verify commands, CI workflows a session may dispatch, stacks, models). The commands contain no
project facts and stop with a message naming the missing key.

## Use it in a project

1. Copy [`templates/toolkit.yaml`](templates/toolkit.yaml) to `.claude/toolkit.yaml` and fill it in.
   Reference: [docs/profile-reference.md](docs/profile-reference.md).
2. Get the toolkit into your cloud sessions, either way ([docs/delivery.md](docs/delivery.md)):
   - add the plugins in your Claude Project's settings (marketplace `andras-tkcs/claude-toolkit`), or
   - call [`install/session-start.sh`](install/session-start.sh) from the project's SessionStart hook,
     pinned by `toolkit.ref`.
3. Start a session and run `/make-plan <what you want>`.

## What is here

| Path | |
|---|---|
| `plugins/devflow` | the three commands, the `project-profile`, `pr-steward`, `review-checklist` and `secure-code-review` skills, `scripts/validate_manifest.py`, `scripts/validate_profile.py`, `schema/profile.schema.json` |
| `plugins/stack-python`, `plugins/stack-swift` | stack skills the profile selects |
| `install/session-start.sh` | delivery for cloud sessions |
| `templates/toolkit.yaml` | starter profile |
| `docs/` | profile reference, delivery, design, [migrating PrivacyFence](docs/migrating-privacyfence.md) |
| `tests/` | `python -m pytest tests -q` (Python 3.11+, PyYAML) |

There is no server and nothing long-running: everything runs inside Claude Code sessions.

## Development

```
python3 -m venv .venv && .venv/bin/pip install -r tests/requirements.txt
.venv/bin/python -m pytest tests -q
```

The tests include a check that no project-specific word (a particular project's name, test runner
or linter) appears in the generic plugin. Stack-specific words belong in `plugins/stack-python`.
