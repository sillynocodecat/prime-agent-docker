#!/bin/bash
# End-to-end launcher test against a real engine and the real image (TODO §6).
# usage: ENGINE=podman|docker IMAGE=<ref> launcher-e2e.sh
# Uses a private HOME and workspaces under $OUT; never touches ~/prime-agent.
set -u
ENGINE=${ENGINE:-podman}; IMAGE=${IMAGE:?IMAGE is required}
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
L="$REPO/prime-agent-container"
# The launcher takes its state root from HOME, so the test gives it a private
# HOME; rootless Podman must still find the real user's storage, hence the XDG
# variables point at the real locations.
REAL_HOME=$HOME
XDG_ENV=(XDG_DATA_HOME="${XDG_DATA_HOME:-$REAL_HOME/.local/share}" XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$REAL_HOME/.config}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}")
OUT=${OUT:-${TMPDIR:-/tmp}/launcher-e2e-$ENGINE-$(date +%H%M%S)}; mkdir -p "$OUT"
# Rootful Docker leaves root-owned files under /data; clean through a container.
clean_data() { rm -rf "$H/prime-agent/data" 2>/dev/null || $ENGINE run --rm -v "$H/prime-agent:/s:Z" --entrypoint sh "$IMAGE" -c 'rm -rf /s/data' >/dev/null 2>&1; mkdir -m 0700 "$H/prime-agent/data"; }
H="$OUT/home"; mkdir -p "$H" "$OUT/ws1" "$OUT/ws2" "$OUT/ws3"
cp "$REPO/build/ci/faux-provider/faux-provider.js" "$OUT/ws1/"; cp "$REPO/build/ci/faux-provider/faux-provider.js" "$OUT/ws2/"
pass=0; failn=0; T0=$(date +%s)
ok() { echo "  ok   $*"; pass=$((pass+1)); }; fail() { echo "  FAIL $*"; failn=$((failn+1)); }
check() { if eval "$1"; then ok "$2"; else fail "$2"; fi; }
el() { echo "[$(( $(date +%s)-T0 ))s] $*"; }
launch() { # launch <workspace> [VAR=value...] -- args...; stdin from /dev/null unless STDIN_FROM set
  ws=$1; shift; envs=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift || true
  ( cd "$ws" && env -i PATH="$PATH" HOME="$H" TERM=xterm "${XDG_ENV[@]}" PRIME_AGENT_ENGINE="$ENGINE" PRIME_AGENT_IMAGE="$IMAGE" "${envs[@]}" "$L" "$@" ) >"$OUT/out" 2>"$OUT/err" </dev/null
  ST=$?; return $ST
}
ins() { $ENGINE inspect --format "$1" prime-agent 2>/dev/null; }
fence() { cat "$H/prime-agent/control/workspace/$1" 2>/dev/null; }
cstate() { $ENGINE inspect --format '{{.State.Status}}|{{.State.ExitCode}}' prime-agent 2>/dev/null; }
wait_exit() { local t=$(date +%s); while [ "$(cstate | cut -d'|' -f1)" = running ] && [ $(( $(date +%s)-t )) -lt "$1" ]; do sleep 2; done; echo $(( $(date +%s)-t )); }
$ENGINE rm -f prime-agent >/dev/null 2>&1
VER=$($ENGINE image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")

echo "===== 1. fresh claim from ws1 ($ENGINE, $IMAGE)"
launch "$OUT/ws1" -- --version; el "launcher exit $ST"
check '[ $ST -eq 0 ]' "launcher exit 0 for --version"
check 'grep -qx "$VER" "$OUT/err" || grep -qx "$VER" "$OUT/out"' "CLI --version printed $VER (non-TTY stdin → stderr)"
check '[ -f "$H/prime-agent/control/workspace/complete" ]' "fence complete"
check '[ "$(fence workspace)" = "$OUT/ws1" ]' "fence workspace = ws1"
check '[ "$(fence engine)" = "$ENGINE" ]' "fence engine"
check '[ "$(fence image)" = "$IMAGE" ]' "fence image ref"
IMGID=$($ENGINE image inspect --format '{{.Id}}' "$IMAGE" | sed 's/^sha256://'); check '[ "$(fence image-id)" = "$IMGID" ]' "fence image-id = local image id"
check '[ "$(fence image-version)" = "$VER" ]' "fence image-version = $VER"
check '[ -n "$(fence tz)" ]' "fence tz = $(fence tz)"
check '[ "$(cstate)" = "running|0" ]' "container running"
check '[ "$(ins "{{index .Config.Labels \"io.github.sillynocodecat.prime-agent-docker.managed\"}}")" = true ]' "managed label"
check '[ "$(ins "{{index .Config.Labels \"io.github.sillynocodecat.prime-agent-docker.workspace\"}}")" = "$OUT/ws1" ]' "workspace label"
check '[ "$(ins "{{index .Config.Labels \"io.github.sillynocodecat.prime-agent-docker.claim\"}}")" = "$(fence token)" ]' "claim label = fence token"
check '[ "$(ins "{{.Config.StopTimeout}}")" = 30 ]' "stop timeout 30"
check '[ "$(ins "{{.HostConfig.RestartPolicy.Name}}")" = no ]' "restart policy no"
check 'ins "{{.HostConfig.SecurityOpt}}" | grep -q no-new-privileges' "no-new-privileges: $(ins '{{.HostConfig.SecurityOpt}}')"
check 'ins "{{.HostConfig.Init}}{{.HostConfig.Tmpfs}}" | grep -q "prime-agent-container"' "init + tmpfs: $(ins '{{.HostConfig.Init}} {{.HostConfig.Tmpfs}}')"
# Docker reports the :Z option in Binds; Podman rewrites it, so the relabel itself is the proof there.
check 'ins "{{.HostConfig.Binds}}" | grep -q ":/work:Z" || ls -dZ "$OUT/ws1" | grep -q container_file_t' "private :Z relabel on /work (binds: $(ins '{{.HostConfig.Binds}}' | tr -d '\n' | cut -c1-80)…)"
check 'ins "{{.HostConfig.Binds}}" | grep -q ":/data:Z" || ls -dZ "$H/prime-agent/data" | grep -q container_file_t' "private :Z relabel on /data"
check 'ins "{{.HostConfig.PortBindings}}" | grep -q 127.0.0.1' "OAuth ports bound to loopback"
check 'ins "{{range .Config.Env}}{{.}}{{\"\\n\"}}{{end}}" | grep -q "^TZ=$(fence tz)$"' "container TZ env = fence tz"
check 'ins "{{range .Config.Env}}{{.}}{{\"\\n\"}}{{end}}" | grep -q "^PRIME_AGENT_CONTAINER_CLIENT=$"' "empty client marker pinned"
check '[ ! -e "$H/prime-agent/control/launcher.lock" ]' "lock released"
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = Enforcing ]; then
  check 'ls -dZ "$OUT/ws1" | grep -q container_file_t' "SELinux: workspace relabeled container_file_t ($(ls -dZ "$OUT/ws1" | cut -d" " -f1))"
