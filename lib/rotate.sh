#!/usr/bin/env bash
# Round-robin start position for the repo loop, split out so the
# arithmetic is testable without gh or a checkout (same shape as
# lib/merge.sh). Source-time side effects are forbidden here.

# Rotate a whitespace-separated list left by $2 positions, one item per
# output line. Why this exists: REPOS walked in a fixed order gives the
# LAST repo only the round budget's leftovers, so it can starve while the
# others fill every round (the log says "round budget spent" before reaching
# it, round after round).
# Rotating the start each round gives every repo
# the front of the line one round in N. A guaranteed-one-PR-per-repo pass
# was considered and rejected: it rewrites the whole per-PR loop for the
# same practical effect.
#
# $2 is taken modulo the list length, and anything non-numeric reads as 0 —
# a corrupt cursor file must degrade to the old fixed order, never abort
# the round.
rotate_list() {
  local list="${1-}" cur="${2-0}" n
  case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  n="$(printf '%s\n' $list | grep -c . || true)"
  [ "${n:-0}" -gt 0 ] || return 0
  printf '%s\n' $list | awk -v s="$(( cur % n ))" \
    'NR > s { print } NR <= s { hold[NR] = $0 } END { for (i = 1; i <= s; i++) print hold[i] }'
}
