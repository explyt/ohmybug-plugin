#!/bin/bash
# Does a real Claude Code client LOAD the plugin, not only validate it?
#
# `claude plugin validate` reads the manifest. It does not open the hooks files
# the manifest lists, so it passed while 2.0.77 and 2.1.140 refused the whole
# plugin over a hooks file they parse differently ("failed to load"). This asks
# the client itself: install the plugin from this checkout into a throwaway
# config dir, start one headless session, and read the client's own debug log.
#
# The session has no credentials and a dead API address, so it never reaches a
# model: it loads plugins, fails to log in and exits within seconds.
#
#   --mod        the client runs mods: the bughunter module must also load
#   --self-test  positive control: the check must FAIL on a copy whose mods
#                file has the shape old clients refuse. A client that renames
#                its log line would otherwise turn this check green for good.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
usage() { echo "usage: scripts/load-check.sh [--mod | --self-test] <claude-binary>" >&2; exit 2; }

mode=load
case "${1:-}" in --mod|--self-test) mode=${1#--}; shift ;; esac
[ $# = 1 ] || usage
claude=$1

# check <checkout> <mode>: 0 when the client loads the plugin cleanly.
check() {
  local src=$1 want=$2 cfg log
  cfg=$(mktemp -d)
  export CLAUDE_CONFIG_DIR=$cfg
  "$claude" plugin marketplace add "$src" >/dev/null
  "$claude" plugin install bughunter@ohmybug >/dev/null
  # The session-start hooks keep their state in the throwaway dir too.
  OMB_STATE_DIR=$cfg/state ANTHROPIC_API_KEY= ANTHROPIC_BASE_URL=http://127.0.0.1:9 \
    "$claude" -p hi --debug </dev/null >/dev/null 2>&1 || true
  log=$(cat "$cfg"/debug/*.txt 2>/dev/null || true)
  rm -rf "$cfg"
  if [ -z "$log" ]; then echo "load-check: the client wrote no debug log"; return 1; fi
  if grep -E 'Plugin loading errors|Failed to load hooks' <<<"$log" | head -3 | grep .; then
    echo "load-check: $("$claude" --version) refuses the plugin"; return 1
  fi
  if [ "$want" = mod ] && ! grep -q 'hooks module bughunter@ohmybug loaded' <<<"$log"; then
    echo "load-check: $("$claude" --version) loads the plugin but not its mod"; return 1
  fi
  echo "load-check: $("$claude" --version) loads the plugin (check: $want)"
}

case $mode in
  self-test)
    bad=$(mktemp -d)
    cp -R "$ROOT/.claude-plugin" "$ROOT/plugins" "$bad/"
    printf '{ "modules": ["./mod/register.tsx"] }\n' >"$bad/plugins/bughunter/hooks/mods.json"
    if check "$bad" load >/dev/null; then
      rm -rf "$bad"; echo "load-check self-test: FAILED, the refused shape passed"; exit 1
    fi
    rm -rf "$bad"; echo "load-check self-test: ok" ;;
  *) check "$ROOT" "$mode" ;;
esac
