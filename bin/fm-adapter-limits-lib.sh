#!/usr/bin/env bash
# fm-adapter-limits-lib.sh - read rows of bin/fm-adapter-limits.tsv.
# bin/fm-adapter-limits.sh owns the table's meaning and its consistency check.

FM_ADAPTER_LIMITS_FILE="${FM_ADAPTER_LIMITS_FILE:-$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-adapter-limits.tsv}"

# fm_adapter_limit_field <name> <column>: that column of the row, empty when absent.
fm_adapter_limit_field() {
  awk -F'\t' -v n="$1" -v c="$2" '$1 !~ /^[[:space:]]*#/ && $1 == n { print $c; exit }' "$FM_ADAPTER_LIMITS_FILE" 2>/dev/null
}

# fm_adapter_limit <name>: the row's value in the unit the table gives.
fm_adapter_limit() {
  fm_adapter_limit_field "$1" 2
}
