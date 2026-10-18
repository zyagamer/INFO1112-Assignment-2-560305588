#!/usr/bin/env bash

server_ip=$(ifconfig eth0 | awk '/inet / {print $2}')

if [[ -z "$server_ip" ]]; then
    echo "Error: could not determine the server IP address." >&2
    exit 1
fi

if [[ ! "${SERVER_PORT:-}" =~ ^[0-9]{1,5}$ ]]; then
    echo "Error: configure SERVER_PORT with a number from 1 to 65535." >&2
    exit 1
fi

SERVER_PORT=$((10#$SERVER_PORT))

if (( SERVER_PORT < 1 || SERVER_PORT > 65535 )); then
    echo "Error: port must be between 1 and 65535." >&2
    exit 1
fi

listener_pid=""

cleanup() {
    if [[ -n "$listener_pid" ]]; then
        kill "$listener_pid" 2>/dev/null || true
        wait "$listener_pid" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

assignment_response() {
    local html text block title topic due points output_file

    if ! html=$(curl -fLsS --max-time 30 \
        'https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC'); then
        echo "Error: could not download the unit webpage." >&2
        printf '{"error":"Could not download assignment information"}\n'
        return 1
    fi

    if ! text=$(printf '%s' "$html" | html2text -width 1000); then
        echo "Error: HTML conversion failed." >&2
        printf '{"error":"Could not convert assignment information"}\n'
        return 1
    fi

    block=$(printf '%s\n' "$text" | awk '
        /Assignment 2/ {capture = 1}
        capture && /Outcomes assessed:/ {exit}
        capture {print}
    ')

    title=$(printf '%s\n' "$block" | awk '
        /Assignment 2/ {
            sub(/^[[:space:]]+/, "")
            sub(/[[:space:]]+Week.*/, "")
            sub(/[[:space:]]+$/, "")
            print
            exit
        }
    ')

    topic=$(printf '%s\n' "$block" | awk '
        /Programming task[[:space:]]*-/ {
            sub(/^.*Programming task[[:space:]]*-[[:space:]]*/, "")
            sub(/[[:space:]]+[0-9]+%.*/, "")
            sub(/[[:space:]]+$/, "")
            print
            exit
        }
    ')

    due=$(printf '%s\n' "$block" | awk '
        /Due date:/ {
            sub(/^.*Due date:[[:space:]]*/, "")
            if ($4 == "at")
                print $1 " " $2 " " $3 " " $5
            exit
        }
    ')

    points=$(printf '%s\n' "$block" | awk '
        /Programming task/ && match($0, /[0-9]+%/) {
            print substr($0, RSTART, RLENGTH - 1)
            exit
        }
    ')

    if [[ -z "$title" || -z "$topic" || -z "$due" ||
          ! "$points" =~ ^[0-9]+$ ]]; then
        echo "Error: assignment fields could not be extracted." >&2
        printf '{"error":"Could not extract assignment fields"}\n'
        return 1
    fi

    # Display the downloaded assignment information on the server.
    printf '%s\n' "$block" >&2

    output_file="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/assignment.json"

    if ! printf '{\n  "title": "%s",\n  "topic": "%s",\n  "due_date": "%s",\n  "points": %s\n}\n' \
        "$(json_escape "$title")" \
        "$(json_escape "$topic")" \
        "$(json_escape "$due")" \
        "$((10#$points))" > "$output_file"; then
        echo "Error: could not write assignment.json." >&2
        printf '{"error":"Could not create assignment.json"}\n'
        return 1
    fi

    cat "$output_file"
}

while true; do
    coproc CONNECTION {
        exec nc -4 -l -N "$SERVER_PORT"
    }

    listener_pid=$CONNECTION_PID
    send_fd=${CONNECTION[1]}
    receive_fd=${CONNECTION[0]}

    listening_port=""

    for ((attempt = 0; attempt < 30; attempt++)); do
        listening_port=$(ss -ltnpH | awk -v pid="$listener_pid" '
            index($0, "pid=" pid ",") {
                address = $4
                sub(/^.*:/, "", address)
                print address
                exit
            }
        ')

        [[ -n "$listening_port" ]] && break
        kill -0 "$listener_pid" 2>/dev/null || break
        sleep 0.1
    done

    if [[ -z "$listening_port" ]]; then
        echo "Error: could not detect the listening port." >&2
        exit 1
    fi

    printf 'Server listening at %s, port=%s\n' \
        "$server_ip" "$listening_port"

    if IFS= read -r -u "$receive_fd" request; then
        peer=$(ss -tnpH | awk -v pid="$listener_pid" '
            index($0, "pid=" pid ",") {
                print $5
                exit
            }
        ')

        if [[ -n "$peer" ]]; then
            client_ip="${peer%:*}"
            printf 'Client IP: %s\n' "$client_ip"
        else
            echo "Error: could not determine client IP." >&2
        fi

        printf 'Received: %s\n' "$request"
        case "$request" in
            assignment)
                if ! assignment_response >&"$send_fd"; then
                    echo "Assignment request failed." >&2
                fi
                ;;
            *)
                printf '{"error":"Unknown request"}\n' >&"$send_fd"
                ;;
        esac
    else
        echo "Error: client disconnected without a complete request." >&2
    fi

    # Finish the response so netcat can signal EOF to the client.
    exec {send_fd}>&-
    exec {receive_fd}<&-

    if ! wait "$listener_pid"; then
        echo "Error: netcat exited unsuccessfully." >&2
        exit 1
    fi

    listener_pid=""
done