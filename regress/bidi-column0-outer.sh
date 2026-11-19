#!/bin/sh

# Test where a bidi-capable client writes the directional isolates of a pane
# that starts at column 0. An inner tmux client (with the bidi terminal
# feature) runs in a pane of an outer tmux; the bytes it writes for a refresh
# are captured from the outer pane (pipe-pane -O) and checked as they are, with
# the SGR sequences taken out, so the order of the isolates and the cells is
# what is compared.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
TMUX2="$TEST_TMUX -LtestB$$ -f/dev/null"

TMP=$(mktemp)
RAW=$(mktemp)
trap 'rm -f "$TMP" "$RAW"; $TMUX kill-server 2>/dev/null; $TMUX2 kill-server 2>/dev/null' \
	0 1 15

exit_status=0

ESC=$(printf '\033')
BORDER=$(printf '\342\224\202')
FSI='\0342\0201\0250'
PDI='\0342\0201\0251'
LRI='\0342\0201\0246'
A10=aaaaaaaaaa
A80=$A10$A10$A10$A10$A10$A10$A10$A10
RIGHT='sleep 100'

# inner <case> <pane_output> <split>
#   Show pane_output in the first pane of an inner session (split in two side
#   by side panes if split is 1, the second showing $RIGHT), attach an inner
#   client to it from an outer pane and save the bytes the inner client writes
#   for the refresh, without SGR sequences, in $RAW.
inner() {
	$TMUX kill-server 2>/dev/null
	$TMUX2 kill-server 2>/dev/null
	sleep 1

	printf '%b' "$2" >"$TMP"
	$TMUX2 new -d -x80 -y5 "cat '$TMP'; sleep 100" || exit 1
	$TMUX2 set -g status off || exit 1
	$TMUX2 set -g window-size manual || exit 1
	$TMUX2 set -as terminal-features '*:bidi' || exit 1
	[ "$3" = 1 ] && { $TMUX2 splitw -h "$RIGHT" || exit 1; }
	sleep 1
	$TMUX new -d -x80 -y5 "TMUX= $TMUX2 attach" || exit 1
	sleep 1
	: >"$RAW"
	$TMUX pipe-pane -O -t0:0.0 "cat >>'$RAW'" || exit 1
	$TMUX2 refresh-client -t "$($TMUX2 list-clients -F '#{client_name}')" ||
		exit 1
	sleep 1
	[ -s "$RAW" ] || {
		echo "[FAIL] case $1: the inner client's refresh was not captured"
		exit_status=1
		return 1
	}
	sed "s/$ESC\[[0-9;]*m//g" "$RAW" >"$TMP"
}

# want <case> <split> <pane_output> <expected> <what>
#   The captured bytes hold expected (printf format) as they are.
want() {
	inner "$1" "$3" "$2" || return
	LC_ALL=C grep -aqF -- "$(printf '%b' "$4")" "$TMP" || {
		echo "[FAIL] case $1: expected $5"
		exit_status=1
	}
}

# count <string> <file>
#   The number of times string (printf format) occurs in file.
count() {
	LC_ALL=C grep -aoF -- "$(printf '%b' "$1")" "$2" | wc -l
}

# The inner client writes its isolate before the shin at column 0, with only
# SGR sequences between them.
want 1 1 "\033[8h\033[?2501hשלום world" "\033[H${FSI}ש" \
    "the FSI right before the shin at row 1 column 1"

# The closing isolate of the pane's own FSI goes after the space the cursor is
# on, positioned there, and the pane's own isolate is not written before the
# prompt glyph. The glyph is not one tmux and the terminal are known to give
# the same width and still the FSI leads it. The full width row ends with the
# cell and the PDI the terminal keeps in pending wrap, with no move in between.
want 2 0 "\033[8h\033[?2501h❯ ${FSI}אני " \
    "${FSI}❯ ${FSI}אני\033[K  \033[72C ${PDI}\033[1;8H${PDI}" \
    "the pane's own PDI after the cursor cell and the last cell closed in pending wrap"

# The pane's LRI at column 0 of a row it soft-wrapped into is dropped (the
# terminal alone would not keep it there): the 80 a are followed by the PDI in
# pending wrap and the next row is positioned explicitly and led by the FSI.
inner 3 "\033[8h\033[?2501h${A80}b\r${LRI}c" 0 && {
	[ "$(count "${A80}${PDI}\033[2;1H${FSI}c" "$TMP")" -eq 1 ] || {
		echo "[FAIL] case 3: expected the 80 a closed in pending wrap" \
		    "and row 2 positioned and led by an FSI"
		exit_status=1
	}
	[ "$(count "$LRI" "$TMP")" -eq 0 ] || {
		echo "[FAIL] case 3: the inner client wrote the pane's LRI"
		exit_status=1
	}
}

# check_shared <case> <left_pane_output> <lris> <pdis>
#   In a row shared with another pane the pane's column-0 LRI stays at terminal
#   column 0, after the FSI the client leads the row with, and the cell, the
#   pane's own isolate and the segment are all closed: before the first border
#   there are lris LRI and pdis PDI.
check_shared() {
	inner "$1" "$2" 1 && {
		row1=$(LC_ALL=C sed -n "1s/$BORDER.*//p" "$RAW")
		printf '%s\n' "$row1" >"$TMP"
		[ "$(count "$LRI" "$TMP")" -eq "$3" ] || {
			echo "[FAIL] case $1: expected $3 LRI before the border"
			exit_status=1
		}
		[ "$(count "$PDI" "$TMP")" -eq "$4" ] || {
			echo "[FAIL] case $1: expected $4 PDI before the border"
			exit_status=1
		}
		[ "$(count "${FSI}${LRI}" "$TMP")" -eq "$3" ] || {
			echo "[FAIL] case $1: expected the LRI right after the FSI"
			exit_status=1
		}
	}
}

check_shared 4 "\033[8h\033[?2501h${LRI}abc" 1 2
# A VS16 widens the first cell the LRI leads, so the pane's LRI is dropped (as
# bidi-column0.sh checks) and the segment only has its own FSI and PDI.
check_shared 6 "\033[8h\033[?2501h${LRI}☀️ abc" 0 1

# A first cell the terminal may measure differently (the pointing hand) is led
# by the FSI like any other, written before the cell.
want 5 1 "\033[8h\033[?2501h☝ abc" "\033[H${FSI}☝" \
    "the FSI right before the pointing hand"

exit $exit_status
