#!/usr/bin/env bash
#
# run_resstock_demo.sh — the whole ResStock run, from building selection to a
# live view of the ten balances. Put this in contracts/ and run it from there.
#
#   ./run_resstock_demo.sh
#
# Everything is configurable from the environment:
#
#   STATE=MA          which state's ResStock buildings to draw from
#   WITH_PV=5         how many dwellings with rooftop PV
#   WITHOUT_PV=5      how many without
#   DAYS_FROM / DAYS_TO   date range; you need one more day than you simulate,
#                         because the solver looks one day ahead
#   REFERENCE=...     folder holding rollingHorizon.py; found automatically
#                     in the usual places if you do not set it
#   PACE=4            seconds of wall clock per quarter-hour of market time
#   ZONE=WCMA         ISO New England load zone the prices come from
#   DELIVERY_ADDER    per kWh added to the wholesale price to get the retail one
#   TARIFF_MODE=feed  "feed" for real day-ahead prices, "schedule" for the flat
#                     French-style tariff
#   SKIP_DATA=1       reuse the profiles already built, go straight to the run
#
set -euo pipefail

STATE="${STATE:-MA}"
WITH_PV="${WITH_PV:-5}"
WITHOUT_PV="${WITHOUT_PV:-5}"
DAYS_FROM="${DAYS_FROM:-2018-07-01}"
DAYS_TO="${DAYS_TO:-2018-07-05}"
NETPUTS="${NETPUTS:-netputs_resstock.json}"
PACE="${PACE:-4}"
FLOOR_EUR="${FLOOR_EUR:-31}"
ZONE="${ZONE:-WCMA}"
DELIVERY_ADDER="${DELIVERY_ADDER:-0.12}"
TARIFF_MODE="${TARIFF_MODE:-feed}"

N=$((WITH_PV + WITHOUT_PV))

