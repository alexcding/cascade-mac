#!/bin/sh
# Cascade's Claude Code status line. Claude Code pipes its session state here as JSON, the only
# place it reports the real context window. This keeps a copy for the app, then hands the same
# JSON to the status line the user configured, so theirs still draws.
#
# $1 is the task id when the app launched the session. Installed for every session from
# Settings, there is no argument, and the copy is filed under Claude's own session id; the app
# finds it by the directory it names.
input=$(cat)
support="$HOME/Library/Application Support/Cascade"
dir="$support/statusline"
key=$1
if [ -z "$key" ]; then
    id=$(printf '%s' "$input" | /usr/bin/plutil -extract session_id raw -o - - 2>/dev/null)
    [ -n "$id" ] && key="session-$id"
fi
case "$key" in "" | *[!A-Za-z0-9-]*) key= ;; esac

# Claude Code also runs this every couple of seconds, to follow a resize, mostly with nothing new.
# What was drawn is kept with what it was drawn for: the width, the minute (reset times count down
# in minutes) and the state, less the run's wall-clock durations, which change every time and are
# drawn by nothing here.
state=$(printf '%s' "$input" | sed -E 's/"total_(api_)?duration_ms":[0-9.]+//g' | cksum)
stamp="$COLUMNS $(($(date +%s) / 60)) $state"
keep=
if [ -n "$key" ]; then
    keep="$dir/.$key.line"
    if [ "$(head -n 1 "$keep" 2>/dev/null)" = "$stamp" ]; then tail -n +2 "$keep"; exit 0; fi
    mkdir -p "$dir"
    # A session's first draw clears what sessions long gone left.
    [ -f "$keep" ] || find "$dir" -name '.*.line' -mtime +2 -delete 2>/dev/null
    # The app's copy, rewritten only when the state changed.
    if [ "$(head -n 1 "$keep" 2>/dev/null | cut -d' ' -f3-)" != "$state" ]; then
        printf '%s' "$input" > "$dir/.$key.$$" && mv -f "$dir/.$key.$$" "$dir/$key.json"
    fi
fi
# Draws the line, keeping it for the next run.
show() {
    [ -n "$1" ] && printf '%s\n' "$1"
    [ -n "$keep" ] && printf '%s\n%s\n' "$stamp" "$1" > "$keep.$$" && mv -f "$keep.$$" "$keep"
    exit 0
}

# The user's own status line: set aside in original.json while ours is installed for every
# session, still in their settings when ours only rides along on a launch. Never ours again.
own=$(/usr/bin/plutil -extract command raw -o - "$dir/original.json" 2>/dev/null)
[ -z "$own" ] && own=$(/usr/bin/plutil -extract statusLine.command raw -o - "$HOME/.claude/settings.json" 2>/dev/null)
case "$own" in
    "" | *cascade-statusline*) ;;
    *) show "$(printf '%s' "$input" | /bin/sh -c "$own")" ;;
esac

# With none of their own, one line across the terminal: the model, how full its context is and what
# the session has cost on the left; on the right, how much of the plan's session and week is left,
# with the time until each resets. The toolbar shows none of it, so this line is
# where a terminal session reads them.
field() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }
number() { case "$1" in "" | *[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
short() {
    if [ "$1" -ge 1000000 ] && [ $(($1 % 1000000)) -eq 0 ]; then echo "$(($1 / 1000000))M"
    elif [ "$1" -ge 1000 ]; then echo "$((($1 + 500) / 1000))k"
    else echo "$1"; fi
}
# A percentage plutil prints as 48 or 48.500000, rounded to a whole one.
whole() {
    case "$1" in
        "" | *[!0-9.]* | .*) echo ;;
        *.[5-9]*) echo $((${1%%.*} + 1)) ;;
        *) echo "${1%%.*}" ;;
    esac
}
# Time until a reset, short: 45m, 2h10m, and whole days past one.
span() {
    m=$((($1 + 59) / 60))
    if [ "$m" -ge 1440 ]; then echo "$((m / 1440))d"
    elif [ "$m" -ge 60 ]; then echo "$((m / 60))h$((m % 60))m"
    else echo "${m}m"; fi
}
# Characters, not bytes: the separator is multibyte.
width() { printf '%s' "$1" | LC_ALL=en_US.UTF-8 /usr/bin/wc -m | tr -d ' '; }
sep=" · "

left=$(field model.display_name)
[ -z "$left" ] && left=$(field model.id)
effort=$(field effort.level)
[ -n "$effort" ] && left="$left$sep$effort"
[ "$(field fast_mode)" = "true" ] && left="$left${sep}fast"
size=$(number "$(field context_window.context_window_size)")
used=0
for kind in input_tokens cache_creation_input_tokens cache_read_input_tokens; do
    used=$((used + $(number "$(field "context_window.current_usage.$kind")")))
done
if [ "$used" -gt 0 ] && [ "$size" -gt 0 ]; then
    left="$left$sep$(short "$used") / $(short "$size") ($((used * 100 / size))%)"
elif [ "$used" -gt 0 ]; then
    left="$left$sep$(short "$used")"
fi
cost=$(field cost.total_cost_usd)
# The program, in the C locale: the shell's own printf keeps the locale it started in, and one whose
# decimal mark is a comma would not read the number.
case "$cost" in "" | *[!0-9.]*) ;; *) left="$left$sep\$$(LC_ALL=C /usr/bin/printf '%.2f' "$cost")" ;; esac
left=${left#"$sep"}

# The right side, most wanted first: a narrow terminal keeps what fits, in this order.
now=$(date +%s)
set --
for window in five_hour:session seven_day:week; do
    limit=$(whole "$(field "rate_limits.${window%%:*}.used_percentage")")
    [ -z "$limit" ] && continue
    remaining=$((100 - limit)); [ "$remaining" -lt 0 ] && remaining=0
    part="${window#*:} $remaining% left"
    resets=$(number "$(field "rate_limits.${window%%:*}.resets_at")")
    [ "$resets" -gt "$now" ] && part="$part ($(span $((resets - now))))"
    set -- "$@" "$part"
done

# The terminal's width, which Claude Code sets on each run; the script cannot ask the terminal, whose
# output Claude Code captures. It indents the line and cuts what runs past the edge, so a little
# room is kept. Unknown, everything is shown and the right side follows after a gap. Claude Code does
# not rerun the line on a resize; the launch's `refreshInterval` brings it to a new width.
columns=$(number "$COLUMNS")
room=$((columns - 4))
taken=$(width "$left")
right=
for part in "$@"; do
    next="$right$sep$part"; next=${next#"$sep"}
    [ "$columns" -gt 0 ] && [ $((taken + 2 + $(width "$next"))) -gt "$room" ] && continue
    right=$next
done

line=$left
if [ -n "$right" ]; then
    gap=2
    [ "$columns" -gt 0 ] && gap=$((room - taken - $(width "$right")))
    [ "$gap" -lt 2 ] && gap=2
    line="$line$(printf "%${gap}s" '')$(printf '\033[2m')$right$(printf '\033[0m')"
fi
show "$line"
