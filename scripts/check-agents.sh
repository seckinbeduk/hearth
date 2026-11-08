#!/bin/bash
# Checks the running Hearth (e.g. a freshly installed DMG) receives agent events: sends a test session
# with this install's token, confirms Hearth counts it, then ends it. Run after installing a release.
#   ./scripts/check-agents.sh
set -euo pipefail
TOKEN=$(defaults read io.github.seckinbeduk.hearth hearth.agents.token 2>/dev/null || true)
[[ -n "$TOKEN" ]] || { echo "❌ No Agents token yet: turn Agents on in Hearth first."; exit 1; }
# Hearth uses the preferred port (8800 unless set) or the next free one, up to 9 above it.
FIRST=$(defaults read io.github.seckinbeduk.hearth hearth.port 2>/dev/null || echo 8800)
URL=""
for port in $(seq "$FIRST" $((FIRST + 9))); do
  if curl -s -m 1 "http://127.0.0.1:$port/health" 2>/dev/null | grep -q '"server":"Hearth"'; then URL="http://127.0.0.1:$port"; break; fi
done
[[ -n "$URL" ]] || { echo "❌ Hearth isn't answering on ports $FIRST–$((FIRST + 9))."; exit 1; }
status() { curl -s -m 2 -H "X-Hearth-Token: $TOKEN" "$URL/agents/status" || { echo "❌ No answer from $URL/agents/status." >&2; exit 1; }; }
post() { curl -s -o /dev/null -m 2 -H 'Expect:' -H 'Content-Type: application/json' -H "X-Hearth-Token: $TOKEN" \
  --data-binary "$1" "$URL/agents/claude-code" || { echo "❌ Couldn't send a test event to $URL." >&2; exit 1; }; }
before=$(status)
echo "$before" | grep -q '"enabled":true' || { echo "❌ Agents is off in Hearth ($before)."; exit 1; }
ID="hearth-check-$(date +%s)"
post "{\"session_id\":\"$ID\",\"hook_event_name\":\"SessionStart\",\"cwd\":\"/tmp/hearth-check\"}"
post "{\"session_id\":\"$ID\",\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"/tmp/hearth-check\",\"prompt\":\"check\"}"
sleep 1
after=$(status)
post "{\"session_id\":\"$ID\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}"
n() { echo "$1" | sed -E 's/.*"sessions":([0-9]+).*/\1/'; }
if [[ $(n "$after") -gt $(n "$before") ]]; then
  echo "✅ Hearth received the test event ($(n "$before") → $(n "$after") sessions). It shows as \"hearth-check\" in the panel, ended."
else
  echo "❌ Hearth didn't count the test session ($before → $after)."; exit 1
fi
