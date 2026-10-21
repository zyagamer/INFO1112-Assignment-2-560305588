#!/usr/bin/env bash
# AI acknowledgement: OpenAI ChatGPT assisted with Bash implementation,
# debugging and tests, and generated the Python plotting section.

SERVER_PORT=${SERVER_PORT:-1234}
if [[ ! "$SERVER_PORT" =~ ^[0-9]{1,5}$ ]]; then
    echo 'Error: invalid listening port.' >&2
    exit 1
fi
SERVER_PORT=$((10#$SERVER_PORT))
if (( SERVER_PORT < 1 || SERVER_PORT > 65535 )); then
    echo 'Error: port must be between 1 and 65535.' >&2
    exit 1
fi
cd -- "$(dirname -- "$0")" || exit 1
work=${INFO1112_WORK:-}

error() {
    printf 'Error: %s\n' "$1" >&2
    jq -n --arg message "$1" '{error: $message}'
    return 1
}

assignment_response() {
    local block title topic due points
    curl -fLsS --max-time 30 \
        'https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC' \
        -o "$work/unit.html" || { error 'Assignment download failed'; return 1; }
    html2text -width 1000 "$work/unit.html" > "$work/unit.txt" || {
        error 'HTML conversion failed'; return 1;
    }
    block=$(awk '/Assignment 2/ {show=1}
        show && /Outcomes assessed:/ {exit}
        show {print}' "$work/unit.txt")
    title=$(printf '%s\n' "$block" | awk '/Assignment 2/ {
        sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+Week.*/, ""); print; exit}')
    topic=$(printf '%s\n' "$block" | awk '/Programming task/ {
        sub(/^.*Programming task[[:space:]]*-[[:space:]]*/, "")
        sub(/[[:space:]]+[0-9]+%.*/, ""); print; exit}')
    due=$(printf '%s\n' "$block" | awk '/Due date:/ {
        sub(/^.*Due date:[[:space:]]*/, "")
        if ($4 == "at") print $1 " " $2 " " $3 " " $5; exit}')
    points=$(printf '%s\n' "$block" | awk '/Programming task/ && match($0, /[0-9]+%/) {
        print substr($0, RSTART, RLENGTH-1); exit}')
    if [[ -z "$title" || -z "$topic" || -z "$due" || ! "$points" =~ ^[0-9]+$ ]]; then
        error 'Could not extract assignment fields'; return 1
    fi
    printf '%s\n' "$block" >&2
    jq -n --arg title "$title" --arg topic "$topic" --arg due "$due" --arg points "$points" \
        '{title:$title, topic:$topic, due_date:$due, points:($points|tonumber)}' \
        > assignment.json || { error 'Could not create assignment.json'; return 1; }
    cat assignment.json
}

population_response() {
    local header row year population latest_year=0 latest_population i
    local -a years values
    curl -fLsS --max-time 30 'https://dbr.abs.gov.au/processedData/csv/STE_1.csv' \
        -o "$work/population.csv" || { error 'Population download failed'; return 1; }
    IFS= read -r header < "$work/population.csv"
    row=$(grep '^ERP_P_20,' "$work/population.csv")
    IFS=',' read -r -a years <<< "${header%$'\r'}"
    IFS=',' read -r -a values <<< "${row%$'\r'}"
    # Bash extracts every available year/population pair from the CSV.
    for ((i=3; i<${#years[@]}; i++)); do
        year=${years[i]}
        population=${values[i]:-}
        if [[ "$year" =~ ^[0-9]{4}$ && "$population" =~ ^[0-9]+$ ]]; then
            printf '%s,%s\n' "$year" "$population"
            if (( 10#$year > latest_year )); then
                latest_year=$((10#$year))
                latest_population=$population
            fi
        fi
    done > "$work/pairs.csv"
    (( latest_year > 0 )) || { error 'No population data found'; return 1; }
    printf 'Latest NSW population (%s): %s\n' "$latest_year" "$latest_population" >&2
    # AI-generated plotting code. Python only reads Bash-extracted pairs.
    if ! python3 - "$work/pairs.csv" <<'PY'
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import StrMethodFormatter

with open(sys.argv[1]) as source:
    pairs = sorted(tuple(map(int, line.strip().split(","))) for line in source)
years, populations = zip(*pairs)
fig, ax = plt.subplots(figsize=(9, 5))
ax.plot(years, populations, marker="o")
ax.set(title="NSW estimated resident population - 30 June",
       xlabel="Year", ylabel="Population (people)")
ax.set_xticks(years)
ax.yaxis.set_major_formatter(StrMethodFormatter("{x:,.0f}"))
ax.grid(True, alpha=0.3)
fig.tight_layout()
fig.savefig("population.png", dpi=150)
plt.close(fig)
PY
    then
        error 'Could not generate population plot'; return 1
    fi
    cat population.png
}

api='https://maps.six.nsw.gov.au/arcgis/rest/services/public/NSW_POI/MapServer/0/query'
api_get() {
    local destination="$1"
    shift
    curl -fSsG --connect-timeout 10 --max-time 60 "$api" \
        --data-urlencode 'f=json' "$@" -o "$destination" || return 1
    jq -e 'type == "object" and .error == null' "$destination" > /dev/null
}

poi_batch() {
    api_get "$work/batch.json" --data-urlencode "objectIds=$1" \
        --data-urlencode 'outFields=objectid,poiname,poitype' \
        --data-urlencode 'returnGeometry=true' --data-urlencode 'outSR=4326' || return 1
    jq -e '(.features|type) == "array" and .exceededTransferLimit != true' \
        "$work/batch.json" > /dev/null || return 1
    jq -c '.features[]' "$work/batch.json" >> "$work/features.txt"
}

poi_response() {
    local mode first second third separators radius latitude longitude name matches
    local id batch="" number=0
    separators=${1//[^|]/}
    IFS='|' read -r mode first second third <<< "$1"
    case "$mode" in
        'poi name')
            [[ ${#separators} == 2 && -n "$first" ]] || {
                error 'Use poi name|NAME|METRES'; return 1;
            }
            radius=$second ;;
        'poi coords')
            [[ ${#separators} == 3 ]] || {
                error 'Use poi coords|LATITUDE|LONGITUDE|METRES'; return 1;
            }
            latitude=$first; longitude=$second; radius=$third ;;
        *) error 'Unknown POI format'; return 1 ;;
    esac
    [[ "$radius" =~ ^[0-9]{1,6}$ ]] || { error 'Invalid radius'; return 1; }
    radius=$((10#$radius))
    (( radius > 0 )) || { error 'Radius must be greater than zero'; return 1; }
    if [[ "$mode" == 'poi name' ]]; then
        name=$(printf '%s' "$first" | tr '[:lower:]' '[:upper:]' | sed "s/'/''/g")
        api_get "$work/location.json" --data-urlencode "where=poiname='$name'" \
            --data-urlencode 'outFields=poiname' --data-urlencode 'returnGeometry=true' \
            --data-urlencode 'outSR=4326' || { error 'POI name lookup failed'; return 1; }
        matches=$(jq '.features | length' "$work/location.json")
        [[ "$matches" != 0 ]] || { error 'POI name not found'; return 1; }
        [[ "$matches" == 1 ]] || { error 'Ambiguous name: use coordinates'; return 1; }
        latitude=$(jq -r '.features[0].geometry.y' "$work/location.json")
        longitude=$(jq -r '.features[0].geometry.x' "$work/location.json")
    fi
    [[ "$latitude" =~ ^-?[0-9]+(\.[0-9]+)?$ && "$longitude" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || {
        error 'Coordinates must be numbers'; return 1;
    }
    awk -v y="$latitude" -v x="$longitude" 'BEGIN {exit !(y>=-90 && y<=90 && x>=-180 && x<=180)}' || {
        error 'Latitude or longitude is out of range'; return 1;
    }
    api_get "$work/ids.json" --data-urlencode 'where=1=1' \
        --data-urlencode "geometry=$longitude,$latitude" --data-urlencode 'geometryType=esriGeometryPoint' \
        --data-urlencode 'inSR=4326' --data-urlencode 'spatialRel=esriSpatialRelIntersects' \
        --data-urlencode "distance=$radius" --data-urlencode 'units=esriSRUnit_Meter' \
        --data-urlencode 'returnIdsOnly=true' || { error 'POI radius lookup failed'; return 1; }
    jq -e 'has("objectIds") and (.objectIds == null or (.objectIds|type) == "array")' \
        "$work/ids.json" >/dev/null || { error 'Invalid POI ID list'; return 1; }
    jq -r '.objectIds[]?' "$work/ids.json" | sort -n -u > "$work/expected.txt"
    : > "$work/features.txt"
    # Fetch at most 500 IDs per request to avoid the API result limit.
    while IFS= read -r id; do
        if [[ -n "$batch" ]]; then batch="$batch,$id"; else batch=$id; fi
        number=$((number+1))
        if (( number % 500 == 0 )); then
            printf 'Fetching POI batch ending at %s\n' "$number" >&2
            poi_batch "$batch" || { error 'POI batch failed'; return 1; }
            batch=""
        fi
    done < "$work/expected.txt"
    if [[ -n "$batch" ]]; then
        poi_batch "$batch" || { error 'POI batch failed'; return 1; }
    fi
    jq -r '.attributes.objectid' "$work/features.txt" | sort -n -u > "$work/received.txt"
    cmp -s "$work/expected.txt" "$work/received.txt" || { error 'Incomplete POI results'; return 1; }
    jq -s --arg lat "$latitude" --arg lon "$longitude" --arg radius "$radius" '{
        source:"NSW Points of Interest API",
        center:{latitude:($lat|tonumber), longitude:($lon|tonumber)},
        radius_metres:($radius|tonumber), count:length,
        pois:map({id:.attributes.objectid, name:.attributes.poiname,
                  type:.attributes.poitype, latitude:.geometry.y, longitude:.geometry.x})
    }' "$work/features.txt" > nearby-pois.json || { error 'Could not create POI JSON'; return 1; }
    printf 'Returning %s POIs\n' "$number" >&2
    cat nearby-pois.json
}

handle_request() {
    case "$1" in
        assignment) assignment_response ;;
        population) population_response ;;
        poi\ *) poi_response "$1" ;;
        *) error 'Unknown request' ;;
    esac
}

# BusyBox netcat connects this handler's input/output to the client socket.
if [[ "${INFO1112_CLIENT_MODE:-}" == 1 ]]; then
    peer=$(ss -tnpH | awk -v pid="$$" '
        index($0,"pid=" pid ",") {print $5; exit}')
    client_ip=${peer%:*}
    client_ip=${client_ip#\[}
    client_ip=${client_ip%\]}
    client_ip=${client_ip#::ffff:}
    printf 'Client IP: %s\n' "$client_ip" >&2
    # mkdir succeeds for only one handler, even if two connect together.
    if ! mkdir "$work/busy" 2>/dev/null; then
        printf 'Rejected busy client: %s\n' "$client_ip" >&2
        error 'Server busy: another request is being processed'
        exit 1
    fi
    trap 'rmdir "$work/busy" 2>/dev/null' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ! IFS= read -r -t 30 request; then
        error 'No complete request received'
        exit 1
    fi
    request=${request%$'\r'}
    printf 'Received: %s\n' "$request" >&2
    handle_request "$request"
    exit $?
fi

server_ip=$(ifconfig eth0 | awk '/inet / {print $2}')
[[ -n "$server_ip" ]] || { echo 'Error: no server IP found.' >&2; exit 1; }
work=$(mktemp -d) || exit 1
cleanup() {
    local child
    # Stop any connected handlers, then the persistent listener.
    for child in $(ps -o pid,ppid | awk -v parent="${listener:-0}" '$2==parent {print $1}'); do
        kill "$child" 2>/dev/null || true
    done
    [[ -z "${listener:-}" ]] || kill "$listener" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export INFO1112_WORK="$work"
export INFO1112_SCRIPT="$PWD/$(basename -- "$0")"
# -e takes an executable file; this small wrapper starts the Bash handler.
printf '#!/bin/sh\nexec bash "$INFO1112_SCRIPT"\n' > "$work/handler"
chmod +x "$work/handler"

# BusyBox -lk keeps one listener open and starts a handler for each client.
INFO1112_CLIENT_MODE=1 busybox nc -lk -p "$SERVER_PORT" -e "$work/handler" &
listener=$!
port=""
for ((attempt=0; attempt<30; attempt++)); do
    port=$(ss -ltnpH | awk -v pid="$listener" '
        index($0,"pid=" pid ",") {p=$4; sub(/^.*:/,"",p); print p; exit}')
    [[ -n "$port" ]] && break
    kill -0 "$listener" 2>/dev/null || break
    sleep 0.1
done
if [[ -z "$port" ]]; then
    echo 'Error: could not detect listening port.' >&2
    exit 1
fi
printf 'Server listening at %s, port=%s\n' "$server_ip" "$port"
wait "$listener"
