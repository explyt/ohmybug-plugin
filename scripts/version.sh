#!/bin/bash
# The plugin's version, derived instead of chosen.
#
# `0.<commit-count>.0`. Hand-maintained semver on a plugin nobody depends on as
# a library is a decision with no inputs: every release asked "is this a minor?"
# about a marketplace that only ever compares for "is there something newer".
# A count answers that and cannot be forgotten.
#
# Why a count and not the CI run number, which is what our other repositories
# use for the human-facing build string: a Claude Code marketplace reads
# `plugin.json` out of the repository, so the number has to be COMMITTED, and a
# run number is not available to someone releasing from a laptop. The count is
# reproducible from any checkout of the same commit.
#
# The known limits, so nobody is surprised:
#   - it needs full history (a shallow clone counts what it has);
#   - two branches can produce the same count, so it identifies a release only
#     together with the sha, which is why publish also tags.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/version.sh [--write | --check | --self-test]
  (no args)    print the version this commit would carry
  --write      write it into plugin.json and marketplace.json
  --check      exit 1 if the manifests disagree with this commit
  --self-test  prove the computation and the rewrite still work
EOF
  exit 2
}

compute() {
  local n
  n=$(git rev-list --count HEAD) || { echo "not a git repository" >&2; exit 1; }
  printf '0.%s.0' "$n"
}

MANIFESTS=(
  "plugins/bughunter/.claude-plugin/plugin.json"
  ".claude-plugin/marketplace.json"
)

# In-place rewrite of a "version": "..." field, done with python rather than sed
# so a malformed manifest fails loudly instead of being half-edited.
write_version() { # file, version
  python3 - "$1" "$2" <<'PY'
import json, re, sys
path, version = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()
json.loads(text)  # refuse to touch a file that is not valid JSON
new, n = re.subn(r'("version"\s*:\s*")[^"]*(")', lambda m: m.group(1) + version + m.group(2), text, count=1)
if n == 0:
    sys.exit(0)  # no version field in this manifest; nothing to do
json.loads(new)
with open(path, 'w') as f:
    f.write(new)
print(f"{path}: {version}")
PY
}

read_version() { # file
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$1"
}

case "${1:-}" in
  '')
    compute; echo
    ;;
  --write)
    V=$(compute)
    for m in "${MANIFESTS[@]}"; do [ -f "$m" ] && write_version "$m" "$V"; done
    ;;
  --check)
    V=$(compute)
    bad=0
    for m in "${MANIFESTS[@]}"; do
      [ -f "$m" ] || continue
      cur=$(read_version "$m")
      # An empty version field means the manifest does not carry one (the
      # marketplace file may not), which is not a disagreement.
      if [ -n "$cur" ] && [ "$cur" != "$V" ]; then
        echo "$m says $cur, this commit is $V — run scripts/version.sh --write" >&2
        bad=1
      fi
    done
    exit $bad
    ;;
  --self-test)
    # A version script that silently stops computing is a release that ships the
    # previous number forever, so this proves the two things it actually does.
    V=$(compute)
    case "$V" in
      0.*.0) ;;
      *) echo "self-test: computed version has the wrong shape: $V" >&2; exit 1 ;;
    esac
    [ "${V#0.}" != "$V" ] || { echo "self-test: no leading 0." >&2; exit 1; }
    N=${V#0.}; N=${N%.0}
    [ "$N" -gt 0 ] 2>/dev/null || { echo "self-test: commit count is not a positive number: $N" >&2; exit 1; }

    tmp=$(mktemp -d)
    printf '{\n  "name": "x",\n  "version": "9.9.9"\n}\n' > "$tmp/m.json"
    write_version "$tmp/m.json" "0.42.0" >/dev/null
    got=$(read_version "$tmp/m.json")
    [ "$got" = "0.42.0" ] || { echo "self-test: rewrite produced '$got'" >&2; rm -rf "$tmp"; exit 1; }
    # A manifest with no version field must be left alone, not corrupted.
    printf '{\n  "name": "x"\n}\n' > "$tmp/n.json"
    write_version "$tmp/n.json" "0.42.0" >/dev/null
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp/n.json" \
      || { echo "self-test: rewrite broke a manifest with no version field" >&2; rm -rf "$tmp"; exit 1; }
    rm -rf "$tmp"
    echo "version self-test: ok ($V)"
    ;;
  *)
    usage
    ;;
esac
