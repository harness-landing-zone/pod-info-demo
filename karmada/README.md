# Karmada on the CRC hub, managing the k3d spokes

Local test bed for the multi-cluster architecture we discussed: the **Karmada
control plane runs on the CRC/OpenShift hub** (same cluster that already runs
your `gitops-preprod` / `gitops-prod` Argo CD instances), and the three k3d
clusters (`dev`, `staging`, `prod`) — today your Argo CD spokes — are joined as
**Karmada member clusters**, standing in for "3 DCs in one region".

The demo shows the two capabilities ApplicationSets cannot provide:

1. **`Divided` replica scheduling** — one Deployment with a *region-total*
   replica count, split across members by Karmada.
2. **Health-driven failover** — stop one k3d cluster; its share of replicas is
   rescheduled onto the survivors, then rebalanced when it returns.

```
                        Mac host (192.168.0.231)
  ┌──────────────────────────────────────────────────────────────┐
  │  CRC VM (OpenShift hub)              k3d spokes (Docker)     │
  │  ┌────────────────────────┐    ┌─────┐  ┌─────┐  ┌─────┐    │
  │  │ gitops-preprod (Argo)──┼──▶ │ dev │  │ stg │  │prod │    │
  │  │ gitops-prod    (Argo)──┼──▶ └──▲──┘  └──▲──┘  └──▲──┘    │
  │  │ karmada-system         │       │         │         │      │
  │  │   etcd / apiserver     │       │         │         │      │
  │  │   controllers ─────────┼───────┴─────────┴─────────┘      │
  │  └────────────────────────┘  same path Argo CD already uses: │
  │                              https://192.168.0.231:<port>     │
  └──────────────────────────────────────────────────────────────┘
```

## Networking: reuse the path that already works

The hub→spoke path was verified from your live setup — the Argo CD cluster
secrets (`spoke-dev`, `spoke-staging`, `spoke-prod`) all point at the **Mac's
LAN IP with TLS verification disabled**:

| Spoke | Server (from Argo CD secret) | Status |
|---|---|---|
| dev | `https://192.168.0.231:52509` | Synced/Healthy |
| staging | `https://192.168.0.231:56950` | Synced/Healthy |
| prod | `https://192.168.0.231:56981` | registered |

Karmada's controllers run as pods on the same CRC cluster as Argo CD, so the
identical addressing works for `karmadactl join`. Two consequences, inherited
from the existing setup:

- **The Mac's LAN IP is baked in.** If DHCP hands you a new address, both the
  Argo CD secrets and the Karmada member registrations break together. The
  scripts detect the current IP at run time (`ipconfig getifaddr en0`).
- **The k3d host ports change if a `serverlb` container is recreated** — the
  scripts read them live from `docker port`.
- TLS to members is `insecure-skip-tls-verify` (the k3s certs don't carry the
  LAN IP SAN). Same trade-off your Argo CD secrets already make; fine locally.

> Note: `host.crc.testing` forwarding is *disabled* on this CRC install
> (`host-network-access=false`) — probed and confirmed. Not needed, since the
> LAN-IP path works; documented here so nobody burns time on it again.

## Install

### 1. Control plane on CRC

```bash
./scripts/01-install-control-plane.sh
```

What it does and why:

| Step | Why |
|---|---|
| `oc adm policy add-scc-to-group anyuid system:serviceaccounts:karmada-system` | Karmada ships upstream images (etcd, kube-apiserver) that don't fit OpenShift's `restricted-v2` random-UID SCC. Demo-grade fix. |
| `karmadactl init --etcd-storage-mode PVC --storage-classes-name crc-csi-hostpath-provisioner` | etcd needs a volume; CRC's default StorageClass provides it (hostPath mode would need privileged SCC). |
| `--cert-external-ip=127.0.0.1` | Adds a SAN so the Mac can talk to the Karmada API through a port-forward. |
| `--karmada-data ./.run --karmada-pki ./.run/pki` | Default is `/etc/karmada` → sudo on macOS. Everything generated lands in `karmada/.run/` (gitignored). |
| port-forward `svc/karmada-apiserver 32443:5443` + kubeconfig rewrite to `127.0.0.1:32443` | CRC exposes no NodePorts to the Mac; the port-forward is how `karmadactl`/`kubectl` on the Mac reach the Karmada API. Re-run the script to restart it after a reboot. |

