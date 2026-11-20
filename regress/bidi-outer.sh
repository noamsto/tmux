#!/bin/sh

# Test how a bidi-capable client mixes the terminal's outer bidi mode and
# isolate regions. The rows of a bidi pane that fills the terminal width, with
# no floating pane over it, are outer rows: the client sets BDSM (CSI 8 h)
# before it writes their text and writes no isolate of its own there. Every
# other row is a region row, written with BDSM off and its bidi segments
# wrapped in isolates. When the set of outer rows changes the client switches
# the terminal's modes off, clears it and redraws every row.
#
# An inner tmux client (with the bidi terminal feature) runs in a pane of an
# outer tmux; the bytes it writes are captured from the outer pane (pipe-pane
# -O) from before it attaches and checked as they are, with the SGR sequences
# taken out. The panes of the inner session read lines of shell from the
# inner server, so a case can write to them after the client attached.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
TMUX2="$TEST_TMUX -LtestB$$ -f/dev/null"

RAW=$(mktemp)
RAW2=$(mktemp)
SGR=$(mktemp)
LOOP=$(mktemp)
OFF=$(mktemp)
CTL=$(mktemp)
GO=$(mktemp -u)
GO2=$(mktemp -u)
trap 'rm -f "$RAW" "$RAW2" "$SGR" "$LOOP" "$OFF" "$CTL" "$GO" "$GO2"; $TMUX kill-server 2>/dev/null; $TMUX2 kill-server 2>/dev/null' \
	0 1 15

exit_status=0

ESC=$(printf '\033')
FSI='\0342\0201\0250'
LRI='\0342\0201\0246'
PDI='\0342\0201\0251'
RFSI=$(printf '\342\201\250')
RPDI=$(printf '\342\201\251')
ISOLATES=$(printf '\342\201[\246-\251]')
MODES='\033\[8h|\033\[8l|\033\[\?2501h|\033\[\?2501l|\033\[0 k'
CLEAR='\033[?2501l\033[0 k\033[H\033[J'
HEB='שלום'

# Panes run lines of shell read from the inner server's send-keys.
cat >"$LOOP" <<'EOF'
stty -echo
while IFS= read -r l; do eval "$l"; done
EOF
PANE="sh $LOOP"
BDSM_ON='printf "\033[8h\033[?2501h"'

# setup [features]
#   Start an inner session of one 80x5 window with the bidi terminal feature
#   (or features, a terminal-features value) and no status line, and an outer
#   one to attach it from.
setup() {
	$TMUX kill-server 2>/dev/null
	$TMUX2 kill-server 2>/dev/null
	sleep 0.5
	$TMUX2 new -d -x80 -y5 "$PANE" || exit 1
	$TMUX2 set -g status off || exit 1
	$TMUX2 set -g window-size manual || exit 1
	$TMUX2 set -as terminal-features "${1:-*:bidi}" || exit 1
}

# attach
#   Attach a client to the inner session from the first window of an outer
#   session, with the bytes it writes saved in $RAW from its start.
attach() {
	: >"$RAW"
	MARK=0
	rm -f "$GO"
	$TMUX new -d -x80 -y5 "while [ ! -e '$GO' ]; do sleep 0.01; done; TMUX= exec $TMUX2 attach -t0" ||
		exit 1
	$TMUX pipe-pane -O -t0:0.0 "cat >>'$RAW'" || exit 1
	touch "$GO"
	sleep 1
}

# write <pane> <shell>
#   Run shell in a pane of the inner session.
write() {
	$TMUX2 send-keys -t "$1" -l "$2" || exit 1
	$TMUX2 send-keys -t "$1" Enter || exit 1
	sleep 0.3
}

# mark
#   Count only the bytes the client writes from here on.
mark() {
	MARK=$(wc -c <"$RAW")
}

# since
#   Save the bytes written since mark in $SGR, without the SGR sequences.
since() {
	sleep 0.5
	tail -c "+$((MARK + 1))" "$RAW" | sed "s/$ESC\[[0-9;]*m//g" >"$SGR"
}

# count <string> [file]
#   The number of times string (printf format) occurs in file ($SGR); newlines
#   are matched as ordinary bytes.
count() {
	LC_ALL=C tr '\n' '\001' <"${2:-$SGR}" |
		LC_ALL=C grep -aoF -- "$(printf '%b' "$1" | tr '\n' '\001')" | wc -l
}

