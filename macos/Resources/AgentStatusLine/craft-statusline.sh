#!/bin/sh
# Craft's Claude Code status line. Claude Code pipes its session state here as JSON, the only
# place it reports the real context window. This keeps a copy for the app, then hands the same
# JSON to the status line the user configured, so theirs still draws.
#
# $1 is the task id when the app launched the session. Installed for every session from
# Settings, there is no argument, and the copy is filed under Claude's own session id; the app
# finds it by the directory it names.
input=$(cat)
support="$HOME/Library/Application Support/Craft"
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
    "" | *craft-statusline* | *taskhub-statusline*) ;;
    *) printf '%s' "$input" | /bin/sh -c "$own" ;;
esac
exit 0
