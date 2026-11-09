#!/usr/bin/env bash
# fm-request-log-retention.sh - keep the request-logger directory from growing ~1.6 GB/day.
# Usage: fm-request-log-retention.sh [--dry-run|--apply] [--dir <request-logs-dir>] [--raw-hours N] [--archive-days N]
#   default --dry-run; the hourly cron line passes --apply.
# Layout under <dir> (default $FM_HOME/data/request-logs): logs/<UTC-stamp>_<agent>.{md,request.txt,response.txt} written by the
#   logger, archive/<UTC-hour>.tar.zst written here, keep/ for requests preserved by hand (never read or touched here).
# Rules: a request older than --raw-hours (default 6) by its filename stamp is packed, with its three files, into one
#   archive/<YYYY-MM-DDTHH>.tar.zst per hour (zstd -19 --long=27: consecutive requests repeat almost all of their context, ~100x).
#   Newer requests stay raw so the .md files remain readable. Originals are deleted only after the archive passes `zstd -t` and a
#   byte comparison against the files on disk. Archives older than --archive-days (default 30) are deleted.
# Never: a request any file of which was modified in the last 5 minutes or is open by a live process (the request being written);
#   keep/; a request whose stamp does not parse. A second run for an hour already archived writes <hour>.2.tar.zst, never overwrites.
# Env: FM_HOME, RL_NOW (tests only: epoch used as now), RL_ZSTD_LEVEL (default 19).
# Exit: 0 ok (also when another run holds the lock), 64 usage, 1 an archive failed verification (originals kept).
set -uo pipefail
FM_HOME=${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
dir=$FM_HOME/data/request-logs; raw_hours=6; archive_days=30; apply=0
while [ $# -gt 0 ]; do case "$1" in
  --apply) apply=1;; --dry-run) apply=0;;
  --dir) dir=${2:?}; shift;; --raw-hours) raw_hours=${2:?}; shift;; --archive-days) archive_days=${2:?}; shift;;
  *) echo "usage: $0 [--dry-run|--apply] [--dir DIR] [--raw-hours N] [--archive-days N]" >&2; exit 64;; esac; shift; done
case "$raw_hours$archive_days" in *[!0-9]*|'') echo "usage: --raw-hours and --archive-days take whole numbers" >&2; exit 64;; esac
logs=$dir/logs; arch=$dir/archive
[ -d "$logs" ] || { echo "no logs dir: $logs"; exit 0; }
now=${RL_NOW:-$(date +%s)}; level=${RL_ZSTD_LEVEL:-19}
mkdir -p "$arch"
exec 9> "$arch/.lock"; flock -n 9 || { echo "another run holds the lock"; exit 0; }
part=""; open=$(mktemp); cand=$(mktemp)
# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() { rm -f "$open" "$cand"; [ -z "$part" ] || rm -f "$part"; }
trap cleanup EXIT
echo "== fm-request-log-retention $([ $apply = 1 ] && echo apply || echo dry-run) dir=$dir raw=${raw_hours}h archive=${archive_days}d"
find /proc/[0-9]*/fd -lname "$logs/*" -printf '%l\n' 2>/dev/null | sort -u > "$open"
# <hour>\t<file> for every file of a request that is old enough (filename stamp is UTC, so a string compare is a time compare) and idle
cutoff=$(date -u -d "@$((now-raw_hours*3600))" +%Y-%m-%dT%H-%M-%S-999)
find "$logs" -maxdepth 1 -type f -printf '%f\t%T@\n' | awk -F'\t' -v now="$now" -v cutoff="$cutoff" -v opn="$open" -v logs="$logs" '
  BEGIN{ while((getline l < opn)>0) busy[l]=1 }
  { name=$1; mt=$2
    if(match(name,/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{3}_.+\.(md|request\.txt|response\.txt)$/)==0) next
    key=name; sub(/\.(md|request\.txt|response\.txt)$/,"",key)
    F[name]=key; if(!(key in newest) || mt>newest[key]) newest[key]=mt
    if((logs "/" name) in busy) bz[key]=1 }
  END{ for(n in F){ k=F[n]
      if(substr(k,1,23)>cutoff) continue
      if(now-newest[k]<300 || (k in bz)) continue
      print substr(k,1,13) "\t" n } }' | sort > "$cand"
nreq=$(cut -f2 "$cand" | sed -E 's/\.(md|request\.txt|response\.txt)$//' | sort -u | wc -l)
total=0; failed=0; packed=0
while IFS= read -r hour; do
  [ -n "$hour" ] || continue
  list=$(mktemp); awk -F'\t' -v h="$hour" '$1==h{print $2}' "$cand" | sort > "$list"
  bytes=$(cd "$logs" && xargs -a "$list" -d '\n' stat -c %s | awk '{s+=$1}END{print s+0}')
  nf=$(wc -l < "$list"); total=$((total+bytes))
  out=$arch/$hour.tar.zst; i=2; while [ -e "$out" ]; do out=$arch/$hour.$i.tar.zst; i=$((i+1)); done
  echo "pack $hour: $nf files $bytes bytes -> ${out##*/}"
  if [ $apply = 1 ]; then
    part=$out.part
    if tar -C "$logs" -cf - -T "$list" | zstd -q -"$level" --long=27 -T1 -o "$part" -f \
       && zstd -tq "$part" && [ "$(zstd -dc --long=27 "$part" | tar -tf - | wc -l)" = "$nf" ] \
       && zstd -dc --long=27 "$part" | tar -C "$logs" --compare -f - >/dev/null 2>&1; then
      mv "$part" "$out"; part=""
      (cd "$logs" && xargs -a "$list" -d '\n' rm -f --); packed=$((packed+nf))
      echo "  ok: $(stat -c %s "$out") bytes archived, $nf originals removed"
    else
      rm -f "$part"; part=""; failed=1; echo "  FAILED verification, originals kept"
    fi
  fi
  rm -f "$list"
done < <(cut -f1 "$cand" | sort -u)
echo "requests: $nreq in $(cut -f1 "$cand" | sort -u | wc -l) hours, $total bytes $([ $apply = 1 ] && echo packed || echo would be packed)"
old=0; oldb=0
while IFS= read -r a; do [ -n "$a" ] || continue
  b=$(stat -c %s "$a"); old=$((old+1)); oldb=$((oldb+b)); echo "prune archive ${a##*/} ($b bytes, older than ${archive_days}d)"
  [ $apply = 1 ] && rm -f -- "$a"
done < <(find "$arch" -maxdepth 1 -type f -name '*.tar.zst' -printf '%T@ %p\n' | awk -v lim="$((now-archive_days*86400))" '$1<lim{sub(/^[^ ]+ /,""); print}')
echo "archives pruned: $old ($oldb bytes)$([ $apply = 1 ] || echo ' (dry-run)')"
[ "$failed" = 0 ] || exit 1
exit 0
