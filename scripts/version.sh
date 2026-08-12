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
#   - the number is the count at the commit it was COMPUTED on, so the manifest
#     reads one behind the commit that records it. That is why --check does not
#     compare for equality.
set -euo pipefail

SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

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
    # `[ -f ] && write` would leave the loop's status at 1 when the LAST
    # manifest is the absent one, and under `set -e` that is a --write that
    # wrote the version and then reported failure.
    for m in "${MANIFESTS[@]}"; do
      if [ -f "$m" ]; then write_version "$m" "$V"; fi
    done
    ;;
  --check)
    # NOT equality with `compute`. The write is computed before the commit that
    # records it, so the manifest is permanently one behind the count and an
    # equality check could never pass on any commit — a check nobody can
    # satisfy gets deleted, and then nothing checks.
    #
    # The defect worth catching is the plugin changing without the version
    # changing: the marketplace then never offers the update, and nothing looks
    # broken. So: nothing under plugins/ may have changed since the manifest
    # last did.
    bad=0
    count=$(git rev-list --count HEAD)
    for m in "${MANIFESTS[@]}"; do
      [ -f "$m" ] || continue
      cur=$(read_version "$m")
      # An empty version field means the manifest does not carry one (the
      # marketplace file may not), which is not a disagreement.
      [ -n "$cur" ] || continue
      n=${cur#0.}; n=${n%.0}
      if ! [ "$n" -le "$count" ] 2>/dev/null; then
        echo "$m says $cur, which is not a commit count this history has reached ($count)" >&2
        bad=1
      fi
    done
    since=$(git log -1 --format=%H -- "${MANIFESTS[0]}")
    if [ -n "$since" ] && [ -n "$(git log --format=%H "$since..HEAD" -- plugins/)" ]; then
      echo "plugins/ changed since the version was last written — run scripts/version.sh --write" >&2
      git log --oneline "$since..HEAD" -- plugins/ >&2
      bad=1
    fi
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
    # --check is the half that runs unattended, so it gets a real history:
    # a commit under plugins/ that leaves the manifest alone must be caught,
    # and writing the version must clear it.
    repo=$tmp/repo
    mkdir -p "$repo/plugins/bughunter/.claude-plugin"
    git -C "$repo" init -q -b main
    gitc() { git -C "$repo" -c user.email=t@t -c user.name=t "$@"; }
    printf '{"version":"0.1.0"}\n' > "$repo/plugins/bughunter/.claude-plugin/plugin.json"
    gitc add -A; gitc commit -qm one
    echo hook > "$repo/plugins/bughunter/hooks.sh"
    gitc add -A; gitc commit -qm two
    rc=0; (cd "$repo" && bash "$SELF" --check) >/dev/null 2>&1 || rc=$?
    [ "$rc" = 1 ] || { echo "self-test: --check passed a plugin change with a stale version (rc=$rc)" >&2; rm -rf "$tmp"; exit 1; }
    (cd "$repo" && bash "$SELF" --write) >/dev/null
    gitc add -A; gitc commit -qm three
    rc=0; (cd "$repo" && bash "$SELF" --check) >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || { echo "self-test: --check still failing after a version write (rc=$rc)" >&2; rm -rf "$tmp"; exit 1; }
    rm -rf "$tmp"
    echo "version self-test: ok ($V)"
    ;;
  *)
    usage
    ;;
esac
