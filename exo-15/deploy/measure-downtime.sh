#!/usr/bin/env bash
# measure-downtime.sh : mesure de disponibilité pendant un déploiement
#   RATE requêtes/s sur URL, jusqu'à DURATION secondes ou jusqu'à la création de STOP_FILE.
#   Une requête est un échec si elle ne répond pas HTTP 200 en moins de TIMEOUT secondes.
#
#   ./deploy/measure-downtime.sh                                   # 100 req/s sur la préprod, 60 s
#   URL=http://127.0.0.1/health DURATION=30 ./deploy/measure-downtime.sh
set -euo pipefail
URL="${URL:-http://127.0.0.1:8088/health}"
HOST_HEADER="${HOST_HEADER:-api.localhost}"   # routage Traefik par Host
RATE="${RATE:-100}"
DURATION="${DURATION:-60}"
TIMEOUT="${TIMEOUT:-2}"
STOP_FILE="${STOP_FILE:-}"

exec python3 - "$URL" "$HOST_HEADER" "$RATE" "$DURATION" "$TIMEOUT" "$STOP_FILE" <<'PY'
import collections, os, sys, threading, time, urllib.error, urllib.request
from concurrent.futures import ThreadPoolExecutor

url, host = sys.argv[1], sys.argv[2]
rate, duration, timeout, stop_file = int(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5]), sys.argv[6]
results, lock = [], threading.Lock()

def hit(t_sched):
    try:
        req = urllib.request.Request(url, headers={"Host": host})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            ok, detail = r.status == 200, "HTTP %d" % r.status
    except urllib.error.HTTPError as e:
        ok, detail = False, "HTTP %d" % e.code
    except urllib.error.URLError as e:
        ok, detail = False, type(e.reason).__name__
    except Exception as e:  # timeout, connexion coupée...
        ok, detail = False, type(e).__name__
    with lock:
        results.append((t_sched, ok, detail))

print("mesure : %d req/s sur %s (Host: %s)" % (rate, url, host), flush=True)
start = time.time()
with ThreadPoolExecutor(max_workers=max(50, rate)) as pool:
    i = 0
    while True:
        now = time.time() - start
        if now >= duration or (stop_file and os.path.exists(stop_file)):
            break
        target = i / rate
        if target > now:
            time.sleep(target - now)
        pool.submit(hit, target)
        i += 1
elapsed = time.time() - start

results.sort()
fails = [r for r in results if not r[1]]
total = len(results)
print("durée %.1f s | requêtes %d | succès %d | ÉCHECS %d (%.2f %%)"
      % (elapsed, total, total - len(fails), len(fails), 100.0 * len(fails) / max(total, 1)))
if fails:
    kinds = collections.Counter(d for _, _, d in fails)
    secs = sorted(set(int(t) for t, _, _ in fails))
    print("types : " + ", ".join("%s x%d" % kv for kv in kinds.most_common()))
    print("premier échec à t=%.2f s, dernier à t=%.2f s, %d seconde(s) touchée(s) : %s"
          % (fails[0][0], fails[-1][0], len(secs), " ".join(map(str, secs))))
PY
