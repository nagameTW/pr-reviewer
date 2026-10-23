#!/usr/bin/env bash
# The display copy of a diff, the only form of the diff that a model reads.
# Sourced by pr-autoreview.sh.
#
# Why it exists: the Read tool prints a line number in front of each line of
# a file. A model that reads the raw diff copied that number into the
# "line" field of a finding, so the comment pointed at the wrong code. The
# display copy gives every diff line a label that holds the new-side line
# number. The label is not a bare number, so it cannot be mistaken for the
# number that Read prints.
#
# Label, then one tab, then the full original line:
#   NEW[<n>]  context line or added line. n is its line in the new file.
#   NEW[-]    removed line. It has no line in the new file.
#   HUNK[-]   hunk header ("@@ -a,b +c,d @@").
#   NOTE[-]   the "\ No newline at end of file" marker.
#   META[-]   every other line: file headers, rename and mode lines, binary
#             stubs.
# The harness writes the label. The author controls only the bytes after the
# tab, so author text that looks like a label stays payload.
#
# The raw diff stays as it is. git apply, the slice splitter, the symbol
# scan, the file lists and the existence checks all need the raw patch.

# diffview_render IN OUT: write the display copy of IN to OUT. Returns 1 and
# leaves no OUT when IN is missing, empty, or not a diff this function can
# label line by line. The counts in each hunk header decide where the hunk
# ends. A line that starts with "+++ " inside a hunk is an added line.
# Trade-off: a combined diff (@@@) and any other format that GitHub does not
# send is refused, and the caller falls back to the raw diff.
diffview_render() {
  local in="${1-}" out="${2-}"
  [ -n "$out" ] && [ -f "$in" ] && [ -s "$in" ] || return 1
  if LC_ALL=C awk '
    function fail(msg) { print "diffview: " msg " at line " NR > "/dev/stderr"; failed = 1; exit 1 }
    {
      line = $0
      if (inh) {
        c = substr(line, 1, 1)
        if (c == " " || (line == "" && orem > 0 && nrem > 0)) {
          if (orem < 1 || nrem < 1) fail("context line beyond the hunk counts")
          printf "NEW[%d]\t%s\n", n, line; n++; orem--; nrem--
        } else if (c == "+") {
          if (nrem < 1) fail("added line beyond the hunk counts")
          printf "NEW[%d]\t%s\n", n, line; n++; nrem--
        } else if (c == "-") {
          if (orem < 1) fail("removed line beyond the hunk counts")
          printf "NEW[-]\t%s\n", line; orem--
        } else if (c == "\\") {
          printf "NOTE[-]\t%s\n", line; next
        } else fail("unexpected line inside a hunk")
        if (orem == 0 && nrem == 0) { inh = 0; last = 1 } else last = 0
        next
      }
      if (line ~ /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/) {
        split(line, p, " ")
        o = substr(p[2], 2); w = substr(p[3], 2)
        orem = 1; nrem = 1
        if (index(o, ",")) { split(o, oo, ","); orem = oo[2] + 0 }
        if (index(w, ",")) { split(w, ww, ","); nrem = ww[2] + 0 }
        n = (index(w, ",") ? ww[1] : w) + 0
        printf "HUNK[-]\t%s\n", line
        inh = (orem > 0 || nrem > 0); last = 0
        next
      }
      if (line ~ /^@@/) fail("hunk header this function cannot read")
      if (last && substr(line, 1, 1) == "\\") { printf "NOTE[-]\t%s\n", line; last = 0; next }
      last = 0
      c = substr(line, 1, 1)
      if (c == " " || (c == "+" && substr(line, 1, 4) != "+++ ") || (c == "-" && substr(line, 1, 4) != "--- "))
        fail("hunk line outside a hunk")
      printf "META[-]\t%s\n", line
    }
    END {
      if (failed) exit 1
      if (inh) { print "diffview: the last hunk is cut short" > "/dev/stderr"; exit 1 }
      if (NR == 0) exit 1
    }' "$in" > "$out"; then
    return 0
  fi
  rm -f "$out"
  return 1
}

# diffview_make SRC ROOT NAME: render SRC into ROOT/NAME/diff.numbered and
# print that path. The directory holds that one file and nothing else, so a
# model call may be given the directory (--add-dir) and no other file comes
# with it. Returns 1 and prints nothing when the copy cannot be made. The
# caller then reads SRC instead.
diffview_make() {
  local src="${1-}" root="${2-}" name="${3-}" dir
  [ -n "$root" ] && [ -n "$name" ] || return 1
  dir="$root/$name"
  mkdir "$dir" 2>/dev/null || return 1
  if diffview_render "$src" "$dir/diff.numbered"; then
    printf '%s\n' "$dir/diff.numbered"
    return 0
  fi
  rm -rf "$dir"
  return 1
}

# diffview_added_lines IN: print the new-side lines that the diff adds, as
# "file<TAB>n" rows, one for each added line. A file that has a new side also
# gets one "file<TAB>-" row, so a file with only removed lines is in the map.
# It reads the labels of diffview_render, so it has no diff parser of its own.
# The copy goes to a temp file under GATE_SCRATCH (or TMPDIR) that is removed
# before return. Returns 1 and prints nothing when the diff cannot be labelled.
# Trade-off: a file whose "+++" path git quotes (it starts with a double quote,
# as for a name with a tab, a newline, a backslash or a non-ASCII byte) is left
# out of the map. The escapes are not decoded here, and a quoted "a\tb" would
# otherwise collide with a different file named a\tb. A caller that looks a
# name up and finds nothing keeps its default, so a finding on such a file
# keeps its severity.
diffview_added_lines() {
  local in="${1-}" view rows
  view="$(mktemp "${GATE_SCRATCH:-${TMPDIR:-/tmp}}/prreview-added-XXXXXX")" || return 1
  if ! diffview_render "$in" "$view"; then
    rm -f "$view"
    return 1
  fi
  rows="$(LC_ALL=C awk -F'\t' '
    $1 == "META[-]" && substr($2, 1, 4) == "+++ " {
      f = substr($2, 5)
      sub(/\t.*$/, "", f)
      if (f == "/dev/null") { f = ""; next }
      if (substr(f, 1, 1) == "\"") { f = ""; next }
      if (substr(f, 1, 2) == "b/") f = substr(f, 3)
      else { f = ""; next }
      printf "%s\t-\n", f
      next
    }
    f != "" && $1 ~ /^NEW\[[0-9]+\]$/ && substr($2, 1, 1) == "+" {
      n = $1; sub(/^NEW\[/, "", n); sub(/\]$/, "", n)
      printf "%s\t%s\n", f, n
    }' "$view")" || { rm -f "$view"; return 1; }
  rm -f "$view"
  [ -z "$rows" ] || printf '%s\n' "$rows"
}
