#!/usr/bin/env bash
# Replicate Claude Code skills into goose's own skills root.
#
# goose reads skills from ~/.agents/skills (its own convention) and also from
# ~/.claude/skills if that exists. Names are de-duplicated and ~/.agents wins, so
# copying a skill across makes goose use its copy and ignore Claude's.
#
# Copying the files is not enough. Skills contain hardcoded paths — sala-vty, for
# example, keeps its knowledge registry and interaction log under its skill home —
# and a plain copy leaves goose reading and WRITING Claude's tree while appearing
# independent. This rewrites those paths so the copy is genuinely self-contained.
#
#   ./scripts/sync-skills.sh           # copy any skill not already in goose's root
#   ./scripts/sync-skills.sh --force   # re-copy, overwriting goose's versions
#
# Claude's originals are never modified.

set -uo pipefail

SRC="${CLAUDE_SKILLS:-$HOME/.claude/skills}"
DST="${GOOSE_SKILLS:-$HOME/.agents/skills}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
info() { printf '  \033[2m•\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

[ -d "$SRC" ] || { bad "no Claude skills at $SRC"; exit 1; }
mkdir -p "$DST"

printf '\033[1mReplicating skills\033[0m  %s -> %s\n' "${SRC/#$HOME/~}" "${DST/#$HOME/~}"

# Skills sit at <root>/<name>/SKILL.md, and synced ones a further two levels down
# at <root>/synced/<uuid>/<name>/SKILL.md — hence depth 4, not 3.
find "$SRC" -name SKILL.md -maxdepth 4 -print0 2>/dev/null | while IFS= read -r -d '' skill; do
  dir="$(dirname "$skill")"
  name="$(basename "$dir")"

  if [ -e "$DST/$name" ] && [ "$FORCE" -eq 0 ]; then
    info "$name already in goose's root — left alone (--force to replace)"
    continue
  fi

  rm -rf "${DST:?}/$name"
  cp -a "$dir" "$DST/$name" || { bad "failed to copy $name"; continue; }

  # Repo metadata and caches of cloned repos are not worth duplicating; the
  # skill re-fetches them under its own root when it next needs them.
  rm -rf "$DST/$name/.git" "$DST/$name/.github" "$DST/$name/cache"

  # Point every path the skill uses at goose's root instead of Claude's.
  rewritten=0
  while IFS= read -r f; do
    python3 - "$f" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
try:
    t = p.read_text()
except (UnicodeDecodeError, OSError):
    sys.exit(0)
o = t
t = t.replace("~/.claude/skills", "~/.agents/skills")
t = t.replace(".claude/skills",  ".agents/skills")
t = t.replace(".claude/commands", ".agents/commands")
t = t.replace('".claude"', '".agents"')
if t != o:
    p.write_text(t)
PY
    rewritten=$((rewritten+1))
  done < <(grep -rl '\.claude' "$DST/$name" 2>/dev/null)

  size="$(du -sh "$DST/$name" | cut -f1)"
  if [ "$rewritten" -gt 0 ]; then
    ok "$name ($size, $rewritten file(s) repointed at goose's root)"
  else
    ok "$name ($size)"
  fi
done

# Anything left pointing at Claude means the copy is not self-contained.
leaks="$(grep -rl '\.claude' "$DST" 2>/dev/null | wc -l | tr -d ' ')"
printf '\n'
if [ "$leaks" -eq 0 ]; then
  ok "self-contained: no path under $(basename "$DST") refers to Claude"
else
  bad "$leaks file(s) still reference .claude — inspect before relying on this"
  grep -rl '\.claude' "$DST" 2>/dev/null | head -5 | sed "s|$DST/|      |"
fi

command -v goose >/dev/null 2>&1 && {
  printf '\n  %sgoose now resolves:%s\n' "$(printf '\033[2m')" "$(printf '\033[0m')"
  goose skills list 2>/dev/null | awk -F'|' 'NR>1 && NF>4 {gsub(/^ +| +$/,"",$5); print $5}' \
    | awk '{if ($0 ~ /\.agents/) a++; else if ($0 ~ /builtin/) b++; else c++} END {
        printf "    own: %d   builtin: %d   from Claude: %d\n", a+0, b+0, c+0}'
}