fi
CID1=$(ins '{{.Id}}')

echo "===== 2. reuse from ws1, refuse ws2, client status pass-through"
launch "$OUT/ws1" -- status --json; check '[ $ST -eq 0 ] && grep -q "\"status\": \"current\"" "$OUT/out"' "second launcher reuses the container (status --json through it)"
check '[ "$(ins "{{.Id}}")" = "$CID1" ]' "same container"
launch "$OUT/ws2" -- --version; check '[ $ST -eq 73 ] && grep -q "another workspace is active" "$OUT/err" && grep -q "$OUT/ws1" "$OUT/err"' "ws2 refused with the recorded path (exit $ST)"
launch "$OUT/ws1" -- schedule cancel no-such-job-id; el "failing CLI command → exit $ST"; check '[ $ST -ne 0 ] && [ $ST -ne 73 ] && [ $ST -ne 70 ] && [ $ST -ne 64 ] && [ $ST -ne 69 ] && [ $ST -ne 75 ]' "CLI failure status preserved ($ST)"

echo "===== 3. TUI through the launcher: hello → ack → /quit; Ctrl-D; double Ctrl-C"
tui() { timeout 150 python3 "$REPO/build/ci/lifecycle/tui.py" --log "$OUT/$1.raw" "${@:2}" >"$OUT/$1.txt" 2>&1; }
( cd "$OUT/ws1" && env -i PATH="$PATH" HOME="$H" TERM=xterm "${XDG_ENV[@]}" PRIME_AGENT_ENGINE="$ENGINE" PRIME_AGENT_IMAGE="$IMAGE" \
  timeout 150 python3 "$REPO/build/ci/lifecycle/tui.py" --log "$OUT/tui1.raw" 'sleep:8' 'send:hello\r' 'expect:ack: hello:60' 'sleep:1' 'send:/quit\r' 'eof' -- "$L" -e /work/faux-provider.js --model faux/faux-1 >"$OUT/tui1.txt" 2>&1 ); rc=$?
check '[ $rc -eq 0 ]' "interactive session via launcher (-it): hello → ack → /quit ($(grep -c 'expect.*: ok' "$OUT/tui1.txt") expects ok)"
check '[ "$(cstate)" = "running|0" ]' "container still running after the client left"
( cd "$OUT/ws1" && env -i PATH="$PATH" HOME="$H" TERM=xterm "${XDG_ENV[@]}" PRIME_AGENT_ENGINE="$ENGINE" PRIME_AGENT_IMAGE="$IMAGE" \
  timeout 100 python3 "$REPO/build/ci/lifecycle/tui.py" --log "$OUT/tui2.raw" 'sleep:8' 'send:\x04' 'eof' -- "$L" -e /work/faux-provider.js --model faux/faux-1 >"$OUT/tui2.txt" 2>&1 ); rc=$?
