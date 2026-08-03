# podinfo delivery — ONE pipeline, gated between stages

`podinfo-promote-dev-to-prod.yaml` is the only pipeline. It was three
(`podinfo_dev_sync`, `podinfo_prod_canary`, `podinfo_promote_dev_to_prod`);
the first two are deleted because a promotion pipeline that also does the dev
deploy is the thing a platform team actually ships, and three pipelines meant
three copies of the same GitOps wiring drifting apart.

```
Dev                 UpdateReleaseRepo -> MergePR -> FetchLinkedApps -> Sync
  |                                                        (plain rolling update)
Approve Prod        HarnessApproval                        <- the change gate
  |
Prod Canary         UpdateReleaseRepo -> MergePR -> FetchLinkedApps -> Sync
                    -> Verify @20%  -> GitOpsRollout resume
                    -> Verify @60%  -> GitOpsRollout promote-full
```

**The canary advances on evidence, not on a timer.** It used to be two 2-minute
`Wait` steps; those are now `Verify` steps (Canary, sensitivity HIGH, 5m window)
that compare the new pods against the stable pods and roll the stage back on an
anomaly. A timer proves the pods did not crash; it proves nothing about whether
they are serving correctly.

Developers test in `team1-dev`, then promote the **same image tag** to
`team1-prod`. Staging is deliberately skipped here; adding it is another
Deployment stage with its own `environmentRef`, not a new pipeline.

The `Approve Prod` stage is the extension point for a real change-management
gate — Jira/ServiceNow change requests attach here, replacing or wrapping the
`HarnessApproval` step. Nothing else in the pipeline needs to change for that.

**This file is INLINE in Harness.** The copy in this repo is a mirror, not the
source of truth, and it *will* drift the moment someone edits the pipeline in
the UI. Regenerate rather than hand-edit:

```
curl -s -H "x-api-key: $HARNESS_API_KEY" \
  "https://app.harness.io/pipeline/api/pipelines/podinfo_promote_dev_to_prod?accountIdentifier=<acct>&orgIdentifier=gitopsdemo&projectIdentifier=selfmanagedargo" \
  | python3 -c "import json,sys;print((json.load(sys.stdin).get('data') or {}).get('yamlPipeline',''))" \
  > pipeline/podinfo-promote-dev-to-prod.yaml
```

---

## Traps paid for — do not rediscover

**`GitOpsUpdateReleaseRepo` DESTROYS every comment in the file it writes.** It
re-serialises the values file from its parsed structure. A 22-line explanatory
header in `envs/team1-dev.yaml` came back as three lines on the first
successful run. **Never document anything in `envs/<env>.yaml`** — that file is
machine-owned. `envs/defaults.yaml` and `envs/tiers/*` are safe; the step only
touches the path in the service's ReleaseRepo manifest.

**A GitOps cluster must be LINKED to the Harness Environment.** Registering it
is not enough. Without the link the stage dies in ~12s at the `GitopsClusters`
step with *"No GitOps Cluster is selected with the current environment
configuration"* — before it touches git, so there is nothing to unwind. Check:

```
harness_list(resource_type='gitops_cluster_link', filters={environment_id:'team1_dev'})
```

Empty result = not linked. Both `team1_dev` and `team1_prod` needed it.

**`GitOpsFetchLinkedApps` needs a Deployment Repo manifest OR an App Set
Reference.** With neither it fails outright: *"Deployment Repo Manifests are
mandatory"*. The service originally carried a **ReleaseRepo** manifest only, so
the step was removed and both Sync steps named their Application explicitly via
`applicationsList`.

It is now back, because the service gained `appsetConfigs` (App Set Reference) —
the documented alternative to a DeploymentRepo manifest, and the better fit
here: a DeploymentRepo points at ApplicationSet YAML in git, but ours is
rendered by the `charts/appsets` Helm chart and would likely not parse.

With the step present, the **ApplicationSet is the source of truth** for which
Applications exist, the Sync steps carry no `applicationsList` at all, and
adding an environment or a cluster to the appset needs no pipeline edit.

Requires the `GITOPS_APPLICATIONSET_FIRST_CLASS_SUPPORT` feature flag. **The
service accepting the `appsetConfigs` YAML does NOT prove the flag is on** —
Harness stores fields it will not act on. The only real test is running the
step; with the flag off you get the same "Deployment Repo Manifests are
mandatory" error as before.

**Sync steps MUST use `serverSideApply: true`.** The Application declares
`ServerSideApply=true` in `syncOptions`, but a step-level `serverSideApply:
false` overrides it — and mixing the two **orphans fields permanently**. A field
written by an earlier server-side Apply (`runAsGroup: 100`) could not be removed
by a later client-side `Update`, because a client-side update only writes the
fields it carries. Result: `OutOfSync` forever, on a Healthy app, with no
manager willing to drop the field. All four Sync steps (both stages, both
rollback paths) are now `true`.

