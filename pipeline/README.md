# podinfo delivery — ONE pipeline, gated between stages

`podinfo-promote-dev-to-prod.yaml` is the only pipeline. It was three
(`podinfo_dev_sync`, `podinfo_prod_canary`, `podinfo_promote_dev_to_prod`);
the first two are deleted because a promotion pipeline that also does the dev
deploy is the thing a platform team actually ships, and three pipelines meant
three copies of the same GitOps wiring drifting apart.

```
Dev                 UpdateReleaseRepo -> MergePR -> Sync        (plain rolling update)
  |
Approve Prod        HarnessApproval                             <- the change gate
  |
Prod Canary         UpdateReleaseRepo -> MergePR -> Sync
                    -> GitOpsRollout 20% -> 60% -> 100%
```

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

**`GitOpsFetchLinkedApps` requires a Deployment Repo manifest and we do not
have one.** It fails with *"Deployment Repo Manifests are mandatory"*; the
service carries a **ReleaseRepo** manifest only. The step is unnecessary here —
the docs say applications can be named directly in the Sync step, and both Sync
steps do exactly that via `applicationsList`. Removed from both stages. Adding a
DeploymentRepo manifest instead would mean pointing it at ApplicationSet YAML,
but ours is rendered by the `charts/appsets` Helm chart, so it would likely not
parse.

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
