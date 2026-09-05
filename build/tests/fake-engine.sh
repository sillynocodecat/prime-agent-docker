#!/bin/sh
# Fake container engine for the launcher self-test (POSIX sh).
#
# State lives under $FAKE_STATE:
#   container            9 lines: status exit startedAt imageId managed workspace imageRef claim id
#   images/<id>          lines: id schema version digests, then KEY=VALUE env lines
#   refs                 lines: "<ref> <id>" (references that resolve locally)
#   pullable             lines: "<ref> <id>" (references `pull` can fetch)
#   ready                exists → the container's readiness marker is present
#   stopping             exists → the stopping gate is set
#   run-fails            exists → `run` fails; contents: "none" | "created" | "running"
#   client-exit          exit status for a client exec (default 0)
#   client-exits         optional queue of statuses, one per line (consumed first)
#   engine-down          exists → every inspect fails like a stopped daemon
#   run-delay, rm-delay  seconds to sleep inside `run` / `rm` (race and kill tests)
#   client-delay         seconds a client exec sleeps before exiting (hang-up test)
# Every invocation appends one line to $FAKE_LOG: arguments joined with U+001F.
set -u
S=${FAKE_STATE:?}; L=${FAKE_LOG:?}
# one log line per call: arguments joined with U+001F, embedded newlines as U+001E
{ i=0; for a in "$@"; do i=$((i+1)); [ "$i" -gt 1 ] && printf '\037'; printf '%s' "$a" | tr '\n' '\036'; done; printf '\n'; } >>"$L"
cmd=$1; shift
[ -e "$S/engine-down" ] && { echo "Cannot connect to the engine daemon" >&2; exit 1; }

fields() { # print fields 1..n of $S/container by line numbers given
  for n in "$@"; do sed -n "${n}p" "$S/container"; done
}

case "$cmd" in
  inspect)
    # inspect --type container --format FMT name
    fmt=$4; name=$5
    [ "$name" = prime-agent ] || { echo "Error: no such container $name" >&2; exit 125; }
    [ -f "$S/container" ] || { echo "Error: no such container \"$name\"" >&2; exit 125; }
    case "$fmt" in *State.Status*State.ExitCode*State.StartedAt*.Image*managed*workspace*.image*claim*.Id*) ;; *) echo "fake-engine: unexpected container format: $fmt" >&2; exit 99 ;; esac
    cat "$S/container"; exit 0 ;;
  image)
    # image inspect --format FMT ref
    [ "$1" = inspect ] || { echo "fake-engine: unsupported image subcommand $1" >&2; exit 99; }
    fmt=$3; ref=$4
    case "$fmt" in *.Id*runtime-schema*image.version*RepoDigests*Config.Env*) ;; *) echo "fake-engine: unexpected image format: $fmt" >&2; exit 99 ;; esac
    id=
    if [ -f "$S/images/$ref" ]; then id=$ref
    else id=$(awk -v r="$ref" '$1==r {print $2; exit}' "$S/refs" 2>/dev/null); fi
    [ -n "$id" ] && [ -f "$S/images/$id" ] || { echo "Error: $ref: image not known" >&2; exit 125; }
    cat "$S/images/$id"; exit 0 ;;
  pull)
    ref=$1
    id=$(awk -v r="$ref" '$1==r {print $2; exit}' "$S/pullable" 2>/dev/null)
    # a pruned image comes back from the "registry" copy under pullable-images/
    [ -n "$id" ] && [ ! -f "$S/images/$id" ] && [ -f "$S/pullable-images/$id" ] && cp "$S/pullable-images/$id" "$S/images/$id"
    [ -n "$id" ] && [ -f "$S/images/$id" ] || { echo "Error: cannot pull $ref" >&2; exit 125; }
    grep -q "^$ref " "$S/refs" 2>/dev/null || printf '%s %s\n' "$ref" "$id" >>"$S/refs"
    echo "pulled $ref"; exit 0 ;;
  run)
    # parse labels and the image (last argument)
    managed=; ws=; imgref=; claim=; name=
    prev=
    for a in "$@"; do
      case "$prev" in
        --label) case "$a" in
          io.github.sillynocodecat.prime-agent-docker.managed=*) managed=${a#*=} ;;
          io.github.sillynocodecat.prime-agent-docker.workspace=*) ws=${a#*=} ;;
          io.github.sillynocodecat.prime-agent-docker.image=*) imgref=${a#*=} ;;
          io.github.sillynocodecat.prime-agent-docker.claim=*) claim=${a#*=} ;;
        esac ;;
        --name) name=$a ;;
      esac
      prev=$a; last=$a
    done
    [ -f "$S/container" ] && { echo "Error: container name $name is already in use" >&2; exit 125; }
    [ -f "$S/run-delay" ] && sleep "$(cat "$S/run-delay")"
    if [ -f "$S/run-fails" ]; then
      mode=$(cat "$S/run-fails")
      case "$mode" in
        created) printf '%s\n' created 0 "0001-01-01 00:00:00 +0000 UTC" "$last" "$managed" "$ws" "$imgref" "$claim" fakectr1 >"$S/container" ;;
        running) printf '%s\n' running 0 "2026-09-05T12:00:00Z" "$last" "$managed" "$ws" "$imgref" "$claim" fakectr1 >"$S/container" ;;
      esac
      echo "Error: run failed (fake)" >&2; exit 125
    fi
    printf '%s\n' running 0 "2026-09-05T12:00:00Z" "$last" "$managed" "$ws" "$imgref" "$claim" fakectr1 >"$S/container"
    echo fakectr1; exit 0 ;;
  start)
    [ -f "$S/container" ] || { echo "Error: no such container" >&2; exit 125; }
    { echo running; sed -n '2p' "$S/container"; echo "2026-09-05T12:30:00Z"; sed -n '4,9p' "$S/container"; } >"$S/container.new"
    mv "$S/container.new" "$S/container"; echo prime-agent; exit 0 ;;
  rm)
    [ -f "$S/container" ] || { echo "Error: no such container" >&2; exit 125; }
    [ -f "$S/rm-delay" ] && sleep "$(cat "$S/rm-delay")"
    rm -f "$S/container"; echo prime-agent; exit 0 ;;
  logs) echo "fake log line"; exit 0 ;;
  exec)
    # exec [-it|-i] -w /work -e ... name cmd args...
    case "$*" in
      *"test -f /run/prime-agent-container/ready"*) [ -e "$S/ready" ] && exit 0 || exit 1 ;;
      *"test -e /run/prime-agent-container/stopping"*) [ -e "$S/stopping" ] && exit 0 || exit 1 ;;
      *"kill -HUP"*) exit 0 ;;   # launcher hang-up of its own client (logged like every call)
    esac
    [ -f "$S/client-delay" ] && sleep "$(cat "$S/client-delay")"
    [ -f "$S/container" ] && [ "$(sed -n 1p "$S/container")" = running ] || { echo "Error: container not running" >&2; exit 125; }
    if [ -s "$S/client-exits" ]; then st=$(sed -n 1p "$S/client-exits"); sed -i '1d' "$S/client-exits" 2>/dev/null || { tail -n +2 "$S/client-exits" >"$S/ce.tmp"; mv "$S/ce.tmp" "$S/client-exits"; }
    else st=$(cat "$S/client-exit" 2>/dev/null || echo 0); fi
    [ -e "$S/stopping" ] && [ "$st" = 0 ] && st=200
    echo "client ran"; exit "$st" ;;
  *) echo "fake-engine: unsupported command $cmd" >&2; exit 99 ;;
esac
