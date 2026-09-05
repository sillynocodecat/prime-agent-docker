#!/bin/bash
# Lifecycle scenarios against the real image (ENTRYPOINT = service) with real
# resident sessions driven through the TUI (pty) and the credential-free faux
# provider extension. usage: run-lifecycle.sh [G R K M S C D W I ...]
set -u
IMG=${IMG:-localhost/prime-agent-docker:dev}
ENGINE=${ENGINE:-podman}
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-${TMPDIR:-/tmp}/prime-agent-lifecycle-$(date +%H%M%S)}
mkdir -p "$OUT"
EXT="-e /ci/faux-provider/faux-provider.js --model faux/faux-1"
pass=0; failn=0
ok()   { echo "  ok   $*"; pass=$((pass+1)); }
fail() { echo "  FAIL $*"; failn=$((failn+1)); }
check() { if eval "$1"; then ok "$2"; else fail "$2"; fi; }
now() { date +%s; }
T0=$(now); el() { echo "[$(( $(now)-T0 ))s] $*"; }

start_container() { # $1 = name, rest = extra engine args
  local name=$1; shift
  $ENGINE rm -f "$name" >/dev/null 2>&1
  mkdir -p "$OUT/$name/data" "$OUT/$name/work"
  $ENGINE run -d --name "$name" --platform linux/amd64 --init --security-opt no-new-privileges --stop-timeout 30 --restart=no \
    --tmpfs /run/prime-agent-container:rw,mode=0700,nosuid,nodev --tmpfs /tmp:rw,mode=1777,nosuid,nodev \
    -v "$OUT/$name/data:/data:z" -v "$OUT/$name/work:/work:z" -v "$REPO/build/ci:/ci:ro,z" -e TZ=Europe/Berlin "$@" "$IMG" >/dev/null || { fail "start $name"; return 1; }
  wait_ready "$name"
}
wait_ready() { local t=$(now); for i in $(seq 1 40); do $ENGINE exec "$1" test -f /run/prime-agent-container/ready 2>/dev/null && { el "$1 ready after $(( $(now)-t ))s"; return 0; }; sleep 1; done; fail "$1 not ready"; return 1; }
cstate() { $ENGINE inspect --format '{{.State.Status}}|{{.State.ExitCode}}' "$1" 2>/dev/null; }
wait_exit() { # $1 name, $2 max seconds → prints elapsed
  local t=$(now); while [ "$(cstate "$1" | cut -d'|' -f1)" = running ] && [ $(( $(now)-t )) -lt "$2" ]; do sleep 2; done; echo $(( $(now)-t )); }
