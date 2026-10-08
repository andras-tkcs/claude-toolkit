# Delivery: getting the toolkit into a cloud session

A cloud session (claude.ai/code) does **not** install plugins that a repo enables through its
`.claude/settings.json`. Two routes work; use one of them, not both.

## Route 1: Claude Project plugins

1. In claude.ai, open the Claude Project the repository's sessions belong to, and its settings.
2. Add the marketplace `andras-tkcs/claude-toolkit` (GitHub repository source).
3. Enable `devflow`, plus `stack-python` and/or `stack-swift` for the stacks the profile lists.
4. Commit `.claude/toolkit.yaml` to the repository (see [profile-reference.md](profile-reference.md)).
5. In a new session, `/make-plan`, `/implement` and `/dod` are available. Under this route Claude
   Code namespaces plugin skills (`devflow:project-profile`); the commands handle both forms.

Upgrade by updating the plugin in the Project. There is no pin in the repository, so a plan run is
only reproducible to the extent the Project's plugin version is.

**Status: not tested end to end.** The Project settings UI cannot be driven from a session. What was
verified: `claude plugin validate` passes for the marketplace and all three plugins, and
`claude plugin marketplace add <path>` followed by `claude plugin install devflow@claude-toolkit`
puts the commands, skills and scripts in `~/.claude/plugins/cache/claude-toolkit/devflow/<version>/`,
which is where the `project-profile` skill looks for them.

## Route 2: SessionStart hook

`install/session-start.sh` is called from the project's own SessionStart hook. In
`.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command",
        "command": "curl -fsSL https://raw.githubusercontent.com/andras-tkcs/claude-toolkit/v0.1.0/install/session-start.sh | bash" } ] }
    ]
  }
}
```

and, in `.claude/toolkit.yaml`:

```yaml
toolkit:
  ref: v0.1.0
```

What the script does, only when `CLAUDE_CODE_REMOTE=true`:

1. Reads the tag from `toolkit.ref` (or `DEVFLOW_REF`). No tag: it warns and installs nothing.
2. If `~/.claude/devflow/.installed` already records the same ref, repo and scope, it exits (second
   start, resume, compact: a few milliseconds).
3. Otherwise `git clone --depth 1 --branch <ref>` of the toolkit into a temp directory (under a
   timeout, 30 s by default), copies `commands/` and `skills/` of every plugin and the validator
   scripts and schema, removes anything an earlier install put there and no longer exists, and records
   what it installed.
4. Never fails the session: a problem is a `WARNING` line and exit code 0, and the commands will then
   be missing. It never overwrites a command or skill that is not its own.

Variables: `DEVFLOW_REF`, `DEVFLOW_REPO` (default the public repo; a local path works),
`DEVFLOW_SCOPE` (`user` or `project`), `DEVFLOW_TIMEOUT`.

**Vendored alternative.** If you would rather not fetch the script itself on every session start,
copy `install/session-start.sh` to `.claude/hooks/devflow.sh` in the project and point the hook at it.
It still fetches the toolkit at `toolkit.ref`; upgrading then means bumping the ref and, if you want
it, re-copying the script.

### Where it installs: `~/.claude/` (default) or the project's `.claude/`

| Scope | Installs under | In the repository's working tree | `.git/info/exclude` |
|---|---|---|---|
| `user` (default) | `~/.claude/commands`, `~/.claude/skills`, `~/.claude/devflow` | never | not needed |
| `project` (`DEVFLOW_SCOPE=project`) | `<project>/.claude/commands`, `.../skills`, `.../devflow` | yes, as untracked files | every installed path is appended, so nothing shows in `git status` and a worker cannot commit it |

In claude.ai/code `~/.claude` is the **cloud container's** home (`/root/.claude`), a fresh Linux
container per session: your machine is not involved and nothing is left behind after the session.

### What was observed in a real cloud session

Tested with `create_session` against this repository (Sonnet, `auto` mode, container
`HOME=/root`, Claude Code 2.1.294), on 2026-10-08:

1. **Are files written during SessionStart picked up by the same session?** Yes, in both locations.
   A hook wrote a command and a skill under `~/.claude/` and another pair under `<project>/.claude/`.
   At the session's first turn all four were in the skill/command listing (together with two committed
   control files), and the `Skill` tool invoked every one of them. The hook finished in 17 ms,
   before the listing was built; no restart or second session is needed. So the fallback (a vendoring
   script plus a GitHub Action that opens a PR when the pinned ref changes) is **not needed** and is not
   built.
2. **Project-level files are untracked files.** The session's stop hook
   (`~/.claude/stop-hook-git-check.sh`) immediately asked the session to commit and push them. That is
   the reason user scope is the default, and why project scope writes `.git/info/exclude`.
3. **The real installer, end to end** (a session whose repository carried the one-line curl hook and a
   `.claude/toolkit.yaml` with `toolkit.ref`): `~/.claude/devflow` and the nine skills/commands were
   installed before the first turn; the `/dod` command loaded `project-profile`, whose script lookup
   found `/root/.claude/devflow`, `validate_profile.py --resolved` printed the resolved profile, the
   `verify.dod` commands ran (both commands printed their output: `2` and `3`),
   and `stack-python` loaded because the profile lists it. `git status` showed none of the installed
   files. A fetch of the toolkit through the session's proxy took about 0.8 s.
4. **Not observed:** typing `/dod` in the web UI (the `Skill` tool resolved the same names); a session
   whose repository could not reach `github.com` (the hook would warn and install nothing); a private
   toolkit repository (the repository is public; there is no token handling).

### Checking it yourself

In a new session: the hook's output has `==> Installing devflow <ref>` (or `already installed`).
Run `ls ~/.claude/devflow ~/.claude/commands` and `cat ~/.claude/devflow/.installed`. To test a branch
of the toolkit before tagging, set `toolkit.ref` to the branch name.

## Uninstall

Delete the hook entry. In a cloud session there is nothing else: the container goes away.
