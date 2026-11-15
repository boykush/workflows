#!/usr/bin/env bash
# Steps of agent-plugins.yml, kept in a file so they can be run by hand too:
#   agent-plugins.sh generate|check|tag <root>
#   agent-plugins.sh bump <root> <base-commit>
# <root> holds one Agent Plugin per directory, each with a plugin.json.
set -euo pipefail

plugins() {
  local d
  for d in "$1"/*/; do
    [ -f "$d/plugin.json" ] && printf '%s\n' "${d%/}"
  done
}

# A tag is <name>--v<version>: the one shape besides v<version> that apm's semver
# ranges resolve, and the one Renovate's versioning for these tags expects.
tag_of() {
  jq -er '
    if (.name | test("^[a-z0-9]+(-[a-z0-9]+)*$")) | not then error("name \(.name) is not kebab-case")
    elif (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) | not then error("version \(.version) is not MAJOR.MINOR.PATCH")
    else "\(.name)--v\(.version)" end' "$1/plugin.json"
}

# apm can't deploy an Agent Plugin to Claude or Codex, but it reads an apm.yml next to
# plugin.json and picks skills/ up on its own, so the MCP servers are all it is told.
generate() {
  local dir skill
  while read -r dir; do
    {
      echo "# Written from plugin.json and mcp.json by boykush/workflows' agent-plugins.yml; edit those."
      # A JSON string reads as a double-quoted YAML scalar as it is.
      jq -r '"name: \(.name | tojson)", "version: \(.version | tojson)", "description: \(.description | tojson)", "author: \(.author.name | tojson)"' "$dir/plugin.json"
      echo 'dependencies:'
      # With no dependency at all, apm takes the directory for an Agent Plugin again and
      # deploys nothing, so a plugin with skills only names them; listed, they are counted
      # twice and apm warns that one replaced the other, which is harmless.
      if [ "$(jq '.mcpServers // {} | length' "$dir/mcp.json" 2>/dev/null || echo 0)" -gt 0 ]; then
        echo '  apm: []'
      elif ls "$dir"/skills/*/SKILL.md > /dev/null 2>&1; then
        echo '  apm:'
        for skill in "$dir"/skills/*/SKILL.md; do
          printf '    - ./skills/%s\n' "$(basename "$(dirname "$skill")")"
        done
      else
        echo '  apm: []'
      fi
      if [ ! -f "$dir/mcp.json" ]; then
        echo '  mcp: []'
      else
        # A declaration apm's transports can't carry stops here rather than being dropped.
        jq -r '
          (.mcpServers // {}) as $s
          | if ($s | length) == 0 then "  mcp: []" else "  mcp:",
            ($s | to_entries[] | .key as $n | .value
              | if (keys - ["type", "url"]) != [] then error("\($n): only type and url can be carried") else . end
              | ({"streamable-http": "http", "http": "http", "sse": "sse"}[.type]
                 // error("\($n): transport \(.type) can not be carried")) as $t
              | "    - name: \($n | tojson)", "      registry: false", "      transport: \($t)", "      url: \(.url | tojson)")
          end' "$dir/mcp.json"
      fi
    } > "$dir/apm.yml"
    echo "wrote $dir/apm.yml"
  done < <(plugins "$1")
}

# Installs each plugin into a throwaway consumer and asserts that every server and
# every skill it ships lands for both clients.
check() {
  local dir abs tmp url skill name shipped n=0
  while read -r dir; do
    n=$((n + 1))
    shipped=0
    tag_of "$dir" > /dev/null
    abs=$(cd "$dir" && pwd)
    tmp=$(mktemp -d)
    printf 'name: check\nversion: 0.0.0\ntargets: [claude, codex]\ndependencies:\n  apm:\n    - %s\n' "$abs" > "$tmp/apm.yml"
    (cd "$tmp" && git init -q && apm install > install.log 2>&1) || { cat "$tmp/install.log" >&2; exit 1; }
    name=$(basename "$dir")
    if [ -f "$dir/mcp.json" ]; then
      for url in $(jq -r '.mcpServers // {} | .[].url' "$dir/mcp.json"); do
        grep -qF "$url" "$tmp/.mcp.json" || { echo "::error::$name: $url is not in .mcp.json" >&2; exit 1; }
        grep -qF "$url" "$tmp/.codex/config.toml" || { echo "::error::$name: $url is not in .codex/config.toml" >&2; exit 1; }
        echo "ok $name: $url"
        shipped=$((shipped + 1))
      done
    fi
    for skill in "$dir"/skills/*/; do
      [ -f "$skill/SKILL.md" ] || continue
      skill=$(basename "$skill")
      for to in .claude/skills .agents/skills; do
        diff -r "$dir/skills/$skill" "$tmp/$to/$skill" > /dev/null \
          || { echo "::error::$name: skill $skill did not land whole in $to" >&2; exit 1; }
      done
      echo "ok $name: skill $skill"
      shipped=$((shipped + 1))
    done
    [ "$shipped" -gt 0 ] || { echo "::error::$name ships no MCP server and no skill" >&2; exit 1; }
  done < <(plugins "$1")
  [ "$n" -gt 0 ] || { echo "::error::no plugin.json under $1" >&2; exit 1; }
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
      echo "::error file=$dir/plugin.json::$(basename "$dir") changed, but $tag already exists: raise version in plugin.json" >&2
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

cmd=${1:?generate, check, bump or tag}
shift
"$cmd" "$@"
