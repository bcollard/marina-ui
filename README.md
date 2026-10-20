# Marina UI

> macOS companion app for the [marina](https://github.com/bcollard/marina) CLI. Visualize your VM, kind clusters, and registry mirrors — without leaving the menu bar.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)

---

## Why

`marina` runs a Lima-based macOS VM that hosts your kind clusters and registry mirrors. The CLI is great for one-off commands, but to keep an eye on **what's running, how loaded it is, and which LoadBalancer services are reachable**, you'd otherwise be juggling `marina cluster list`, `kubectl get`, `kubectl top`, `ssh top`, and `du -sh ~/.marina/registry-cache/*` in different terminals.

Marina UI rolls all of that into one native SwiftUI app:

- **VM dashboard** — live CPU% and memory graphs, sampled every 5 s over the SSH ControlMaster socket marina already maintains.
- **Per-cluster view** — node + pod inventory, helm-installable `metrics-server`, live CPU/memory time series, top pods by CPU and memory.
- **LoadBalancer service browser** — lists every `Service` with externalIPs, probes each `(ip, port)` over TCP, and renders a clickable link when reachable.
- **Registry mirror inspector** — cache disk usage and image count for each mirror in `~/.marina/registry-cache/`.
- **Cluster creation, live** — create a cluster and watch its `kind` log stream in-app (with a cancel button); a "delete all" action tears the whole set down.
- **Labels & fleets** — shows each cluster's node labels (fleet, region/zone, …), badges its fleet, and can add a label to a running cluster (`marina cluster label`, needs marina 0.1.35+).
- **kubectl context** — badges the active cluster and switches `current-context` from the cluster view.
- **Docker containers** — optionally lists the containers you run in the VM: everything that isn't a kind node or a registry mirror. Containers are grouped by `docker compose` project and titled by service, with ports, labels, a log tail, and start/stop/restart per container.
- **Bind-mount reality check** — docker resolves a `-v` source *inside* the VM, so binding a host path marina doesn't share doesn't fail: dockerd creates it empty in the guest and your container silently sees nothing. Each container's mounts are checked against the directories the VM actually shares (`vm.mounts`, marina 0.1.59+) and flagged when they don't reach your Mac.
- **Volume mounts** — lists the directories of your Mac the VM can see, read from the live Lima instance, and warns when your config has changes the VM hasn't picked up yet.
- **Diagnostics** — runs `marina doctor` in-app, showing each health check with its fix command (copyable), and applying the repairs marina can make itself. Also surfaces the HTTP proxy and extra CA trust marina applies to dockerd, the mirrors and every kind node.
- **App integrity** — verifies that this copy of Marina is genuinely Developer-ID signed and notarized by Apple, checkable offline against Apple's public roots.
- **Stays live** — auto-refreshes when the VM starts/stops or clusters are created/deleted out-of-band (e.g. via the CLI).
- **Single-VM model** — marina only ever runs one VM, so the sidebar surfaces that one VM at the top and the rest of the workspace beneath it.

## Install

```bash
brew tap bcollard/marina
brew install --cask marina-ui
```

Or grab the latest `MarinaUI.dmg` (or `.zip`) from the [Releases](https://github.com/bcollard/marina-ui/releases) page.

Requirements:

- macOS 14 Sonoma or later
- A working [marina](https://github.com/bcollard/marina) install — at least one VM under `~/.marina/`
- `kubectl` and `helm` on PATH (used for cluster operations; marina pulls these in)

The release build is signed with a Developer ID and notarized by Apple, so Gatekeeper opens it without warnings.

## How it works

No backend, no daemon, no new state — Marina UI reads from the same places marina itself uses:

```
┌─────────────────────────┐    ┌──────────────────────┐    ┌──────────────────────┐
│ ~/.marina/<vm>/         │    │ kind clusters        │    │ ~/.marina/           │
│   lima.yaml, ssh.config │    │   (kubeconfig)       │    │   registry-cache/    │
│   vz.pid (liveness)     │    │                      │    │                      │
└──────────┬──────────────┘    └──────────┬───────────┘    └──────────┬───────────┘
           │                              │                           │
           ▼                              ▼                           ▼
  InstanceDiscovery /        KubeClient (kubectl shell-out)     RegistryCacheInspector
  GuestSSH (ssh -F)          MetricsClient (kubectl raw)        + DirectorySize (du -sk)
           │                              │                           │
           └──────────────┬───────────────┴───────────────────────────┘
                          ▼
                       AppModel
                          │
                          ▼
                       SwiftUI
```

- **VM stats** come straight from `/proc/stat` and `/proc/meminfo` inside the guest, read over SSH every 5 s. CPU% is computed as `1 − idleΔ/totalΔ` (idle includes iowait).
- **Cluster metrics** come from the Kubernetes `metrics.k8s.io` API. If `metrics-server` isn't installed yet, the Metrics tab offers a one-click Helm install with `--set args[0]=--kubelet-insecure-tls` (required for kind's self-signed kubelet).
- **LoadBalancer reachability** is probed via `NWConnection` from the host — actual TCP, not a static CIDR check.
- **Cache size** uses `du -sk`; image count walks the Docker registry v2 layout (`_manifests/tags/*/current/link` for tags, `_manifests` dirs for repos).
- **Containers** are listed with one `docker ps` in the guest over that same SSH socket. kind nodes are identified by the `io.x-k8s.kind.cluster` label and mirrors by the names in your marina config, so both are filtered out; what's left is grouped by `com.docker.compose.project`.
- **Diagnostics** parses `marina doctor -o json`; **app integrity** runs `codesign`, `spctl` and `stapler validate` against the running bundle. Notarization is decided by the stapled ticket, not by Gatekeeper's verdict — which means nothing on a Mac where assessment has been turned off.

See [`CLAUDE.md`](CLAUDE.md) for the full architecture notes (file-by-file map, polling cadences, why we shell out to `kubectl` rather than using a native Swift Kubernetes client).

## Build from source

```bash
git clone https://github.com/bcollard/marina-ui
cd marina-ui
./build.sh                                                    # → .build/bundler/apps/MarinaUI/MarinaUI.app (ad-hoc signed)
cp -R .build/bundler/apps/MarinaUI/MarinaUI.app /Applications/
open /Applications/MarinaUI.app
```

Requires Xcode (for the Swift 6 toolchain) and [swift-bundler](https://github.com/moreSwift/swift-bundler).

### Cutting a release

```bash
# Bump `version` in Bundler.toml first.
./scripts/release.sh
# → .build/bundler/apps/MarinaUI/MarinaUI.{zip,dmg}
# → both signed with Developer ID, notarized, stapled, Gatekeeper-verified
# → prints a ready-to-paste cask block for bcollard/homebrew-marina
```

The script requires:

- Developer ID Application cert in the login keychain.
- A `notarytool` keychain profile (default `marina-notary`, from an App Store Connect API key):

  ```bash
  xcrun notarytool store-credentials marina-notary \
    --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>
  ```

- `brew install create-dmg` for the DMG step.

Then upload the produced `MarinaUI.dmg` and `MarinaUI.zip` to a new GitHub release, and paste the cask block into `Casks/marina-ui.rb` in the [`bcollard/homebrew-marina`](https://github.com/bcollard/homebrew-marina) tap.

## Related

- [marina](https://github.com/bcollard/marina) — the Go CLI this app companions.
- [swift-bundler](https://github.com/moreSwift/swift-bundler) — turns SwiftPM executable packages into proper macOS app bundles.
