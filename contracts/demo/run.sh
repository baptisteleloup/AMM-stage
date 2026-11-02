#!/usr/bin/env bash
#
# demo/run.sh: the whole ResStock run, from building selection to a
# live view of the ten balances. Run it from contracts/.
#
#   bash demo/run.sh
#
# Everything is configurable from the environment:
#
#   STATE=MA          which state's ResStock buildings to draw from
#   WITH_PV=5         how many dwellings with rooftop PV
#   WITHOUT_PV=5      how many without
#   DAYS_FROM / DAYS_TO   date range; the last day is dropped from the netputs
#   PACE=4            seconds of wall clock per quarter-hour of market time
#   ZONE=WCMA         ISO New England load zone the prices come from
#   DELIVERY_ADDER    per kWh added to the wholesale price to get the retail one
#   TARIFF_MODE=feed  "feed" for real day-ahead prices, "schedule" for the flat
#                     French-style tariff
#   SKIP_DATA=1       reuse the profiles already built, go straight to the run
#
set -euo pipefail

# Everything below runs from contracts/, wherever this script is invoked from.
# The demo redirects the core through the environment; the core itself has no
# idea this layout exists.
cd "$(dirname "$0")/.."
DEMO_DATA="demo/data"
DEMO_STATE="demo/state"
mkdir -p "$DEMO_DATA" "$DEMO_STATE"
export DEPLOYMENT_JSON="${DEPLOYMENT_JSON:-$DEMO_STATE/deployed_demo.json}"
export DEPLOY_OUT="${DEPLOY_OUT:-$DEMO_STATE/deployed_demo.json}"
export PROSUMERS_OUT="${PROSUMERS_OUT:-$DEMO_STATE/prosumers_demo.json}"
export PROSUMERS_JSON="${PROSUMERS_JSON:-$DEMO_STATE/prosumers_demo.json}"
export DATA_DIR="${DATA_DIR:-$DEMO_STATE/operator-data}"
export OPERATOR_DB="${OPERATOR_DB:-$DEMO_STATE/operator-data/operator.db}"
export RECEIPTS_DIR="${RECEIPTS_DIR:-$DEMO_STATE/operator-data/receipts}"
export CLIENT_DATA_DIR="${CLIENT_DATA_DIR:-$DEMO_STATE/client-data}"
export PRICES_JSON="${PRICES_JSON:-$DEMO_DATA/prices.json}"

STATE="${STATE:-MA}"
WITH_PV="${WITH_PV:-5}"
WITHOUT_PV="${WITHOUT_PV:-5}"
DAYS_FROM="${DAYS_FROM:-2018-07-01}"
DAYS_TO="${DAYS_TO:-2018-07-05}"
NETPUTS="${NETPUTS:-demo/data/netputs_raw.json}"
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
# CHAIN=besu runs on the Besu network in network/, no anvil needed.
[ "${CHAIN:-anvil}" = anvil ] && need anvil
need curl
[ -f js_scripts/demo/demo_ui.ts ] || { red "run this from contracts/ (js_scripts/demo/demo_ui.ts not found)"; exit 1; }

python3 - <<'EOF' || { echo; echo "install them with:"; echo "  python3 -m pip install pandas pyarrow openpyxl tqdm matplotlib"; exit 1; }
import sys
missing = []
for m in ("pandas", "pyarrow", "openpyxl", "tqdm", "matplotlib"):
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
  if ! ls demo/data/raw/"${PRICE_YEAR}"_smd_hourly.* >/dev/null 2>&1 \
     && ! ls ~/Downloads/"${PRICE_YEAR}"_smd_hourly.* >/dev/null 2>&1; then
    red "the ${PRICE_YEAR} ISO New England hourly workbook is missing"
    echo
    echo "ISO-NE puts a captcha on these files, so it has to be fetched by hand once:"
    echo "  1. open https://www.iso-ne.com/isoexpress/web/reports/pricing/-/tree/zone-info"
    echo "  2. in the Zonal Information table find ${PRICE_YEAR}_smd_hourly.xlsx"
    echo "  3. tick it, solve the captcha, download"
    echo "  4. leave it in ~/Downloads or move it into demo/data/raw/ , then run this again"
    echo
    echo "or skip real prices for now with:   TARIFF_MODE=schedule bash $0"
    exit 1
  fi
  green "price workbook for ${PRICE_YEAR} found"
