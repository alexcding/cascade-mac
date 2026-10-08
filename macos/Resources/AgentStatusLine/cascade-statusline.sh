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
case "$key" in
    "" | *[!A-Za-z0-9-]*) ;;
    *) mkdir -p "$dir" && printf '%s' "$input" > "$dir/.$key.$$" && mv -f "$dir/.$key.$$" "$dir/$key.json" ;;
esac
# The user's own status line: set aside in original.json while ours is installed for every
# session, still in their settings when ours only rides along on a launch. Never ours again.
own=$(/usr/bin/plutil -extract command raw -o - "$dir/original.json" 2>/dev/null)
[ -z "$own" ] && own=$(/usr/bin/plutil -extract statusLine.command raw -o - "$HOME/.claude/settings.json" 2>/dev/null)
case "$own" in
    "" | *cascade-statusline*) ;;
    *) printf '%s' "$input" | /bin/sh -c "$own"; exit 0 ;;
esac

# With none of their own, the model and how full the context is: the toolbar shows neither, so
# this line is where a terminal session reads them.
field() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }
number() { case "$1" in "" | *[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
short() {
    if [ "$1" -ge 1000000 ] && [ $(($1 % 1000000)) -eq 0 ]; then echo "$(($1 / 1000000))M"
    elif [ "$1" -ge 1000 ]; then echo "$((($1 + 500) / 1000))k"
    else echo "$1"; fi
}
line=$(field model.display_name)
[ -z "$line" ] && line=$(field model.id)
effort=$(field effort.level)
[ -n "$effort" ] && line="$line · $effort"
size=$(number "$(field context_window.context_window_size)")
used=0
for kind in input_tokens cache_creation_input_tokens cache_read_input_tokens; do
    used=$((used + $(number "$(field "context_window.current_usage.$kind")")))
done
if [ "$used" -gt 0 ] && [ "$size" -gt 0 ]; then
    line="$line · $(short "$used") / $(short "$size") ($((used * 100 / size))%)"
elif [ "$used" -gt 0 ]; then
    line="$line · $(short "$used")"
fi
line=${line# · }
[ -n "$line" ] && printf '%s\n' "$line"
exit 0
