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

# The count of the history the version will LIVE in, which is not the history
# it is computed on.
#
# Counting HEAD looked equivalent and is not, because we squash-merge: five
# commits on a branch become one on main. `--write` also runs before the commit
# that records it, so a branch stamps `base + k - 1` while the squash gives main
# `base + 1` — the two agree only for k <= 2. A three-commit branch therefore
# lands a number main's history has not reached, `--check` goes red on main
# right after the merge (where nobody is looking), and the NEXT release computes
# LOWER than the one already published — the marketplace only ever asks "is
# there something newer", so users stop being offered updates until the count
# catches up. Measured on this repo: a 5-commit branch stamped 0.50.0 onto a
# main that would reach 48.
#
# `origin/main` first-parent + 1 is what the squash will produce, from any
# branch, whatever its length. It is also monotonic, which is the property the
# marketplace actually needs.
#
# ponytail: two branches in flight stamp the same number; the second must
# re-run --write after rebasing, and `--check`'s first rule catches it if it
# does not. Key on the published version instead if that ever stops being rare.
main_count() {
  local b n
  for b in origin/main origin/master main master; do
    n=$(git rev-list --count --first-parent "$b" 2>/dev/null) && [ -n "$n" ] && { printf '%s' "$n"; return 0; }
  done
  return 1
}

compute() {
  local n
  # No main to predict (a bare `git init`, a detached CI checkout with no
  # branches): fall back to counting HEAD, which is what this did before.
  n=$(main_count) && printf '0.%s.0' "$((n + 1))" && return 0
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
    # Bound by the same quantity `--write` stamps, not only by this history.
    # `--write` moved onto `origin/main + 1`; this rule stayed on HEAD, and on
    # a branch cut a few merges back that is the SMALLER number — so the script
    # called its own correct stamp invalid seconds after writing it. Take
    # whichever is larger: the rule exists to catch a number no history could
    # reach, and both of these are histories this commit can reach.
    if n=$(main_count) && [ "$((n + 1))" -gt "$count" ]; then count=$((n + 1)); fi
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

    # The squash case, driven end to end, because it is the one that shipped a
    # red main: a branch LONGER than the squash it becomes must still stamp the
    # number its merge will produce. Counting HEAD gives 7 here and the merge
    # gives 4, so this fails loudly on any return to that.
    origin=$tmp/origin
    git clone -q --bare "$repo" "$origin"
    gitc remote add origin "$origin"
    gitc fetch -q origin main
    base=$(git -C "$repo" rev-list --count --first-parent origin/main)
    gitc checkout -q -b long
    for i in 1 2 3 4; do
      echo "$i" > "$repo/plugins/bughunter/f$i"
      gitc add -A; gitc commit -qm "long $i"
    done
    want="0.$((base + 1)).0"
    got=$(cd "$repo" && bash "$SELF")
    [ "$got" = "$want" ] || {
      echo "self-test: a 4-commit branch stamped $got, but its squash merge will make main $want" >&2
      rm -rf "$tmp"; exit 1
    }
    # And the number must survive the merge it predicted: squash it and confirm
    # --check, the rule that turns main red, is satisfied by what we stamped.
    (cd "$repo" && bash "$SELF" --write) >/dev/null
    gitc add -A; gitc commit -qm "long 5 (version)"
    gitc checkout -q main
    gitc merge -q --squash long
    gitc commit -qm "squashed"
    rc=0; (cd "$repo" && bash "$SELF" --check) >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || { echo "self-test: --check red on main right after a squash merge (rc=$rc)" >&2; rm -rf "$tmp"; exit 1; }

    # The remote ref must beat a local `main` that is behind it. This is the
    # half the change rests on and the half nothing above could see: everywhere
    # earlier, `main` and `origin/main` sit on the same commit, so dropping
    # `origin/main` from the ref list left the whole self-test green. What that
    # mutation costs is the silent failure, not a red one — a laptop that
    # fetches without fast-forwarding stamps BELOW the published number, and
    # the marketplace, which only asks "is there something newer", stops
    # offering the update to everyone.
    gitc checkout -q main
    echo ahead > "$repo/plugins/bughunter/ahead"
    gitc add -A; gitc commit -qm "pushed by someone else"
    gitc push -q origin main
    gitc reset -q --hard HEAD~1
    gitc fetch -q origin main
    remote=$(git -C "$repo" rev-list --count --first-parent origin/main)
    localn=$(git -C "$repo" rev-list --count --first-parent main)
    [ "$remote" -gt "$localn" ] || {
      echo "self-test: fixture failed to leave local main behind origin/main ($localn vs $remote)" >&2
      rm -rf "$tmp"; exit 1
    }
    want="0.$((remote + 1)).0"
    got=$(cd "$repo" && bash "$SELF")
    [ "$got" = "$want" ] || {
      echo "self-test: a stale local main stamped $got, but origin/main says the release will be $want" >&2
      rm -rf "$tmp"; exit 1
    }
    # And --check must accept what --write just produced, on this very branch.
    # The two were keyed on different quantities once: --write on origin/main,
    # --check on HEAD, which on a branch behind main is the smaller number — so
    # the script called its own stamp invalid, seconds after writing it.
    (cd "$repo" && bash "$SELF" --write) >/dev/null
    gitc add -A; gitc commit -qm "version"
    rc=0; (cd "$repo" && bash "$SELF" --check) >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || { echo "self-test: --check rejects the version --write just stamped (rc=$rc)" >&2; rm -rf "$tmp"; exit 1; }

    rm -rf "$tmp"
    echo "version self-test: ok ($V)"
    ;;
  *)
    usage
    ;;
esac