# expect <case> <bytes> <what>
#   The captured bytes hold bytes (printf format) as they are.
expect() {
	[ "$(count "$2")" -ge 1 ] || {
		echo "[FAIL] case $1: expected $3"
		exit_status=1
	}
}

# expect_count <case> <bytes> <n> <what>
expect_count() {
	got=$(count "$2")
	[ "$got" -eq "$3" ] || {
		echo "[FAIL] case $1: expected $3 $4, got $got"
		exit_status=1
	}
}

# expect_none <case> <bytes> <what>
expect_none() {
	[ "$(count "$2")" -eq 0 ] || {
		echo "[FAIL] case $1: unexpected $3"
		exit_status=1
	}
}

# expect_no_isolates <case> [file]
#   The client wrote no FSI, LRI, RLI or PDI.
expect_no_isolates() {
	got=$(LC_ALL=C grep -aoE -- "$ISOLATES" "${2:-$SGR}" | wc -l)
	[ "$got" -eq 0 ] || {
		echo "[FAIL] case $1: expected no isolate, got $got"
		exit_status=1
	}
}

# expect_balanced <case>
#   The client wrote as many PDI as initiators, and at least one.
expect_balanced() {
	open=$(LC_ALL=C grep -aoE -- "$(printf '\342\201[\246-\250]')" "$SGR" | wc -l)
	close=$(count "$PDI")
	[ "$open" -ge 1 ] && [ "$open" -eq "$close" ] || {
		echo "[FAIL] case $1: expected balanced isolates, got $open open, $close PDI"
		exit_status=1
	}
}

# expect_no_modes <case> [file]
#   The client set no bidi mode, auto-direction or direction (SCP).
expect_no_modes() {
	got=$(LC_ALL=C grep -aEc -- "$(printf '%b' "$MODES")" "${2:-$SGR}")
	[ "$got" -eq 0 ] || {
		echo "[FAIL] case $1: the client set a bidi mode"
		exit_status=1
	}
}

# client
#   The name of the first client of the inner server.
client() {
	$TMUX2 list-clients -F '#{client_name}' | sed -n 1p
}

# same_screen <case> <pane> <what>
#   The first outer row starts with the first row of the inner pane as it is
#   in the inner pane's grid.
same_screen() {
	inner=$($TMUX2 capture-pane -p -t "$2" | sed -n 1p)
	outer=$($TMUX capture-pane -p -t0:0.0 | sed -n 1p)
	case $outer in
	"$inner"*) ;;
	*)
		echo "[FAIL] case $1: $3: expected row '$inner', got '$outer'"
		exit_status=1
		;;
	esac
}

# A bidi pane that fills the window: BDSM goes on before its text and none of
# its rows holds a tmux isolate. The status line is written with BDSM off.
setup
write %0 "$BDSM_ON; printf '$HEB\\n\\n\\n'"
$TMUX2 set -g status on || exit 1
attach
since
expect outer "\033[8h\033[?2501h\033[1;1H$HEB\033[K" \
    "BDSM on and the text on row 1"
expect outer "\033[K\033[8l\r\n[0] 0:" "BDSM off before the status line"
expect_no_isolates outer

# A status redraw alone (the clock) over the full width pane writes BDSM off
# once, and only the status line; the next write to the pane puts BDSM back on
# before its text.
$TMUX2 set -g status-interval 1 || exit 1
$TMUX2 set -g status-right '%S' || exit 1
sleep 1.5
write %0 "printf 'x'"
mark
sleep 1.3
since
expect status-redraw "\033[8l\r\n[0] 0:" "CSI 8 l before the status line"
expect_none status-redraw "$HEB" "a redraw of the pane rows"
expect_none status-redraw "\033[8h" "CSI 8 h"
expect_no_isolates status-redraw
mark
sleep 1.3
since
expect_none status-redraw-2 "\033[8l" "CSI 8 l (BDSM is off already)"
expect_none status-redraw-2 "\033[8h" "CSI 8 h"
mark
write %0 "printf 'y'"
since
expect pane-write "\033[8hy" "CSI 8 h right before the write"

