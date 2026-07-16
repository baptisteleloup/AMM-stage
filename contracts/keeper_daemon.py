"""
Keeper — one instance per validator organization. Stateless and idempotent:
N copies run in parallel, first tx in wins, the others revert harmlessly
(that IS the availability mechanism, there is no reward on a private chain).

Three jobs:
  1. settle(sid) for every opened, unsettled, closed session
  2. finalizeDay(day) once the challenge window has elapsed
  3. (Feed mode only) post tomorrow's day-ahead vector after publication

  uv run python keeper_daemon.py
"""

import os
import time
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
import besu_common as bc

SLOT = 900
DAY  = 96
POLL = 5                          # seconds
LOOKBACK = 2 * DAY                # sessions re-checked each loop (late opens, races)
WAD  = 10**18

market = bc.contract("Market", bc.dep["Market"])
tariff = bc.contract("GridTariff", bc.dep["GridTariff"])
KEEPER = bc.operator              # TODO: one key per validator org, not the operator's

FEED_MODE    = tariff.functions.mode().call() == 1
ENTSOE_TOKEN = os.environ.get("ENTSOE_TOKEN")
FR_DOMAIN    = "10YFR-RTE------C"
MARGIN       = 8 * WAD            # c€/kWh added to spot for lambda_high — regime-specific


def try_tx(func, label):
    # losing the race or a duplicate call reverts: expected noise, not an error
    try:
        bc.send(func, KEEPER)
        print(f"[keeper] {label}")
    except Exception as e:
        if "revert" not in str(e).lower():
            print(f"[keeper] {label} failed: {e}")


def settle_pending(now_sid: int):
    for sid in range(max(0, now_sid - LOOKBACK), now_sid):
        sess = market.functions.sessions(sid).call()
        if sess[0] and not sess[1]:                      # opened, not settled
            try_tx(market.functions.settle(sid), f"settle({sid})")


def finalize_pending(today: int):
    window = market.functions.challengeWindow().call()
    for day in range(max(0, today - 3), today):
        closed, finalized, cancelled, closed_at, _ = market.functions.dayBatch(day).call()
        if closed and not finalized and not cancelled and time.time() >= closed_at + window:
            try_tx(market.functions.finalizeDay(day), f"finalizeDay({day})")


# ---- Feed mode: day-ahead prices, one vector per day ----

def fetch_dayahead_spot(date) -> list[int]:
    # ENTSO-E Transparency, documentType A44. Hourly EUR/MWh -> 96 slots, c€/kWh 1e18.
    start = date.strftime("%Y%m%d0000")
    end   = (date + timedelta(days=1)).strftime("%Y%m%d0000")
    url = (f"https://web-api.tp.entsoe.eu/api?securityToken={ENTSOE_TOKEN}"
           f"&documentType=A44&in_Domain={FR_DOMAIN}&out_Domain={FR_DOMAIN}"
           f"&periodStart={start}&periodEnd={end}")
    tree = ET.parse(urllib.request.urlopen(url, timeout=30))
    ns = {"n": tree.getroot().tag.split("}")[0].strip("{")}
    hourly = [float(p.find("n:price.amount", ns).text)
              for p in tree.getroot().iter(f"{{{ns['n']}}}Point")][:24]
    assert len(hourly) == 24, "incomplete day-ahead data"
    # 1 EUR/MWh = 0.1 c€/kWh
    return [int(h * 0.1 * WAD) for h in hourly for _ in range(4)]


def submit_feed(today: int):
    tomorrow = today + 1
    marker = f".fed_{tomorrow}"
    if os.path.exists(marker) or datetime.now(timezone.utc).hour < 13:
        return                                          # EPEX publication ~12:45 CET
    try:
        spot = fetch_dayahead_spot(datetime.fromtimestamp(tomorrow * DAY * SLOT, timezone.utc))
    except Exception as e:
        print(f"[keeper] day-ahead fetch failed, retrying next loop: {e}")
        return
    low  = spot                                         # lambda_low = spot: adapt to your regime
    high = [p + MARGIN for p in spot]
    try_tx(tariff.functions.submitDailyPrices(tomorrow, low, high), f"feed({tomorrow})")
    open(marker, "w").close()


if __name__ == "__main__":
    print(f"Keeper up ({'feed' if FEED_MODE else 'schedule'} mode), poll {POLL}s")
    while True:
        now_sid = int(time.time() // SLOT)
        settle_pending(now_sid)
        finalize_pending(now_sid // DAY)
        if FEED_MODE and ENTSOE_TOKEN:
            submit_feed(now_sid // DAY)
        time.sleep(POLL)
