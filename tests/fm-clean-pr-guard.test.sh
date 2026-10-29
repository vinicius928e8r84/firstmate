#!/usr/bin/env bash
# Tests for bin/fm-clean-pr-guard.sh against a stand-in `gh` (PR state comes from files under $T/gh).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); G=$ROOT/bin/fm-clean-pr-guard.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME=$T/home FM_SW_NO_NOTIFY=1 FM_HOME=$T FM_STATE_OVERRIDE=$T/state PATH=$T/bin:$PATH
mkdir -p "$HOME" "$T/state" "$T/data/rv-1" "$T/data/reviews" "$T/gh" "$T/bin"
cat > "$T/bin/gh" <<'A'
#!/usr/bin/env bash
# gh pr view <url> --json ...: answers from $FM_HOME/gh/<pr number>.json, fails when the file is absent
f=$FM_HOME/gh/${3##*/}.json; [ -f "$f" ] || exit 1; cat "$f"
A
chmod +x "$T/bin/gh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2' want '$3')"; fail=1; fi; }
pr() { printf '{"headRefOid":"%s","mergeStateStatus":"%s","state":"%s"}\n' "$2" "$3" "${4:-OPEN}" > "$T/gh/$1.json"; }
meta() { printf 'kind=%s\npr=https://github.com/o/r/pull/%s\n' "$2" "$3" > "$T/state/$1.meta"; }
H1=1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; H2=2222222bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; H3=3333333ccccccccccccccccccccccccccccccc
H4=4444444dddddddddddddddddddddddddddddddd; H5=5555555eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

meta t1 ship 1; pr 1 $H1 CLEAN                       # clean, no review: alerts
meta t2 ship 2; pr 2 $H2 CLEAN; echo "reviewed $H2" > "$T/state/t2.reviewed"
meta t3 ship 3; pr 3 $H3 CLEAN; echo "# review of ${H3:0:7}" > "$T/data/rv-1/report.md"
meta t4 ship 4; pr 4 $H4 BLOCKED                     # not clean
meta t5 ship 5; pr 5 $H5 CLEAN MERGED                # not open
meta t6 secondmate 6; pr 6 $H1 CLEAN                 # secondmate: skipped
meta t7 ship 7                                       # gh has no answer: skipped
meta t8 ship 8; pr 8 8888888fffffffffffffffffffffffffffffffff CLEAN
printf '{"reviewed_head":"8888888fffffffffffffffffffffffffffffffff"}\n' > "$T/data/reviews/o-r-8.json"
printf 'kind=ship\n' > "$T/state/t9.meta"             # no pr= line

out=$("$G"); rc=$?
check one-alert "$(printf '%s' "$out" | wc -l)" 0
check alert-text "$out" "clean-pr-guard: https://github.com/o/r/pull/1 head 1111111 is CLEAN with no review record (task t1)"
check exit-1 "$rc" 1
out=$("$G"); rc=$?
check once-only "$out|$rc" "|0"
pr 1 $H5 CLEAN
out=$("$G"); check new-head-alerts "${out#*head }" "5555555 is CLEAN with no review record (task t1)"
pr 1 $H5 BEHIND; pr 1 $H5 CLEAN
check seen-after-unclean "$("$G" | wc -l)" 0
echo "$H5" > "$T/state/t1.reviewed"; pr 1 $H1 CLEAN   # the older head was already remembered
check old-head-remembered "$("$G" | wc -l)" 0
exit "$fail"
