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

poi_response() (
    # A subshell keeps this request's temporary files and traps isolated.
    work_dir=""
    trap '[[ -z "$work_dir" ]] || rm -rf -- "$work_dir"' EXIT

    poi_fail() {
        printf 'POI error: %s\n' "$1" >&2
        jq -n --arg message "$1" '{error: $message}'
        exit 1
    }

    api='https://maps.six.nsw.gov.au/arcgis/rest/services/public/NSW_POI/MapServer/0/query'
    work_dir=$(mktemp -d) || poi_fail 'Could not create temporary directory'

    poi_fetch() {
        local destination="$1"
        shift
        curl -fSsG --connect-timeout 10 --max-time 60 "$api" \
            --data-urlencode 'f=json' "$@" -o "$destination" ||
            poi_fail 'NSW POI API request failed'
        jq -e 'type == "object" and .error == null' "$destination" >/dev/null ||
            poi_fail 'NSW POI API returned an error or invalid JSON'
    }

    input="$1"
    separators="${input//[^|]/}"
    IFS='|' read -r mode first second third <<< "$input"

    case "$mode" in
        'poi name')
            [[ ${#separators} -eq 2 && -n "$first" ]] ||
                poi_fail 'Use poi name|PLACE NAME|RADIUS_METRES'
            radius="$second"
            ;;
        'poi coords')
            [[ ${#separators} -eq 3 ]] ||
                poi_fail 'Use poi coords|LATITUDE|LONGITUDE|RADIUS_METRES'
            latitude="$first"
            longitude="$second"
            radius="$third"
            ;;
        *) poi_fail 'Unknown POI request format' ;;
    esac

    # Limit input size before arithmetic; radius must be a positive integer.
    [[ "$radius" =~ ^[0-9]{1,6}$ ]] ||
        poi_fail 'Radius must be an integer from 1 to 999999 metres'
    radius=$((10#$radius))
    (( radius > 0 )) || poi_fail 'Radius must be greater than zero'

    if [[ "$mode" == 'poi name' ]]; then
        name="${first^^}"
        escaped_name=$(printf '%s' "$name" | sed "s/'/''/g")
        poi_fetch "$work_dir/location.json" \
            --data-urlencode "where=poiname='$escaped_name'" \
            --data-urlencode 'outFields=objectid,poiname' \
            --data-urlencode 'returnGeometry=true' \
            --data-urlencode 'outSR=4326'

        jq -e '.features | type == "array"' "$work_dir/location.json" >/dev/null ||
            poi_fail 'Location lookup did not return a feature array'
        matches=$(jq '.features | length' "$work_dir/location.json")
        (( matches > 0 )) || poi_fail 'No POI matches that name; try its official name or coordinates'
        [[ "$matches" == 1 ]] &&
            jq -e '.exceededTransferLimit != true' "$work_dir/location.json" >/dev/null ||
            poi_fail 'Multiple POIs match that name; use coordinates instead'
        latitude=$(jq -r '.features[0].geometry.y' "$work_dir/location.json")
        longitude=$(jq -r '.features[0].geometry.x' "$work_dir/location.json")
    fi

    [[ "$latitude" =~ ^-?[0-9]+(\.[0-9]+)?$ &&
       "$longitude" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] ||
        poi_fail 'Coordinates must be decimal numbers'
    jq -en --arg lat "$latitude" --arg lon "$longitude" '
        ($lat | tonumber) as $y | ($lon | tonumber) as $x |
        $y >= -90 and $y <= 90 and $x >= -180 and $x <= 180
    ' >/dev/null || poi_fail 'Latitude or longitude is out of range'

    poi_fetch "$work_dir/ids.json" \
        --data-urlencode 'where=1=1' \
        --data-urlencode "geometry=$longitude,$latitude" \
        --data-urlencode 'geometryType=esriGeometryPoint' \
        --data-urlencode 'inSR=4326' \
        --data-urlencode 'spatialRel=esriSpatialRelIntersects' \
        --data-urlencode "distance=$radius" \
        --data-urlencode 'units=esriSRUnit_Meter' \
        --data-urlencode 'returnIdsOnly=true'

    jq -e 'has("objectIds") and
        (.objectIds == null or (.objectIds | type) == "array") and
        (.exceededTransferLimit != true)' "$work_dir/ids.json" >/dev/null ||
        poi_fail 'API returned an invalid or incomplete ID list'
    jq '(.objectIds // []) | unique | sort' "$work_dir/ids.json" \
        > "$work_dir/expected.json" || poi_fail 'Could not prepare POI IDs'
    total=$(jq 'length' "$work_dir/expected.json")

    for ((offset = 0; offset < total; offset += 500)); do
        ids=$(jq -r --argjson start "$offset" '
            .[$start:($start + 500)] | map(tostring) | join(",")
        ' "$work_dir/expected.json") || poi_fail 'Could not prepare batch'
        printf 'Fetching POIs %s-%s of %s\n' "$((offset + 1))" \
            "$((offset + 500 < total ? offset + 500 : total))" "$total" >&2

        poi_fetch "$work_dir/batch-$offset.json" \
            --data-urlencode "objectIds=$ids" \
            --data-urlencode 'outFields=objectid,poiname,poitype' \
            --data-urlencode 'returnGeometry=true' \
            --data-urlencode 'outSR=4326'
        jq -e '(.features | type) == "array" and
            (.exceededTransferLimit != true)' "$work_dir/batch-$offset.json" >/dev/null ||
            poi_fail 'POI batch was invalid or incomplete'
    done

    if (( total == 0 )); then
        printf '[]\n' > "$work_dir/features.json"
    else
        jq -s '[.[].features[]] | unique_by(.attributes.objectid)' \
            "$work_dir"/batch-*.json > "$work_dir/features.json" ||
            poi_fail 'Could not combine POI batches'
    fi

    jq -en --slurpfile expected "$work_dir/expected.json" \
        --slurpfile features "$work_dir/features.json" '
        $expected[0] == ($features[0] | map(.attributes.objectid) | unique | sort)
    ' >/dev/null || poi_fail 'Returned POI IDs do not match requested IDs'

    jq -n --arg lat "$latitude" --arg lon "$longitude" \
        --argjson radius "$radius" --slurpfile features "$work_dir/features.json" '{
        source: "NSW Points of Interest API",
        center: {latitude: ($lat | tonumber), longitude: ($lon | tonumber)},
        radius_metres: $radius,
        count: ($features[0] | length),
        pois: [$features[0][] | {
            id: .attributes.objectid,
            name: .attributes.poiname,
            type: .attributes.poitype,
            longitude: .geometry.x,
            latitude: .geometry.y
        }]
    }' > "$work_dir/result.json" || poi_fail 'Could not create POI response'

    output_file="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/nearby-pois.json"
    mv -- "$work_dir/result.json" "$output_file" || poi_fail 'Could not save POI response'
    printf 'Returning %s POIs within %s metres\n' "$total" "$radius" >&2
    cat "$output_file"
)


# Each connection runs in its own Bash worker. A directory created with
# mkdir acts as an atomic lock for the client IP across all workers.
serve_connection() (
    local connection_dir="$1"
    local listener_pid="" lock_dir="" owns_lock=0
    local peer="" client_ip="" listening_port="" request=""
    local announced=0 send_fd receive_fd

    connection_cleanup() {
        if [[ -n "$listener_pid" ]]; then
            kill "$listener_pid" 2>/dev/null || true
            wait "$listener_pid" 2>/dev/null || true
        fi
        if (( owns_lock )); then
            rmdir -- "$lock_dir" 2>/dev/null || true
        fi
    }
    trap connection_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    coproc CONNECTION { exec nc -4 -l -N "$SERVER_PORT"; }
    listener_pid=$CONNECTION_PID
    send_fd=${CONNECTION[1]}
    receive_fd=${CONNECTION[0]}

    # Inspect both listening and connected sockets. This also handles a
    # client arriving before the first listening-socket inspection.
    while [[ -z "$peer" ]]; do
        listening_port=$(ss -ltnpH | awk -v pid="$listener_pid" '
            index($0, "pid=" pid ",") {
                address=$4; sub(/^.*:/, "", address); print address; exit
            }
        ')
        if [[ -n "$listening_port" ]] && (( ! announced )); then
            printf 'Server listening at %s, port=%s\n' "$server_ip" "$listening_port"
            announced=1
        fi

        peer=$(ss -tnpH | awk -v pid="$listener_pid" '
            index($0, "pid=" pid ",") &&
            ($1 == "ESTAB" || $1 == "CLOSE-WAIT") {print $5; exit}
        ')
        [[ -n "$peer" ]] && break

        if ! kill -0 "$listener_pid" 2>/dev/null; then
            echo 'Error: listener ended before a client could be identified.' >&2
            exit 1
        fi
        sleep 0.1
    done

    client_ip="${peer%:*}"
    [[ "$client_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo 'Error: could not identify an IPv4 client.' >&2
        exit 1
    }
    lock_dir="$server_work_dir/busy-$client_ip"
    if mkdir -- "$lock_dir" 2>/dev/null; then
        owns_lock=1
    elif [[ ! -d "$lock_dir" ]]; then
        echo 'Error: could not create client lock.' >&2
        exit 1
    fi

    # The accepted connection no longer needs the listening socket.
    # Notify the parent to start listening for the next connection.
    touch "$connection_dir/accepted" || exit 1
    printf 'Client IP: %s\n' "$client_ip"

    if ! IFS= read -r -t 30 -u "$receive_fd" request; then
        printf '{"error":"No complete request received within 30 seconds"}\n' >&"$send_fd"
    elif (( ! owns_lock )); then
        printf 'Rejected busy client: %s\n' "$client_ip"
        printf '{"error":"A request from this client IP is already being processed"}\n' >&"$send_fd"
    else
        request=${request%$'\r'}
        printf 'Received: %s\n' "$request"
        case "$request" in
            assignment)
                if ! assignment_response >&"$send_fd"; then
                    echo 'Assignment request failed.' >&2
                fi
                ;;
            population)
                if ! population_response >&"$send_fd"; then
                    echo 'Population request failed.' >&2
                fi
                ;;
            poi\ *)
                if ! poi_response "$request" >&"$send_fd"; then
                    echo 'POI request failed.' >&2
                fi
                ;;
            *) printf '{"error":"Unknown request"}\n' >&"$send_fd" ;;
        esac
    fi

    exec {send_fd}>&-
    exec {receive_fd}<&-

    # Bound the time spent waiting for a client to close after the reply.
    for ((finish_attempt=0; finish_attempt<100; finish_attempt++)); do
        kill -0 "$listener_pid" 2>/dev/null || break
        sleep 0.1
    done
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    listener_pid=""
)

server_work_dir=$(mktemp -d) || exit 1
workers=()

server_cleanup() {
    local pid
    for pid in "${workers[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${workers[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    rm -rf -- "$server_work_dir"
}
trap server_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while true; do
    # Reap completed workers; their traps have already released their locks.
    active_workers=()
    for pid in "${workers[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            active_workers+=("$pid")
        else
            wait "$pid" 2>/dev/null || true
        fi
    done
    workers=("${active_workers[@]}")

    connection_dir=$(mktemp -d "$server_work_dir/connection.XXXXXX") || exit 1
    serve_connection "$connection_dir" &
    worker_pid=$!
    workers+=("$worker_pid")

    while [[ ! -f "$connection_dir/accepted" ]]; do
        if ! kill -0 "$worker_pid" 2>/dev/null; then
            wait "$worker_pid" 2>/dev/null || true
            echo 'Error: connection worker stopped before accepting a client.' >&2
            exit 1
        fi
        sleep 0.1
    done
    rm -f -- "$connection_dir/accepted"
    rmdir -- "$connection_dir"
done