fi

if [ "${SKIP_DATA:-0}" != "1" ]; then

  step "1/5  choosing $N buildings in $STATE ($WITH_PV with PV, $WITHOUT_PV without)"
  echo "the state metadata file is a few hundred MB and is cached in demo/data/raw/"
  python3 demo/sim/pick_buildings.py --cache "$DEMO_DATA/raw" --out "$DEMO_DATA/selection.json" --state "$STATE" --with-pv "$WITH_PV" --without-pv "$WITHOUT_PV"

  IDS=$(python3 -c "
import json
s = json.load(open('demo/data/selection.json'))
print(','.join(s['with_pv_ids'] + s['without_pv_ids']))
")
  green "selected: $IDS"

  step "2/5  downloading their load curves and splitting the end uses"
  python3 demo/sim/build_profiles.py --cache "$DEMO_DATA/raw" --out "$DEMO_DATA/profiles" --ids "$IDS" --state "$STATE" --days "$DAYS_FROM:$DAYS_TO"

  if [ "$TARIFF_MODE" = "feed" ]; then
    step "3/5  fetching ISO New England day-ahead prices, zone $ZONE"
    echo "same year as the building weather, so loads and prices move together"
    python3 demo/sim/fetch_prices.py --days "$DAYS_FROM:$DAYS_TO" --zone "$ZONE" \
      --delivery-adder "$DELIVERY_ADDER" --out "$DEMO_DATA/prices.json"
  fi

  step "4/5  turning the recorded profiles into netputs at 96 sessions a day"
  rm -f "$NETPUTS"
  python3 demo/sim/make_netputs_raw.py --profiles "$DEMO_DATA/profiles" --out "$NETPUTS" --force

else
  step "skipping data preparation (SKIP_DATA=1)"
  [ -f "$NETPUTS" ] || { red "$NETPUTS not found — run once without SKIP_DATA"; exit 1; }
  if [ "$TARIFF_MODE" = "feed" ] && [ ! -f "$PRICES_JSON" ]; then
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

: > demo/state/demo.log
NETPUTS_JSON="$NETPUTS" \
TARIFF_MODE="$TARIFF_MODE" \
PRICES_JSON="$PRICES_JSON" \
N_PROSUMERS="$N" \
FLOOR_EUR="$FLOOR_EUR" \
SESSION_PACE_MS="$((PACE * 1000))" \
OPEN_BROWSER=0 \
CLIENT_SLOTS=1 \
npx tsx js_scripts/demo/demo_ui.ts >> demo/state/demo.log 2>&1 &
DEMO_PID=$!

echo "simulation running in the background, log in demo/state/demo.log"
echo "one quarter-hour every ${PACE}s, so a day takes about $(( 96 * PACE / 60 )) min"
echo "the single-prosumer web view is at http://127.0.0.1:8787"
echo
echo "waiting for the first day to close before showing balances..."

for i in $(seq 1 240); do
  sleep 5
  if ! kill -0 "$DEMO_PID" 2>/dev/null; then
    red "the simulation stopped. Last lines of demo/state/demo.log:"
    tail -25 demo/state/demo.log
    exit 1
  fi
  if [ -f demo/state/operator-data/operator.db ] && \
     python3 -c "
import sqlite3, sys
try:
    c = sqlite3.connect('file:demo/state/operator-data/operator.db?mode=ro', uri=True)
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
npx tsx js_scripts/demo/monitor.ts watch 10
