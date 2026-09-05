#!/bin/sh
# Fake-engine self-test for the host launcher `prime-agent-container` (POSIX sh).
# Exercises argument screening, engine selection, env-file/timezone/OAuth input
# validation, fence/lock/tombstone transitions, refusal paths, rollback, the
# stopping-gate retry, and the exact engine argv — without any real engine.
#
# usage: launcher-self-test.sh [path/to/prime-agent-container]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LAUNCHER=${1:-$HERE/../../prime-agent-container}
LAUNCHER=$(cd "$(dirname "$LAUNCHER")" && pwd)/$(basename "$LAUNCHER")
FAKE="$HERE/fake-engine.sh"
[ -x "$LAUNCHER" ] || { echo "launcher not executable: $LAUNCHER" >&2; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/launcher-self-test.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
US=$(printf '\037')
NL='
'
pass=0; failn=0
ok()   { pass=$((pass+1)); }
fail() { failn=$((failn+1)); printf '  FAIL [%s] %s\n' "$CASE" "$*"; }
note() { printf '  ok   %s\n' "$*"; }

IMG_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
IMG2_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
NOSCHEMA_ID=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
DEFAULT_IMAGE=ghcr.io/sillynocodecat/prime-agent-docker:latest
DIGEST=ghcr.io/sillynocodecat/prime-agent-docker@sha256:1111111111111111111111111111111111111111111111111111111111111111
PINNED='PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
HOME=/root
LANG=C.UTF-8
LC_ALL=C.UTF-8
TMPDIR=/tmp
TMP=/tmp
TEMP=/tmp
PRIME_AGENT_CODING_AGENT_DIR=/data
PRIME_AGENT_KERNEL_VENV=/opt/prime-agent/kernel-venv
UV_PYTHON_INSTALL_DIR=/opt/prime-agent/python
PRIME_AGENT_CONTAINER_CONFIG_DIR=/etc/prime-agent
PRIME_AGENT_BUILD_ID=81ae3cb34d27d38ee37f9e205a1e73694993b344
PRIME_AGENT_LAUNCHER_PATH=/usr/local/bin/prime-agent
PI_OAUTH_CALLBACK_HOST=0.0.0.0
PI_MCP_OAUTH_CALLBACK_PORT=53700
PI_SKIP_VERSION_CHECK=1'

mk_image() { # $1 id, $2 schema, $3 version, $4 digests
  { printf '%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4"; printf '%s\n' "$PINNED"; printf 'NODE_VERSION=22.23.2\n'; } >"$S/images/$1"
}
reset() { # fresh HOME, workspace, engine state; default image present locally
  rm -rf "$T/home" "$T/ws" "$T/state" "$T/engine.log"
  mkdir -p "$T/home" "$T/ws/my project" "$T/state/images"
  S="$T/state"; : >"$T/engine.log"
  mk_image "$IMG_ID" 1 0.9.1 "$DIGEST"
  mk_image "$IMG2_ID" 1 0.9.2 "ghcr.io/sillynocodecat/prime-agent-docker@sha256:2222222222222222222222222222222222222222222222222222222222222222"
  mk_image "$NOSCHEMA_ID" "" 0.9.1 ""
  printf '%s %s\n' "$DEFAULT_IMAGE" "$IMG_ID" >"$S/refs"
  printf '%s %s\n' "$DIGEST" "$IMG_ID" >"$S/pullable"
  : >"$S/ready"
  WS="$T/ws/my project"
  HOMEDIR="$T/home"
  DATA="$HOMEDIR/prime-agent/data"; CONTROL="$HOMEDIR/prime-agent/control"
}
# run the launcher: run_l [VAR=value ...] -- args...
run_l() {
  envs=""
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs="$envs $1"; shift; done
  [ "${1:-}" = "--" ] && shift
  ( cd "$WS" && env -i PATH="$PATH" HOME="$HOMEDIR" TERM=xterm FAKE_STATE="$S" FAKE_LOG="$T/engine.log" \
      PRIME_AGENT_ENGINE="$FAKE" PRIME_AGENT_ENGINE_KIND=podman PRIME_AGENT_CONTAINER_TEST_TIMEOUTS="2 2 1 2" $envs \
      "$LAUNCHER" "$@" >"$T/out" 2>"$T/err" )
  ST=$?
}
run_nl() { # one VAR=value carrying a newline, then args
  ( cd "$WS" && env -i PATH="$PATH" HOME="$HOMEDIR" TERM=xterm FAKE_STATE="$S" FAKE_LOG="$T/engine.log" \
      PRIME_AGENT_ENGINE="$FAKE" PRIME_AGENT_ENGINE_KIND=podman PRIME_AGENT_CONTAINER_TEST_TIMEOUTS="2 2 1 2" "$1" \
      "$LAUNCHER" >"$T/out" 2>"$T/err" )
  ST=$?
}
expect_status() { [ "$ST" = "$1" ] && ok || fail "exit $ST, expected $1: $(head -3 "$T/err" | tr '\n' ' ')"; }
expect_err() { grep -q -- "$1" "$T/err" && ok || fail "stderr lacks '$1': $(head -3 "$T/err" | tr '\n' ' ')"; }
calls() { cut -d"$US" -f1 "$T/engine.log" | tr '\n' ' '; }
expect_calls() { c=$(calls); case " $c" in *"$1"*) ok ;; *) fail "engine calls '$c' do not contain '$1'" ;; esac; }
expect_no_call() { c=$(calls); case " $c " in *" $1 "*) fail "engine calls '$c' contain forbidden '$1'" ;; *) ok ;; esac; }
last_call_of() { grep "^$1$US" "$T/engine.log" | tail -n 1 | sed 's/PRIME_AGENT_CONTAINER_CLIENT_TOKEN=[0-9a-f]*/PRIME_AGENT_CONTAINER_CLIENT_TOKEN=T/'; }
join() { r=$1; shift; for a in "$@"; do r="$r$US$a"; done; printf '%s\n' "$r"; }
fence_val() { cat "$CONTROL/workspace/$1" 2>/dev/null; }
set_container() { # status exit startedAt imageId managed ws imgref claim id
  printf '%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" >"$S/container"
}
mk_state() { # create the host state tree the way the launcher would
  mkdir -p "$HOMEDIR/prime-agent/data" "$HOMEDIR/prime-agent/control"; chmod 0700 "$HOMEDIR/prime-agent" "$HOMEDIR/prime-agent/data" "$HOMEDIR/prime-agent/control"
}

