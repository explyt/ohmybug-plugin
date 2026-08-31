#!/bin/bash
# The plugin's version, derived instead of chosen.
#
# `0.N.0`, where N only ever goes UP. Hand-maintained semver on a plugin nobody
# depends on as a library is a decision with no inputs: every release asked "is
# this a minor?" about a marketplace that only ever compares for "is there
# something newer". Increasing answers that and cannot be forgotten.
#
# N is the larger of two numbers, and which one wins says what went right:
#
#   main's commit count + 1   what the squash merge of this branch will produce,
#                             so the number stays anchored to real history and
#                             is the same from any branch, whatever its length;
#   published + 1             the number already in main's manifest, plus one.
#
# The second exists because the first is not monotonic across a mistake. A stamp
# that got ahead of the history — a long branch, before this script predicted
# the squash — is PUBLISHED, and recomputing it back down to the count would
# offer the marketplace a version older than what people already installed. It
# only asks "is there something newer", so those users stop being offered
# updates until the count catches up: silent, and invisible from here. Taking
# the larger of the two costs nothing and cannot regress. Measured twice in two
# days: 0.50.0 and then 0.55.0 onto a main that had reached 48.
#
# Why derived at all and not the CI run number, which is what our other
# repositories use for the human-facing build string: a Claude Code marketplace
# reads `plugin.json` out of the repository, so the number has to be COMMITTED,
# and a run number is not available to someone releasing from a laptop.
#
# The known limits, so nobody is surprised:
#   - it needs main's history and main's manifest (a shallow clone sees less);
#   - two branches in flight compute the same number, so it identifies a release
#     only together with the sha, which is why publish also tags.
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
# ponytail: two branches in flight compute the same number, and the cost is not
# a naming inconvenience. The first merges and publishes N; the second's check
# went green before that and GitHub does not re-run it, so its squash lands
# plugin changes under N again — and everyone already on N is never offered
# them. `--check` does catch it on any re-run, and main goes red afterwards, so
# the exposure is a stale green check. Fetch before computing if branches start
# overlapping often enough for that to be a real risk.
main_ref() {
  local b
  for b in origin/main origin/master main master; do
    git rev-parse --verify -q "$b" >/dev/null && { printf '%s' "$b"; return 0; }
  done
  return 1
}

main_count() {
  local b
  b=$(main_ref) || return 1
  git rev-list --count --first-parent "$b"
}

# The N already published on main, read from main's own manifest rather than
# from the working tree — the working tree is what we are about to overwrite.
published() {
  local b json v
  b=$(main_ref) || return 1
  json=$(git show "$b:${MANIFESTS[0]}" 2>/dev/null) || return 1
  v=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))') || return 1
  case "$v" in
    0.*.0) v=${v#0.}; printf '%s' "${v%.0}"; return 0 ;;
    *) return 1 ;;  # someone hand-wrote a version; not ours to reason about
  esac
}

compute() {
  local n p cur want=0
  if p=$(published) && [ "$p" -ge 0 ] 2>/dev/null; then want=$((p + 1)); fi
  if n=$(main_count) && [ "$((n + 1))" -gt "$want" ]; then want=$((n + 1)); fi
  # Never below what this checkout already carries. Both readings above can
  # fail — no main ref to resolve, or a version outside `0.*.0` that someone
  # wrote by hand — and the fallback below counts HEAD, which on this repo is
  # 48 against a published 56. That is a silent DOWNGRADE produced by the very
  # function whose header promises the number only goes up, so the local
  # manifest is a floor under every path, not just the happy one.
  cur=$(current_n) || cur=""
  if [ -n "$cur" ] && [ "$cur" -gt "$want" ] 2>/dev/null; then want=$cur; fi
  # Nothing to go on at all (a bare `git init` with a manifest that carries no
  # usable version): fall back to counting HEAD, which is what this did before
  # any of it existed.
  if [ "$want" -eq 0 ]; then
    n=$(git rev-list --count HEAD) || { echo "not a git repository" >&2; exit 1; }
    want=$n
  fi
  printf '0.%s.0' "$want"
}

MANIFESTS=(
  "plugins/bughunter/.claude-plugin/plugin.json"
  "plugins/bughunter/.codex-plugin/plugin.json"
  ".claude-plugin/marketplace.json"
)