# The client detaches after a status redraw: it turns auto-direction off
# although BDSM is already off, and BDSM too when a pane write left it on.
setup
write %0 "$BDSM_ON; printf 'a'"
$TMUX2 set -g status on || exit 1
$TMUX2 set -g status-interval 1 || exit 1
$TMUX2 set -g status-right '%S' || exit 1
attach
sleep 1.5
mark
$TMUX2 detach-client
since
expect_count detach-status "\033[?2501l" 1 "CSI ? 2501 l (the status line left BDSM off)"
expect_none detach-status "\033[8l" "CSI 8 l (BDSM is off)"
setup
write %0 "$BDSM_ON; printf 'a'"
attach
mark
$TMUX2 detach-client
since
expect_count detach-pane "\033[?2501l\033[8l" 1 "auto-direction and BDSM turned off by the stop"

# Main-horizontal: a full width bidi pane over two bidi panes side by side.
# The top rows are outer rows, the bottom rows region rows, and BDSM is put in
# the state of the row before each write.
setup
$TMUX2 splitw -v -l2 "$PANE" || exit 1
$TMUX2 splitw -h -t %1 "$PANE" || exit 1
sleep 0.3
write %0 "$BDSM_ON; printf 'AAA'"
write %1 "$BDSM_ON; printf 'BBB'"
write %2 "$BDSM_ON; printf 'CCC'"
attach
since
expect main-horizontal "\033[8h\033[?2501h\033[1;1HAAA\033[K" \
    "the top pane on outer rows"
expect main-horizontal "${FSI}\017BBB" "the bottom left pane in an isolate region"
expect main-horizontal "CCC" "the bottom right pane"
expect_balanced main-horizontal
mark
write %0 "printf 'x'"
since
expect main-horizontal-top "\033[8hx" "CSI 8 h before a write to the top pane"
expect_no_isolates main-horizontal-top
mark
write %1 "printf 'y'"
since
expect main-horizontal-bottom "\033[8ly" "CSI 8 l before a write to the bottom pane"
mark
write %0 "printf 'z'"
since
expect main-horizontal-top-2 "\033[8hz" "CSI 8 h before the top pane's next write"
expect_none main-horizontal-top-2 "\033[8l" "CSI 8 l"

# A split changes the set of outer rows: the client turns the modes off,
# clears and redraws with regions; killing the pane goes back to outer rows.
setup
write %0 "$BDSM_ON; printf 'AAA'"
attach
mark
$TMUX2 splitw -h "$PANE" || exit 1
since
expect split "\033[8l$CLEAR" "BDSM off and a clear before the regions"
expect split "${FSI}AAA" "the pane in a region"
expect_none split "\033[8h" "CSI 8 h"
mark
$TMUX2 killp -t %1 || exit 1
since
expect kill-pane "$CLEAR\033[?25l\033[8h\033[?2501h\033[1;1HAAA" \
    "a clear and then BDSM on for the outer rows"
expect_no_isolates kill-pane

# Zoom a pane of a split to full width and back.
setup
write %0 "$BDSM_ON; printf 'AAA'"
$TMUX2 splitw -h "$PANE" || exit 1
sleep 0.3
attach
mark
$TMUX2 resizep -Z -t %0 || exit 1
since
expect zoom "$CLEAR\033[?25l\033[8h\033[?2501h" "a clear and BDSM on when zoomed"
expect_no_isolates zoom
mark
$TMUX2 resizep -Z -t %0 || exit 1
since
expect unzoom "\033[8l$CLEAR" "BDSM off and a clear when unzoomed"
expect unzoom "${FSI}AAA" "the pane back in a region"

# A floating pane over a plain pane leaves the bidi pane's rows outer; dragged
# onto the bidi pane it makes them regions (clear), and off it again back to
# outer rows (clear).
setup
$TMUX2 splitw -v -l2 "$PANE" || exit 1
write %0 "$BDSM_ON; printf 'AAA'"
attach
mark
FLOAT=$($TMUX2 new-pane -d -PF '#{pane_id}' -x20 -y3 -X5 -Y2 "$PANE") || exit 1
since
expect_none float-over-plain "\033[H\033[J" "a clear for a float over the plain pane"
mark
$TMUX2 move-pane -t "$FLOAT" -X 10 -Y 0 || exit 1
since
expect float-onto "$CLEAR" "a clear when the float is dragged onto the bidi pane"
expect float-onto "${FSI}AAA" "the bidi pane in a region under the float"
expect_none float-onto "\033[8h" "CSI 8 h"
mark
$TMUX2 move-pane -t "$FLOAT" -X 10 -Y 2 || exit 1
since
expect float-off "$CLEAR\033[?25l\033[8h\033[?2501h\033[1;1HAAA" \
    "a clear and BDSM on when the float leaves the bidi pane"
