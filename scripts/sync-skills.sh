#!/usr/bin/env bash
# Replicate another agent's skills into goose's own skills root.
#
# goose reads skills from ~/.agents/skills, its own convention. Other agents keep
# theirs in their own directory. Point SKILLS_SOURCE at that directory and this
# copies them across. Names are de-duplicated and ~/.agents wins, so a copy in
# goose's root shadows the original.
#
# Copying the files is not enough. A skill that keeps state — a knowledge file, a
# cache, a log — writes it under its own skill home, and that path is written
# inside the skill. A plain copy therefore leaves goose reading and WRITING the
# source tree while appearing independent. This rewrites those paths so the copy
# is self-contained.
#
#   SKILLS_SOURCE=~/.someagent/skills ./scripts/sync-skills.sh
#   SKILLS_SOURCE=~/.someagent/skills ./scripts/sync-skills.sh --force
#
# The originals in SKILLS_SOURCE are never modified.

set -uo pipefail

SRC="${SKILLS_SOURCE:-}"
DST="${GOOSE_SKILLS:-$HOME/.agents/skills}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
info() { printf '  \033[2m•\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

if [ -z "$SRC" ]; then
  bad "set SKILLS_SOURCE to the skills directory you want to copy from"
  info "e.g. SKILLS_SOURCE=~/.someagent/skills $0"
  exit 1
fi
[ -d "$SRC" ] || { bad "no skills directory at $SRC"; exit 1; }
mkdir -p "$DST"

# The dot-directory each root lives under — ".someagent" for ~/.someagent/skills.
# Derived rather than hardcoded so this works for any source agent, and so the
# path rewriting below knows what to look for and what to replace it with.
SRC_MARKER="$(basename "$(dirname "$SRC")")"
DST_MARKER="$(basename "$(dirname "$DST")")"

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

  # Point every path the skill uses at goose's root instead of the source's.
  rewritten=0
  while IFS= read -r f; do
    SRC_MARKER="$SRC_MARKER" DST_MARKER="$DST_MARKER" python3 - "$f" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
src = os.environ["SRC_MARKER"]
dst = os.environ["DST_MARKER"]
try:
    t = p.read_text()
except (UnicodeDecodeError, OSError):
    sys.exit(0)
o = t
t = t.replace("~/%s/skills" % src,   "~/%s/skills" % dst)
t = t.replace("%s/skills" % src,     "%s/skills" % dst)
t = t.replace("%s/commands" % src,   "%s/commands" % dst)
t = t.replace('"%s"' % src,          '"%s"' % dst)
if t != o:
    p.write_text(t)
PY
    rewritten=$((rewritten+1))
  done < <(grep -rl -- "$SRC_MARKER" "$DST/$name" 2>/dev/null)

  size="$(du -sh "$DST/$name" | cut -f1)"
  if [ "$rewritten" -gt 0 ]; then
    ok "$name ($size, $rewritten file(s) repointed at goose's root)"
  else
    ok "$name ($size)"
  fi
done

# Anything left pointing at the source means the copy is not self-contained.
leaks="$(grep -rl -- "$SRC_MARKER" "$DST" 2>/dev/null | wc -l | tr -d ' ')"
printf '\n'
if [ "$leaks" -eq 0 ]; then
  ok "self-contained: no path under $(basename "$DST") refers back to the source"
else
  bad "$leaks file(s) still reference $SRC_MARKER — inspect before relying on this"
  grep -rl -- "$SRC_MARKER" "$DST" 2>/dev/null | head -5 | sed "s|$DST/|      |"
fi

command -v goose >/dev/null 2>&1 && {
  printf '\n  %sgoose now resolves:%s\n' "$(printf '\033[2m')" "$(printf '\033[0m')"
  goose skills list 2>/dev/null | awk -F'|' 'NR>1 && NF>4 {gsub(/^ +| +$/,"",$5); print $5}' \
    | awk '{if ($0 ~ /\.agents/) a++; else if ($0 ~ /builtin/) b++; else c++} END {
        printf "    own: %d   builtin: %d   external: %d\n", a+0, b+0, c+0}'
}
