# pod-info-demo

Demo app for the two-cluster Harness promotion pipeline. Runs [podinfo](https://github.com/stefanprodan/podinfo) via an Argo Rollouts canary.

```
pod-info-demo/
├── chart/                ← Helm chart (Rollout + Services + optional Analysis/ServiceMonitor/Ingress)
├── envs/
│   ├── np.yaml           ← fast canary, auto-promote (for k3d-np / dev)
│   └── live.yaml         ← slow canary, pipeline-gated (for k3d-live)
└── applicationset/
    └── podinfo.yaml      ← ApplicationSet that fans out to both clusters
```

## Before anything else — Git hosting

This folder lives under `local-k3d-clusters/`, which is **outside** the `harness-kube-management` git repo (by design — it can hold agent tokens and other local state). The Harness GitOps agent can only pull manifests from a reachable Git URL, so this folder has to be committed somewhere it can fetch from.

Two reasonable options:

**A. Push to a dedicated public/private repo** (recommended — keeps concerns separate)
```bash
cd local-k3d-clusters/pod-info-demo
git init
git remote add origin https://github.com/<you>/pod-info-demo.git
git add . && git commit -m "init" && git push -u origin main
```

**B. Commit into the existing `harness-kube-management` repo** (fine for demo)
Copy `pod-info-demo/` into `harness-kube-management/demo-apps/pod-info-demo/` and commit.

Either way, update `applicationset/podinfo.yaml`:
- `spec.generators[0].list.elements[*].repoURL` → your Git URL
- Paths inside `sources[*].path` match where you put the folder

## What the chart does

- Deploys podinfo as an **Argo Rollout** (not a Deployment), canary strategy.
- Ships **stable** (`podinfo`) and **canary** (`podinfo-canary`) Services. Both select the same pods for now — once an ingress/mesh is added, those become the traffic-split targets.
- Optional **AnalysisTemplate** (requires Prometheus) — queries 5xx rate + p99 latency on the canary.
- Optional **ServiceMonitor** (requires Prometheus Operator).
- Optional **Ingress**.

## Per-env differences

| | `np.yaml` | `live.yaml` |
|---|---|---|
| replicas | 2 | 3 |
| first pause | `duration: 10s` (auto) | `pause: {}` (manual) |
| subsequent pauses | short | longer |
| analysis enabled | false | false (flip on once Prometheus ships) |
| image tag | pinned here | pinned here |

The pipeline's job is to (1) bump the tag in `envs/np.yaml`, sync, verify, (2) bump `envs/live.yaml` to the same tag on promotion.

## First bring-up (manual, before pipeline exists)

After you've committed the folder to a real Git URL and updated the ApplicationSet:

```bash
# Apply ApplicationSet directly via the Harness agent on k3d-np
kubectl --context k3d-np apply -f applicationset/podinfo.yaml -n gitops-agent

# Watch
kubectl --context k3d-np get applications -n gitops-agent -w
kubectl --context k3d-np get rollout -n podinfo -w
```

ApplicationSet generates two Applications — `podinfo-np` and `podinfo-live` — each targeting its own cluster. Harness routes them to the right agent.

## Testing the canary

After the first deploy is Healthy, trigger a canary by bumping the image tag:

```bash
# edit envs/np.yaml: image.tag "6.11.2" → "6.11.0"
git commit -am "np: downgrade to 6.11.0 to test canary"
git push

# Rollout should pause at first step
kubectl --context k3d-np argo rollouts get rollout podinfo -n podinfo --watch

# Manually promote
kubectl --context k3d-np argo rollouts promote podinfo -n podinfo
```

## Chart values quick-reference

```yaml
replicaCount: 2
image:
  repository: ghcr.io/stefanprodan/podinfo
  tag: "6.11.2"

rollout:
  strategy:
    canary:
      steps: [...]            # the canary steps — override per env

analysis:
  enabled: false              # flip on once Prometheus is reachable
  prometheusAddress: http://prometheus-operated.monitoring:9090

monitoring:
  enabled: false              # set true to emit a ServiceMonitor

ingress:
  enabled: false              # use port-forward initially
  host: podinfo.local
```