expect_no_isolates float-off

# A popup over the bidi pane makes its rows share them: regions with a clear;
# closing it goes back to outer rows with a clear and BDSM on.
setup
write %0 "$BDSM_ON; printf 'AAA'"
attach
mark
$TMUX2 display-popup -c "$(client)" -B -x 0 -y 1 -w 10 -h 2 "sleep 100" || exit 1
since
expect popup-open "$CLEAR" "a clear when the popup opens"
expect popup-open "${FSI}" "an isolate initiator for the region rows"
expect popup-open "${PDI}" "a PDI closing the region rows"
expect_none popup-open "\033[8h" "CSI 8 h"
mark
$TMUX2 display-popup -c "$(client)" -C || exit 1
since
expect popup-close "$CLEAR\033[8h\033[?2501h\033[1;1HAAA" \
    "a clear and BDSM on when the popup closes"
expect_no_isolates popup-close

# Each client decides alone: a client whose terminal has no bidi feature gets
# no bidi byte, whatever the other client's rows are.
setup 'tmux-256color:bidi'
write %0 "$BDSM_ON; printf 'AAA'"
$TMUX2 splitw -h "$PANE" || exit 1
$TMUX2 killp -t %1 || exit 1
sleep 0.3
attach
: >"$RAW2"
rm -f "$GO2"
$TMUX new-window "while [ ! -e '$GO2' ]; do sleep 0.01; done; TERM=xterm-256color TMUX= exec $TMUX2 attach -t0" || exit 1
$TMUX pipe-pane -O -t1 "cat >>'$RAW2'" || exit 1
touch "$GO2"
sleep 1
mark
$TMUX2 splitw -h "$PANE" || exit 1
$TMUX2 killp -t %2 || exit 1
sleep 0.5
since
expect second-client-bidi "\033[8l$CLEAR" "the bidi client's clear for the split"
expect second-client-bidi "$CLEAR\033[?25l\033[8h\033[?2501h" \
    "the bidi client's clear and BDSM on when the pane is alone again"
[ -s "$RAW2" ] || {
	echo "[FAIL] case second-client: the plain client wrote nothing"
	exit_status=1
}
sed "s/$ESC\[[0-9;]*m//g" "$RAW2" >"$SGR"
expect_no_modes second-client "$SGR"
expect_no_isolates second-client "$SGR"

# Switching between a window with a full width bidi pane and one with a split.
setup
write %0 "$BDSM_ON; printf 'AAA'"
$TMUX2 new-window "$PANE" || exit 1
$TMUX2 splitw -h "$PANE" || exit 1
write %2 "$BDSM_ON; printf 'BBB'"
$TMUX2 selectw -t0 || exit 1
attach
mark
$TMUX2 selectw -t1 || exit 1
since
expect window-split "$CLEAR" "a clear when switching to the split window"
expect window-split "${FSI}" "the isolates of the split window"
expect_none window-split "\033[8h" "CSI 8 h"
mark
$TMUX2 selectw -t0 || exit 1
since
expect window-full "$CLEAR\033[?25l\033[8h\033[?2501h\033[1;1HAAA" \
    "a clear and BDSM on when switching back"
expect_no_isolates window-full

# With clear-on-attach off the client leaves no stale bidi mode behind with a
# single CSI 8 l at start; a bidi pane on all the rows then still takes the
# switch to outer rows with a clear and BDSM on.
setup
$TMUX2 set -g clear-on-attach off || exit 1
write %0 "$BDSM_ON; printf 'AAA'"
attach
$TMUX2 set -g clear-on-attach off || exit 1
since
expect_count clear-on-attach-off "\033[8l" 1 "CSI 8 l (a single one at start)"
expect clear-on-attach-off "$CLEAR\033[?25l\033[8h\033[?2501h\033[1;1HAAA" \
    "BDSM off at start, the clear and BDSM on for the outer rows"
expect_count clear-on-attach-off "\033[8h" 1 "CSI 8 h"
expect_no_isolates clear-on-attach-off

