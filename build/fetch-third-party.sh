#!/usr/bin/env bash
# Fetch stage for the Prime Agent container image: the static podman-remote
# client and the redistribution license texts for the binaries this image adds
# on top of the base image (Podman, uv). Everything is pinned by version and
# SHA-256; nothing is installed unless every digest matches.
#
# Required environment:
#   PODMAN_VERSION                plain X.Y.Z (v6.1.1 audited)
#   PODMAN_REMOTE_AMD64_SHA256    digest of podman-remote-static-linux_amd64.tar.gz
#   PODMAN_LICENSE_SHA256         digest of the Podman LICENSE at that tag
#   UV_VERSION                    plain X.Y.Z (0.12.9 audited)
#   UV_LICENSE_MIT_SHA256         digest of uv LICENSE-MIT at that tag
#   UV_LICENSE_APACHE_SHA256      digest of uv LICENSE-APACHE at that tag
# Optional:
#   OUT_DIR (default /out)        receives bin/podman-remote and licenses/...
set -euo pipefail

die() { printf 'fetch-third-party: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

OUT_DIR=${OUT_DIR:-/out}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

plain_version() { # $1 = name, $2 = value
  case "$2" in
    *[!0-9.]*|.*|*.|*..*|"") die "$1 must be a plain X.Y.Z version, got: $2" ;;
  esac
  [ "$(printf '%s' "$2" | tr -cd '.' | wc -c)" -eq 2 ] || die "$1 must be X.Y.Z, got: $2"
}
hex64() { # $1 = name, $2 = value
  case "$2" in
    *[!0-9a-f]*|"") die "$1 must be 64 lowercase hexadecimal characters" ;;
  esac
  [ "${#2}" -eq 64 ] || die "$1 must be exactly 64 characters, got ${#2}"
}

podman_version=${PODMAN_VERSION:?PODMAN_VERSION is required}
podman_version=${podman_version#v}
plain_version PODMAN_VERSION "$podman_version"
uv_version=${UV_VERSION:?UV_VERSION is required}
plain_version UV_VERSION "$uv_version"
for name in PODMAN_REMOTE_AMD64_SHA256 PODMAN_LICENSE_SHA256 UV_LICENSE_MIT_SHA256 UV_LICENSE_APACHE_SHA256; do
  hex64 "$name" "${!name:?$name is required}"
done

arch=$(dpkg --print-architecture)
[ "$arch" = "amd64" ] || die "unsupported Debian architecture: $arch (only amd64 is built)"
for tool in curl tar gzip sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done

fetch() { # $1 = url, $2 = destination
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -o "$2" "$1"
}
verify() { # $1 = file, $2 = expected sha256
  local actual
  actual=$(sha256sum "$1" | cut -d' ' -f1)
  [ "$actual" = "$2" ] || die "digest mismatch for $(basename "$1"): expected $2, got $actual"
  printf '  ok   sha256 %s  %s\n' "$actual" "$(basename "$1")"
}

# ---------------------------------------------------------------------------
# podman-remote: pinned digest AND the release's own shasums must agree, so a
# silently re-uploaded asset is caught even if this file's pin were edited.
# ---------------------------------------------------------------------------
log "podman-remote v${podman_version} (amd64)"
base="https://github.com/podman-container-tools/podman/releases/download/v${podman_version}"
archive="podman-remote-static-linux_${arch}.tar.gz"
fetch "$base/shasums" "$WORK/shasums"
listed=$(awk -v name="$archive" '$2 == name { print $1 }' "$WORK/shasums")
[ -n "$listed" ] || die "release shasums has no entry for $archive"
[ "$listed" = "$PODMAN_REMOTE_AMD64_SHA256" ] || die "release shasums lists $listed for $archive, pinned $PODMAN_REMOTE_AMD64_SHA256"
fetch "$base/$archive" "$WORK/$archive"
verify "$WORK/$archive" "$PODMAN_REMOTE_AMD64_SHA256"
members=$(tar -tzf "$WORK/$archive")
[ "$members" = "bin/podman-remote-static-linux_${arch}" ] || die "unexpected archive members:
$members"
mkdir -p "$OUT_DIR/bin"
tar -xzf "$WORK/$archive" -C "$WORK" "bin/podman-remote-static-linux_${arch}"
install -m 0755 "$WORK/bin/podman-remote-static-linux_${arch}" "$OUT_DIR/bin/podman-remote"
# A static client must run without any engine socket and must report the pinned
# version; the check runs here, in the same architecture the image targets.
reported=$("$OUT_DIR/bin/podman-remote" --version)
case "$reported" in
  *" ${podman_version}"*|*" ${podman_version}") printf '  ok   %s\n' "$reported" ;;
  *) die "podman-remote --version reported '$reported', expected version ${podman_version}" ;;
esac

# ---------------------------------------------------------------------------
# License texts at the exact tags the binaries were built from.
# ---------------------------------------------------------------------------
log "License texts"
mkdir -p "$OUT_DIR/licenses/podman" "$OUT_DIR/licenses/uv"
fetch "https://raw.githubusercontent.com/podman-container-tools/podman/v${podman_version}/LICENSE" "$OUT_DIR/licenses/podman/LICENSE"
verify "$OUT_DIR/licenses/podman/LICENSE" "$PODMAN_LICENSE_SHA256"
grep -q 'Apache License' "$OUT_DIR/licenses/podman/LICENSE" || die "Podman LICENSE is not the expected Apache text"
fetch "https://raw.githubusercontent.com/astral-sh/uv/${uv_version}/LICENSE-MIT" "$OUT_DIR/licenses/uv/LICENSE-MIT"
verify "$OUT_DIR/licenses/uv/LICENSE-MIT" "$UV_LICENSE_MIT_SHA256"
grep -q '^MIT License' "$OUT_DIR/licenses/uv/LICENSE-MIT" || die "uv LICENSE-MIT is not the expected MIT text"
fetch "https://raw.githubusercontent.com/astral-sh/uv/${uv_version}/LICENSE-APACHE" "$OUT_DIR/licenses/uv/LICENSE-APACHE"
verify "$OUT_DIR/licenses/uv/LICENSE-APACHE" "$UV_LICENSE_APACHE_SHA256"
grep -q 'Apache License' "$OUT_DIR/licenses/uv/LICENSE-APACHE" || die "uv LICENSE-APACHE is not the expected Apache text"
chmod 0644 "$OUT_DIR"/licenses/*/*

log "fetched: $(find "$OUT_DIR" -type f | sort | tr '\n' ' ')"