blue()  { printf "\033[36m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }
step()  { echo; blue "── $1 ──────────────────────────────────────────"; }

need() {
  command -v "$1" >/dev/null 2>&1 || { red "missing: $1"; exit 1; }
}

step "checks"
need python3
need npx
need anvil
need curl
[ -f js_scripts/demo_ui.ts ] || { red "run this from contracts/ (js_scripts/demo_ui.ts not found)"; exit 1; }

# Find the paper's solver. REFERENCE wins if it is set and correct; otherwise
# look in the usual places, then search nearby. A zip that already contains a
# "reference" folder gives you reference/reference when unzipped into a folder
# of the same name, so both shapes are tried.
find_solver() {
  local c
  for c in "${REFERENCE:-}" \
           "${REFERENCE:-}/reference" \
           ./reference ./reference/reference \
           ../reference ../reference/reference \
           ../../reference ../../reference/reference; do
    [ -n "$c" ] && [ -f "$c/rollingHorizon.py" ] && { echo "$c"; return 0; }
  done
  c=$(find .. -maxdepth 4 -name rollingHorizon.py -not -path "*/node_modules/*" 2>/dev/null | head -1)
  [ -n "$c" ] && { dirname "$c"; return 0; }
  return 1
}

if ! REFERENCE=$(find_solver); then
  red "cannot find rollingHorizon.py (the paper's solver) anywhere nearby"
  echo
  echo "unzip reference.zip, then point REFERENCE at the folder that HOLDS"
  echo "rollingHorizon.py. Note the shell detail that bites here: setting the"
  echo "variable on its own line does not export it to this script. Use either"
  echo
  echo "    export REFERENCE=\"/path/to/reference\""
  echo "    ./run_resstock_demo.sh"
  echo
  echo "or put both on one line:"
  echo
  echo "    REFERENCE=\"/path/to/reference\" ./run_resstock_demo.sh"
  echo
  echo "to locate it:   find ~ -name rollingHorizon.py 2>/dev/null"
  exit 1
fi
REFERENCE=$(cd "$REFERENCE" && pwd)
green "solver found at $REFERENCE"

python3 - <<'EOF' || { echo; echo "install them with:"; echo "  python3 -m pip install pandas pyarrow openpyxl cvxpy tqdm matplotlib"; exit 1; }
import sys
missing = []
for m in ("pandas", "pyarrow", "openpyxl", "cvxpy", "tqdm", "matplotlib"):
    try:
        __import__(m)
    except Exception:
        missing.append(m)
if missing:
    print("missing python packages: " + ", ".join(missing))
    sys.exit(1)
print("python packages ok")
EOF

# ISO New England captchas its downloads, so the price workbook is a manual,
# one-time step. Check for it now rather than three steps and a few minutes in.
if [ "$TARIFF_MODE" = "feed" ] && [ "${SKIP_DATA:-0}" != "1" ]; then
  PRICE_YEAR="${DAYS_FROM%%-*}"
  if ! ls raw/"${PRICE_YEAR}"_smd_hourly.* >/dev/null 2>&1 \
     && ! ls ~/Downloads/"${PRICE_YEAR}"_smd_hourly.* >/dev/null 2>&1; then
    red "the ${PRICE_YEAR} ISO New England hourly workbook is missing"
    echo
    echo "ISO-NE puts a captcha on these files, so it has to be fetched by hand once:"
    echo "  1. open https://www.iso-ne.com/isoexpress/web/reports/pricing/-/tree/zone-info"
    echo "  2. in the Zonal Information table find ${PRICE_YEAR}_smd_hourly.xlsx"
    echo "  3. tick it, solve the captcha, download"
    echo "  4. leave it in ~/Downloads or move it into raw/ , then run this again"
    echo
    echo "or skip real prices for now with:   TARIFF_MODE=schedule bash $0"
    exit 1
  fi
  green "price workbook for ${PRICE_YEAR} found"
fi

if [ -f netputs_nice.json ] && [ ! -f netputs_nice.json.bak ]; then
  cp netputs_nice.json netputs_nice.json.bak
  green "backed up netputs_nice.json (the paper's Nice data) to netputs_nice.json.bak"
fi

if [ "${SKIP_DATA:-0}" != "1" ]; then

  step "1/5  choosing $N buildings in $STATE ($WITH_PV with PV, $WITHOUT_PV without)"
  echo "the state metadata file is a few hundred MB and is cached in raw/"
  python3 pick_buildings.py --state "$STATE" --with-pv "$WITH_PV" --without-pv "$WITHOUT_PV"

  IDS=$(python3 -c "
import json
s = json.load(open('selection.json'))
print(','.join(s['with_pv_ids'] + s['without_pv_ids']))
")
  green "selected: $IDS"

  step "2/5  downloading their load curves and splitting the end uses"
  python3 build_profiles.py --ids "$IDS" --state "$STATE" --days "$DAYS_FROM:$DAYS_TO"

  if [ "$TARIFF_MODE" = "feed" ]; then
    step "3/5  fetching ISO New England day-ahead prices, zone $ZONE"
    echo "same year as the building weather, so loads and prices move together"
    python3 fetch_prices.py --days "$DAYS_FROM:$DAYS_TO" --zone "$ZONE" \
      --delivery-adder "$DELIVERY_ADDER" --out prices.json
    PRICE_ARG="--prices prices.json"
  else
    PRICE_ARG=""
  fi

  step "4/5  running the paper's solver at 96 steps a day"
  echo "this is where gross production and consumption become netputs"
  rm -f "$NETPUTS"
  # shellcheck disable=SC2086
  python3 make_netputs.py --profiles profiles --reference "$REFERENCE" --out "$NETPUTS" $PRICE_ARG --force

else
  step "skipping data preparation (SKIP_DATA=1)"
  [ -f "$NETPUTS" ] || { red "$NETPUTS not found — run once without SKIP_DATA"; exit 1; }
  if [ "$TARIFF_MODE" = "feed" ] && [ ! -f prices.json ]; then
    red "prices.json not found but TARIFF_MODE=feed — run once without SKIP_DATA"
    exit 1
  fi
fi

step "5/5  running the market"

cleanup() {
  echo
  blue "stopping the simulation"
  [ -n "${DEMO_PID:-}" ] && kill "$DEMO_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

: > demo.log
NETPUTS_JSON="$NETPUTS" \
TARIFF_MODE="$TARIFF_MODE" \
PRICES_JSON=prices.json \
N_PROSUMERS="$N" \
FLOOR_EUR="$FLOOR_EUR" \
SESSION_PACE_MS="$((PACE * 1000))" \
OPEN_BROWSER=0 \
CLIENT_SLOTS=1 \
npx tsx js_scripts/demo_ui.ts >> demo.log 2>&1 &
DEMO_PID=$!

echo "simulation running in the background, log in demo.log"
echo "one quarter-hour every ${PACE}s, so a day takes about $(( 96 * PACE / 60 )) min"
echo "the single-prosumer web view is at http://127.0.0.1:8787"
echo
echo "waiting for the first day to close before showing balances..."

for i in $(seq 1 240); do
  sleep 5
  if ! kill -0 "$DEMO_PID" 2>/dev/null; then
    red "the simulation stopped. Last lines of demo.log:"
    tail -25 demo.log
    exit 1
  fi
  if [ -f operator-data/operator.db ] && \
     python3 -c "
import sqlite3, sys
try:
    c = sqlite3.connect('file:operator-data/operator.db?mode=ro', uri=True)
    n = c.execute('SELECT count(*) FROM openings').fetchone()[0]
except Exception:
    n = 0
sys.exit(0 if n > 0 else 1)
" 2>/dev/null; then
    green "first balances written"
    break
  fi
  printf "."
done

echo
npx tsx js_scripts/monitor.ts watch 10
