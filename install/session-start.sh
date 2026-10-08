#!/bin/bash
# Installs the devflow commands and skills into a Claude Code on the web session.
#
# Call it from the project's own SessionStart hook (see docs/delivery.md):
#
#   "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/devflow.sh"      # a one-line wrapper, or
#   "command": "bash <(curl -fsSL https://raw.githubusercontent.com/andras-tkcs/claude-toolkit/<tag>/install/session-start.sh)"
#
# Only when CLAUDE_CODE_REMOTE=true. Fetches the toolkit at the tag in the profile's `toolkit.ref`
# (.claude/toolkit.yaml), copies commands and skills where Claude Code reads them, and the scripts
# the commands run under ~/.claude/devflow. Idempotent: a second run with the same ref returns at
# once. It never fails the session: a problem is printed as a WARNING and the hook exits 0.
#
# Environment (all optional):
#   DEVFLOW_REF    override toolkit.ref
#   DEVFLOW_REPO   toolkit git URL (default the public repo); a local path works too, for tests
#   DEVFLOW_SCOPE  user (default): install under ~/.claude, outside the repository, so nothing can be
#                  committed. project: install under <project>/.claude and add every installed path
#                  to .git/info/exclude, so a worker can never commit them.
#   DEVFLOW_TIMEOUT seconds allowed for the fetch (default 30)
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

REPO_URL="${DEVFLOW_REPO:-https://github.com/andras-tkcs/claude-toolkit}"
SCOPE="${DEVFLOW_SCOPE:-user}"
FETCH_TIMEOUT="${DEVFLOW_TIMEOUT:-30}"
PROJECT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PROFILE="$PROJECT/.claude/toolkit.yaml"

warn() { echo "    WARNING: devflow: $*" >&2; }
bail() { warn "$*; /make-plan, /implement and /dod are NOT installed in this session"; exit 0; }

case "$SCOPE" in
  user) BASE="$HOME/.claude" ;;
  project) BASE="$PROJECT/.claude" ;;
  *) bail "DEVFLOW_SCOPE must be 'user' or 'project' (got '$SCOPE')" ;;
esac
DEST="$BASE/devflow"
RECORD="$DEST/.installed"

# The ref: env override, else `toolkit.ref` in the profile. Plain text parse, so no YAML library is needed.
REF="${DEVFLOW_REF:-}"
if [ -z "$REF" ] && [ -f "$PROFILE" ]; then
  REF="$(awk '
    /^toolkit:[[:space:]]*$/ { in_t = 1; next }
    in_t && /^[^[:space:]#]/ { in_t = 0 }
    in_t && /^[[:space:]]+ref:/ {
      sub(/^[[:space:]]+ref:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/["'\'']/, ""); print; exit
    }' "$PROFILE")"
fi
[ -n "$REF" ] || bail "no toolkit.ref: set 'toolkit: {ref: <tag>}' in .claude/toolkit.yaml (or DEVFLOW_REF)"
case "$REF" in
  *[!A-Za-z0-9._/-]*|-*) bail "toolkit.ref '$REF' is not a plain tag name" ;;
esac

if [ -f "$RECORD" ] && [ "$(sed -n 1p "$RECORD")" = "$REF|$REPO_URL|$SCOPE" ]; then
  echo "==> devflow $REF already installed ($BASE)"
  exit 0
fi

echo "==> Installing devflow $REF into $BASE"
TMP="$(mktemp -d)" || bail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
if ! timeout "$FETCH_TIMEOUT" git clone --quiet --depth 1 --branch "$REF" -c advice.detachedHead=false \
     "$REPO_URL" "$TMP/toolkit" 2>"$TMP/err"; then
  bail "could not fetch $REPO_URL at '$REF' ($(tail -n1 "$TMP/err"))"
fi
SRC="$TMP/toolkit/plugins"
[ -d "$SRC/devflow/commands" ] || bail "'$REF' of $REPO_URL has no plugins/devflow (not a toolkit tag?)"

# Remove what an earlier install put here (the record lists it), then copy the new files.
if [ -f "$RECORD" ]; then
  tail -n +2 "$RECORD" | while IFS= read -r rel; do
    case "$rel" in ""|/*|*..*) continue ;; esac
    rm -rf "${BASE:?}/$rel"
  done
fi
mkdir -p "$BASE/commands" "$BASE/skills" "$DEST" || bail "cannot create directories under $BASE"
rm -rf "$DEST/scripts" "$DEST/schema"
cp -R "$SRC/devflow/scripts" "$SRC/devflow/schema" "$DEST/" || bail "copy of scripts failed"

installed=()
for f in "$SRC"/devflow/commands/*.md; do
  name="$(basename "$f")"
  if [ -e "$BASE/commands/$name" ]; then
    warn "$BASE/commands/$name exists and is not the toolkit's; left alone, so /${name%.md} is the project's own"
    continue
  fi
  if [ "$SCOPE" = "user" ] && [ -f "$PROJECT/.claude/commands/$name" ]; then
    warn "the project has its own .claude/commands/$name, which may shadow the toolkit's /${name%.md}; delete it when migrating"
  fi
  cp "$f" "$BASE/commands/$name" && installed+=("commands/$name")
done
for d in "$SRC"/devflow/skills/*/ "$SRC"/stack-*/skills/*/; do
  [ -f "$d/SKILL.md" ] || continue
  name="$(basename "$d")"
  if [ -e "$BASE/skills/$name" ]; then
    warn "$BASE/skills/$name exists and is not the toolkit's; left alone"
    continue
  fi
  cp -R "$d" "$BASE/skills/$name" && installed+=("skills/$name")
done
installed+=("devflow")

{
  echo "$REF|$REPO_URL|$SCOPE"
  printf '%s\n' "${installed[@]}"
} > "$RECORD.tmp" && mv "$RECORD.tmp" "$RECORD"

if [ "$SCOPE" = "project" ]; then
  exclude="$(git -C "$PROJECT" rev-parse --git-path info/exclude 2>/dev/null)"
  if [ -n "$exclude" ]; then
    case "$exclude" in /*) ;; *) exclude="$PROJECT/$exclude" ;; esac
    mkdir -p "$(dirname "$exclude")"
    touch "$exclude"
    for rel in "${installed[@]}"; do
      line="/.claude/$rel"
      grep -qxF "$line" "$exclude" || echo "$line" >> "$exclude"
    done
  else
    warn "not a git checkout; could not write .git/info/exclude"
  fi
fi

echo "    installed ${#installed[@]} items: $(printf '%s ' "${installed[@]}")"
exit 0
