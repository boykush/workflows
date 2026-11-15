#!/usr/bin/env bash
# Steps of apm-plugins.yml, kept in a file so they can be run by hand too:
#   apm-plugins.sh check|tag <root>
#   apm-plugins.sh bump <root> <base-commit>
# <root> holds one apm package per directory, each with an apm.yml.
set -euo pipefail

plugins() {
  local d
  for d in "$1"/*/; do
    [ -f "$d/apm.yml" ] && printf '%s\n' "${d%/}"
  done
}

# A tag is <name>--v<version>: the one shape besides v<version> that apm's semver
# ranges resolve, and the one Renovate's apm manager reads a version from.
tag_of() {
  yq -e '
    select(.name | tostring | test("^[a-z0-9]+(-[a-z0-9]+)*$")) | select(.version | tostring | test("^[0-9]+\.[0-9]+\.[0-9]+$"))
    | .name + "--v" + .version' "$1/apm.yml" \
    || { echo "::error file=$1/apm.yml::name must be kebab-case and version MAJOR.MINOR.PATCH" >&2; return 1; }
}

# Installs each plugin into a throwaway consumer and asserts that every server and
# every skill it ships lands for both clients.
check() {
  local dir abs tmp url skill name to shipped n=0
  while read -r dir; do
    n=$((n + 1))
    shipped=0
    tag_of "$dir" > /dev/null
    abs=$(cd "$dir" && pwd)
    name=$(basename "$dir")
    tmp=$(mktemp -d)
    printf 'name: check\nversion: 0.0.0\ntargets: [claude, codex]\ndependencies:\n  apm:\n    - %s\n' "$abs" > "$tmp/apm.yml"
    (cd "$tmp" && git init -q && apm install > install.log 2>&1) || { cat "$tmp/install.log" >&2; exit 1; }
    for url in $(yq '.dependencies.mcp // [] | .[].url' "$dir/apm.yml"); do
      grep -qF "$url" "$tmp/.mcp.json" || { echo "::error::$name: $url is not in .mcp.json" >&2; exit 1; }
      grep -qF "$url" "$tmp/.codex/config.toml" || { echo "::error::$name: $url is not in .codex/config.toml" >&2; exit 1; }
      echo "ok $name: $url"
      shipped=$((shipped + 1))
    done
    for skill in "$dir"/.apm/skills/*/; do
      [ -f "$skill/SKILL.md" ] || continue
      skill=$(basename "$skill")
      for to in .claude/skills .agents/skills; do
        diff -r "$dir/.apm/skills/$skill" "$tmp/$to/$skill" > /dev/null \
          || { echo "::error::$name: skill $skill did not land whole in $to" >&2; exit 1; }
      done
      echo "ok $name: skill $skill"
      shipped=$((shipped + 1))
    done
    [ "$shipped" -gt 0 ] || { echo "::error::$name ships no MCP server and no skill" >&2; exit 1; }
  done < <(plugins "$1")
  [ "$n" -gt 0 ] || { echo "::error::no apm.yml under $1" >&2; exit 1; }
}

# A plugin whose files changed must carry a version whose tag is not taken yet, or its
# consumers would keep the old content under the same tag. README.md ships to no one.
bump() {
  local dir changed tag
  while read -r dir; do
    changed=$(git diff --name-only "$2" HEAD -- "$dir" ':(exclude)'"$dir"/README.md)
    [ -n "$changed" ] || continue
    tag=$(tag_of "$dir")
    if git rev-parse -q --verify "refs/tags/$tag" > /dev/null; then
      echo "::error file=$dir/apm.yml::$(basename "$dir") changed, but $tag already exists: raise version in apm.yml" >&2
      exit 1
    fi
    echo "ok $(basename "$dir"): changed, to be released as $tag"
  done < <(plugins "$1")
}

# Through the API rather than git push, so the checkout keeps no credentials.
tag() {
  local dir tag
  while read -r dir; do
    tag=$(tag_of "$dir")
    if git rev-parse -q --verify "refs/tags/$tag" > /dev/null; then
      echo "ok $tag exists"
      continue
    fi
    gh api "repos/$GITHUB_REPOSITORY/git/refs" -f ref="refs/tags/$tag" -f sha="$GITHUB_SHA" > /dev/null
    echo "tagged $tag at $GITHUB_SHA"
  done < <(plugins "$1")
}

cmd=${1:?check, bump or tag}
shift
"$cmd" "$@"
