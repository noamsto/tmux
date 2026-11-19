#!/bin/sh

# Test the bytes a bidi-capable client writes for a screen holding bidi panes:
# each row segment of a bidi pane is wrapped in an isolate region (the
# initiator right before its first cell at column 0, right after the border
# cell otherwise; the PDI after the segment), plain panes get none of their
# own, and the client never switches the terminal's bidi modes. An inner tmux
# client (with the bidi terminal feature) runs in a pane of an outer tmux; the
# bytes it writes for a refresh are captured from the outer pane (pipe-pane -O)
# and checked as they are, with the SGR sequences taken out.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
TMUX2="$TEST_TMUX -LtestB$$ -f/dev/null"

LEFT=$(mktemp)
RIGHTF=$(mktemp)
RAW=$(mktemp)
ALL=$(mktemp)
SGRLESS=$(mktemp)
GO=$(mktemp -u)
trap 'rm -f "$LEFT" "$RIGHTF" "$RAW" "$ALL" "$SGRLESS" "$GO"; $TMUX kill-server 2>/dev/null; $TMUX2 kill-server 2>/dev/null' \
	0 1 15

exit_status=0

ESC=$(printf '\033')
BORDER=$(printf '\342\224\202')
FSI='\0342\0201\0250'
PDI='\0342\0201\0251'
BIDI='\033[8h\033[?2501h'
A10=aaaaaaaaaa
SP30='                              '
A79=$A10$A10$A10$A10$A10$A10$A10${A10%?}

# run <case> <left_output> <right_output>
#   Show left_output in the first pane of an inner session, split in two side
#   by side panes showing right_output unless that is empty, attach an inner
#   client to it from an outer pane and save the bytes the inner client writes
#   for the refresh in $RAW, and without SGR sequences in $SGRLESS.
run() {
	$TMUX kill-server 2>/dev/null
	$TMUX2 kill-server 2>/dev/null
	sleep 1

	printf '%b' "$2" >"$LEFT"
	printf '%b' "$3" >"$RIGHTF"
	$TMUX2 new -d -x80 -y5 "cat '$LEFT'; sleep 100" || exit 1
	$TMUX2 set -g status off || exit 1
	$TMUX2 set -g window-size manual || exit 1
	$TMUX2 set -as terminal-features '*:bidi' || exit 1
	[ -n "$3" ] && { $TMUX2 splitw -h "cat '$RIGHTF'; sleep 100" || exit 1; }
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
	cat "$RAW" >>"$ALL"
	sed "s/$ESC\[[0-9;]*m//g" "$RAW" >"$SGRLESS"
}

# count <string> <file>
#   The number of times string (printf format) occurs in file.
count() {
	LC_ALL=C grep -aoF -- "$(printf '%b' "$1")" "$2" | wc -l
}

# expect <case> <bytes> <what>
#   The captured bytes hold bytes (printf format) as they are.
expect() {
	[ "$(count "$2" "$SGRLESS")" -ge 1 ] || {
		echo "[FAIL] case $1: expected $3"
		exit_status=1
	}
}

# expect_count <case> <bytes> <n> <what>
expect_count() {
	got=$(count "$2" "$SGRLESS")
	[ "$got" -eq "$3" ] || {
		echo "[FAIL] case $1: expected $3 $4, got $got"
		exit_status=1
	}
}

# S1: a bidi pane left of a plain one. The FSI leads the first cell, the PDI
# closes the segment at the column of the border and the plain segment right of
# it holds no isolate.
run S1 "${BIDI}שלום world" "abc אבג"
expect S1 "\033[H${FSI}שלום world${SP30}${PDI}" \
    "the FSI before the shin and the PDI at column 40"
expect S1 "${PDI}\033[Cabc אבג\033[K" \
    "the plain segment after the PDI with no isolate of its own"
expect_count S1 "$FSI" 1 "FSI (blank rows have none)"
expect_count S1 "$PDI" 1 "PDI (blank rows have none)"