**`OutOfSync` on a Healthy app is a real diff, not a stale cache.** Compare
Argo's own `normalizedLiveState` against `predictedLiveState` to find it:

```
harness_list(resource_type='gitops_managed_resource', compact=false,
             filters={agent_id:'team1_argo_agent', app_name:'podinfo-team1-dev'})
```

**The ADOT annotations are NOT drift.** The `amazon-cloudwatch-observability`
addon injects eight `instrumentation.opentelemetry.io/inject-*` and
`cloudwatch.aws.amazon.com/auto-annotate-*` annotations into the Deployment's
pod template. They appear in `normalizedLiveState` **and**
`predictedLiveState`, so they cancel out and Argo ignores them. Do not add
`ignoreDifferences` for them — it would be a fix for a problem that does not
exist. (They also inject four init containers into every pod, which is noise
when reading `kubectl logs` — pass `-c podinfo`.)

**The ApplicationSet has no `syncPolicy.automated`.** A `git push` alone never
deploys. Applications go OutOfSync and wait for a pipeline run or a manual sync.

**Max two `MergePR` steps per stage.** Each stage already uses both — one
forward, one in the rollback path. There is no room to add another.

**`autoPromoteRolloutBehavior` has no `"none"`.** The enum is only
`["promote-full", "resume"]`, so the only way to let a canary stop at its first
pause is to **omit the field**. Setting `promote-full` drives the rollout to
100% on sync and makes every gate decorative.

**Deployment Freeze does not apply to GitOps PR pipelines.** Use ArgoCD Sync
Windows or an OPA policy on the Application.

---

## Continuous Verification — what it needs before it means anything

CV is the easiest thing here to configure and the easiest to configure into a
lie. Every prerequisite below fails SILENTLY, and every one of them fails in the
direction of the gate PASSING.

**1. Traffic.** Without it the analysis window sees kubelet probes and nothing
else, and the verdict is meaningless. `loadgen.enabled` exists for exactly this;
turn it off wherever real users provide the traffic.

**2. Series from BOTH populations.** Canary analysis compares new pods against
stable pods. Argo Rollouts splits them across two Services, so the chart emits a
ServiceMonitor per Service and the loadgen drives both. Scrape only the stable
side and CV has nothing to compare — with no error.

**3. A ServiceMonitor that actually matches.** Its selector matches the
SERVICE's metadata labels, not the pod selector. Getting this wrong produces a
ServiceMonitor that looks correct, a Prometheus with zero targets, and queries
that return `[]`. Verify by asking Prometheus, never by reading the manifest:

```
up{namespace="team1-prod"}                          -> expect one row per pod per role
sum by (role) (rate(http_requests_total{...}[5m]))  -> expect BOTH stable and canary
```

**4. A service instance field.** Metric queries must return a per-pod label
(`pod` here) or Harness cannot map series to instances.

**5. Fail closed on `Unknown`.** A `Verification` failure means CV saw an
anomaly. `Unknown` means it could not reach a verdict — no data, Prometheus
unreachable, empty query. Both roll back here, deliberately. If `Unknown`
promotes, then every misconfiguration above turns into a green pipeline, which
is worse than having no gate at all.

**6. Rehearse the failure.** A gate you have never seen fail is a gate you do
not know works. `loadgen.canaryPath: /status/500` degrades ONLY the canary
series while probes stay green, so the verification gate is exercised in
isolation from Kubernetes' own health gate. Put it back to `/` afterwards — a
permanently red canary teaches everyone to click through the gate.

## Other production-readiness items

**Pin `delegateSelectors` on the Prometheus connector.** An unpinned connector
is tested on whichever delegate answers. The Prometheus service is ClusterIP, so
only `eks-delegate` can reach it; anywhere else the connector "fails" for
reasons unrelated to Prometheus.

**`allowEmptyCommit: true` makes every re-run write a commit and open a PR**,
even when the tag is unchanged. Two no-op runs left the app repo 8 commits ahead
with a zero-byte diff. Convenient for re-runs, noisy in an app team's history —
`false` fails the stage instead, which is arguably the more honest signal for a
promotion pipeline.

**Rejecting the approval SKIPS the prod stage; it does not roll dev back.**
Verified: run 5 ended `ApprovalRejected` with Prod Canary `Skipped` and dev left
deployed. That is usually what you want, but it means "reject" is not an undo.

**Deployment Freeze does not apply to GitOps PR pipelines** (verbatim in the
docs). Use ArgoCD Sync Windows or an OPA policy on the Application.

**The approval stage is the change-management seam.** A Jira/ServiceNow change
request attaches here, replacing or wrapping `HarnessApproval`. Nothing else in
the pipeline changes.

**Notifications are not configured.** A pipeline that rolls back at 03:00 and
tells nobody has traded an outage for a silent non-deployment. Wire pipeline
notifications before this pattern carries real traffic.

**Dev deliberately has no CV.** Fast feedback matters more there, and dev is a
plain Deployment with no canary population to compare against.
