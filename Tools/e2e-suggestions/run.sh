#!/bin/sh
# End-to-end test of Ollie's suggestions against a local Companion stand-in.
# Builds Ollie Dev, runs it headless (--background-check, pop-outs off: nothing on screen),
# points it at mock_companion.py on 127.0.0.1, drives every Yes / Not now through
# `ollie suggest answer`, and checks the writes the stand-in received. No production call.
# Usage: Tools/e2e-suggestions/run.sh [port]   (exit 0 = every check passed)
set -u
cd "$(dirname "$0")/../.."
PORT="${1:-8799}"
WORK="$(mktemp -d /tmp/ollie-e2e-run.XXXXXX)"
LOG="$WORK/requests.jsonl"
DEV="dist/Ollie Dev.app/Contents/MacOS/Ollie Dev"
SNAP="$HOME/Library/Application Support/Ollie Dev/suggestions.json"
FAIL=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAIL=1; }
list() { "$DEV" --cli suggest list; }
jq_py() { python3 -I -c "import json,sys; d=json.load(sys.stdin); $1"; }
posts() { python3 -I -c "import json; print(sum(1 for e in map(json.loads, open('$LOG')) if e['method']=='POST' and not e['path'].startswith('/__')))"; }
ctl() { curl -s -X POST -d "$2" "http://127.0.0.1:$PORT/__$1" >/dev/null; }
wait_for() { i=0; while [ $i -lt "$2" ]; do if eval "$1"; then return 0; fi; sleep 2; i=$((i+2)); done; return 1; }

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT is in use"; exit 2; fi
# It drives Ollie Dev and resets Ollie Dev's own answered list, so never take over a session someone is using.
if pgrep -f "Ollie Dev.app/Contents/MacOS/Ollie Dev" >/dev/null; then echo "Ollie Dev is running; quit it first"; exit 2; fi
make check-dev > "$WORK/build.log" 2>&1 || { echo "build failed: $WORK/build.log"; exit 2; }
python3 -I Tools/e2e-suggestions/mock_companion.py "$PORT" "$LOG" > "$WORK/mock.log" 2>&1 &
MOCK=$!
trap 'kill $MOCK 2>/dev/null; pkill -f "Ollie Dev.app/Contents/MacOS/Ollie Dev"' EXIT
sleep 1
"$DEV" --cli companion set --url "http://127.0.0.1:$PORT" >/dev/null
"$DEV" --cli suggest off >/dev/null
defaults delete com.outlandish.ollie.dev ollieSuggestionsHandled 2>/dev/null
rm -f "$SNAP"; : > "$LOG"
nohup "$DEV" --background-check > "$WORK/app.log" 2>&1 &
wait_for '[ -f "$SNAP" ] && list | jq_py "sys.exit(0 if len(d[\"feed\"])==4 else 1)"' 120 \
  && pass "offers exactly 4 ideas (draft, ask, hand-off, an agent's suggested answer)" || fail "4 ideas offered: $(list | jq_py 'print([f["id"] for f in d["feed"]])')"
list | jq_py 'ids=[f["id"] for f in d["feed"]]; sys.exit(0 if not any("ap-2" in i or "ap-3" in i for i in ids) else 1)' \
  && pass "an outside send and an item not yours are never offered" || fail "excluded approvals leaked"
list | jq_py 'sys.exit(0 if any(f["text"]=="Want me to ask Amber Lee (account manager) to restock Glow Primer or choose another hero product?" for f in d["feed"]) else 1)' \
  && pass "an ask says who does the work, with the listing title shortened" || fail "ask wording"
sleep 30
[ "$(posts)" = "0" ] && pass "untouched for 30 s+: zero writes" || fail "wrote without being asked: $(posts)"
pgrep -f "Ollie Dev.app/Contents/MacOS/Ollie Dev" >/dev/null && pass "Ollie Dev still running" || fail "Ollie Dev died"