# ===========================================================================
CASE="validation"
reset
run_l PRIME_AGENT_IMAGE="" -- ; expect_status 64; expect_err "PRIME_AGENT_IMAGE is empty"
run_nl "PRIME_AGENT_IMAGE=a${NL}b"; expect_status 64; expect_err newline
run_l PRIME_AGENT_NO_OAUTH_PORTS=2 -- ; expect_status 64; expect_err "must be exactly 1"
run_l PRIME_AGENT_NO_OAUTH_PORTS=true -- ; expect_status 64
for v in DOCKER_HOST DOCKER_CONTEXT CONTAINER_HOST CONTAINER_CONNECTION PODMAN_HOST; do
  run_l "$v=x" -- ; expect_status 64; expect_err "$v is set"
done
run_l -- --mode daemon; expect_status 64; expect_err reserved
run_l -- --mode=daemon; expect_status 64
run_l -- --daemon-socket /tmp/x; expect_status 64
run_l -- --daemon-socket=/tmp/x; expect_status 64
run_l -- --socket; expect_status 64
run_l -- --socket=/tmp/x; expect_status 64
run_l -- -p hello --mode; expect_status 0   # "--mode" without "daemon" is fine
run_l -- -- --mode daemon; expect_status 0 # after the first standalone -- everything is a literal
run_l "PRIME_AGENT_ENGINE=$T/nope" -- ; expect_status 69; expect_err "not an executable"
run_nl "PRIME_AGENT_ENGINE=x${NL}y"; expect_status 64; expect_err newline
run_nl "PRIME_AGENT_TZ=UTC${NL}x"; expect_status 64
run_nl "PRIME_AGENT_ENV_FILE=$T/a${NL}b"; expect_status 64
run_l PRIME_AGENT_ENGINE=no-such-engine-xyz -- ; expect_status 69; expect_err "not on PATH"
run_l "PRIME_AGENT_TZ=../../etc" -- ; expect_status 64; expect_err "not a valid timezone"
run_l "PRIME_AGENT_TZ=/usr/share/zoneinfo/UTC" -- ; expect_status 64
reset; printf 'A=1\nNODE_OPTIONS=--require /x\n' >"$T/bad.env"; run_l "PRIME_AGENT_ENV_FILE=$T/bad.env" -- ; expect_status 64; expect_err "NODE_OPTIONS"; expect_no_call run
for k in LD_PRELOAD LD_LIBRARY_PATH NODE_PATH PRIME_AGENT_INTERNAL_DAEMON_X PRIME_AGENT_KERNEL_PYTHON PRIME_AGENT_SESSION_DIR PRIME_AGENT_CODING_AGENT_SESSION_DIR PRIME_AGENT_CONTAINER_CLIENT DOCKER_HOST CONTAINER_HOST CONTAINER_CONNECTION PODMAN_HOST CONTAINERS_CONF; do
  printf '# comment\n\n%s=value\n' "$k" >"$T/bad.env"; run_l "PRIME_AGENT_ENV_FILE=$T/bad.env" -- ; expect_status 64; expect_err "$k"
done
run_l "PRIME_AGENT_ENV_FILE=$T/missing.env" -- ; expect_status 64; expect_err "not a readable regular file"
run_l "PRIME_AGENT_ENV_FILE=$T" -- ; expect_status 64
grep -q 'value' "$T/err" && fail "env-file value leaked into diagnostics" || ok
note "validation: image, OAuth flag, remote-engine variables, reserved daemon flags, engine, TZ, env-file keys"

