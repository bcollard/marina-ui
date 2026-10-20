# Marina UI — Architecture Notes

A native macOS app that reads marina state directly (no CLI shell-out for state), talks to the guest VM over the SSH ControlMaster socket marina already maintains, and uses `kubectl`/`helm` shell-outs for cluster operations.

- **Bundle id:** `dev.bcollard.MarinaUI`
- **Display name:** Marina
- **Target:** macOS 14+
- **Toolchain:** Swift 6, SwiftPM executable target
- **Distribution:** Developer-ID-signed + notarized DMG via the [`bcollard/homebrew-marina`](https://github.com/bcollard/homebrew-marina) tap. Built with [swift-bundler](https://github.com/moreSwift/swift-bundler) (config in `Bundler.toml`).


## Renamed from Klimax UI (v0.3.0)

The app was Klimax UI (`dev.bcollard.KlimaxUI`, cask `klimax-ui`) until the CLI's
klimax → marina rename. Identifiers follow the CLI exactly: `~/.marina`, the
`marina` binary, `marina.run/fleet`, `managed-by=marina`, `marina-dns*` containers,
`default/marina-wildcard-tls`. The bundle id changed, so preferences start fresh.
The notarytool keychain profile keeps its old default name `klimax-notary` — it
lives in the keychain, not in this repo. The tap needs `cask_renames.json`
`{"klimax-ui": "marina-ui"}` once `Casks/marina-ui.rb` is published.

---

## Quick start

```bash
./build.sh                                                # → .build/bundler/apps/MarinaUI/MarinaUI.app (ad-hoc signed)
cp -R .build/bundler/apps/MarinaUI/MarinaUI.app /Applications/
open /Applications/MarinaUI.app
```

For a signed + notarized release, use `./scripts/release.sh` (see [Release](#build-and-release)).

---

## Project layout

```
marina-ui/
├── Package.swift                       # SwiftPM, macOS 14, executable target, Yams dep
├── Bundler.toml                        # swift-bundler config; source of truth for Info.plist
├── build.sh                            # dev path: swift-bundler bundle + ad-hoc sign
├── scripts/release.sh                  # full Developer ID release flow
├── Sources/MarinaUI/
│   ├── MarinaUIApp.swift               # @main, WindowGroup, NSApp activationPolicy hack
│   ├── AppAssets.swift                 # loads marina-logo.png from Bundle.module
│   ├── AppModel.swift                  # @MainActor @Observable, all state + polling tasks
│   ├── Models/
│   │   ├── Instance.swift              # VM struct: name, dir, runtime, ssh, lima config
│   │   ├── Cluster.swift               # KindCluster: name, num, apiPort, kubeconfigPath
│   │   ├── MarinaConfig.swift          # mirrors ~/.marina/_config/config.yaml
│   │   ├── KubeTypes.swift             # KubeNode/Pod/Deployment/Service decodables
│   │   ├── Metrics.swift               # cluster metric samples + ring-buffer history
│   │   ├── VMMetrics.swift             # VM sample + history (raw /proc/stat ticks for CPU%)
│   │   ├── AppSettings.swift           # @Observable prefs (visibility + poll cadences), UserDefaults-backed
│   │   ├── LogRecord.swift             # LogScope enum + LogRecord for scoped action logs
│   │   ├── DoctorReport.swift          # decodes `marina doctor -o json` (stable check ids)
│   │   ├── MarinaStatus.swift         # decodes `marina status -o json` — VM host mounts, local DNS state
│   │   ├── LocalDNS.swift              # dns list records, ca status, wildcard coverage, name resolution, ExternalDNS state, IPv4 CIDR
│   │   ├── DockerContainer.swift       # guest container, compose membership, classification
│   │   └── SidebarSelection.swift      # enum: .cluster(name) | .mirror(name) | .container(id) | nil
│   ├── Services/
│   │   ├── InstanceDiscovery.swift     # scans ~/.marina/, reads vz.pid liveness, lima.yaml
│   │   ├── SSHConfigParser.swift       # hand-parses OpenSSH config from ssh.config
│   │   ├── GuestSSH.swift              # ssh -F shell-out; reads /proc/stat, /proc/meminfo
│   │   ├── ProcessRunner.swift         # async Process wrapper with PATH search
│   │   ├── MarinaCLI.swift             # wraps `marina cluster list/status/doctor/dns list/ca status -o json`, up/down, create/delete, dns/ca attach, ca secret/cert
│   │   ├── KubeClient.swift            # kubectl shell-out: nodes/pods/services/deployments
│   │   ├── Helm.swift                  # helm repo add/update/install metrics-server
│   │   ├── DockerClient.swift          # guest `docker ps`(+inspect labels)/logs/lifecycle over GuestSSH
│   │   ├── CodeSignatureCheck.swift    # codesign + spctl + stapler on the running .app bundle
│   │   ├── MetricsClient.swift         # kubectl get --raw /apis/metrics.k8s.io/v1beta1/{nodes,pods}
│   │   ├── QuantityParser.swift        # k8s quantity strings → millicores / MiB
│   │   ├── TCPProbe.swift              # NWConnection probe with 1.5s timeout
│   │   ├── DirectorySize.swift         # du -sk wrapper
│   │   └── RegistryCacheInspector.swift # counts tags + repos in Docker registry v2 layout
│   ├── Views/
│   │   ├── RootView.swift              # NavigationSplitView dispatcher
│   │   ├── SidebarView.swift           # VM card + clusters + mirrors + containers sections
│   │   ├── OverviewDetailView.swift    # home dashboard with cluster/mirror/container cards + VM charts
│   │   ├── ClusterDetailView.swift     # Info / Services / Metrics tab picker
│   │   ├── ServicesTabView.swift       # LoadBalancer services with per-port TCP probes
│   │   ├── MirrorDetailView.swift      # mirror config + cache storage + usage hint
│   │   ├── MetricsChartsView.swift     # cluster CPU/mem charts + top pods table
│   │   ├── VMChartsView.swift          # VM CPU%/mem charts (Swift Charts + hover tooltips)
│   │   ├── SettingsView.swift          # ⌘, preferences window: Visibility/Refresh/Diagnostics/About
│   │   ├── DiagnosticsTabView.swift    # marina doctor checks + app integrity block
│   │   ├── ContainerDetailView.swift   # user's container: compose stack, ports, labels, logs, lifecycle
│   │   ├── ConsoleLogView.swift        # collapsible aggregated console panel (bottom of detail)
│   │   ├── LogConsoleView.swift        # scrollable colorized log box (per-view "Last action" cards)
│   │   ├── SystemResolverBanner.swift  # "apps on this Mac don't resolve the zone" (MDM DNS profile / DNS proxy)
│   │   ├── FleetDeletionDialog.swift   # shared `marina fleet delete` confirmation (sidebar + overview)
│   │   └── NewClusterSheet.swift       # modal for `marina cluster create`
│   └── Resources/
│       └── marina-logo.png             # used both for in-app branding and AppIcon (via swift-bundler)
└── .gitignore
```

---

## Data sources

We **bypass the marina CLI for state-reads** wherever possible — every CLI invocation is a fork+exec and stale state from the CLI's own caching path would only confuse the UI. State of record:

### `~/.marina/<vm>/` — VM truth

- `lima.yaml` — Lima config; we read `cpus`, `memory`, `disk` for the VM card.
- `ssh.config` — generated by marina; gives us host/port/user/IdentityFile/ControlPath.
- `vz.pid` — VM process ID; `kill(0, pid)` tells us if the VM is running.
- `_config/config.yaml` — marina-level config (mirrors, kind defaults). Decoded via Yams.

`InstanceDiscovery.scan()` walks this directory, skips reserved entries (`_config`, `registry-cache`, `share`), and builds an `Instance`. Only one VM is ever expected.

### Guest VM — `/proc/stat` over SSH

`GuestSSH` shell-outs to `ssh -F <ssh.config> <host>`, riding the ControlMaster socket marina already keeps open (no fresh handshake on each call). For the VM polling loop we issue a single SSH command that emits `/proc/stat | head -1` and `/proc/meminfo | head -3` separated by `---`, then parse:

- **CPU%** — `1 − idleΔ/totalΔ`, where `idle` is `(idle + iowait)` ticks. Requires a stored previous sample (`GuestRawSample`) to take the delta.
- **Memory** — `MemTotal − MemAvailable` for used, `MemTotal` for total.

Poll cadence: user-configurable, default 5 s (`AppSettings.vmPollSeconds`; read live off `settings.vmPollInterval` at the top of each loop). Skipped entirely when the "VM stats & graphs" preference is off.

#### Disk usage — root disk and the image-cache disk

marina gives the VM two independently-resizable disks (`lima.yaml`: `disk` for the root
filesystem, `additionalDisks: [marina-img]` mounted at `/var/lib/containerd`) — everything
`docker pull`/`build` writes lands on the second one, separately from the root disk. A full
one can't be seen from `df` on the Mac (it's inside the VM) and fails in a way that looks
like anything else — a `docker compose up --build` dying mid-export with "no space left on
device" gives no hint which of the two disks is actually full, or that there even are two.

`GuestSSH.stats()` (not the 5 s poll loop — this rides `refreshAll()`, same cadence as
kernel/OS info) adds one more section to its single round-trip: `df -k
--output=source,size,used,avail / /var/lib/containerd`. The two paths are always passed in
that fixed order, so the parser reads them positionally rather than matching the `target`
column. `imageDisk` is only populated when its device differs from the root's — an older
marina without the `additionalDisks` split reports the same filesystem for both paths, and
showing two identical bars would be misleading rather than informative.

The sidebar VM card renders both as "used / total GiB", colored by fraction full — 80%/95%
warn/crit thresholds, higher than memory's 70%/90%, because disks routinely run hotter than
RAM without that meaning anything.

### Kubernetes — `kubectl` shell-out

We shell to `kubectl --kubeconfig <path>` rather than embedding a Swift Kubernetes client because:

1. kubeconfig schemas (exec credential plugins, OIDC, etc.) drift constantly; reusing `kubectl` inherits Apple's bug-fix budget.
2. The user already has `kubectl` configured for these clusters.
3. The query surface we need is tiny (`get nodes/pods/services/deployments -o json`).

`KubeClient` wraps the common verbs. `MetricsClient` hits `kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes` and `/pods` and decodes the result via private `NodeMetricsList` / `PodMetricsList` types. `QuantityParser` handles the menagerie of k8s quantity formats:

- `93642001n` → 93.6 millicores
- `123m` → 123 millicores
- `1.5Gi`, `512Mi`, `1024Ki` → MiB

Cluster metric poll cadence: user-configurable, default 15 s (`AppSettings.metricsPollSeconds`).

### LoadBalancer reachability — `NWConnection`

`TCPProbe.probe(host:port:)` opens a Network framework TCP connection with a 1.5 s timeout and treats `.waiting` as failure (so unreachable IPs fast-fail instead of stalling on retry). `OnceFlag` guards the `CheckedContinuation` against double-resume in the cancellation path.

For each selected cluster's LoadBalancer services, `AppModel.probeLoadBalancers(for:)` runs a `TaskGroup` over every `(externalIP, port)` and writes results to `serviceProbes[clusterName]`. The Services tab renders a green/red/spinner dot per port, and turns the row into a clickable `Link` when reachable.

### Registry mirror cache — filesystem inspection

`RegistryCacheInspector` walks each mirror directory under `~/.marina/registry-cache/<mirror>/`:

- Total disk usage via `du -sk` (`DirectorySize`).
- Tag count via `find <path> -path '*/_manifests/tags/*/current/link' -type f`.
- Repository count via `find <path> -type d -name _manifests`.

This is exactly the Docker registry v2 on-disk layout — no registry HTTP API call needed.

### Guest containers — `docker ps` over SSH

`DockerClient` runs one guest command per refresh, in two sections separated by a
sentinel, and parses it into `DockerContainer`:

1. `docker ps -a --no-trunc --format …` — **tab**-separated, because `.Ports`,
   `.Networks`, `.Mounts` and `.Labels` are themselves comma-joined.
2. `docker ps -aq | xargs -r docker inspect --format '{{.Id}}\t{{json .Config.Labels}}\t{{json .Mounts}}'`
   — the label map and the typed mount list as JSON. Mounts come from here because the
   `{{.Mounts}}` ps column flattens binds and volumes into one undifferentiated list with
   no destination and no read-only flag.

Both ride the same SSH round-trip; the network hop is the cost, not the second local
docker call.

**Never parse `{{.Labels}}` for anything that drives behavior.** That column comma-joins
the label map *without escaping commas inside values*, and two labels routinely contain
them — `com.docker.compose.project.config_files` (one entry per `-f` flag) and
`com.docker.compose.depends_on`. A two-file compose stack silently splits into a bogus
entry and a truncated path. So:

- Every label the app **reasons about** gets its own `{{.Label "…"}}` column, which is
  structurally immune.
- The **displayed** label map comes from the `docker inspect` JSON, which is exact.
- The `{{.Labels}}` parse survives only as the fallback if the inspect pass fails —
  classification never depends on it, so a failure there can't make kind nodes show up
  as strays.

Classification (`DockerContainer.managed(mirrorNames:)`) decides what marina owns:

- **kind nodes** by the `io.x-k8s.kind.cluster` label — the same signal `kind get
  clusters` uses, so it beats matching on the container name.
- **registry mirrors** by name against `registries.mirrors[].name` from the marina
  config. marina puts **no label** on these containers, so the config is the primary
  signal; a `registry-*` name on a `registry:<tag>` image is the fallback for a config
  that has drifted from what is actually running.
- **local DNS** (`marina-dns`, `marina-dns-etcd`) by name — also unlabelled. Without
  this they'd surface as the user's containers, with stack Stop/Remove next to the
  server every `*.demo.internal` lookup on the Mac depends on.

Everything else is the user's own and surfaces as **Docker containers** in the sidebar/overview/detail views when
`AppSettings.showContainers` is on. When it's off nothing queries the guest's docker at
all. Published ports are linked at the VM's **lima0** address, not `127.0.0.1`: marina
sets `network.disablePortMirroring`, so Lima's loopback mirroring is off and lima0 is
the only address that works from the host.

#### Compose stacks

Docker containers are bucketed by `com.docker.compose.project` into
`AppModel.containerGroups` — stacks first (alphabetically, members ordered by service
then replica), standalone containers last. A stack is a unit the user thinks about as a
whole, so five flat `myapp-worker-{1..5}` rows next to an unrelated container hide the
one fact that matters about them. Inside a stack, rows and cards are titled by
**service** (`web`, `worker #2`), because the container name is just
`<project>-<service>-<n>` repeated.

Compose labels read (all verified against a live stack, Compose v5.5.1):

| Label | Use |
|---|---|
| `com.docker.compose.project` | the group key; stack name (launch dir unless `-p` / `COMPOSE_PROJECT_NAME`) |
| `com.docker.compose.service` | row/card title |
| `com.docker.compose.container-number` | replica index, 1-based; shown as `#n` only when > 1 |
| `com.docker.compose.oneoff` | `True`/`False` (Go casing, not JSON) — flags `docker compose run` throwaways |
| `com.docker.compose.project.working_dir` | shown on the group header and detail card |
| `com.docker.compose.project.config_files` | comma-separated list of compose files |

> ⚠️ **Never run `docker compose up` inside the marina VM casually.** The Compose in the
> guest removes orphan containers *without* `--remove-orphans` being passed, and it
> considers kind node containers orphans — a `docker compose up` in a scratch project
> destroyed a running kind cluster's node (verified in `docker events`). Test compose
> label handling with `docker run -l com.docker.compose.project=…` instead, which
> produces identical labels with no orphan sweep.

`ContainerDetailView` offers start / stop / restart (logged under `LogScope.container(id)`)
and an on-demand `docker logs --tail N`. Deliberately **no `docker rm`** on a single
container — removal is unrecoverable and one container isn't marina's to destroy out
from under the rest of its stack.

The stack as a whole gets Start/Stop/Remove next to its name in the sidebar and overview
(`AppModel.performStackAction` / `performStackRemoval`, logged under
`LogScope.composeStack(project)`). All three are `docker start`/`stop`/`rm -f` against the
stack's own container ids, never the real `docker compose up`/`down` — see the orphan-sweep
warning above; `docker compose down` would walk into the same failure mode as `up`. Remove
is gated behind a confirmation dialog (`ContainerGroup`-keyed `@State`, one per view) since
it's the one irreversible action here. It exists because `docker compose ls` **hides fully
stopped projects by default** (`ls` lists running projects only; `-a` is needed to see a
project with zero running containers) — so a stack sitting `exited` in the guest, like
every real example we've seen, is invisible to a plain `docker compose ls` even though
`compose down` would still work fine on it. The app has no such blind spot: it always shows
every container regardless of state, so Remove is the in-app way to clear one out without
first rediscovering `-a` or the project's original compose files.

### Host mounts — `marina status -o json`

marina 0.1.59 added `vm.mounts`: host directories shared into the guest over virtiofs.
This matters more than it sounds, and it is the one place the UI can tell the user
something neither `docker` nor `kubectl` will:

> Docker runs **inside** the VM and resolves a bind-mount source **there**. Binding a host
> path marina doesn't share does **not** fail — dockerd creates the missing directory in
> the guest and the container sees an empty one. The container starts, reports healthy,
> and silently has none of your files.

`MarinaCLI.status()` decodes `marina status -o json` for `mounts.shares` and
`mounts.pendingRestart`. Deliberately this and not `config.yaml`: marina reads the share
list from the **Lima instance config**, so it answers "what does the VM actually have"
rather than "what will it have after the next restart" — and `pendingRestart` is marina
telling us the two disagree. It costs one CLI invocation (~350 ms), so it rides
`refreshAll()` and never a poll loop. `mounts` is absent on older marina; the optional
decodes to nil and the UI omits the section rather than guessing.

The overview titles this section **Volume mounts** and lists marina's own registry-cache
share last and greyed out: it is a real share — a bind into it does reach the Mac, so it
stays in the data the backing check uses — but it is plumbing the user never configured,
so the count above it only counts theirs.

`AppModel.backing(for:)` resolves each container bind against that list —
`.hostShare` / `.guestOnly` / `.notApplicable` (a volume) / `.unknown` (marina too old to
say, so we must not claim either way). The prefix test appends a `/` before comparing, so
a share of `/Users/me/projects` does not falsely claim `/Users/me/projectsX`. The
comparison is against `guestPath`, not `hostPath`, because a remapped `mountPoint` is what
docker actually resolves against.

The container detail view renders that per mount: green "on your Mac", orange "not shared
from your Mac — this path exists only inside the VM", nothing for a volume.

### Local DNS — `marina status` + `marina dns list`

marina 0.2.0 publishes every LoadBalancer Service (and Ingress host) as
`<svc>.<ns>.<cluster>.<domain>` (default domain `demo.internal`): ExternalDNS per
cluster writes into etcd, CoreDNS on the kind network (`x.y.255.53`) serves it, and
`/etc/resolver/<domain>` sends the Mac's lookups there.

- **State** comes from the `dns` block of the same `status()` call as the mounts
  (`enabled`, `domain`, `server`, `hostResolver`, `serverRunning`). Absent on older
  marina → `AppModel.localDNS == nil` → every DNS feature is hidden, not shown as "off".
- **Records** come from `marina dns list -o json` (one `etcdctl` over SSH inside
  marina). Fetched on `refreshAll()` and in `loadClusterDetail` — never polled. With a
  cluster selected, `refreshAll` skips its own call because `refreshSelection` does it.
- **Services tab** matches records to a Service by VIP within the cluster's subzone
  **or its fleet zone** `<fleet>.<domain>` (marina 0.2.3; `AppModel.dnsNames(for:in:)`),
  ordered most deliberate first: names from the Service's
  `external-dns.kubernetes.io/hostname` annotation, then other names on the VIP
  (`DNSNameSource.sharedVIP`, typically Ingress hosts), then the automatic name
  (`network.dns.nameTemplate`, default `{{.Name}}.{{.Namespace}}`). marina runs
  ExternalDNS with `--combine-fqdn-annotation`, so the automatic name stays published
  next to a custom one — it is listed last and dimmed, and the first name is the
  endpoint host. Each name carries an `annotation` / `automatic` / `same VIP` badge;
  fleet-zone names get a `fleet` badge.
- **Ports** render as a grid: port, protocol, `appProtocol`, name, targetPort, endpoint.
  The endpoint is a link only when `PortScheme.infer` finds a scheme — `appProtocol`
  first (authoritative: a non-HTTP value means no link), then the port name's prefix
  (`http`, `https-admin`), then 80/8080/443/8443. Anything else is raw TCP and shows
  `host:port` to copy, never an `http://` URL.
- **Two dots, two questions.** The DNS row's dot is `getaddrinfo` (`HostResolver`),
  which on macOS goes through mDNSResponder and so honours `/etc/resolver` — the same
  path a browser takes. The TCP row's dot is still the probe against the IP. A red DNS
  dot next to a green TCP dot points at the resolver file or the DNS container, not
  the Service.
- **Cluster Info** shows the subzone and ExternalDNS's state
  (`KubeClient.externalDNSState()`: `external-dns/external-dns`; only a kubectl
  `NotFound` reads as "missing", so an unreachable API server doesn't offer Attach).
  Missing → **Attach** runs `marina dns attach <name>` behind a confirmation, because
  it restarts the cluster's CoreDNS.
- **Diagnostics** gets a Local DNS section (zone, server, resolver file, record count)
  and lists records whose IP is outside `kindBridgeCIDR` — they resolve, but the Mac
  has no route. `dig` ignores `/etc/resolver`, so the copyable command is
  `dig @<server> <name>` and the footer points at `dscacheutil -q host -a name`.
- The doctor `dns` check's `--fix` writes `/etc/resolver` with `sudo -n`, which fails
  from an app bundle; the check's `fix` field (`marina up`) is the copyable fallback.
- **Stale records.** marina 0.2.0's ExternalDNS published every Service type, so
  headless Services landed with pod IPs. 0.2.1 added `--service-type-filter=LoadBalancer`,
  but only a `marina dns attach` applies it to an existing cluster.
  `AppModel.clustersWithUnroutedRecords` drives a **Re-attach** button on the cluster
  Info card and per-cluster buttons in Diagnostics.
- **The Mac's own resolver can be bypassed** (marina 0.3.3). An MDM encrypted-DNS
  profile (`com.apple.dnsSettings.managed`, e.g. Kandji → Quad9 DoH) sends every
  lookup past `/etc/resolver`: curl and browsers get NXDOMAIN while `dig @server`
  and the doctor `dns` check are fine. marina publishes `marina-probe.<domain>` →
  the server IP for this. `AppModel.checkSystemResolver()` (on `refreshAll`, in a
  background task — a DoH lookup can take seconds) resolves it with `getaddrinfo`;
  on failure `/usr/bin/dig @server` separates `.probeMissing` (DNS set up by an older
  marina; `marina up` adds the record) from `.bypassed(profile:)`, and
  `ManagedDNSProfile.find()` reads the profile from `/Library/Managed Preferences`
  like marina does. `SystemResolverBanner` says it once above the Services tab's
  names (their red dots then point at it) and under Diagnostics › Local DNS, with
  the exemption to ask the MDM admin for (`OnDemandRules` `EvaluateConnection`,
  `DomainAction: NeverConnect`). The matching doctor check is `dns-system-resolver`;
  its `fix` is prose when a profile is the cause, so `DoctorCheck.fixIsCommand`
  renders it as text rather than a copyable command.
- **Ingress hosts are opt-in** (`network.dns.ingress`, marina 0.3.0). The Ingress
  source made `--fqdn-template` name every Ingress object too. `KubeClient.externalDNS()`
  reads whether the deployment runs `--source=ingress`;
  `AppModel.ingressSourceDrift(for:)` compares it with the config, and a mismatch
  (typically a cluster attached before 0.3.0) gets the **Re-attach** button on the
  cluster Info card. The `same VIP` badge's tooltip follows the deployed source.
- macOS negative-caches a failed lookup for **~75 s** regardless of the zone's SOA, so a
  name looked up before ExternalDNS published it stays red that long.

### Local CA — `marina status` + `marina ca status`

marina 0.2.2 runs an in-process CA for the zone (`network.dns.tls`, on by default): a
root in `~/.marina/pki/<domain>/` trusted in the System keychain, one intermediate and
`*.<cluster>.<domain>` wildcard per cluster (Secret `default/marina-wildcard-tls`), and
from 0.2.3 a `*.<fleet>.<domain>` wildcard in every member
(`default/marina-fleet-wildcard-tls`).

- `status.dns.tls` (`exists`, `trusted`, `root`) gates everything; `marina ca status -o
  json` adds the root expiry and which clusters/fleets hold a wildcard. It only reads
  files on the Mac (~30 ms), so it rides `refreshAll()` next to `status`.
- **A wildcard covers exactly one label.** The default automatic name is two labels
  (`<svc>.<ns>.<cluster>.<domain>`), so it is *not* covered. The Services tab shows a
  green lock only on one-label names under a zone with an issued wildcard
  (`WildcardCoverage.isOneLabel`), and a grey struck lock elsewhere. Its tooltip names
  the ways out: a one-label hostname annotation, a cert-manager `marina-ca` Certificate.
- **Cluster Info** lists the cluster and fleet wildcards with expiry, **Copy to
  namespace** (`marina ca secret <cluster> -n <ns> [--fleet]`, namespaces taken from the
  loaded pods minus system ones), **Renew** within 30 days of expiry, and **Issue
  wildcard** when none exists. Issue/Renew both run `marina ca attach`, behind a
  confirmation because installing the root restarts the nodes' containerd.
- **Diagnostics** shows root trust and expiry, the wildcard count, which clusters lack
  one, the root path, and **Copy root PEM** (`marina ca cert`) for clients that don't
  read the keychain. Trusting the root needs sudo, so an untrusted root shows
  `marina ca trust` to run in a terminal. The doctor check id is `tls`.

### Diagnostics — `marina doctor` and the app's own signature

The Settings window's **Diagnostics** tab answers two unrelated questions.

`MarinaCLI.doctor(fix:)` shells `marina doctor -o json`; the check `id`s are a documented
stable contract on the marina side, so `DoctorCheck.title` keys its labels off them and an
unknown `status` decodes to `.unknown` rather than failing the whole report. Nothing here
is polled — the probes (route table, in-guest iptables, Rosetta) are far too heavy for a
loop. `--fix` repairs the route / iptables / IP-forwarding checks itself, but the route fix
shells to `sudo`; launched from an app bundle there is no controlling terminal, so sudo
fails fast with "no tty present" and the UI surfaces that plus a copyable command.

The tab's **Network & trust** section reads `network.proxy` and `vm.caCerts` from the
marina config (0.1.60+). Both are invisible everywhere else and both fail in ways that
look like something else — a proxy-less pull hangs, an untrusted CA fails with "certificate
signed by unknown authority". An **absent** proxy block is not "no proxy": marina inherits
macOS's system settings, so the UI says "inherited from macOS" rather than "none".

`CodeSignatureCheck` verifies the *running* bundle with `codesign --verify`, `codesign
-dvvv` (the `-dvvv` is what makes it print the `Authority=` chain at all), `spctl -a -vv`,
and `xcrun stapler validate`. Notarization is decided by the **stapled ticket** or a
`source=Notarized Developer ID` from spctl — never by spctl's bare "accepted", which means
nothing on a Mac with assessment disabled (`override=security disabled`, surfaced as a
caveat). A `./build.sh` bundle reports "ad-hoc (local build)", which is a distinct state
from a broken signature. This is not build provenance: it says nothing about which commit
produced the binary.

---

## App model and polling

`AppModel` is a `@MainActor @Observable` class holding every piece of state the views read. It is constructed with an `AppSettings` (`AppModel(settings:)`) and reads the poll cadences off it on **each loop iteration**, so changing an interval in the Settings window takes effect on the next cycle without restarting any task. Polling is structured around four tasks held as properties:

- `vmPollTask` — `settings.vmPollInterval` loop (default 5 s) driving `collectVMSample()` (`GuestSSH.rawSample()` → CPU%/mem). Started by `startVMPollingIfRunning()` when the VM is up **and** the "VM stats & graphs" preference is on; toggling that preference (via a `RootView` `.onChange`) starts/stops it.
- `metricsTask` — `settings.metricsPollInterval` loop (default 15 s) scoped to the selected cluster; fetches node + pod metrics and appends to the per-cluster `MetricsHistory` ring buffer (capacity 60).
- `probeTask` — one-shot `TaskGroup` triggered on cluster selection or service refresh.
- `statePollTask` — `settings.clusterRefreshInterval` loop (default 6 s, `pollForExternalChanges()`) that detects out-of-band changes: VM started/stopped, clusters created/deleted via the CLI, and — when `showContainers` is on — containers that appeared or vanished (there is no cheaper signal for a `docker run` in a terminal than re-listing). On a change it calls `refreshAll()`/`refreshClusters()` so the UI stays live without a manual ⌘R. Skips while `inFlightAction`/a running `creation` would refresh anyway.

### Settings and scoped action logs

- **`AppSettings`** (`@MainActor @Observable`, `UserDefaults`-backed) holds visibility toggles (`showConsoleLog`, `showMirrors`, `showVMStats`, `showContainers`) and the three poll cadences. One instance is created in `MarinaUIApp`, injected into the SwiftUI environment (`@Environment(AppSettings.self)`) for the views **and** passed to `AppModel` for the loops. The `Settings { SettingsView(model:) }` scene binds it to ⌘, and the standard "Settings…" menu item; the sidebar footer's "Settings & About" button opens the same window via `@Environment(\.openSettings)`. The window's fourth tab, **About**, is the home for version/environment facts — Marina UI, marina CLI, the Kubernetes version of the kind nodes, and the guest VM's distribution and kernel — so it takes `AppModel` as well as `AppSettings`.
- **Action logs are scoped** (`LogScope`: `.vm` / `.cluster(name)` / `.metrics(name)` / `.container(id)` / `.general`). Every completed action appends a `LogRecord` via `appendLog(scope:label:text:)`; each view surfaces only its relevant entry via `model.latestLog(for:)` / `latestLog(forAny:)` — the cluster Info/Services tabs show `.cluster`, the Metrics tab shows `.metrics`, the overview shows `.vm`/`.general`. The optional bottom **`ConsoleLogView`** (toggled by `showConsoleLog`, collapsible) shows the full timestamped `consoleTranscript` across all scopes.

`AppModel.refreshAll()` reloads VM state, clusters, mirrors, config, **and the marina CLI version** (so it tracks CLI upgrades). `loadClusterDetail(_:)` fetches nodes/pods/services/deployments/version concurrently for the just-selected cluster.

### Cluster labels, fleet, and kube-context

- **Node labels aren't in `marina cluster list`** — read them from `kubectl` node metadata (`KubeNode.metadata.labels`), cached per cluster in `AppModel.clusterLabels`. marina applies `managed-by`, `marina.run/fleet`, `topology.kubernetes.io/{region,zone}`, `ingress-ready` (the last is set by the marina CLI's kind config, not the UI). `AppModel.displayLabels(_:)` filters out k8s system labels.
- **Adding a label post-creation** uses `marina cluster label <name> -l key=value` (MarinaCLI.labelCluster) — **requires marina 0.1.35+**.
- **kube-context names == cluster name** (marina merges each cluster into `~/.kube/config` under a context named after the cluster, not `kind-<name>`), so `currentKubeContext == cluster.name` and `use-context <name>` both work directly.
- **Clusters are grouped by fleet** (`AppModel.clusterGroups`, `ClusterGroup`): fleets first, alphabetically, then clusters with no fleet. The sidebar and the overview both give each fleet a header with a delete button (the sidebar also has a right-click "Delete Fleet…" on member rows), behind the shared `fleetDeletionDialog` confirmation. Deletion shells `marina fleet delete <name> -y` (marina 0.1.37+) rather than looping over names in Swift: marina resolves membership by label inside the guest, so a cluster whose labels the UI failed to fetch is still included. The dialog lists the members the UI knows about and adds a caveat when `hasClustersWithUnknownFleet`. Logged under `LogScope.fleet(name)`, surfaced on the overview (the fleet's header is gone once it succeeds).
- **The same node fetch also caches the kubelet version** (`AppModel.clusterNodeVersion`). `kubeNodeVersionSummary` reduces it for the About tab: one version when every cluster agrees, `mixed` (with a per-cluster tooltip) when they don't, and the configured `kind.nodeVersion` image tag from `config.yaml` as the fallback when no cluster is up.

The About tab also shows the guest VM's distribution and kernel (`GuestStats.osName` / `.kernel`), read in one SSH round-trip: `uname -r` plus `PRETTY_NAME` from `/etc/os-release`. They come from the full `stats()` call (refreshAll), not the 5 s sample loop, which just carries them forward.

The sidebar footer itself is down to two lines: the active kube context and the settings button. Note that `.textSelection(.enabled)` on a `Text` makes it draw in the label color and ignore `.foregroundStyle` — that's why those footer rows aren't selectable.

Selection state lives in `AppModel.selection: SidebarSelection?` and drives both the sidebar list selection and `RootView`'s detail dispatch.

---

## Key design decisions

### "Docker containers" are a separate concept from clusters

kind nodes and registry mirrors already have first-class places in the UI (the Clusters
and Registry mirrors sections). The Containers section is deliberately *everything else* —
what a `docker run` in a terminal left behind — so it never duplicates what's above it. It
is off by default: a stock marina VM has none, and an empty section is worse than no
section.

### Single-VM model

marina only ever runs one VM. The sidebar dedicates its top section to that one VM (logo, status, CPU/mem stats) and the rest of the workspace below. There is no VM list, no VM switcher — just `if let vm = model.vm` everywhere.

### Why we don't use the marina CLI for state

`marina cluster list -o json` is the one CLI command we DO use, because parsing kind's cluster discovery ourselves would duplicate marina's work. For everything else (VM liveness, lima config, ssh config, mirror config) we read the filesystem directly. Reasons:

1. CLI invocation costs ~50–150 ms each (fork + Swift→marina→Go→exit).
2. State files are the source of truth — the CLI just reads them.
3. UI polling cadences would multiply CLI invocations.

### Re-using marina's SSH ControlMaster

When marina brings the VM up, it opens an OpenSSH ControlMaster socket described by `~/.marina/<vm>/ssh.config`. By passing `-F <ssh.config>` to our own `ssh` calls, we ride that existing socket — no fresh TCP handshake, no fresh auth, sub-100 ms round-trip for short commands.

### Hardened-runtime re-sign step

swift-bundler v3 does code-sign with the supplied Developer ID identity, but **does not** add the `--options runtime` flag — and notarization rejects bundles without the hardened runtime. `scripts/release.sh` therefore re-signs after the initial bundle with `--options runtime --timestamp`. Don't simplify this away.

### App lives outside the App Store

The app shells out to `ssh`, `kubectl`, `helm`, reads arbitrary paths under `~/.marina/`, opens SSH ControlMaster sockets, and uses `NWConnection` to probe arbitrary LAN IPs. The App Store sandbox would fight every one of those. Homebrew cask via Developer ID is the right call here.

---

## Build and release

### Build (dev)

```bash
./build.sh                  # swift-bundler bundle -c release + ad-hoc codesign
                            # → .build/bundler/apps/MarinaUI/MarinaUI.app
```

### Release (signed + notarized + DMG + ZIP)

Prerequisites (one-time):

- Apple Developer ID Application certificate in the login keychain.
- A `notarytool` keychain profile:
  ```bash
  xcrun notarytool store-credentials klimax-notary \
    --apple-id you@example.com --team-id YOURTEAMID \
    --password <app-specific-password>
  ```
- `brew install create-dmg`.
- `swift-bundler` on PATH (`~/.local/bin/swift-bundler` built from [moreSwift/swift-bundler](https://github.com/moreSwift/swift-bundler)).

Bump `version` in `Bundler.toml`, then:

```bash
./scripts/release.sh
# → .build/bundler/apps/MarinaUI/MarinaUI.{zip,dmg}
# → both signed with Developer ID, notarized, stapled, Gatekeeper-verified
# → prints a ready-to-paste cask block (version + dmg sha256) at the end
```

Env overrides:

- `MARINA_SIGN_IDENTITY` — the Developer ID Application identity name.
- `MARINA_NOTARY_PROFILE` — the `notarytool` profile name (default `klimax-notary`).

### Publishing checklist

1. `./scripts/release.sh` — verify both artifacts land in `.build/bundler/apps/MarinaUI/`.
2. `gh release create vX.Y.Z .build/bundler/apps/MarinaUI/MarinaUI.dmg .build/bundler/apps/MarinaUI/MarinaUI.zip --title "vX.Y.Z" --notes "..."`.
3. Paste the printed cask block into `Casks/marina-ui.rb` in the [`bcollard/homebrew-marina`](https://github.com/bcollard/homebrew-marina) tap; commit and push.
4. End-users update via `brew upgrade --cask marina-ui`.

---

## Known limitations

### metrics-server is a manual install

kind doesn't ship metrics-server out of the box. The Metrics tab detects this and offers a one-click Helm install:

```
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server
helm repo update
helm install metrics-server metrics-server/metrics-server \
  -n kube-system --set args[0]=--kubelet-insecure-tls --wait --timeout 120s
```

The `--kubelet-insecure-tls` is required: kind's kubelet uses a self-signed cert that metrics-server otherwise rejects.

### CPU% requires a previous sample

The first VM sample after VM start shows no CPU% (we need a delta against a prior sample). After ~5 s the second sample arrives and the chart populates. This is normal; the empty state shows "Waiting for the first interval…".

### LoadBalancer probes assume routability

The probe runs from the macOS host. It assumes the LoadBalancer external IPs are routable from the host — usually true when marina is set up with MetalL plus a host network bridge. If the user has split networking, the probe will report unreachable even though the IP works from elsewhere.

### App Store distribution would require sandboxing

The sandbox would block: `ssh` to arbitrary hosts, reading `~/.marina/` without explicit Files-and-Folders entitlement, `NWConnection` to arbitrary LAN IPs, `kubectl`/`helm` shell-outs. Stick with the cask path.

---

## Future work

- **Logs view.** Tail `kubectl logs -f` for selected pods inside the app.
- **Resource graphs by namespace.** Top-N pods is useful; per-namespace stacked area would surface heavy tenants.
- **MetalLB IP allocation map.** Pull `MetalLB`'s `IPAddressPool` CRDs and show which ranges are in use vs free.
- **VM resize.** Edit `lima.yaml` (cpus/memory/disk) and trigger `marina restart` from the UI.
- **Mirror prune.** Surface aged tags and offer a "delete tag" action via the registry HTTP API.