# Only one of the two capabilities (Bidireg without Enbidi, and Enbidi without
# Bidireg): no bidi handling.
# one_capability <case> <override>
one_capability() {
	setup 'nomatch:bidi'
	$TMUX2 set -as terminal-overrides "$2" || exit 1
	write %0 "$BDSM_ON; printf 'AAA'"
	$TMUX2 splitw -h "$PANE" || exit 1
	sleep 0.3
	attach
	write %0 "printf 'x'"
	since
	expect "$1" "AAA" "the pane text"
	expect_no_modes "$1"
	expect_no_isolates "$1"
}
one_capability bidireg-only ',*:Bidireg'
one_capability enbidi-only ',*:Enbidi=\E[8h'

# A menu at column 0 over an outer row: the row stays outer. The initiator
# goes after the menu's first border cell (a line drawing cell does not keep
# it before the cell) and the PDI after the menu. A menu without a border
# starts with a space, which keeps it.
setup
write %0 "$BDSM_ON; printf '$HEB\\nxyz\\n'"
attach
mark
$TMUX2 display-menu -c "$(client)" -x 0 -y 1 -T t "one" a "" "two" b "" ||
	exit 1
since
expect menu-border "\033[H┌─\017t" "the menu's border at column 0"
expect menu-border "\033[2G${LRI}\033[10C${PDI}" \
    "the LRI after the first border cell and the PDI after the menu"
expect_none menu-border "\033[H${LRI}" "an LRI before the border cell"
expect_none menu-border "$CLEAR" "a clear for the menu"
expect_none menu-border "$FSI" "an FSI"
$TMUX2 send-keys -K -c "$(client)" Escape
sleep 0.5
mark
$TMUX2 display-menu -c "$(client)" -x 0 -y 1 -b none "漢字" a "" "😀 x" b "" ||
	exit 1
since
expect menu-borderless "\033[H${LRI} " "the LRI before the first cell of the menu, a space"
expect_none menu-borderless "$CLEAR" "a clear for the menu"
$TMUX2 send-keys -K -c "$(client)" Escape
sleep 0.5

# Balancing: the isolates a menu writes itself are balanced within the menu
# over a bidi pane: a stray PDI dropped, an open FSI closed.
setup
write %0 "$BDSM_ON; printf 'abc\\n'"
attach
mark
$TMUX2 display-menu -c "$(client)" -x 0 -y 1 -b none \
    "q${RPDI}r" a "" "s${RFSI}t" b "" || exit 1
since
expect menu-balance "${LRI} qr (a) ${PDI}" "the stray PDI dropped"
expect menu-balance "${LRI} s${FSI}t (b) ${PDI}${PDI}" \
    "the open FSI closed in the menu's last cell together with the menu's PDI"
$TMUX2 send-keys -K -c "$(client)" Escape

# Balancing in a pane status line: the pane status line, a plain line, drops
# the isolates it writes itself.
setup
write %0 "$BDSM_ON; printf 'abc\\n'"
attach
mark
$TMUX2 set -g pane-border-status top || exit 1
$TMUX2 set -g pane-border-format "x${RPDI}y${RFSI}z" || exit 1
since
expect pane-status "xyz" "the pane status line without its stray PDI and open FSI"
expect_none pane-status "${FSI}z" "the pane status line's FSI"

# Balancing in the side status line, a plain line beside a bidi pane: the pane
# is a region now (the window is narrower than the client).
setup
write %0 "$BDSM_ON; printf 'abc\\n'"
attach
mark
$TMUX2 set -g side-status-format "q${RPDI}r${RFSI}s" || exit 1
$TMUX2 set -g side-status-width 6 || exit 1
$TMUX2 set -g side-status left || exit 1
since
expect side-status "$CLEAR" "a clear when the side status makes the pane share its rows"
expect side-status "\033[1;1Hqrs" "the side status line without its stray PDI and open FSI"
expect_none side-status "\033[8h" "CSI 8 h"
expect_balanced side-status

# Balancing with an ACS cell beside a bidi pane: the plain pane's line drawing
# cells keep their place, its stray PDI and open FSI are dropped.
setup
$TMUX2 splitw -h "$PANE" || exit 1
sleep 0.3
write %1 "$BDSM_ON; printf 'abc'"
write %0 "printf '\\033(0lq${RPDI}x${RFSI}k\\033(B tail'"
attach
since
expect acs "┌─│┐\017 tail" "the line drawing cells without the stray PDI and open FSI"
expect_balanced acs