CASE="home-and-workspace"
reset
( cd "$WS" && env -i PATH="$PATH" HOME="relative/home" FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" "$LAUNCHER" >/dev/null 2>"$T/err" ); ST=$?; expect_status 64; expect_err absolute
( cd "$WS" && env -i PATH="$PATH" HOME="/" FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" "$LAUNCHER" >/dev/null 2>"$T/err" ); ST=$?; expect_status 64
( cd "$WS" && env -i PATH="$PATH" HOME="" FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" "$LAUNCHER" >/dev/null 2>"$T/err" ); ST=$?; expect_status 64
( cd / && env -i PATH="$PATH" HOME="$HOMEDIR" FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" "$LAUNCHER" >/dev/null 2>"$T/err" ); ST=$?; expect_status 64; expect_err "refusing to use /"
mkdir -p "$T/ws/colon:dir"; ( cd "$T/ws/colon:dir" && env -i PATH="$PATH" HOME="$HOMEDIR" FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" "$LAUNCHER" >/dev/null 2>"$T/err" ); ST=$?; expect_status 64; expect_err "':'"
mkdir -p "$T/ws/nl${NL}dir"; ( cd "$T/ws/nl${NL}dir" && env -i PATH="$PATH" HOME="$HOMEDIR" FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" "$LAUNCHER" >/dev/null 2>"$T/err" ); ST=$?; expect_status 64; expect_err newline
# workspace inside the state tree, and state tree inside the workspace (via symlinked HOME)
mk_state; mkdir -p "$HOMEDIR/prime-agent/data/sub"; ( cd "$HOMEDIR/prime-agent/data/sub" && env -i PATH="$PATH" HOME="$HOMEDIR" FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" "$LAUNCHER" >/dev/null 2>"$T/err" ); ST=$?; expect_status 73; expect_err "inside the state directory"
( cd "$HOMEDIR" && env -i PATH="$PATH" HOME="$HOMEDIR" FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" "$LAUNCHER" >/dev/null 2>"$T/err" ); ST=$?; expect_status 73; expect_err "inside the workspace"
ln -s "$HOMEDIR" "$T/homelink"; ( cd "$T/homelink" && env -i PATH="$PATH" HOME="$T/homelink" FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" "$LAUNCHER" >/dev/null 2>"$T/err" ); ST=$?; expect_status 73
chmod 0755 "$HOMEDIR/prime-agent/control"; ( cd "$WS" && env -i PATH="$PATH" HOME="$HOMEDIR" FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" "$LAUNCHER" >/dev/null 2>"$T/err" ); ST=$?; expect_status 73; expect_err "mode-0700"; chmod 0700 "$HOMEDIR/prime-agent/control"
rm -rf "$HOMEDIR/prime-agent/data/sub"
note "HOME/workspace rules: relative, /, empty, colon, newline, overlap through symlinks, mode"

CASE="fresh-claim"
reset
run_l -- ; expect_status 0
expect_no_call pull
[ -f "$CONTROL/workspace/complete" ] && ok || fail "fence not complete"
[ "$(fence_val workspace)" = "$WS" ] && ok || fail "fence workspace"
[ "$(fence_val engine)" = podman ] && ok || fail "fence engine"
[ "$(fence_val image)" = "$DEFAULT_IMAGE" ] && ok || fail "fence image"
[ "$(fence_val image-id)" = "$IMG_ID" ] && ok || fail "fence image-id"
[ "$(fence_val image-version)" = 0.9.1 ] && ok || fail "fence image-version"
[ "$(fence_val image-digest)" = "$DIGEST" ] && ok || fail "fence image-digest"
[ "$(fence_val oauth)" = ports ] && ok || fail "fence oauth"
[ -n "$(fence_val tz)" ] && ok || fail "fence tz"
[ -n "$(fence_val token)" ] && ok || fail "fence token"
[ ! -e "$CONTROL/launcher.lock" ] && ok || fail "lock not released before exec"
for f in "$CONTROL/workspace"/*; do case "$(ls -l "$f" | cut -c1-10)" in -rw-------) ;; *) fail "fence file $f not 0600" ;; esac; done; ok
case "$(ls -ld "$DATA" | cut -c1-10)" in drwx------) ok ;; *) fail "data dir mode" ;; esac
TOKEN=$(fence_val token); TZV=$(fence_val tz)
expected=$(join run -d --name prime-agent --init --restart=no --stop-timeout 30 --security-opt no-new-privileges \
  --tmpfs /run/prime-agent-container:rw,mode=0700,nosuid,nodev --tmpfs /tmp:rw,mode=1777,nosuid,nodev \
  -v "$WS:/work:Z" -v "$DATA:/data:Z" -w /work \
  --label io.github.sillynocodecat.prime-agent-docker.managed=true --label "io.github.sillynocodecat.prime-agent-docker.workspace=$WS" \
  --label "io.github.sillynocodecat.prime-agent-docker.image=$DEFAULT_IMAGE" --label "io.github.sillynocodecat.prime-agent-docker.claim=$TOKEN" \
  --label "io.github.sillynocodecat.prime-agent-docker.tz=$TZV" --label io.github.sillynocodecat.prime-agent-docker.oauth=ports \
  -p 127.0.0.1:1455:1455 -p 127.0.0.1:53692:53692 -p 127.0.0.1:53700-53709:53700-53709)
for kv in $PINNED; do expected="$expected$US-e$US$kv"; done
expected="$expected$US-e${US}TZ=$TZV$US-e${US}PRIME_AGENT_CONTAINER_CLIENT=$US$IMG_ID"
[ "$(last_call_of run)" = "$expected" ] && ok || fail "run argv differs:${NL}got: $(last_call_of run | tr "$US" ' ')${NL}exp: $(printf '%s' "$expected" | tr "$US" ' ')"
[ "$(last_call_of exec)" = "$(join exec -i -w /work -e PRIME_AGENT_CONTAINER_CLIENT=1 -e PRIME_AGENT_CONTAINER_CLIENT_TOKEN=T -e TERM=xterm prime-agent /usr/local/bin/prime-agent)" ] && ok || fail "exec argv: $(last_call_of exec | tr "$US" ' ')"
note "fresh claim: fence records, modes, lock released, exact run/exec argv"

CASE="argument-preservation"
reset
run_l -- -p "two words" "" --weird=--mode --socket-ish -- --mode daemon --daemon-socket=x
expect_status 0
[ "$(last_call_of exec)" = "$(join exec -i -w /work -e PRIME_AGENT_CONTAINER_CLIENT=1 -e PRIME_AGENT_CONTAINER_CLIENT_TOKEN=T -e TERM=xterm prime-agent /usr/local/bin/prime-agent -p "two words" "" --weird=--mode --socket-ish -- --mode daemon --daemon-socket=x)" ] && ok || fail "args not preserved: $(last_call_of exec | tr "$US" '|')"
printf 7 >"$S/client-exit"; run_l -- -p x; expect_status 7
printf 130 >"$S/client-exit"; run_l -- ; expect_status 130
rm -f "$S/client-exit"
note "argument preservation (spaces, empty, --, reserved flags after --) and client exit status pass-through"

CASE="env-file-tz-oauth"
reset
printf 'ANTHROPIC_API_KEY=secret-value-xyz\n# c\nPATH=/evil\nTZ=Mars/Olympus\nPRIME_AGENT_CODING_AGENT_DIR=/tmp/steal\n' >"$T/ok.env"
run_l "PRIME_AGENT_ENV_FILE=$T/ok.env" PRIME_AGENT_TZ=Europe/Berlin PRIME_AGENT_NO_OAUTH_PORTS=1 -- ; expect_status 0
r=$(last_call_of run)
case "$r" in *"$US--env-file$US$T/ok.env$US-e${US}PATH=/usr/local/bin"*) ok ;; *) fail "--env-file must precede the pinned -e values: $(printf %s "$r" | tr "$US" ' ')" ;; esac
case "$r" in *"-e${US}TZ=Europe/Berlin"*) ok ;; *) fail "TZ override" ;; esac
case "$r" in *"-e${US}PRIME_AGENT_CODING_AGENT_DIR=/data"*) ok ;; *) fail "/data pinned" ;; esac
case "$r" in *"-p$US"*) fail "ports published despite PRIME_AGENT_NO_OAUTH_PORTS=1" ;; *) ok ;; esac
case "$r" in *secret-value*) fail "env-file value leaked into argv" ;; *) ok ;; esac
grep -q secret-value "$T/err" "$CONTROL"/workspace/* 2>/dev/null && fail "env-file value leaked into stderr/control" || ok
[ "$(fence_val env-file)" = "$T/ok.env" ] && ok || fail "fence env-file"
[ "$(fence_val env-cksum)" = "$(cksum <"$T/ok.env" | cut -d' ' -f1,2)" ] && ok || fail "fence env-cksum"
[ "$(fence_val tz)" = Europe/Berlin ] && ok || fail "fence tz"
[ "$(fence_val oauth)" = none ] && ok || fail "fence oauth none"
reset; run_l TZ=:Asia/Tokyo -- ; expect_status 0; [ "$(fence_val tz)" = Asia/Tokyo ] && ok || fail "host TZ precedence (got $(fence_val tz))"
reset; run_l PRIME_AGENT_TZ=UTC TZ=Asia/Tokyo -- ; expect_status 0; [ "$(fence_val tz)" = UTC ] && ok || fail "PRIME_AGENT_TZ beats TZ"
note "env-file after/before ordering, pinned overrides, no value leaks, TZ precedence, OAuth mode"

CASE="reuse-running"
reset
run_l -- ; expect_status 0
: >"$T/engine.log"
run_l PRIME_AGENT_IMAGE=other:tag -- -c; expect_status 0
expect_no_call run; expect_no_call start; expect_no_call rm; expect_calls exec
expect_err "keeping the recorded"
note "running same-workspace container is reused; image change only warns"

CASE="refuse-other-workspace"
mkdir -p "$T/ws/other"; ( cd "$T/ws/other" && env -i PATH="$PATH" HOME="$HOMEDIR" FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" PRIME_AGENT_ENGINE_KIND=podman "$LAUNCHER" >/dev/null 2>"$T/err" ); ST=$?
expect_status 73; expect_err "another workspace is active"; expect_err "$WS"; expect_no_call run; expect_no_call rm; expect_no_call start
[ -f "$S/container" ] && ok || fail "container mutated"
note "running different-workspace container is refused with the recorded path"

CASE="clean-release"
set_container exited 0 "2026-09-05T12:00:00Z" "$IMG_ID" true "$WS" "$DEFAULT_IMAGE" "$(fence_val token)" fakectr1
mkdir -p "$DATA/sessions"; : >"$DATA/sessions/x.jsonl"   # data is now non-empty
: >"$T/engine.log"
( cd "$T/ws/other" && env -i PATH="$PATH" HOME="$HOMEDIR" TERM=xterm FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" PRIME_AGENT_ENGINE_KIND=podman PRIME_AGENT_CONTAINER_TEST_TIMEOUTS="2 2 1 2" "$LAUNCHER" >/dev/null 2>"$T/err" ); ST=$?
expect_status 0; expect_calls "rm"; expect_calls run
[ "$(fence_val workspace)" = "$T/ws/other" ] && ok || fail "new fence for the other workspace"
[ -n "$(fence_val release-token)" ] && ok || fail "release token recorded in the replacement fence"
[ ! -e "$CONTROL/clean-release" ] && ok || fail "tombstone should be gone after the replacement started"
c=$(calls); case "$c" in *"rm "*"run "*) ok ;; *) fail "rm must precede run: $c" ;; esac
note "exit-0 container released, tombstone consumed by a claim over non-empty /data"

CASE="unclean-exit"
reset; mkdir -p "$T/ws/other"; run_l -- ; expect_status 0
set_container exited 5 "2026-09-05T12:00:00Z" "$IMG_ID" true "$WS" "$DEFAULT_IMAGE" "$(fence_val token)" fakectr1
: >"$T/engine.log"; run_l -- ; expect_status 0; expect_calls start; expect_no_call rm; expect_no_call run
[ -f "$CONTROL/workspace/complete" ] && ok || fail "fence retained"
set_container exited 5 "2026-09-05T12:00:00Z" "$IMG_ID" true "$WS" "$DEFAULT_IMAGE" "$(fence_val token)" fakectr1
: >"$T/engine.log"; ( cd "$T/ws/other" && env -i PATH="$PATH" HOME="$HOMEDIR" FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" PRIME_AGENT_ENGINE_KIND=podman PRIME_AGENT_CONTAINER_TEST_TIMEOUTS="2 2 1 2" "$LAUNCHER" >/dev/null 2>"$T/err" ); ST=$?
expect_status 73; expect_err "uncleanly"; expect_no_call rm; expect_no_call start; expect_no_call run
( cd "$WS" && env -i PATH="$PATH" HOME="$HOMEDIR" FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" PRIME_AGENT_ENGINE_KIND=docker PRIME_AGENT_CONTAINER_TEST_TIMEOUTS="2 2 1 2" "$LAUNCHER" >/dev/null 2>"$T/err" ); ST=$?
expect_status 73; expect_err "use that engine"
note "unclean exit: same workspace restarts, other workspace/engine refused, fence retained"

CASE="container-removed-recovery"
reset; printf 'X=1\n' >"$T/r.env"; run_l "PRIME_AGENT_ENV_FILE=$T/r.env" PRIME_AGENT_TZ=Asia/Tokyo -- ; expect_status 0
rm -f "$S/container"; : >"$T/engine.log"
run_l -- ; expect_status 0; expect_calls run
r=$(last_call_of run); case "$r" in *"-e${US}TZ=Asia/Tokyo"*"$IMG_ID") ok ;; *) fail "recovery must reuse recorded tz/image: $(printf %s "$r" | tr "$US" ' ')" ;; esac
case "$r" in *"--env-file$US$T/r.env"*) ok ;; *) fail "recovery must reuse the recorded env-file" ;; esac
case "$r" in *"claim=$(fence_val token)"*) ok ;; *) fail "recovery keeps the claim token" ;; esac
rm -f "$S/container"; printf 'X=2\n' >"$T/r.env"; : >"$T/engine.log"; run_l -- ; expect_status 73; expect_err "changed since"; expect_no_call run
printf 'X=1\n' >"$T/r.env"
# recorded image pruned locally, no digest pull source → refused with the recorded identity
rm -f "$S/container"; mkdir -p "$S/pullable-images"; mv "$S/images/$IMG_ID" "$S/pullable-images/$IMG_ID"; : >"$S/pullable"; : >"$T/engine.log"
run_l -- ; expect_status 70; expect_err "cannot pull"; expect_no_call run
# same, but the immutable digest is pullable → restored, identity verified, container recreated
printf '%s %s\n' "$DIGEST" "$IMG_ID" >"$S/pullable"; : >"$T/engine.log"
run_l -- ; expect_status 0; expect_calls "pull"; expect_calls run
[ "$(last_call_of pull)" = "$(join pull "$DIGEST")" ] && ok || fail "must pull the recorded digest, got $(last_call_of pull | tr "$US" ' ')"
note "external removal: recreated from recorded settings; changed env-file refused; recorded image restored by digest"

CASE="rollback"
reset; printf none >"$S/run-fails"; run_l -- ; expect_status 70; expect_err "hint: if a callback port"
[ ! -e "$CONTROL/workspace" ] && ok || fail "fence must be rolled back when run failed without a container"
[ ! -e "$CONTROL/launcher.lock" ] && ok || fail "lock released"
reset; printf created >"$S/run-fails"; run_l -- ; expect_status 70; expect_calls rm
[ ! -e "$CONTROL/workspace" ] && ok || fail "fence rolled back after removing a never-started container"
reset; printf running >"$S/run-fails"; run_l -- ; expect_status 70; expect_no_call rm
[ -f "$CONTROL/workspace/complete" ] && ok || fail "fence retained when a started container exists"
# tombstone survives a failed retry and authorizes the next attempt
reset; run_l -- ; expect_status 0; set_container exited 0 "2026-09-05T12:00:00Z" "$IMG_ID" true "$WS" "$DEFAULT_IMAGE" "$(fence_val token)" fakectr1; : >"$DATA/x"
printf none >"$S/run-fails"; run_l -- ; expect_status 70; [ -f "$CONTROL/clean-release/complete" ] && ok || fail "tombstone retained for retry"; [ ! -e "$CONTROL/workspace" ] && ok || fail "failed claim rolled back"
rm -f "$S/run-fails"; run_l -- ; expect_status 0; [ ! -e "$CONTROL/clean-release" ] && ok || fail "tombstone consumed on the retry"
# readiness never comes: started container is retained, never-started one is rolled back
reset; rm -f "$S/ready"; run_l -- ; expect_status 70; expect_err "did not become ready"; [ -f "$CONTROL/workspace/complete" ] && ok || fail "fence retained after a started-but-unready container"
note "rollback: fence only, never-started container + fence, retained when started; tombstone retry; readiness timeout"

CASE="refusals"
reset; mk_state; : >"$DATA/leftover"; run_l -- ; expect_status 73; expect_err "not empty but no workspace fence"; expect_no_call run
reset; set_container running 0 "2026-09-05T12:00:00Z" "$IMG_ID" "" "" "" "" foreign1; run_l -- ; expect_status 73; expect_err "not managed"; expect_no_call rm; expect_no_call start
reset; set_container running 0 "2026-09-05T12:00:00Z" "$IMG_ID" true "$WS" "$DEFAULT_IMAGE" tok fakectr1; run_l -- ; expect_status 73; expect_err "fence $CONTROL/workspace is missing"; expect_no_call rm
reset; run_l -- ; expect_status 0; set_container running 0 "2026-09-05T12:00:00Z" "$IMG_ID" true "$WS" "$DEFAULT_IMAGE" wrong-claim fakectr1; run_l -- ; expect_status 73; expect_err "does not match the fence"
reset; run_l -- ; expect_status 0; set_container exited 0 "2026-09-05T12:00:00Z" "$IMG_ID" true "/elsewhere" "$DEFAULT_IMAGE" "$(fence_val token)" fakectr1; : >"$T/engine.log"; run_l -- ; expect_status 73; expect_no_call rm
reset; printf 'nosch %s\n' "$NOSCHEMA_ID" >>"$S/refs"; run_l PRIME_AGENT_IMAGE=nosch -- ; expect_status 73; expect_err "runtime-schema"; [ ! -e "$CONTROL/workspace" ] && ok || fail "no fence for a non-managed image"
reset; run_l PRIME_AGENT_IMAGE=unknown:img -- ; expect_status 69; expect_err "cannot pull"; [ ! -e "$CONTROL/workspace" ] && ok || fail "no fence when the image cannot be pulled"
reset; printf 'newimg %s\n' "$IMG2_ID" >>"$S/pullable"; run_l PRIME_AGENT_IMAGE=newimg -- ; expect_status 0; expect_calls pull; [ "$(fence_val image-id)" = "$IMG2_ID" ] && ok || fail "pulled image id recorded"
reset; run_l -- ; expect_status 0; printf '9\n' >"$CONTROL/workspace/version"; run_l -- ; expect_status 73; expect_err "fence version"
reset; run_l -- ; expect_status 0; rm "$CONTROL/workspace/complete"; run_l -- ; expect_status 73; expect_err incomplete
reset; run_l -- ; expect_status 0; printf 'a\nb\n' >"$CONTROL/workspace/workspace"; run_l -- ; expect_status 73; expect_err malformed
reset; run_l -- ; expect_status 0; rm "$CONTROL/workspace/token"; ln -s /etc/hostname "$CONTROL/workspace/token"; run_l -- ; expect_status 73
reset; : >"$S/engine-down"; run_l -- ; expect_status 69; expect_err "engine running"
note "refusals: unfenced data, unmanaged container, missing/mismatched/malformed/incomplete/old fence, bad image, engine down"

CASE="lock"
reset; mk_state
mkdir -p "$CONTROL/launcher.lock"; printf '%s 999999 1\n' "$(cat /proc/sys/kernel/random/boot_id)" >"$CONTROL/launcher.lock/owner"
run_l -- ; expect_status 0; [ ! -e "$CONTROL/launcher.lock" ] && ok || fail "stale lock reclaimed and released"
reset; mk_state
sleep 4 & HOLDER=$!
mkdir -p "$CONTROL/launcher.lock"; printf '%s %s %s\n' "$(cat /proc/sys/kernel/random/boot_id)" "$HOLDER" "$(sed 's/^.*) //' /proc/$HOLDER/stat | cut -d' ' -f20)" >"$CONTROL/launcher.lock/owner"
run_l -- ; expect_status 75; expect_err "owner alive"; expect_no_call run
wait $HOLDER 2>/dev/null; run_l -- ; expect_status 0
note "lock: stale owner reclaimed; live owner waited for, then temporary failure; released afterwards"

CASE="stopping-gate"
reset; run_l -- ; expect_status 0
: >"$S/stopping"; printf '200\n0\n' >"$S/client-exits"; : >"$T/engine.log"
( : >"$S/stopping"; sleep 1; rm -f "$S/stopping" ) &
run_l -- ; expect_status 0
[ "$(grep -c "^exec$US-i" "$T/engine.log")" = 2 ] && ok || fail "client should have been retried exactly once (got $(grep -c "^exec$US-i" "$T/engine.log"))"
: >"$S/stopping"; printf '200\n200\n' >"$S/client-exits"; run_l -- ; expect_status 75; rm -f "$S/stopping" "$S/client-exits"
# gate then container exits 0 → state machine re-entered: release + new claim
run_l -- ; expect_status 0
printf '200\n' >"$S/client-exits"; : >"$S/stopping"
( sleep 1; set_container exited 0 "2026-09-05T12:00:00Z" "$IMG_ID" true "$WS" "$DEFAULT_IMAGE" "$(fence_val token)" fakectr1; rm -f "$S/stopping" ) &
: >"$T/engine.log"; run_l -- ; expect_status 0; expect_calls "rm"; expect_calls run
wait
note "stopping gate: one in-place retry, second gate → 75, gate+exit re-enters the state machine"

CASE="launcher-death"
# (a) died after recording the clean release but before `rm`: tombstone + exited-0 container, no fence
reset; run_l -- ; expect_status 0
set_container exited 0 "2026-09-05T12:00:00Z" "$IMG_ID" true "$WS" "$DEFAULT_IMAGE" "$(fence_val token)" fakectr1
mkdir -m 0700 -p "$CONTROL/clean-release"; cp "$CONTROL/workspace"/* "$CONTROL/clean-release"/; printf 'fakectr1\n' >"$CONTROL/clean-release/container"; printf '0\n' >"$CONTROL/clean-release/exit-code"; rm -rf "$CONTROL/workspace"
: >"$DATA/x"; : >"$T/engine.log"; run_l -- ; expect_status 0; expect_calls "rm"; expect_calls run; expect_err "finishing the recorded clean release"
[ ! -e "$CONTROL/clean-release" ] && ok || fail "tombstone consumed after the finished release"
# (a') same, but the container id does not match the tombstone → nothing is removed
reset; run_l -- ; expect_status 0
set_container exited 0 "2026-09-05T12:00:00Z" "$IMG_ID" true "$WS" "$DEFAULT_IMAGE" "$(fence_val token)" otherctr
mkdir -m 0700 -p "$CONTROL/clean-release"; cp "$CONTROL/workspace"/* "$CONTROL/clean-release"/; printf 'fakectr1\n' >"$CONTROL/clean-release/container"; rm -rf "$CONTROL/workspace"
: >"$T/engine.log"; run_l -- ; expect_status 73; expect_no_call rm; expect_err "fence $CONTROL/workspace is missing"
# (d) died after writing the replacement fence (release-token recorded) but before `run`: tombstone still present
reset; run_l -- ; expect_status 0
set_container exited 0 "2026-09-05T12:00:00Z" "$IMG_ID" true "$WS" "$DEFAULT_IMAGE" "$(fence_val token)" fakectr1; : >"$DATA/x"
run_l -- ; expect_status 0          # releases + reclaims; tombstone consumed
[ ! -e "$CONTROL/clean-release" ] && ok || fail "tombstone gone after a proven start"
mkdir -m 0700 -p "$CONTROL/clean-release"; printf '%s\n' "$(fence_val release-token)" >"$CONTROL/clean-release/token"; for f in workspace engine; do cp "$CONTROL/workspace/$f" "$CONTROL/clean-release/$f"; done; printf 'oldctr\n' >"$CONTROL/clean-release/container"; : >"$CONTROL/clean-release/complete"
rm -f "$S/container"; : >"$T/engine.log"; run_l -- ; expect_status 0; expect_calls run
[ ! -e "$CONTROL/clean-release" ] && ok || fail "leftover tombstone matching the fence's release-token removed after recovery"
# (e) died after `run` before readiness: running container + fence + leftover tombstone
mkdir -m 0700 -p "$CONTROL/clean-release"; printf '%s\n' "$(fence_val release-token)" >"$CONTROL/clean-release/token"; for f in workspace engine; do cp "$CONTROL/workspace/$f" "$CONTROL/clean-release/$f"; done; printf 'oldctr\n' >"$CONTROL/clean-release/container"; : >"$CONTROL/clean-release/complete"
: >"$T/engine.log"; run_l -- ; expect_status 0; expect_no_call run; [ ! -e "$CONTROL/clean-release" ] && ok || fail "leftover tombstone removed on reuse"
# a leftover private claim directory from a killed launcher is dropped under the lock
reset; mk_state; mkdir -p "$CONTROL/claim.deadbeef"; : >"$CONTROL/claim.deadbeef/token"; run_l -- ; expect_status 0; [ ! -e "$CONTROL/claim.deadbeef" ] && ok || fail "stale claim dir removed"
note "launcher death: after tombstone/before rm, after fence/before run, after run/before ready, stale claim dir"

CASE="race-and-kill"
# two launchers in the same workspace: the lock serializes them; the loser reuses the winner's container
reset; printf 2 >"$S/run-delay"
( cd "$WS" && env -i PATH="$PATH" HOME="$HOMEDIR" TERM=xterm FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" PRIME_AGENT_ENGINE_KIND=podman PRIME_AGENT_CONTAINER_TEST_TIMEOUTS="2 10 1 2" "$LAUNCHER" >"$T/outA" 2>"$T/errA" ); echo $? >"$T/stA" &
sleep 1
run_l -- ; STB=$ST; wait; STA=$(cat "$T/stA")
[ "$STA" = 0 ] && [ "$STB" = 0 ] && ok || fail "race: A=$STA B=$STB ($(head -2 "$T/errA" "$T/err" | tr '\n' ' '))"
[ "$(grep -c "^run$US" "$T/engine.log")" = 1 ] && ok || fail "exactly one run call in a race (got $(grep -c "^run$US" "$T/engine.log"))"
[ "$(grep -c "^exec$US-i" "$T/engine.log")" = 2 ] && ok || fail "both clients ran"
[ ! -e "$CONTROL/launcher.lock" ] && ok || fail "lock released after the race"
rm -f "$S/run-delay"
# launcher killed while removing a cleanly exited container: the release is recorded first, the next launcher finishes it
reset; run_l -- ; expect_status 0
set_container exited 0 "2026-09-05T12:00:00Z" "$IMG_ID" true "$WS" "$DEFAULT_IMAGE" "$(fence_val token)" fakectr1; : >"$DATA/x"; printf 5 >"$S/rm-delay"
( cd "$WS" && exec env -i PATH="$PATH" HOME="$HOMEDIR" TERM=xterm FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" PRIME_AGENT_ENGINE_KIND=podman PRIME_AGENT_CONTAINER_TEST_TIMEOUTS="2 2 1 2" "$LAUNCHER" >/dev/null 2>&1 ) & KP=$!
sleep 2; kill -9 "$KP" 2>/dev/null; wait "$KP" 2>/dev/null; pkill -9 -f "fake-engine.sh rm" 2>/dev/null; sleep 1
[ -f "$CONTROL/clean-release/complete" ] && [ ! -e "$CONTROL/workspace" ] && ok || fail "after the kill: tombstone recorded, fence gone"
rm -f "$S/rm-delay"; : >"$T/engine.log"; run_l -- ; expect_status 0
[ "$(fence_val release-token)" = "$(sed -n 1p "$CONTROL/clean-release/token" 2>/dev/null || echo consumed)" ] || [ ! -e "$CONTROL/clean-release" ] && ok || fail "next launcher completed the release"
[ ! -e "$CONTROL/clean-release" ] && ok || fail "tombstone consumed by the next claim"
[ ! -e "$CONTROL/launcher.lock" ] && ok || fail "stale lock of the killed launcher reclaimed"
note "race: one run, loser reuses; kill during rm: tombstone survives, next launcher completes the transition"

CASE="hangup"
# the terminal disappears: SIGHUP reaches the launcher and its engine client; the launcher hangs up its own in-container client (by token) and exits 129
reset; run_l -- ; expect_status 0; printf 10 >"$S/client-delay"; : >"$T/engine.log"
( cd "$WS" && exec env -i PATH="$PATH" HOME="$HOMEDIR" TERM=xterm FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" PRIME_AGENT_ENGINE_KIND=podman PRIME_AGENT_CONTAINER_TEST_TIMEOUTS="2 2 1 2" setsid "$LAUNCHER" >/dev/null 2>"$T/err" ) & LP=$!
i=0; while [ $i -lt 20 ] && ! grep -q "^exec$US-i" "$T/engine.log"; do sleep 1; i=$((i+1)); done; sleep 1
LPID=$(pgrep -f "^/bin/sh $LAUNCHER" | head -n 1); [ -n "$LPID" ] || LPID=$(pgrep -f "$LAUNCHER" | head -n 1)
kill -HUP -- "-$LPID" 2>/dev/null || kill -HUP "$LPID"; wait "$LP" 2>/dev/null; ST=$?
tok=$(grep "^exec$US-i" "$T/engine.log" | tail -n 1 | sed 's/.*PRIME_AGENT_CONTAINER_CLIENT_TOKEN=\([0-9a-f]*\).*/\1/')
[ -n "$tok" ] && grep "kill -HUP" "$T/engine.log" | grep -q "$US$tok\$" && ok || fail "hang-up must target the client token ($tok): $(grep -c 'kill -HUP' "$T/engine.log") cleanup calls"
[ "$ST" = 129 ] && ok || fail "launcher exit after SIGHUP: $ST (expected 129)"
rm -f "$S/client-delay"
note "hang-up: SIGHUP to the launcher group hangs up exactly its own client, exit 129"

CASE="symlink-install"
reset; mkdir -p "$T/bin"; ln -s "$LAUNCHER" "$T/bin/prime-agent"
( cd "$WS" && env -i PATH="$T/bin:$PATH" HOME="$HOMEDIR" FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" PRIME_AGENT_ENGINE_KIND=podman PRIME_AGENT_CONTAINER_TEST_TIMEOUTS="2 2 1 2" prime-agent -p hello >/dev/null 2>"$T/err" ); ST=$?; expect_status 0
[ "$(last_call_of exec | tr "$US" ' ' | sed 's/.*prime-agent //')" = "-p hello" ] && ok || fail "symlinked invocation forwards args"
note "installed as ~/.local/bin/prime-agent symlink"

CASE="tty-and-term"
reset
( cd "$WS" && env -i PATH="$PATH" HOME="$HOMEDIR" FAKE_STATE="$S" FAKE_LOG="$T/engine.log" PRIME_AGENT_ENGINE="$FAKE" PRIME_AGENT_ENGINE_KIND=docker COLORTERM=truecolor "$LAUNCHER" >/dev/null 2>"$T/err" </dev/null ); ST=$?; expect_status 0
r=$(last_call_of run); case "$r" in *"--security-opt${US}no-new-privileges=true"*) ok ;; *) fail "docker spelling of no-new-privileges" ;; esac
e=$(last_call_of exec); case "$e" in *"exec$US-i$US-w"*) ok ;; *) fail "piped stdin should use -i only" ;; esac
case "$e" in *"-e${US}COLORTERM=truecolor"*) ok ;; *) fail "COLORTERM forwarded" ;; esac
# bash-as-sh sets TERM=dumb when unset, so only an empty forwarded TERM would be wrong
case "$e" in *"-e${US}TERM=$US"*) fail "empty TERM forwarded: $e" ;; *) ok ;; esac
[ "$(fence_val engine)" = docker ] && ok || fail "fence engine docker"
note "docker spelling, -i without a TTY, TERM/COLORTERM forwarding"

printf '\nlauncher self-test: %d checks passed, %d failed\n' "$pass" "$failn"
[ "$failn" -eq 0 ]
