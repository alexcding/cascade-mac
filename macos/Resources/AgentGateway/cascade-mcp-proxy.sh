#!/bin/sh
# Cascade's MCP server for an agent in a terminal (Synara's stdio proxy, `stdioProxyScript.ts`).
# The agent's CLI runs this as a stdio MCP server; each JSON-RPC line it writes is posted to the
# backend's gateway (`POST /mcp`) and the answer written back as one line. The port and the token
# are read for every message, so an agent started by an earlier launch of the app still reaches
# the one running now.
#
# Every message is posted at once, in a curl of its own, as Synara's proxy does: a tool call may
# wait on a simulator for minutes, and a ping or another call must not wait behind it. A
# `notifications/cancelled` ends the curl of the request it names, which drops the gateway's
# handler, and that request gets no answer. Answers are written whole, one at a time.
#
# $1 is the port file of the app that started the terminal (CASCADE_PORT_FILE); $2 is the
# terminal's run id (CASCADE_RUN_ID), which tells the gateway who is calling. Both are filled in
# by the terminal's shell when the agent is launched.
port_file=$1
run_id=$2
token_file="$(dirname "$port_file")/.gateway-token"
# The CLI starts its servers in the folder it works in: the session's worktree, or a folder in it,
# which the backend takes for the worktree. Base64, as a header carries ASCII alone.
cwd=$(pwd -P | tr -d '\n' | /usr/bin/base64 | tr -d '\n')

work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cascade-mcp.XXXXXX") || exit 1
trap 'kill $(jobs -p) 2>/dev/null; /bin/rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

# Writes a file to stdout as one line, never interleaved with another answer.
emit() {
    printf '\n' >>"$1"
    /usr/bin/lockf -k "$work/.out" /bin/cat "$1"
}

# A file name for the request id at key path $2 of message $1: its type and value, as Synara's
# `requestKey`, so 1 and "1" are different requests. Nothing for a message without one.
key_of() {
    kind=$(printf '%s' "$1" | /usr/bin/plutil -type "$2" - 2>/dev/null) || return 0
    case "$kind" in
        string | integer | float) ;;
        *) return 0 ;;
    esac
    value=$(printf '%s' "$1" | /usr/bin/plutil -extract "$2" raw -o - - 2>/dev/null) || return 0
    printf '%s:%s' "$kind" "$value" | /sbin/md5 -q
}

# A JSON-RPC error for a request whose answer could not be fetched; a notification gets none.
fail() {
    kind=$(printf '%s' "$1" | /usr/bin/plutil -type id - 2>/dev/null) || return 0
    id=$(printf '%s' "$1" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null) || return 0
    case "$kind" in
        string) id="\"$(printf '%s' "$id" | sed 's/[\\"]/\\&/g')\"" ;;
        integer | float) ;;
        *) return 0 ;;
    esac
    printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":"%s"}}' "$id" "$2" >"$3"
    emit "$3"
}

# Posts message $1 and writes its answer, through files named $2. Run in the background; a TERM
# is its request's cancellation. $3 is the request's key when this post owns it.
forward() {
    pid=
    cancelled=
    trap 'cancelled=1; [ -n "$pid" ] && kill "$pid" 2>/dev/null' TERM
    port=$(cat "$port_file" 2>/dev/null)
    token=$(cat "$token_file" 2>/dev/null)
    if [ -z "$port" ] || [ -z "$token" ]; then
        fail "$1" "Cascade is not running." "$2.error"
    else
        # Tool calls may wait on a simulator for minutes (a boot is bounded at four).
        printf '%s' "$1" | /usr/bin/curl -sSf --max-time 900 \
            -H 'Content-Type: application/json' \
            -H "Authorization: Bearer $token" \
            -H "X-Cascade-Run: $run_id" \
            -H "X-Cascade-Cwd-Base64: $cwd" \
            --data-binary @- -o "$2" "http://127.0.0.1:$port/mcp" 2>/dev/null &
        pid=$!
        [ -n "$cancelled" ] && kill "$pid" 2>/dev/null
        # A TERM ends the wait early; the curl is waited for again, so it is gone when this is.
        until wait "$pid"; status=$?; [ "$status" -le 128 ] || ! kill -0 "$pid" 2>/dev/null; do :; done
        if [ -n "$cancelled" ]; then
            :
        elif [ "$status" -ne 0 ]; then
            fail "$1" "Cascade did not answer." "$2.error"
        elif [ -s "$2" ]; then
            emit "$2"
        fi
    fi
    [ -n "$3" ] && /bin/rm -f "$work/$3"
    /bin/rm -f "$2" "$2.error"
}

n=0
while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    n=$((n + 1))
    # The first post of an id owns it, as in Synara: a duplicate never takes its cancellation.
    key=$(key_of "$line" id)
    if [ -n "$key" ]; then
        if [ -e "$work/$key" ]; then key=; else : >"$work/$key"; fi
    fi
    forward "$line" "$work/$n" "$key" &
    [ -n "$key" ] && [ -e "$work/$key" ] && echo $! >"$work/$key"
    # The cancellation is posted too: the gateway takes it as any notification.
    cancel=
    case "$line" in
        *notifications/cancelled*) cancel=$(key_of "$line" params.requestId) ;;
    esac
    if [ -n "$cancel" ] && [ -e "$work/$cancel" ]; then
        owner=$(cat "$work/$cancel")
        [ -n "$owner" ] && kill "$owner" 2>/dev/null
    fi
done
# As Synara's: what was just sent gets a moment to reach the gateway, and what still waits is ended.
sleep 0.1
kill $(jobs -p) 2>/dev/null
wait
