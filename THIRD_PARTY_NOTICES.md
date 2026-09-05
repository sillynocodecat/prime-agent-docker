# Third-party notices

This container image redistributes the following software. This repository
itself declares no license; the notices below cover only the redistributed
components. Every license text listed here is installed in the image at the
path shown, so the image is self-describing.

| Component | Version | License | Text in the image |
| --- | --- | --- | --- |
| [Prime Agent](https://github.com/PrimeIntellect-ai/prime-agent) (`@earendil-works/*` workspaces, bundled skills, `prime-agent-runtime`) | pinned by `PRIME_AGENT_VERSION` / `PRIME_AGENT_REVISION` in the Dockerfile | MIT (Mario Zechner, Prime Intellect) | `/usr/share/licenses/prime-agent/LICENSE` (copy of `/opt/prime-agent/LICENSE`) |
| Prime Agent npm production dependencies | as resolved by upstream's `package-lock.json` | per package | `/opt/prime-agent/node_modules/<package>/` keeps each package's own `package.json` license field and shipped `LICENSE`/`NOTICE` files |
| [Node.js](https://nodejs.org) (from `docker.io/library/node:22-trixie-slim`) | floating 22.x | MIT and the licenses listed in the Node.js LICENSE file | `/usr/local/LICENSE` |
| npm and Yarn (shipped by the Node base image, unused at runtime) | as shipped by the base image | Artistic-2.0 (npm), BSD-2-Clause (Yarn) | `/usr/local/lib/node_modules/npm/LICENSE`, `/opt/yarn-v*/LICENSE` |
| [uv](https://github.com/astral-sh/uv) (from `ghcr.io/astral-sh/uv`) | pinned by `UV_VERSION` | MIT or Apache-2.0 | `/usr/share/licenses/uv/LICENSE-MIT`, `/usr/share/licenses/uv/LICENSE-APACHE` |
| CPython managed by uv ([python-build-standalone](https://github.com/astral-sh/python-build-standalone)) | 3.11.x as requested by upstream's kernel bootstrap | PSF-2.0 plus the licenses of its bundled libraries | `/opt/prime-agent/python/cpython-*/lib/python3.11/LICENSE.txt` |
| Python packages in the kernel venv (`rlm`, `dill`, requests, httpx, pandas, numpy, scipy, pydantic, ...) | as resolved by upstream's kernel bootstrap | per package | `/opt/prime-agent/kernel-venv/lib/python3.11/site-packages/<dist>.dist-info/` keeps each distribution's `METADATA` and any `LICENSE`/`licenses/` files |
| [Podman](https://github.com/podman-container-tools/podman) remote client (`podman-remote-static-linux_amd64`) | pinned by `PODMAN_VERSION`, digest-verified | Apache-2.0 | `/usr/share/licenses/podman/LICENSE` |
| Debian packages (`bash`, `ca-certificates`, `curl`, `git`, `openssh-client`, `ripgrep`, `fd-find`, `procps`, `iproute2`, `tzdata`, `tar`, `gzip` and their dependencies) | Debian trixie, refreshed on every rebuild | per package | `/usr/share/doc/<package>/copyright` |

The container-owned files (`Dockerfile`, `build/`, `rootfs/`,
`prime-agent-container.patch`, the host launcher) are not covered by any of the
licenses above. The patch modifies Prime Agent source that remains under its
MIT license; the modified files are part of the staged `/opt/prime-agent` tree.

A copy of this file is installed at
`/usr/share/licenses/prime-agent-docker/THIRD_PARTY_NOTICES.md`.