check '[ $rc -eq 0 ]' "Ctrl-D on an empty editor exits the client"
( cd "$OUT/ws1" && env -i PATH="$PATH" HOME="$H" TERM=xterm "${XDG_ENV[@]}" PRIME_AGENT_ENGINE="$ENGINE" PRIME_AGENT_IMAGE="$IMAGE" \
  timeout 100 python3 "$REPO/build/ci/lifecycle/tui.py" --log "$OUT/tui3.raw" 'sleep:8' 'send:\x03' 'sleep:1' 'send:\x03' 'eof' -- "$L" -e /work/faux-provider.js --model faux/faux-1 >"$OUT/tui3.txt" 2>&1 ); rc=$?
check '[ $rc -eq 0 ]' "double Ctrl-C exits the client"
check 'grep -qi "again to exit" "$OUT/tui3.raw"' "first Ctrl-C only shows the exit hint"
check '[ "$(cstate)" = "running|0" ]' "container running after TUI exits"

echo "===== 4. auto-quiescence → exit 0 → next launcher (ws2) releases and claims"
e=$(wait_exit 200); el "container exited after ${e}s: $(cstate)"
check '[ "$(cstate)" = "exited|0" ]' "service exit 0"
launch "$OUT/ws2" -- --version; el "ws2 launcher exit $ST"
check '[ $ST -eq 0 ] && grep -q "finished cleanly" "$OUT/err"' "ws2 claimed after the clean release"
check '[ "$(fence workspace)" = "$OUT/ws2" ]' "fence now ws2"
check '[ -n "$(fence release-token)" ]' "release token recorded"
check '[ ! -e "$H/prime-agent/control/clean-release" ]' "tombstone consumed"
check '[ "$(ins "{{.Id}}")" != "$CID1" ]' "new container"
check '[ -d "$H/prime-agent/data/sessions" ]' "/data kept (sessions survive the release)"

echo "===== 5. unclean stop → same workspace restarts, other refused"
$ENGINE stop -t 30 prime-agent >/dev/null; check '[ "$(cstate)" = "exited|75" ]' "engine stop → 75"
launch "$OUT/ws1" -- --version; check '[ $ST -eq 73 ] && grep -q "uncleanly" "$OUT/err"' "ws1 refused after ws2's unclean stop"
CID2=$(ins '{{.Id}}')
launch "$OUT/ws2" -- --version; check '[ $ST -eq 0 ] && grep -q "restarting the stopped container" "$OUT/err"' "ws2 restarts its stopped container"
check '[ "$(ins "{{.Id}}")" = "$CID2" ] && [ "$(cstate)" = "running|0" ]' "same container restarted"

echo "===== 6. external removal → recreated from the fence"
$ENGINE rm -f prime-agent >/dev/null
launch "$OUT/ws2" -- --version; check '[ $ST -eq 0 ] && grep -q "recreating the removed container" "$OUT/err"' "recreated"
check '[ "$(ins "{{index .Config.Labels \"io.github.sillynocodecat.prime-agent-docker.claim\"}}")" = "$(fence token)" ]' "recreated container carries the same claim token"
check '[ "$(ins "{{.Image}}" | sed s/^sha256://)" = "$(fence image-id)" ]' "recreated with the recorded image id"

echo "===== 7. port conflict → rollback → PRIME_AGENT_NO_OAUTH_PORTS=1 retry"
$ENGINE rm -f prime-agent >/dev/null; rm -rf "$H/prime-agent/control/workspace"; clean_data
python3 -c 'import socket,time,sys; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",1455)); s.listen(1); sys.stdout.write("bound\n"); sys.stdout.flush(); time.sleep(60)' >"$OUT/port.log" & PP=$!
sleep 1; grep -q bound "$OUT/port.log" || fail "could not occupy 127.0.0.1:1455"
launch "$OUT/ws3" -- --version; el "conflict launcher exit $ST"
check '[ $ST -eq 70 ] && grep -q "PRIME_AGENT_NO_OAUTH_PORTS=1" "$OUT/err"' "port conflict → exit 70 with the retry hint"
check '[ ! -e "$H/prime-agent/control/workspace" ]' "fresh claim rolled back"
check '[ "$(cstate)" = "" ]' "no container left behind"
launch "$OUT/ws3" PRIME_AGENT_NO_OAUTH_PORTS=1 -- --version; check '[ $ST -eq 0 ]' "retry without OAuth ports succeeds"
check '[ "$(fence oauth)" = none ] && [ -z "$(ins "{{.HostConfig.PortBindings}}" | tr -d "map[]")" ]' "no port bindings, fence oauth=none"
kill $PP 2>/dev/null; wait $PP 2>/dev/null
$ENGINE stop -t 30 prime-agent >/dev/null; $ENGINE rm -f prime-agent >/dev/null

echo "===== done ($ENGINE): $pass ok, $failn failed — $OUT"
[ "$failn" -eq 0 ]