# The N in the working tree's own manifest, or nothing if it does not carry one
# in our shape.
current_n() {
  local v
  v=$(read_version "${MANIFESTS[0]}" 2>/dev/null) || return 1
  case "$v" in
    0.*.0) v=${v#0.}; printf '%s' "${v%.0}" ;;
    *) return 1 ;;
  esac
}

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
    # records it, and two branches in flight legitimately compute the same
    # number — an equality check could never pass on any commit, and a check
    # nobody can satisfy gets deleted, and then nothing checks.
    #
    # The defect worth catching is never "the number disagrees with the
    # history": being ahead of the count is legal by design, it is what a
    # mistake looks like once it has been published, and the way out is forward.
    # What must not happen is the plugin going out under a number the
    # marketplace already has — no error anywhere, the update simply never
    # appears.
    bad=0
    ref=$(main_ref) || ref=""
    pub=$(published) || pub=""
    if [ -z "$ref" ] || [ -z "$pub" ]; then
      # Not a pass. Every rule below compares against main's number, so without
      # it this command proves nothing — and staying quiet is how a release
      # goes out unchecked while CI shows green.
      echo "cannot read the published version from main (ref='${ref:-none}'): with nothing to compare against, --check proves nothing" >&2
      exit 1
    fi
    # Judge what THIS branch introduces, against the merge base rather than
    # main's tip. A branch opened before the last release carries neither that
    # release's number nor its plugin files, and neither absence is its doing:
    # its squash lands no manifest hunk, so nothing regresses. Measured from the
    # tip, every such branch failed with a claim that was false for it, and was
    # told to stamp a release it does not contain.
    base=$(git merge-base "$ref" HEAD) || base=$ref
    if ! git diff --quiet "$base" -- plugins/; then
      n=$(current_n) || n=""
      if ! [ "${n:-0}" -gt "$pub" ] 2>/dev/null; then
        echo "this branch changes plugins/, so it is a release, but 0.${n:-?}.0 is not newer than the 0.$pub.0 already published — run scripts/version.sh --write" >&2
        bad=1
      fi
    fi
    # On the main ref itself there is no merge base to measure against, so the
    # only question left is one of ORDER: has anything under plugins/ moved
    # since the commit that last wrote the version? This is off on branches by
    # design — there the number is constant for the branch's whole life, so a
    # second `--write` produces the same number, changes no file, records no
    # commit, and the complaint could never be cleared by the remedy it prints.
    if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$ref")" ]; then
      since=$(git log -1 --format=%H -- "${MANIFESTS[0]}")
      if [ -n "$since" ] && [ -n "$(git log --format=%H "$since..HEAD" -- plugins/)" ]; then
        echo "plugins/ changed since the version was last written — run scripts/version.sh --write" >&2
        git log --oneline "$since..HEAD" -- plugins/ >&2
        bad=1
      fi
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

    # The incident itself, replayed: a number that got AHEAD of the history is
    # already published, so the only way out is forward. Recomputing must climb
    # from it, never back down to the count — coming down is what silently ends
    # updates for everyone already holding the published version.
    # The block above deliberately left local main behind origin/main; catch it
    # up first, or this one's push is refused and the failure reads as ours.
    gitc reset -q --hard origin/main
    write_version "$repo/${MANIFESTS[0]}" "0.99.0" >/dev/null
    gitc add -A; gitc commit -qm "a stamp from a long branch"
    gitc push -q origin main
    gitc fetch -q origin main
    got=$(cd "$repo" && bash "$SELF")
    [ "$got" = "0.100.0" ] || {
      echo "self-test: with 0.99.0 published on a short history, the next version came out $got — not forward" >&2
      rm -rf "$tmp"; exit 1
    }
    rc=0; (cd "$repo" && bash "$SELF" --check) >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || { echo "self-test: --check refuses a published number that is ahead of the count (rc=$rc)" >&2; rm -rf "$tmp"; exit 1; }

    # The case commit order cannot see: the plugin and the manifest in ONE
    # commit, with the version left at what is already published. Rule 2 reads
    # that commit as the version's own, finds nothing after it, and passes.
    gitc reset -q --hard origin/main
    echo tweak >> "$repo/plugins/bughunter/hooks.sh"
    # The manifest must really CHANGE in this commit while the version stays put
    # — that is what makes the commit its own "last version write". Rewriting
    # the same number leaves the file untouched, and then rule 2 catches it and
    # this proves nothing.
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["description"]="edited beside the plugin"; json.dump(d, open(sys.argv[1],"w"))' \
      "$repo/${MANIFESTS[0]}"
    gitc add -A; gitc commit -qm "plugin and manifest in one commit"
    rc=0; (cd "$repo" && bash "$SELF" --check) >/dev/null 2>&1 || rc=$?
    [ "$rc" = 1 ] || { echo "self-test: --check passed a plugin change carrying the already-published version (rc=$rc)" >&2; rm -rf "$tmp"; exit 1; }
    (cd "$repo" && bash "$SELF" --write) >/dev/null
    gitc add -A; gitc commit -qm "version"
    rc=0; (cd "$repo" && bash "$SELF" --check) >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || { echo "self-test: --check still red after --write cleared it (rc=$rc)" >&2; rm -rf "$tmp"; exit 1; }

    # And the one number it must refuse: below what main already published.
    write_version "$repo/${MANIFESTS[0]}" "0.98.0" >/dev/null
    gitc add -A; gitc commit -qm "backwards"
    rc=0; (cd "$repo" && bash "$SELF" --check) >/dev/null 2>&1 || rc=$?
    [ "$rc" = 1 ] || { echo "self-test: --check accepted 0.98.0 under a published 0.99.0 (rc=$rc)" >&2; rm -rf "$tmp"; exit 1; }

    # A review round on a branch. The number is constant for a branch's whole
    # life now, so a second plugin commit must NOT demand a new one: re-running
    # --write would produce the same number, change no file, record no commit,
    # and leave a complaint nothing can clear.
    gitc reset -q --hard origin/main
    gitc checkout -q -b review-round
    echo one >> "$repo/plugins/bughunter/hooks.sh"
    gitc add -A; gitc commit -qm "plugin change"
    (cd "$repo" && bash "$SELF" --write) >/dev/null
    gitc add -A; gitc commit -qm "version"
    rc=0; (cd "$repo" && bash "$SELF" --check) >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || { echo "self-test: --check red on a freshly stamped branch (rc=$rc)" >&2; rm -rf "$tmp"; exit 1; }
    echo two >> "$repo/plugins/bughunter/hooks.sh"
    gitc add -A; gitc commit -qm "review round"
    rc=0; (cd "$repo" && bash "$SELF" --check) >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || { echo "self-test: --check red after a second plugin commit on a branch, where --write cannot clear it (rc=$rc)" >&2; rm -rf "$tmp"; exit 1; }

    # A branch that predates the last release and touches no plugin file. It
    # lacks main's newer number and main's newer plugin files, and neither is
    # its doing — its squash lands no manifest hunk, so nothing regresses.
    # Measured against main's TIP instead of the merge base, this went red and
    # told a docs branch to stamp a release.
    gitc checkout -q main
    gitc reset -q --hard origin/main
    gitc checkout -q -b stale
    echo note >> "$repo/notes.txt"
    gitc add -A; gitc commit -qm "docs only"
    gitc checkout -q main
    echo newer >> "$repo/plugins/bughunter/hooks.sh"
    (cd "$repo" && bash "$SELF" --write) >/dev/null
    gitc add -A; gitc commit -qm "a release lands while that branch is open"
    gitc push -q origin main
    gitc fetch -q origin main
    gitc checkout -q stale
    rc=0; (cd "$repo" && bash "$SELF" --check) >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || { echo "self-test: --check failed a branch that predates the release and changes no plugin file (rc=$rc)" >&2; rm -rf "$tmp"; exit 1; }

    # And the paths where main's number cannot be read at all. The fallback used
    # to count HEAD, which on a repo whose published number ran ahead is a
    # silent DOWNGRADE — the one thing this file exists to prevent, produced by
    # the file itself. The manifest in hand is the floor, and --check says so
    # out loud rather than passing with no rule left to apply.
    gitc checkout -q main
    write_version "$repo/${MANIFESTS[0]}" "9.9.9" >/dev/null
    gitc add -A; gitc commit -qm "a version written by hand"
    gitc push -q origin main
    gitc fetch -q origin main
    write_version "$repo/${MANIFESTS[0]}" "0.100.0" >/dev/null
    got=$(cd "$repo" && bash "$SELF")
    [ "$got" = "0.100.0" ] || {
      echo "self-test: with main's number unreadable, the next version came out $got instead of holding at the local 0.100.0" >&2
      rm -rf "$tmp"; exit 1
    }
    # On the MESSAGE, not just the exit code: with nothing readable to compare
    # against, the rules below fall over each other and happen to exit 1 anyway,
    # so a check on the number alone passes whether the refusal is deliberate or
    # accidental — and the accidental one says nothing a reader could act on.
    rc=0; out=$( (cd "$repo" && bash "$SELF" --check) 2>&1 >/dev/null ) || rc=$?
    if [ "$rc" != 1 ] || ! printf '%s' "$out" | grep -q "cannot read the published version"; then
      echo "self-test: --check must refuse loudly when main's number is unreadable (rc=$rc): $out" >&2
      rm -rf "$tmp"; exit 1
    fi

    rm -rf "$tmp"
    echo "version self-test: ok ($V)"
    ;;
  *)
    usage
    ;;
esac