# S2: a plain pane left of a bidi one. The FSI follows the border cell and the
# PDI the last cell, in pending wrap, with the rest of the segment cleared. A
# blank row of the segment is wrapped too.
run S2 "abc אבג" "${BIDI}שלום world\n"
expect S2 "\033[1;41H${BORDER}${FSI}" "the FSI right after the border on row 1"
expect S2 "world\033[K\033[28C ${PDI}" \
    "the PDI right after the last cell in pending wrap"
expect S2 "\033[38C ${PDI}\033[3;41H${BORDER}${FSI}" \
    "a blank bidi segment with its FSI after the border and its PDI"

# A full width bidi pane: a short row is led by the FSI, cleared and closed
# with the last cell and the PDI; a row the text fills ends with the PDI in
# pending wrap and no cursor move and space before it; blank rows have no FSI
# or PDI.
run full "${BIDI}שלום" ""
expect full "\033[H${FSI}שלום\033[K\033[75C ${PDI}" \
    "the FSI, an erase, the last cell and the PDI on a short row"
expect_count full "$FSI" 1 "FSI"
expect_count full "$PDI" 1 "PDI"
run fullrow "${BIDI}ש${A79}\033[3;1Hxyz" ""
expect fullrow "\033[H${FSI}ש${A79}${PDI}\033[2;1H" \
    "the PDI right after the last cell of a full row"
expect fullrow "${FSI}xyz\033[K\033[76C ${PDI}" "a short row led by the FSI"
expect_count fullrow "$FSI" 2 "FSI (blank rows have none)"
expect_count fullrow "$PDI" 2 "PDI (blank rows have none)"

# A plain pane beside a bidi one: its balanced pair is kept, its open FSI is
# dropped and its stray PDI is dropped.
run plain "x${FSI}abc${PDI} y${FSI}z" "${BIDI}abc"
expect plain "\033[Hx${FSI}abc${PDI} yz" \
    "the balanced pair kept and the open FSI dropped"
run stray "p${PDI}q" "${BIDI}abc"
expect stray "\033[Hpq" "the stray PDI dropped"

# tmux sets no bidi mode, auto-direction or direction (SCP) of its own.
[ "$(LC_ALL=C grep -aEc "$ESC\[8h|$ESC\[\?2501|$ESC\[[0-9]* k" "$ALL")" -eq 0 ] || {
	echo "[FAIL] the inner client set a bidi mode, ?2501 or SCP"
	exit_status=1
}

# With clear-on-attach off the client leaves no stale bidi mode behind with a
# single CSI 8 l at start, and sets none.
$TMUX kill-server 2>/dev/null
$TMUX2 kill-server 2>/dev/null
sleep 1
$TMUX2 new -d -x80 -y5 "sleep 100" || exit 1
$TMUX2 set -g status off || exit 1
$TMUX2 set -g clear-on-attach off || exit 1
$TMUX2 set -as terminal-features '*:bidi' || exit 1
$TMUX new -d -x80 -y5 "while [ ! -e '$GO' ]; do sleep 0.01; done; TMUX= exec $TMUX2 attach" ||
	exit 1
: >"$RAW"
$TMUX pipe-pane -O -t0:0.0 "cat >>'$RAW'" || exit 1
touch "$GO"
sleep 1
off8l=$(count "${ESC}[8l" "$RAW")
[ "$off8l" -eq 1 ] || {
	echo "[FAIL] clear-on-attach off: expected 1 CSI 8 l, got $off8l"
	exit_status=1
}
[ "$(LC_ALL=C grep -aEc "$ESC\[8h|$ESC\[\?2501|$ESC\[[0-9]* k" "$RAW")" -eq 0 ] || {
	echo "[FAIL] clear-on-attach off: the inner client set a bidi mode"
	exit_status=1
}

exit $exit_status