# A full width plain pane under a bidi pane keeps its own balanced pair as it
# scrolls, and the rows it scrolls are written with BDSM off.
setup
$TMUX2 splitw -v -l2 "$PANE" || exit 1
sleep 0.3
write %0 "$BDSM_ON; printf 'top'"
attach
mark
write %1 "printf 'a${RFSI}b${RPDI}c\\n1\\n2\\n3\\n'"
since
expect plain-scroll "a${FSI}b${PDI}" "the plain pane's balanced pair as it is"
expect plain-scroll "\033[4;5r" "the scroll in the region of the plain pane's rows"
expect_balanced plain-scroll
expect_none plain-scroll "\033[8h" "CSI 8 h"

# Terminal operations on outer rows are the terminal's own: no tmux isolate,
# and no redraw of the row text.
setup
write %0 "$BDSM_ON; printf 'אבג1\\nשלום2\\nabc3\\ndef4\\nghi5'"
attach
mark
write %0 "printf '\\033[2;1H\\033[L'"
since
expect outer-il "\033[1L" "the terminal's insert line"
expect_no_isolates outer-il
expect_none outer-il "שלום" "a redraw of the row"
mark
write %0 "printf '\\033[2;1H\\033[M'"
since
expect outer-dl "\033[1M" "the terminal's delete line"
expect_no_isolates outer-dl
mark
write %0 "printf '\\033[1;3H\\033[K'"
since
expect outer-el "\033[1;3H\033[K" "the terminal's erase in line"
expect_no_isolates outer-el
mark
write %0 "printf '\\033[1;2H\\033[2X'"
since
expect_no_isolates outer-ech
expect_none outer-ech "אבג" "a redraw of the row"
mark
write %0 "printf '\\033[1;2H\\033[2@'"
since
expect outer-ich "\033[2@" "the terminal's insert character"
expect_no_isolates outer-ich
mark
write %0 "printf '\\033[1;2H\\033[2P'"
since
expect outer-dch "\033[2P" "the terminal's delete character"
expect_no_isolates outer-dch
mark
write %0 "printf '\\033[5;1H\\nnew'"
since
expect outer-scroll "\033[5;1H" "the cursor on the last row"
expect_none outer-scroll "${FSI}new" "an FSI before the new row"
expect_no_isolates outer-scroll

# The same operations on a bidi pane in a split are line redraws with the
# region's initiator and PDI, never a terminal operation.
# region_op <case> <shell> <terminal operation>
region_op() {
	mark
	write %0 "printf '$2'"
	since
	expect_balanced "$1"
	expect_none "$1" "$3" "the terminal's own operation"
}
setup
$TMUX2 splitw -h "$PANE" || exit 1
sleep 0.3
write %0 "$BDSM_ON; printf 'אבג1\\nשלום2\\nabc3\\ndef4\\nghi5'"
attach
region_op split-il '\033[2;1H\033[L' "\033[1L"
region_op split-dl '\033[2;1H\033[M' "\033[1M"
region_op split-el '\033[1;3H\033[K' "\033[1;3H\033[K"
region_op split-ech '\033[1;2H\033[2X' "\033[2X"
region_op split-ich '\033[1;2H\033[2@' "\033[2@"
region_op split-dch '\033[1;2H\033[2P' "\033[2P"
region_op split-scroll '\033[5;1H\nnew' "\r\nnew"

# A full width bidi pane under a floating pane is obscured and its rows are
# regions: its operations are line redraws too.
setup
write %0 "$BDSM_ON; printf 'אבג1\\nשלום2\\nabc3\\ndef4\\nghi5'"
$TMUX2 new-pane -d -x20 -y3 -X50 -Y1 "$PANE" || exit 1
attach
region_op float-il '\033[2;1H\033[L' "\033[1L"
region_op float-dch '\033[1;2H\033[2P' "\033[2P"
region_op float-scroll '\033[5;1H\nnew' "\r\nnew"

# A wide character at the row end survives DCH and ICH at column 3: the
# outer screen shows the row as the inner pane has it, in a full width bidi
# pane, in a split and under a floating pane.
WIDE80='שלום a中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中'
WIDE40='שלום a中中中中中中中中中中中中中中中中中'
wide_row() {
	write %0 "printf '\\033[2J\\033[H$4\\033[1;3H$2'"
	sleep 0.5
	same_screen "$1" %0 "the row after $3"
}
setup
write %0 "$BDSM_ON"
attach
wide_row dch-outer '\033[P' "DCH" "$WIDE80"
wide_row ich-outer '\033[@' "ICH" "$WIDE80"
setup
$TMUX2 splitw -h "$PANE" || exit 1
sleep 0.3
write %0 "$BDSM_ON"
attach
wide_row dch-split '\033[P' "DCH" "$WIDE40"
wide_row ich-split '\033[@' "ICH" "$WIDE40"
setup
write %0 "$BDSM_ON"
$TMUX2 new-pane -d -x20 -y3 -X50 -Y2 "$PANE" || exit 1
attach
wide_row dch-float '\033[P' "DCH" "$WIDE80"
wide_row ich-float '\033[@' "ICH" "$WIDE80"