ctl draft '{"apply_text":"GMV $30,000 this month."}'
"$DEV" --cli suggest answer "sm:res-sm-1:draft" yes >/dev/null
wait_for 'list | jq_py "ids=[f[\"id\"] for f in d[\"feed\"]]; sys.exit(0 if any(\"\$30,000\" in i for i in ids) and not any(\"\$26,000\" in i for i in ids) else 1)"' 40 && [ "$(posts)" = "0" ] \
  && pass "a proposal that changed on the server is refused, nothing sent, the new one offered" || fail "stale draft: $(list | jq_py 'print([f["id"] for f in d["feed"]], d["failures"])')"

ctl token '{"token":"rotated-token"}'
"$DEV" --cli suggest answer "sm:res-sm-1:rec:hero" yes >/dev/null
wait_for 'grep -q "\"status\": 419" "$LOG"' 20 && list | jq_py 'sys.exit(0 if any("hero" in k for k in d["failures"]) and any("hero" in f["id"] for f in d["feed"]) else 1)' \
  && pass "a refused security token shows as a failure and the idea stays" || fail "419 handling"
"$DEV" --cli suggest refresh >/dev/null; sleep 15
"$DEV" --cli suggest answer "sm:res-sm-1:rec:hero" yes >/dev/null
wait_for 'grep -q "hero_out_of_stock%3A1/apply\", \"status\": 200, \"xsrf_ok\": true" "$LOG"' 20 \
  && pass "Yes on an ask sends apply, key encoded, token checked" || fail "ask apply"

"$DEV" --cli suggest answer "sm:res-sm-1:rec:samples" not-now >/dev/null
wait_for 'grep -q "samples_underused%3A2026-11-09/dismiss\", \"status\": 200, \"xsrf_ok\": true" "$LOG"' 20 \
  && pass "Not now on a hand-off sends dismiss" || fail "dismiss"

"$DEV" --cli suggest answer "approval:ap-1" yes >/dev/null
wait_for 'python3 -I -c "import json,sys; sys.exit(0 if any(e[\"path\"]==\"/api/oo/approvals/answer\" and e[\"status\"]==200 and e[\"xsrf_ok\"] and e[\"body\"].get(\"answer\")==\"change\" and e[\"body\"].get(\"text\")==\"Use the spring brief\" and [i[\"id\"] for i in e[\"body\"][\"items\"]]==[\"ap-1\"] for e in map(json.loads, open(\"$LOG\"))) else 1)"' 20 \
  && curl -s "http://127.0.0.1:$PORT/__state" | jq_py 'sys.exit(0 if [a["id"] for a in d["approvals"]]==["ap-2","ap-3"] else 1)' \
  && pass "Yes on an agent's suggested answer sends change + its text for that item only, and the server took it" || fail "approval answer"

"$DEV" --cli suggest refresh >/dev/null; sleep 20
"$DEV" --cli suggest answer "sm:res-sm-1:draft" yes >/dev/null
wait_for 'grep -q "statements\", \"status\": 201, \"xsrf_ok\": true, \"body\": {\"text\": \"GMV \$30,000 this month.\"}" "$LOG"' 30 \
  && pass "Yes on the current proposal sets it as the month's strategy" || fail "statement"
list | jq_py 'sys.exit(0 if not d["feed"] and not d["failures"] else 1)' \
  && pass "all answered: feed empty, no stale errors" || fail "leftovers: $(list | jq_py 'print(d["feed"], d["failures"])')"

ctl reset '{}'; "$DEV" --cli suggest refresh >/dev/null
wait_for 'list | jq_py "sys.exit(0 if len(d[\"feed\"])>=3 else 1)"' 60
ctl auth '{"ok":false}'; "$DEV" --cli suggest refresh >/dev/null
wait_for 'list | jq_py "sys.exit(0 if not d[\"feed\"] else 1)"' 60 \
  && pass "signing out clears every idea" || fail "sign-out reset"

if [ $FAIL = 0 ]; then echo "ALL PASSED  (log: $LOG)"; else echo "SOME FAILED (log: $LOG)"; fi
exit $FAIL
