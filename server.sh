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

population_response() {
    local work_dir output_file header row year population
    local latest_year=0 latest_population=""
    local -a years fields

    work_dir=$(mktemp -d) || {
        echo "Error: could not create temporary directory." >&2
        printf '{"error":"Could not prepare population data"}\n'
        return 1
    }

    if ! curl -fLsS --max-time 30 \
        'https://dbr.abs.gov.au/processedData/csv/STE_1.csv' \
        -o "$work_dir/source.csv"; then
        echo "Error: population download failed." >&2
        rm -rf -- "$work_dir"
        printf '{"error":"Population download failed"}\n'
        return 1
    fi

    IFS= read -r header < "$work_dir/source.csv"
    header=${header%$'\r'}
    IFS=',' read -r -a years <<< "$header"

    # Bash extracts the year/population pairs.
    while IFS= read -r row || [[ -n "$row" ]]; do
        row=${row%$'\r'}
        IFS=',' read -r -a fields <<< "$row"

        [[ "${fields[0]:-}" == "ERP_P_20" ]] || continue

        for ((i = 3; i < ${#years[@]}; i++)); do
            year=${years[i]}
            population=${fields[i]:-}

            if [[ "$year" =~ ^[0-9]{4}$ &&
                  "$population" =~ ^[0-9]+$ ]]; then
                printf '%s,%s\n' "$year" "$population"

                if (( 10#$year > latest_year )); then
                    latest_year=$((10#$year))
                    latest_population=$population
                fi
            fi
        done

        break
    done < "$work_dir/source.csv" > "$work_dir/pairs.csv"

    if [[ -z "$latest_population" ]]; then
        echo "Error: no valid population data found." >&2
        rm -rf -- "$work_dir"
        printf '{"error":"No valid population data found"}\n'
        return 1
    fi

    printf 'Latest NSW population (%s): %s\n' \
        "$latest_year" "$latest_population" >&2

    # AI acknowledgement: this Python plotting section was generated
    # with assistance from OpenAI ChatGPT.
    # It reads only the pairs already extracted by Bash.
    if ! python3 - "$work_dir/pairs.csv" "$work_dir/population.png" <<'PY'
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import StrMethodFormatter

pairs = []
with open(sys.argv[1], encoding="utf-8") as source:
    for line in source:
        year, population = line.strip().split(",")
        pairs.append((int(year), int(population)))

pairs.sort()
years, populations = zip(*pairs)

fig, ax = plt.subplots(figsize=(9, 5))
ax.plot(years, populations, marker="o")
ax.set_title("NSW estimated resident population — 30 June")
ax.set_xlabel("Year")
ax.set_ylabel("Population (people)")
ax.set_xticks(years)
ax.yaxis.set_major_formatter(StrMethodFormatter("{x:,.0f}"))
ax.grid(True, alpha=0.3)
fig.tight_layout()
fig.savefig(sys.argv[2], dpi=150)
plt.close(fig)
PY
    then
        echo "Error: population plotting failed." >&2
        rm -rf -- "$work_dir"
        printf '{"error":"Population plotting failed"}\n'
        return 1
    fi

    output_file="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/population.png"

    if ! mv -- "$work_dir/population.png" "$output_file"; then
        echo "Error: could not save population.png." >&2
        rm -rf -- "$work_dir"
        printf '{"error":"Could not save population plot"}\n'
        return 1
    fi

    rm -rf -- "$work_dir"

    # Only the image bytes go to the client.
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

             population)
                if ! population_response >&"$send_fd"; then
                    echo "Population request failed." >&2
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