Result: `.run/karmada-apiserver.config` — the kubeconfig for the Karmada API.
(This file is also what you would later register in Argo CD/Harness as the
"regional cluster" destination.)

### 2. Join the k3d spokes as members

```bash
./scripts/02-join-members.sh          # join + label all three
./scripts/02-join-members.sh --unjoin # reverse
```

Per cluster it: reads the live host port from `docker port
k3d-<name>-serverlb 6443/tcp`, builds a member kubeconfig with
`server: https://<mac-lan-ip>:<port>` + `insecure-skip-tls-verify: true`
(mirror of the Argo CD spoke secrets), runs `karmadactl join`, then labels the
cluster — the **grouping layer**:

```
infra_region=local1        # the region group the PropagationPolicy selects
environment=dev|staging|prod   # kept for AppSet-style selection later
```

Verify:

```bash
kubectl --kubeconfig .run/karmada-apiserver.config get clusters
# NAME          VERSION        MODE   READY
# k3d-dev       v1.33.6+k3s1   Push   True
# k3d-staging   v1.33.6+k3s1   Push   True
# k3d-prod      v1.33.6+k3s1   Push   True
```

### 3. Demo: Divided scheduling + failover

```bash
./scripts/03-run-demo.sh
```

Applies `manifests/demo-app.yaml` (namespace + podinfo Deployment with
`replicas: 6` — a **region total**, scope 1) and
`manifests/demo-propagationpolicy.yaml` (scope 2: Divided scheduling over the
`infra_region: local1` group, 30s NoExecute tolerations so failover is fast
enough to watch). Expected spread: **2 / 2 / 2**.

```bash
# where did replicas land?
karmadactl --kubeconfig .run/karmada-apiserver.config get pods \
  -n karmada-demo --operation-scope members

# ---- failover test: kill a "DC" ----
k3d cluster stop prod
# after failure detection + 30s toleration → expect 3/3 on dev/staging
watch karmadactl --kubeconfig .run/karmada-apiserver.config get pods \
  -n karmada-demo --operation-scope members

k3d cluster start prod   # replicas rebalance back toward 2/2/2
```

If replicas never move after stopping a cluster, check the feature gates on
`karmada-controller-manager` (`Failover=true,GracefulEviction=true` must be
active):

```bash
kubectl --context crc-admin -n karmada-system get deploy karmada-controller-manager \
  -o yaml | grep -A2 feature-gates
```

## How this maps to the architecture discussion

- k3d `dev`/`staging`/`prod` = member clusters (the "DCs") of one region
  group `local1`; CRC = the regional control-plane host.
- `replicas: 6` in the manifest is the **region total** (scope 1); the
  PropagationPolicy is **placement** (scope 2); nothing DC-specific is baked
  into the manifest — the property that makes one-render-per-region possible.
- **Next step** once this works: register `.run/karmada-apiserver.config` as a
  cluster in one of your Argo CD instances (Harness GitOps agent) and point a
  single Application at it — then your ApplicationSet does grouping/values at
  the region level and Karmada splits replicas underneath. That's the
  two-layer model from the Adyen docs reproduced on your laptop.
- Caveat for later: in a *real* mapping, one region group = clusters of the
  same environment. Here we deliberately group dev/staging/prod into one
  pseudo-region because they're the three clusters available.

## Cleanup

```bash
./scripts/02-join-members.sh --unjoin
karmadactl deinit --kubeconfig ~/.kube/config --context crc-admin
pkill -f "port-forward.*karmada-apiserver"
```

## Files

```
karmada/
├── README.md                       ← this guide
├── .gitignore                      ← ignores .run/ (certs, kubeconfigs)
├── scripts/
│   ├── 01-install-control-plane.sh
│   ├── 02-join-members.sh          ← join + label  (or --unjoin)
│   └── 03-run-demo.sh
├── manifests/
│   ├── demo-app.yaml               ← ns + podinfo Deployment (region-total replicas)
│   └── demo-propagationpolicy.yaml ← Divided + fast-failover tolerations
└── .run/                           ← generated at install time (not committed)
```
