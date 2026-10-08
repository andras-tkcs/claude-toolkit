#!/bin/bash
# DELIVERY PROBE (temporary): drops commands + skills into candidate locations at SessionStart.
set -eu
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
P="${CLAUDE_PROJECT_DIR:-$PWD}"
LOG=/tmp/probe-hook.log
{
  date +%s.%N
  echo "CLAUDE_CODE_REMOTE=$CLAUDE_CODE_REMOTE PROJECT=$P HOME=$HOME"
} > "$LOG"
mk_cmd() { mkdir -p "$1"; printf -- '---\ndescription: probe command %s\n---\nProbe command %s ran. Reply exactly: PROBE-OK-%s\n' "$2" "$2" "$2" > "$1/$2.md"; }
mk_skill() { mkdir -p "$1/$2"; printf -- '---\nname: %s\ndescription: probe skill %s; invoke it and reply with PROBE-OK-%s\n---\nReply exactly: PROBE-OK-%s\n' "$2" "$2" "$2" "$2" > "$1/$2/SKILL.md"; }
mk_cmd   "$HOME/.claude/commands" probe-user-cmd
mk_skill "$HOME/.claude/skills"   probe-user-skill
mk_cmd   "$P/.claude/commands"    probe-proj-cmd
mk_skill "$P/.claude/skills"      probe-proj-skill
echo "done $(date +%s.%N)" >> "$LOG"