# A window bigger than the client, panned right: a bidi pane at column 0 wider
# than the client but ending before the right edge of the part shown shares
# its rows with the pane right of it, so they are region rows: its visible
# part goes in an isolate and BDSM stays off.
setup
$TMUX2 resize-window -x160 -y5 || exit 1
write %0 "$BDSM_ON; printf '%090d $HEB abc\\n' 0"
$TMUX2 splitw -h -l59 "$PANE" || exit 1
sleep 0.3
write %1 "printf 'RIGHT\\n'"
attach
since
expect_none panned "\033[8h" "CSI 8 h (the pane does not own its rows)"
expect panned "${FSI}0000000000 $HEB abc ${PDI}" \
    "the visible part of the bidi pane in an isolate"

# A bidi pane in a split leaving more initiators open than the terminal keeps
# in one cell: only the first 8 are written, and its last cell holds 9 PDIs,
# 8 for them and one for the region's own initiator.
setup
$TMUX2 splitw -h "$PANE" || exit 1
sleep 0.3
write %0 "$BDSM_ON; printf x; i=0; while [ \$i -lt 20 ]; do printf '\\342\\201\\246a'; i=\$((i + 1)); done"
attach
since
expect deep "${FSI}x${LRI}a${LRI}a${LRI}a${LRI}a${LRI}a${LRI}a${LRI}a${LRI}aaaaaaaaaaaaa" \
    "8 of the pane's initiators written"
expect deep "$PDI$PDI$PDI$PDI$PDI$PDI$PDI$PDI$PDI" "9 PDIs closing the region"
expect_none deep "$PDI$PDI$PDI$PDI$PDI$PDI$PDI$PDI$PDI$PDI" "more than 9 PDIs in a row"
expect_balanced deep

# The same pane typing more initiators than it keeps after the client
# attached: every line redraw and closer rewrite writes at most 9 PDIs.
mark
write %0 "printf '\\ny'; i=0; while [ \$i -lt 30 ]; do printf '\\342\\201\\246b'; sleep 0.01; i=\$((i + 1)); done; printf '\\342\\201\\251\\342\\201\\251c'"
since
expect deep-typed "$PDI$PDI$PDI$PDI$PDI$PDI$PDI$PDI$PDI" "9 PDIs closing the region"
expect_none deep-typed "$PDI$PDI$PDI$PDI$PDI$PDI$PDI$PDI$PDI$PDI" "more than 9 PDIs in a row"

# -T bidi with no bidi pane writes the same bytes as no bidi feature, for the
# writes after the attach settled.
# off_run <features> <file> [bidi]
#   Run one script under features (with a bidi pane if bidi is set) and save
#   the bytes of its writes after the attach in file.
off_run() {
	setup "$1"
	$TMUX2 splitw -h "$PANE" || exit 1
	sleep 0.3
	write %0 "${3:+$BDSM_ON; }printf 'hello world\\n\\033[2;1Hxyz'"
	attach
	sleep 1
	mark
	write %0 "printf '\\033[3;1Hmore'"
	$TMUX2 resizep -Z -t %0 || exit 1
	$TMUX2 resizep -Z -t %0 || exit 1
	$TMUX2 killp -t %1 || exit 1
	since
	cp "$SGR" "$2"
}
off_run '*:bidi' "$RAW2"
off_run 'nomatch:bidi' "$OFF"
cmp -s "$RAW2" "$OFF" || {
	echo "[FAIL] case feature-off: the bytes differ with the feature on and no bidi pane"
	exit_status=1
}
[ -s "$RAW2" ] || {
	echo "[FAIL] case feature-off: nothing was captured"
	exit_status=1
}
off_run '*:bidi' "$CTL" bidi
cmp -s "$RAW2" "$CTL" && {
	echo "[FAIL] case feature-off: the control with a bidi pane wrote the same bytes"
	exit_status=1
}

exit $exit_status