sessions() { $ENGINE exec "$1" prime-agent list --json 2>/dev/null | python3 -c 'import sys,json
try: d=json.load(sys.stdin); print(len(d["sessions"]))
except Exception: print("?")'; }
wait_passivation() { # $1 name, $2 max → prints elapsed or "none"
  local t=$(now); while [ $(( $(now)-t )) -lt "$2" ]; do
    [ "$(cstate "$1" | cut -d'|' -f1)" = running ] || { echo "exited"; return; }
    [ "$(sessions "$1")" = 0 ] && { echo $(( $(now)-t )); return; }; sleep 3; done; echo none; }
tui() { # $1 name, $2 log, steps..., then -- extra prime-agent args
  local name=$1 log=$2; shift 2; local steps=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do steps+=("$1"); shift; done; shift || true
  timeout 180 python3 "$HERE/tui.py" --log "$OUT/$log.raw" "${steps[@]}" -- $ENGINE exec -it -e PRIME_AGENT_CONTAINER_CLIENT=1 "$name" prime-agent $EXT "$@" >"$OUT/$log.txt" 2>&1
  local rc=$?; grep -E '^\[tui\] (expect|eof)' "$OUT/$log.txt" | sed 's/^/    /'; return $rc; }
jq_() { python3 -c "import sys,json; d=json.load(sys.stdin); $1"; }
faux_calls() { cat "$OUT/$1/work/.faux/calls.jsonl" 2>/dev/null; }
session_file() { find "$OUT/$1/data/sessions" -maxdepth 1 -name '*.jsonl' | head -1; }
logs() { $ENGINE logs "$1" 2>&1; }

scenario_G() {
  echo "===== G. resident session → client quits → upstream passivation (no archive) → exit 0"
  start_container lc-G || return
  tui lc-G G-tui1 'sleep:6' 'send:hello\r' 'expect:ack: hello:60' 'sleep:2' 'send:/quit\r' 'eof' -- ; rc=$?; check "[ $rc -eq 0 ]" "TUI session: hello → ack → /quit"
  local j; j=$($ENGINE exec lc-G prime-agent list --json)
  check "printf '%s' \"\$j\" | jq_ 'assert len(d[\"sessions\"])==1 and d[\"sessions\"][0][\"lifecycle\"]==\"live\" and d[\"sessions\"][0][\"attachedClients\"]==0'" "after /quit: 1 live resident session, 0 attached clients"
  local ps; ps=$($ENGINE exec lc-G ps -eo pid,args); echo "$ps" | grep -q 'rlm.repl' && ok "worker kernel process present" || fail "no kernel process"
  sleep 6; check "[ \"\$($ENGINE exec lc-G sh -c 'ls /run/prime-agent-container/clients | wc -l')\" = 0 ]" "stale client lease pruned"
  local p; p=$(wait_passivation lc-G 150); el "passivation after ${p}s"; check "[ \"$p\" != none ] && [ \"$p\" != exited ]" "upstream passivated the idle worker (list empty) while the container was alive"
  logs lc-G | grep -q 'Evicted idle worker' && ok "daemon log: Evicted idle worker (idle eviction, not shutdown)" || fail "no eviction log line"
  local e; e=$(wait_exit lc-G 200); el "exit after ${e}s: $(cstate lc-G)"; check "[ \"$(cstate lc-G)\" = 'exited|0' ]" "service exit 0 after passivation"
  logs lc-G | grep -q 'automatic quiescence proven' && ok "controller: automatic quiescence proven" || fail "controller did not report quiescence"
  local f; f=$(session_file lc-G); check "[ -n \"$f\" ] && grep -q 'ack: hello' \"$f\"" "transcript persisted with the assistant reply"
  check "[ \"\$(grep -c '\"status\":\"archived\"' \"$f\")\" = 0 ]" "session not archived (no archived state marker)"
  check "[ \"\$(faux_calls lc-G | wc -l)\" = 1 ]" "exactly one model call (faux log)"
}

scenario_R() {
  echo "===== R. restart the stopped container → passivated session visible as live → resume → exit 0"
  [ "$(cstate lc-G | cut -d'|' -f1)" = exited ] || { fail "R needs G's exited container"; return; }
  $ENGINE start lc-G >/dev/null; wait_ready lc-G || return
  check "[ \"\$($ENGINE exec lc-G sh -c 'ls -A /run/prime-agent-container | tr \"\\n\" \" \"')\" = 'clients ready ' ]" "fresh tmpfs after restart (only clients/ and ready)"
  local sid; sid=$(faux_calls lc-G | head -1 | python3 -c 'import sys,json; print(json.loads(sys.stdin.readline())["sessionId"])')
  local all; all=$($ENGINE exec lc-G prime-agent list --all --json)
  check "printf '%s' \"\$all\" | jq_ 'm=[s for s in d[\"sessions\"] if s[\"sessionId\"]==\"$sid\"]; assert len(m)==1 and m[0][\"lifecycle\"]==\"live\" and m[0][\"messageCount\"]==2, m'" "list --all shows the passivated session as live with 2 messages (Agents View inactive section)"
  check "[ \"$(sessions lc-G)\" = 0 ]" "no resident worker before attach"
  tui lc-G R-tui 'sleep:6' 'send:again\r' 'expect:ack: again:60' 'sleep:2' 'send:/quit\r' 'eof' -- --resume "$sid"; rc=$?; check "[ $rc -eq 0 ]" "resume via --resume: again → ack"
  grep -q 'ack: hello' "$OUT/R-tui.raw" && ok "resumed TUI replayed the earlier transcript" || fail "earlier transcript not shown"
  local h1 h2; h1=$(faux_calls lc-G | sed -n 1p | python3 -c 'import sys,json;print(json.loads(sys.stdin.readline())["systemPromptSha256"])'); h2=$(faux_calls lc-G | sed -n 2p | python3 -c 'import sys,json;print(json.loads(sys.stdin.readline())["systemPromptSha256"])')
  check "[ -n \"$h1\" ] && [ \"$h1\" = \"$h2\" ]" "system prompt identical before and after passivation+restart ($h1)"
  local p; p=$(wait_passivation lc-G 150); el "passivation after ${p}s"; local e; e=$(wait_exit lc-G 200); el "exit after ${e}s: $(cstate lc-G)"
  check "[ \"$(cstate lc-G)\" = 'exited|0' ]" "second cycle also exits 0"
  check "[ \"\$(grep -c '\"status\":\"archived\"' \"$(session_file lc-G)\")\" = 0 ]" "still not archived after two cycles"
}

scenario_K() {
  echo "===== K. SIGTERM (engine stop) while a resident worker is idle-but-not-yet-passivated"
  start_container lc-K || return
  tui lc-K K-tui 'sleep:6' 'send:hello\r' 'expect:ack: hello:60' 'sleep:1' 'send:/quit\r' 'eof' --
  check "[ \"$(sessions lc-K)\" = 1 ]" "resident worker present before stop"
  local t=$(now); $ENGINE stop -t 30 lc-K >/dev/null; el "stopped in $(( $(now)-t ))s: $(cstate lc-K)"
  check "[ \"$(cstate lc-K)\" = 'exited|75' ]" "SIGTERM → exit 75"
  local f; f=$(session_file lc-K); check "grep -q 'ack: hello' \"$f\"" "transcript persisted through SIGTERM"
  local arch; arch=$(grep -c '"status":"archived"' "$f"); el "archived markers after SIGTERM with a resident worker: $arch (upstream shutdown archives resident workers)"
  logs lc-K | tail -6 | sed 's/^/    /' | cut -c1-160
  $ENGINE start lc-K >/dev/null; wait_ready lc-K || return
  local sid; sid=$(faux_calls lc-K | head -1 | python3 -c 'import sys,json; print(json.loads(sys.stdin.readline())["sessionId"])')
  $ENGINE exec lc-K prime-agent list --all --json | jq_ 'm=[s for s in d["sessions"] if s["sessionId"]=="'"$sid"'"]; print("    list --all after restart:", [(s["lifecycle"],s["messageCount"]) for s in m])'
  tui lc-K K-tui2 'sleep:6' 'send:back\r' 'expect:ack: back:60' 'sleep:1' 'send:/quit\r' 'eof' -- --resume "$sid"; rc=$?; check "[ $rc -eq 0 ]" "session resumable after SIGTERM+restart"
  $ENGINE stop -t 30 lc-K >/dev/null
}

scenario_M() {
  echo "===== M. manual shutdown through the wrapper with a resident worker → workers/kernels closed → exit 75"
  start_container lc-M || return
  tui lc-M M-tui 'sleep:6' 'send:hello\r' 'expect:ack: hello:60' 'sleep:1' 'send:/quit\r' 'eof' --
  local before; before=$($ENGINE exec lc-M ps -eo pid,args | grep -c -E 'rlm.repl|session-worker|prime-agent$')
  el "processes before shutdown (worker/kernel-ish): $before"; $ENGINE exec lc-M ps -eo pid,ppid,args | grep -v ' ps ' | sed 's/^/    /' | cut -c1-140
  local r; r=$($ENGINE exec -e PRIME_AGENT_CONTAINER_CLIENT=1 lc-M prime-agent shutdown --force --json 2>/dev/null); echo "    shutdown → $r"
  local after; after=$($ENGINE exec lc-M ps -eo pid,args 2>/dev/null | grep -v ' ps ' ); echo "$after" | sed 's/^/    /' | cut -c1-140
  check "! printf '%s' \"\$after\" | grep -q 'rlm.repl'" "kernel child closed by shutdown"
  local e; e=$(wait_exit lc-M 60); el "exit after ${e}s: $(cstate lc-M)"; check "[ \"$(cstate lc-M)\" = 'exited|75' ]" "manual shutdown → exit 75"
  check "grep -q 'ack: hello' \"$(session_file lc-M)\"" "transcript persisted"
}

scenario_S() {
  echo "===== S. an active schedule pins the container; cancel → passivation → exit 0"
  start_container lc-S || return
  tui lc-S S-tui 'sleep:6' 'send:hello\r' 'expect:ack: hello:60' 'sleep:1' 'send:/quit\r' 'eof' --
  local agent; agent=$($ENGINE exec lc-S prime-agent list --json | jq_ 'print(d["sessions"][0]["id"])')
  local add; add=$($ENGINE exec lc-S prime-agent schedule add "$agent" "* * * * *" -- "tick" 2>&1); echo "    schedule add → $add"
  local sl; sl=$($ENGINE exec lc-S prime-agent schedule list --all --json 2>/dev/null); echo "    $sl" | cut -c1-300
  check "printf '%s' \"\$sl\" | jq_ 'assert any(j[\"status\"]==\"active\" for j in d[\"jobs\"])'" "schedule list --all --json shows an active job"
  el "waiting 150 s (passivation would normally happen within ~70 s)"; sleep 150
  check "[ \"$(cstate lc-S | cut -d'|' -f1)\" = running ]" "container still running after 150 s with an active schedule"
  local j; j=$($ENGINE exec lc-S prime-agent list --json); printf '%s' "$j" | jq_ 'print("    resident:", [(s["id"], s.get("hasRegisteredCronJob"), s["messageCount"]) for s in d["sessions"]])'
  # v0.9.1 keeps a scheduled session's worker resident (hasRegisteredCronJob); from v0.9.2 the
  # worker may passivate and the daemon merges passive jobs into `schedule list --all`, so the
  # controller's schedule probe is what keeps the container alive. Accept both, require the pin.
  local sl2; sl2=$($ENGINE exec lc-S prime-agent schedule list --all --json 2>/dev/null)
  if printf '%s' "$j" | jq_ 'assert len(d["sessions"])==1 and d["sessions"][0].get("hasRegisteredCronJob")==True' 2>/dev/null; then ok "worker stays resident with hasRegisteredCronJob (v0.9.1 residency)"
  elif printf '%s' "$sl2" | jq_ 'assert any(j["status"]=="active" for j in d["jobs"])' 2>/dev/null; then ok "worker passivated but the active job is still listed by schedule list --all (passive-schedule pin, v0.9.2+)"
  else fail "neither a resident scheduled worker nor an active passive job: $(printf '%s' "$sl2" | cut -c1-120)"; fi
  local ticks; ticks=$(faux_calls lc-S | grep -c '"lastUser":"tick"'); check "[ \"$ticks\" -ge 1 ]" "scheduled prompt ran (tick calls: $ticks)"
  local jid; jid=$(printf '%s' "$sl" | jq_ 'print([j["id"] for j in d["jobs"] if j["status"]=="active"][0])')
  local c; c=$($ENGINE exec lc-S prime-agent schedule cancel "$jid" 2>&1); echo "    cancel → $c"
  local p; p=$(wait_passivation lc-S 150); el "passivation after cancel: ${p}s"; local e; e=$(wait_exit lc-S 200); el "exit after ${e}s: $(cstate lc-S)"
  check "[ \"$(cstate lc-S)\" = 'exited|0' ]" "exit 0 after the schedule was cancelled"
}

scenario_C() {
  echo "===== C. recursive subagent: parent spawns a child; child messages the parent; nothing evicted mid-hop"
  start_container lc-C || return
  local code="h = await rlm('run-python: await agent_message.send(\"hi parent\", receiver_role=\"parent\")', name='kid'); print('spawned', h.rlm_child_id)"
  tui lc-C C-tui 'sleep:6' "send:run-python: $code\r" 'expect:spawned|done:90' 'sleep:25' 'send:/quit\r' 'eof' --
  local j; j=$($ENGINE exec lc-C prime-agent list --json 2>/dev/null); printf '%s' "$j" | jq_ 'print("    sessions:", [(s["id"], s.get("runtimeKind"), s["activity"], s["messageCount"]) for s in d["sessions"]])'
  faux_calls lc-C | python3 -c 'import sys,json
for l in sys.stdin:
    e=json.loads(l); print("    call", e["call"], "pid", e["pid"], "session", e["sessionId"][:8], e["lastRole"], repr(e["lastUser"][:60]))'
  check "faux_calls lc-C | grep -q 'task from parent.*run-python: await agent_message.send'" "child session made a model call (spawned with the parent model)"
  check "faux_calls lc-C | grep -q 'from child:kid'" "parent received the child's message and took a follow-up turn ([from child:kid] delivery call)"
  check "grep -q 'hi parent' \"$(session_file lc-C)\"" "delivered message text reached the parent transcript"
  local n; n=$(faux_calls lc-C | python3 -c 'import sys,json; print(len({json.loads(l)["sessionId"] for l in sys.stdin}))'); check "[ \"$n\" = 2 ]" "two distinct sessions in the faux log (parent + child), got $n"
  local p; p=$(wait_passivation lc-C 180); el "passivation after ${p}s"; local e; e=$(wait_exit lc-C 200); el "exit after ${e}s: $(cstate lc-C)"
  check "[ \"$(cstate lc-C)\" = 'exited|0' ]" "exit 0 only after parent and child settled"
  check "[ \"\$(grep -l 'hi parent' $OUT/lc-C/data/sessions/*.jsonl 2>/dev/null | wc -l)\" -ge 1 ]" "child's message persisted in a transcript"
  logs lc-C | grep -E 'Evicted|quiescent' | sed 's/^/    /' | cut -c1-160
}

scenario_D() {
  echo "===== D. documented limitation: a detached shell-only process is not a liveness signal"
  start_container lc-D || return
  tui lc-D D-tui 'sleep:6' 'send:run-python: await bash("nohup sleep 600 >/dev/null 2>&1 &"); print("detached")\r' 'expect:detached|done:90' 'sleep:3' 'send:/quit\r' 'eof' --
  local ps; ps=$($ENGINE exec lc-D ps -eo pid,ppid,args | grep -v ' ps '); echo "$ps" | grep 'sleep 600' | sed 's/^/    /'
  check "printf '%s' \"\$ps\" | grep -q 'sleep 600'" "detached sleep is running after the turn ended"
  local p; p=$(wait_passivation lc-D 150); el "passivation after ${p}s"
  local ps2; ps2=$($ENGINE exec lc-D ps -eo pid,ppid,args 2>/dev/null | grep -v ' ps '); if printf '%s' "$ps2" | grep -q 'sleep 600'; then el "detached sleep still alive after passivation"; else el "detached sleep was reaped with the worker at passivation"; fi
  local e; e=$(wait_exit lc-D 200); el "exit after ${e}s: $(cstate lc-D)"; check "[ \"$(cstate lc-D)\" = 'exited|0' ]" "container exits 0 although a detached process existed (limitation documented)"
}

scenario_W() {
  echo "===== W. worker crash: SIGKILL the resident worker → upstream recovery → attach again"
  start_container lc-W || return
  tui lc-W W-tui 'sleep:6' 'send:hello\r' 'expect:ack: hello:60' 'sleep:1' 'send:/quit\r' 'eof' --
  local wp sid; wp=$($ENGINE exec lc-W prime-agent list --json | jq_ 'print(d["sessions"][0]["workerPid"])'); sid=$(faux_calls lc-W | head -1 | python3 -c 'import sys,json; print(json.loads(sys.stdin.readline())["sessionId"])')
  el "killing worker pid $wp"; $ENGINE exec lc-W sh -c "kill -9 $wp"; sleep 8
  local j; j=$($ENGINE exec lc-W prime-agent list --all --json 2>/dev/null); printf '%s' "$j" | jq_ 'm=[s for s in d["sessions"] if s["sessionId"]=="'"$sid"'"]; print("    after kill:", [(s["lifecycle"], s.get("workerState"), s.get("workerPid"), s.get("rosterStatus")) for s in m])'
  local dst; dst=$($ENGINE exec lc-W prime-agent status --json | jq_ 'print(d[0]["status"])'); check "[ \"$dst\" = current ]" "supervisor unaffected by the worker crash (status $dst)"
  tui lc-W W-tui2 'sleep:6' 'send:recovered\r' 'expect:ack: recovered:60' 'sleep:1' 'send:/quit\r' 'eof' -- --resume "$sid"; rc=$?; check "[ $rc -eq 0 ]" "attach after crash works (new worker with fresh runtime context)"
  grep -q 'ack: hello' "$OUT/W-tui2.raw" && ok "transcript survived the crash" || fail "transcript lost"
  local h1 h2; h1=$(faux_calls lc-W | sed -n 1p | python3 -c 'import sys,json;print(json.loads(sys.stdin.readline())["systemPromptSha256"])'); h2=$(faux_calls lc-W | tail -1 | python3 -c 'import sys,json;print(json.loads(sys.stdin.readline())["systemPromptSha256"])')
  check "[ \"$h1\" = \"$h2\" ]" "same system prompt in the recovered worker"
  $ENGINE stop -t 30 lc-W >/dev/null
}

scenario_I() {
  echo "===== I. managed prompt/skills injection via PRIME_AGENT_CONTAINER_CONFIG_DIR reaches initial, recursive, resumed sessions and survives --no-skills"
  mkdir -p "$OUT/cfg/skills/container-test-skill"
  printf 'You are running inside a Docker/Podman container (managed marker 7f3a).\n' >"$OUT/cfg/APPEND_SYSTEM.md"
  printf -- '---\nname: container-test-skill\ndescription: Managed test skill marker 9c2e\n---\n# container-test-skill\nUse marker 9c2e.\n' >"$OUT/cfg/skills/container-test-skill/SKILL.md"
  mkdir -p "$OUT/lc-I/work/.prime/agent"; printf 'PROJECT-APPEND-MARKER-5511\n' >"$OUT/lc-I/work/.prime/agent/APPEND_SYSTEM.md"; printf '# AGENTS\nAGENTS-MD-MARKER-6622\n' >"$OUT/lc-I/work/AGENTS.md"
  start_container lc-I -v "$OUT/cfg:/etc/prime-agent:ro,z" || return
  tui lc-I I-tui 'sleep:6' 'send:hello\r' 'expect:ack: hello:60' 'sleep:1' 'send:/quit\r' 'eof' --
  local pf; pf=$(ls "$OUT/lc-I/work/.faux"/prompt-*-1.txt | head -1)
  check "grep -q 'managed marker 7f3a' \"$pf\"" "APPEND_SYSTEM.md from the managed dir is in the system prompt"
  check "grep -q 'container-test-skill' \"$pf\"" "managed skill is listed in the system prompt"
  check "grep -q 'AGENTS-MD-MARKER-6622' \"$pf\"" "AGENTS.md project context still loads (unaffected by the patch)"
  check "! grep -q 'PROJECT-APPEND-MARKER-5511' \"$pf\"" "documented limitation: <cwd>/.prime/agent/APPEND_SYSTEM.md is NOT auto-discovered while the managed entry exists"
  local p; p=$(wait_passivation lc-I 150); el "passivation after ${p}s"
  tui lc-I I-tui2 'sleep:6' 'send:run-python: h = await rlm("child hello", name="kid"); print("spawned")\r' 'expect:spawned|done:90' 'sleep:20' 'send:/quit\r' 'eof' -- --no-skills
  local calls; calls=$(faux_calls lc-I | wc -l); el "faux calls so far: $calls"
  local child; child=$(faux_calls lc-I | grep 'task from parent.*child hello' | head -1 | python3 -c 'import sys,json; e=json.loads(sys.stdin.readline()); print(e["pid"], e["call"])')
  check "[ -n \"$child\" ]" "child (recursive) session made a model call"
  if [ -n "$child" ]; then local cpf="$OUT/lc-I/work/.faux/prompt-${child% *}-${child#* }.txt"; check "grep -q 'managed marker 7f3a' \"$cpf\"" "managed prompt reached the recursive subagent"; check "grep -q 'container-test-skill' \"$cpf\"" "managed skill reached the recursive subagent"; fi
  local nosk; nosk=$(faux_calls lc-I | grep -v 'task from parent' | tail -1 | python3 -c 'import sys,json; e=json.loads(sys.stdin.readline()); print(e["pid"], e["call"])'); local npf="$OUT/lc-I/work/.faux/prompt-${nosk% *}-${nosk#* }.txt"
  check "grep -q 'container-test-skill' \"$npf\"" "--no-skills does not remove the managed skill (new session started with --no-skills)"
  check "grep -q 'managed marker 7f3a' \"$npf\"" "managed prompt present in the --no-skills session"
  p=$(wait_passivation lc-I 180); el "passivation after ${p}s"; local e; e=$(wait_exit lc-I 200); el "exit after ${e}s: $(cstate lc-I)"
  check "[ \"$(cstate lc-I)\" = 'exited|0' ]" "exit 0"
}

scenario_J() {
  echo "===== J. baked managed prompt/skills (no test config mount): explicit --system-prompt/--append-system-prompt still apply; package install survives the daemon restart"
  start_container lc-J || return
  printf '# AGENTS\nAGENTS-MD-MARKER-6622\n' >"$OUT/lc-J/work/AGENTS.md"
  tui lc-J J-tui 'sleep:6' 'send:hello\r' 'expect:ack: hello:60' 'sleep:1' 'send:/quit\r' 'eof' -- --system-prompt "SYS-MARKER-4242" --append-system-prompt "USER-APPEND-8383"
  local pf; pf=$(ls "$OUT/lc-J/work/.faux"/prompt-*-1.txt | head -1)
  check "grep -q 'inside a Docker/Podman container' \"$pf\"" "baked APPEND_SYSTEM.md is in the system prompt (no config mount)"
  check "grep -q 'container-shell-execution-policy' \"$pf\" && grep -q 'container-package-management' \"$pf\"" "both managed skills are listed in the system prompt"
  check "grep -q 'SYS-MARKER-4242' \"$pf\"" "explicit --system-prompt still applies"
  check "grep -q 'USER-APPEND-8383' \"$pf\"" "explicit --append-system-prompt still applies alongside the managed entry"
  check "grep -q 'AGENTS-MD-MARKER-6622' \"$pf\"" "AGENTS.md still loads"
  check "faux_calls lc-J | head -1 | grep -q '\"hasContainerMarker\":true'" "faux log confirms the container marker"
  # package install through the wrapper: a local package with one skill
  mkdir -p "$OUT/lc-J/work/pkg-test/skills/pkg-test-skill"
  printf '{ "name": "pkg-test", "version": "1.0.0" }\n' >"$OUT/lc-J/work/pkg-test/package.json"
  printf -- '---\nname: pkg-test-skill\ndescription: test package skill marker 5151\n---\n# pkg-test-skill\n' >"$OUT/lc-J/work/pkg-test/skills/pkg-test-skill/SKILL.md"
  local pid0; pid0=$($ENGINE exec lc-J prime-agent status --json | jq_ 'print(d[0]["pid"])')
  local inst; inst=$($ENGINE exec -e PRIME_AGENT_CONTAINER_CLIENT=1 lc-J prime-agent package install /work/pkg-test 2>&1 </dev/null); echo "    package install → $(printf '%s' "$inst" | tr '\n' ' ' | cut -c1-200)"
  sleep 3; local pl; pl=$($ENGINE exec lc-J prime-agent package list 2>&1 </dev/null); echo "    package list → $(printf '%s' "$pl" | tr '\n' ' ' | cut -c1-160)"
  check "printf '%s' \"\$pl\" | grep -q 'pkg-test'" "package list shows the installed package (persisted in /data)"
  local st; st=$($ENGINE exec lc-J prime-agent status --json); local pid1; pid1=$(printf '%s' "$st" | jq_ 'print(d[0]["pid"] if d else "")'); local dst; dst=$(printf '%s' "$st" | jq_ 'print(d[0]["status"] if d else "none")')
  el "daemon pid before install $pid0, after $pid1 ($dst)"
  check "[ \"$dst\" = current ]" "a current default daemon is present after package install"
  logs lc-J | grep -E 'adopt|daemon exited|restart|current' | tail -4 | sed 's/^/    /' | cut -c1-160
  [ "$(cstate lc-J | cut -d'|' -f1)" = running ] && ok "container still running after the package-triggered daemon restart" || fail "container state $(cstate lc-J)"
  # the discovered project APPEND_SYSTEM.md is suppressed by the managed entry (limitation) but can be passed explicitly
  mkdir -p "$OUT/lc-J/work/.prime/agent"; printf 'PROJECT-APPEND-MARKER-5511\n' >"$OUT/lc-J/work/.prime/agent/APPEND_SYSTEM.md"
  check "! grep -q 'PROJECT-APPEND-MARKER-5511' \"$pf\"" "limitation: <cwd>/.prime/agent/APPEND_SYSTEM.md was not auto-discovered in the first session"
  tui lc-J J-tui2 'sleep:6' 'send:again\r' 'expect:ack: again:60' 'sleep:1' 'send:/quit\r' 'eof' -- --append-system-prompt /work/.prime/agent/APPEND_SYSTEM.md
  local pf2; pf2=$(ls -t "$OUT/lc-J/work/.faux"/prompt-*.txt | head -1)
  check "grep -q 'PROJECT-APPEND-MARKER-5511' \"$pf2\"" "the same file passed explicitly with --append-system-prompt <path> is applied (README workaround)"
  check "grep -q 'pkg-test-skill' \"$pf2\"" "the package's skill is listed in the next session's prompt"
  check "grep -q 'inside a Docker/Podman container' \"$pf2\"" "managed prompt still present after the daemon restart"
  local p; p=$(wait_passivation lc-J 180); el "passivation after ${p}s"; local e; e=$(wait_exit lc-J 200); el "exit after ${e}s: $(cstate lc-J)"
  check "[ \"$(cstate lc-J)\" = 'exited|0' ]" "exit 0 after the sessions passivated"
  $ENGINE start lc-J >/dev/null; wait_ready lc-J || return
  pl=$($ENGINE exec lc-J prime-agent package list 2>&1 </dev/null); check "printf '%s' \"\$pl\" | grep -q 'pkg-test'" "package still installed after a container restart"
  $ENGINE stop -t 30 lc-J >/dev/null
}

[ $# -gt 0 ] || set -- G R K M S C D W I J
for s in "$@"; do "scenario_$s"; done
echo "===== done: $pass ok, $failn failed ($OUT)"
for c in lc-G lc-K lc-M lc-S lc-C lc-D lc-W lc-I lc-J; do $ENGINE rm -f $c >/dev/null 2>&1; done
[ "$failn" -eq 0 ]
