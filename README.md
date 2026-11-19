# Kubernetes CIS Benchmark audits with kube-bench

Sample Kubernetes configuration for scheduled [kube-bench](https://github.com/aquasecurity/kube-bench) scans. A CronJob discovers the cluster's nodes, runs scan Jobs sequentially, and collects JSON reports and PASS/FAIL/WARN/INFO summaries in its logs.

The example uses standard Kubernetes resources and Kustomize. It requires no S3 storage, Ceph, or GitOps tooling. It reports findings; remediation and manual assessment remain operator tasks.

**Validation status:** installation, manual benchmark overrides, scheduled execution, JSON export, accelerated TTL cleanup, and uninstallation have been exercised on a local kind cluster running Kubernetes `v1.35.8` on Linux arm64, with one control-plane node and two workers. Successful runs used a manual `cis-1.12` override and each produced seven valid JSON reports. Automatic selection was checked against the bundled image mapping with supplied version fixtures; a real automatic run on `v1.35.8` confirmed rejection before scan Jobs because that version has no exact mapping. Shell syntax and manifest generation have also been checked locally.

## Relationship to the blog article

This repository is a simplified companion to [Kubernetes Security Audit with kube-bench: Automating CIS Benchmarking with Jobs and Ceph S3](https://cloudification.io/cloud-blog/kubernetes-security-audit-with-kube-bench-automating-cis-benchmarking-with-jobs-and-ceph-s3/). The article describes a broader implementation with Ceph S3 storage and GitOps. This public example demonstrates the core audit workflow using standard Kubernetes resources.

| Area | Implementation in the article | This repository |
| --- | --- | --- |
| Report collection | A scanner init container writes `/reports/report.json`; an uploader sends it to Ceph S3 | One scanner container writes `/tmp/report.json`; the orchestrator validates and collects reports in its logs for local export |
| Report retention | A configured number of audit runs is retained in S3 | Child Job TTL and CronJob history limits clean up Kubernetes resources; reports have no persistent store |
| Deployment | Argo CD manages the audit resources through GitOps | Apply the resources directly with `kubectl apply -k manifests/` |
| Benchmark selection | The original setup explicitly selects `cis-1.12` | The default `auto` setting uses the image's exact upstream mapping; `config.env` supports a manual override |

For this example, use the commands, paths, configuration defaults, and [benchmark compatibility information](#benchmark-compatibility) in this README together with the files under [`manifests/`](manifests/). The orchestrator includes bounded API polling and report validation, so some shell snippets differ from those in the article.

The six-node validation results in the article describe the original setup. Validation of this repository is reported separately above.

## How it works

The `kube-bench` CronJob runs [`manifests/orchestrator.sh`](manifests/orchestrator.sh), mounted from a ConfigMap. The script discovers nodes through the Kubernetes API, selects a benchmark, and creates one scan Job at a time.

| Target | Where it runs |
| --- | --- |
| `master` | Each discovered control-plane node |
| `etcd` | Each discovered control-plane node |
| `controlplane` | Each discovered control-plane node |
| `node` | Every node, including control-plane nodes |
| `policies` | One Job for the cluster, using the Kubernetes API |

Control-plane discovery recognizes both `node-role.kubernetes.io/control-plane` and `node-role.kubernetes.io/master` labels. Nodes carrying both labels are scanned once per target. For three control-plane nodes and three workers, a run creates 16 scan Jobs.

Each scanner writes a temporary JSON file, validates its totals, and prints the summary and full report to stdout. The orchestrator collects these logs before continuing. It checks that each collected log contains exactly one complete report block with valid JSON, controls, and numeric totals. It records Job creation, execution, timeout, log collection, and report validation failures, continues the remaining scans, and exits unsuccessfully if any scan had a technical failure.

## Requirements and scope

- A self-managed Linux Kubernetes cluster with accessible control-plane nodes and host paths matching this configuration. Review the read-only mounts in [`manifests/orchestrator.sh`](manifests/orchestrator.sh) for your distribution.
- `kubectl` with Kustomize support, access to the intended cluster, and permissions to create the included namespace, ServiceAccounts, RBAC resources, and CronJob. Installing the RBAC also requires permission to grant its rules.
- Nodes able to pull the image configured by `KUBE_BENCH_IMAGE` (default: `docker.io/aquasec/kube-bench:v0.16.0`). The orchestrator and policies Pods need a node on which ordinary Pods can be scheduled; no tolerations are configured for them.
- Admission policies that permit the node scanners' `hostPID` and `hostPath` access. These fields are disallowed by the [Baseline and Restricted Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/).
- Local `jq` for extracting and inspecting reports. It is already included in the scanner image.

The namespace and RBAC resource names are fixed to `kube-bench`. Use this example as a dedicated installation, avoiding collisions with an existing deployment.

This configuration assumes that etcd runs on the discovered control-plane nodes. External etcd, Windows nodes, and distributions with different host paths need adaptations. In managed Kubernetes services, the control plane may be inaccessible. If no labelled control-plane nodes are discovered, the orchestrator logs a warning and skips the `master`, `etcd`, and `controlplane` targets. A successful run therefore does not establish complete cluster coverage.

### Benchmark compatibility

The image is pinned to `v0.16.0`. The default `KUBE_BENCH_BENCHMARK=auto` setting selects the benchmark from the upstream `version_mapping` in `/opt/kube-bench/cfg/config.yaml` inside that image.

In automatic mode the orchestrator:

1. Gets the Kubernetes API server's `gitVersion` from `kubectl version -o json`.
2. Extracts `major.minor`, accepting patch versions and vendor suffixes such as `v1.34.8+k3s1`.
3. Looks up an **exact** entry in the bundled upstream mapping.
4. Checks that the selected benchmark contains the files needed for the scan targets, then passes it explicitly to every child Job.

One selection based on the API server version is used for the whole audit. Assess version skew separately when nodes run different Kubernetes versions.

Examples from the pinned release's [upstream mapping](https://github.com/aquasecurity/kube-bench/blob/v0.16.0/cfg/config.yaml):

| Kubernetes version | Automatically selected CIS benchmark |
| --- | --- |
| `1.28.x` | `cis-1.10` |
| `1.29.x`–`1.31.x` | `cis-1.11` |
| `1.32.x`–`1.34.x` | `cis-1.12` |
| `1.35.x` and newer | No mapping in `v0.16.0`; audit stops before creating scan Jobs |

See the version-pinned [support table](https://github.com/aquasecurity/kube-bench/blob/v0.16.0/docs/platforms.md) for the full list. Upstream mapping describes benchmark selection; it does not establish end-to-end testing of this repository on every listed version.

If the API version cannot be read or parsed, the mapping is missing, or required benchmark files are unavailable, the orchestrator exits with an error. Automatic mode does not fall back to an older Kubernetes mapping. There is no runtime download of a mapping or automatic image upgrade; the table and benchmark files come from the same pinned image.

### Manual benchmark override

Set the desired benchmark in [`manifests/config.env`](manifests/config.env):

```dotenv
KUBE_BENCH_BENCHMARK=cis-1.12
```

This overrides automatic selection and bypasses version lookup. The required benchmark files must exist in the image. Review compatibility before using an override; a successful scan does not establish that the benchmark matches the Kubernetes version.

To restore automatic selection, set:

```dotenv
KUBE_BENCH_BENCHMARK=auto
```

An empty or omitted value also enables automatic selection. Reapply with `kubectl apply -k manifests/` after editing.

For Kubernetes versions absent from the bundled mapping, review and update `KUBE_BENCH_IMAGE` in `config.env`, then apply with Kustomize. This is the single image setting for the orchestrator and both scanner templates. Changing the benchmark alone does not adapt the targets or host mounts in `orchestrator.sh`. Review those too.

## Install

Clone the repository and confirm the intended Kubernetes context:

```bash
git clone https://github.com/cloudification-io/kubernetes-cis-benchmark.git
cd kubernetes-cis-benchmark
kubectl config current-context
```

Review [`manifests/config.env`](manifests/config.env), [`manifests/rbac.yaml`](manifests/rbac.yaml), and the compatibility requirements above. Then preview and apply the resources:

```bash
kubectl kustomize manifests/
kubectl apply -k manifests/
kubectl -n kube-bench get cronjob kube-bench
```

Applying the manifests enables the weekly schedule immediately. To install with scheduled runs disabled, set `spec.suspend: true` in `cronjob.yaml` before applying.

## Run an audit manually

Check existing Jobs first and let an active audit finish before starting another:

```bash
kubectl -n kube-bench get jobs
```

The CronJob's `concurrencyPolicy: Forbid` prevents overlapping scheduled runs from that CronJob. Manually created Jobs bypass this protection. Avoid overlapping manual and scheduled audits.

Create a manual run and follow its logs, saving a local copy:

```bash
audit_job="kube-bench-manual-$(date -u +%Y%m%d%H%M%S)"
kubectl -n kube-bench create job --from=cronjob/kube-bench "$audit_job"
./scripts/follow-audit.sh "$audit_job" | tee "${audit_job}.log"
```

The helper waits up to 180 seconds for the orchestrator to become ready **or for the Job to finish**, then reads its logs. An early failure such as an unsupported automatic benchmark selection therefore exposes its diagnostic logs immediately. It uses the current kubectl context; optionally pass a context as its second argument.

Use the same shell for the following examples, which reuse `audit_job`. Stopping the log follower does not stop the audit. To retrieve the available logs again, run:

```bash
kubectl -n kube-bench logs "job/$audit_job" > "${audit_job}.log"
kubectl -n kube-bench get job "$audit_job"
```

Log streaming alone does not establish success. Check the parent Job's final status and the final execution summary in its logs. Scan count and duration depend on the discovered nodes and any failures.

## Export JSON reports

Each report in the orchestrator log is preceded by its child Job name and enclosed by these markers:

```text
=== Results: kube-bench-<run-id>-<node-id>-node ===
CIS summary: PASS=19 FAIL=1 WARN=5 INFO=0
--- BEGIN JSON REPORT ---
... JSON report ...
--- END JSON REPORT ---
```

This is an illustrative excerpt. To extract one file per report from a completed run's saved log:

```bash
mkdir -p "${audit_job}-reports"
awk -v output="${audit_job}-reports" '
  /^=== Results: / { job = $3 }
  /^--- BEGIN JSON REPORT ---$/ { capture = 1; next }
  /^--- END JSON REPORT ---$/ { capture = 0; next }
  capture { print > (output "/" job ".json") }
' "${audit_job}.log"
jq '.Totals' "${audit_job}-reports/"*.json
```

Compare the number of exported reports with the expected scan count: `3 × control-plane nodes + all nodes + 1`. A failed scan or interrupted/truncated log can leave missing or incomplete reports; review the Job status and extraction errors before using the results.

### Retention

The default TTL makes each finished child Job eligible for deletion after 600 seconds. Kubernetes also deletes its dependent Pods, so early child reports may already be unavailable by the time the full audit finishes. See [Kubernetes Job TTL cleanup](https://kubernetes.io/docs/concepts/workloads/controllers/ttlafterfinished/).

Use the orchestrator's combined log to export the whole run promptly. The CronJob history limits retain at most one successful and one failed parent Job. Jobs created with `kubectl create job --from=cronjob/...` carry a CronJob owner reference and are also subject to these history limits. Parent Jobs have no separate TTL. Kubernetes log rotation or Pod/node loss can also remove logs; this repository provides no persistent report store or report-history guarantee.

## Configuration

Edit [`manifests/config.env`](manifests/config.env) and apply the manifests again:

```bash
kubectl apply -k manifests/
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `KUBE_BENCH_IMAGE` | `docker.io/aquasec/kube-bench:v0.16.0` | Shared image for the orchestrator and all scan Jobs |
| `KUBE_BENCH_BENCHMARK` | `auto` | Exact upstream mapping from the API server version, or an explicit benchmark override |
| `KUBE_BENCH_SCAN_TTL` | `600` | Finished child Job cleanup delay, in seconds; minimum `60` |
| `KUBE_BENCH_SCAN_TIMEOUT` | `1800` | Child Job execution deadline, in seconds; positive integer |
| `KUBE_BENCH_CPU_REQUEST` | `50m` | CPU request per scanner |
| `KUBE_BENCH_MEMORY_REQUEST` | `64Mi` | Memory request per scanner |
| `KUBE_BENCH_CPU_LIMIT` | `500m` | CPU limit per scanner |
| `KUBE_BENCH_MEMORY_LIMIT` | `256Mi` | Memory limit per scanner |

Kustomize fills the CronJob image from `KUBE_BENCH_IMAGE`; the orchestrator reads the same setting from its environment for child Jobs. Always apply the directory with `-k`, rather than applying `cronjob.yaml` directly.

Kustomize gives both ConfigMaps names based on their contents and updates the CronJob references when settings or the script change. Existing Jobs retain their original settings and script references, including Jobs whose Pods have not started yet. The settings are read into the parent Pod's environment at startup. Orchestrator resources are configured separately in `cronjob.yaml`.

Each child Job has the configured execution deadline. The orchestrator's status polling also has a deadline of the scan timeout plus a 60-second allowance, with bounded API requests. This is a per-Job limit; there is no separate deadline for the entire audit.

The default schedule, `0 4 * * 0`, runs on Sundays at 04:00. No `spec.timeZone` is set, so Kubernetes uses the controller manager's local time zone. To make the schedule explicitly UTC, add `timeZone: Etc/UTC` under the CronJob's `spec`. See [CronJob time zones](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/#time-zones).

To pause future scheduled runs:

```bash
kubectl -n kube-bench patch cronjob kube-bench --type=merge -p '{"spec":{"suspend":true}}'
```

Set `suspend: false` to resume. Suspension does not stop existing Jobs. To keep this setting when applying the manifests again, update `spec.suspend` in `cronjob.yaml` too.

## Interpret results

| Result | Meaning |
| --- | --- |
| `PASS` | The check satisfied its criteria |
| `FAIL` | The check did not satisfy its criteria, or a scored check encountered an execution error |
| `WARN` | Further review is required; causes include manual checks, missing tests, and unscored failures or execution errors |
| `INFO` | Informational or skipped result; it does not count as a pass |

These are check statuses, not severity levels. Inspect each finding's description, actual value, reason, and remediation guidance. Their implementation is documented in the [pinned kube-bench source](https://github.com/aquasecurity/kube-bench/blob/v0.16.0/check/check.go).

With the commands used here, a report containing CIS `FAIL` findings can still come from a successful Kubernetes Job. The orchestrator's exit status describes workflow execution, log collection, and report validation. It does not certify that all checks passed or that the cluster is CIS compliant. Likewise, some individual check execution errors are represented inside the report rather than as a failed Kubernetes Job.

## Permissions and host access

[`manifests/rbac.yaml`](manifests/rbac.yaml) defines two ServiceAccounts:

- `kube-bench-orchestrator` can list nodes, create and get Jobs in `kube-bench`, list their Pods, and read Pod logs. It cannot get individual nodes or Pods, watch or delete Jobs, or change RBAC.
- `kube-bench-policies` can get and list Pods, ServiceAccounts, Roles, and ClusterRoles across the cluster, and list ClusterRoleBindings. It has no watch permissions or access to RoleBindings. Its impersonation permission is restricted to the user named `system:authenticated`, used by the selected benchmark's authorization checks. See the [policy checks](https://github.com/aquasecurity/kube-bench/blob/v0.16.0/cfg/cis-1.12/policies.yaml).

Node scan Pods disable ServiceAccount token mounting. They share the host PID namespace and mount selected host paths read-only to inspect processes and configuration. That remains sensitive access: mounted files can contain credentials. Review the manifests and resulting logs under your organization's access policies.

## Troubleshooting

Inspect the parent Job, available child Jobs, and namespace events:

```bash
kubectl -n kube-bench describe job "$audit_job"
kubectl -n kube-bench get jobs -l app.kubernetes.io/name=kube-bench
kubectl -n kube-bench get pods
kubectl -n kube-bench get events --sort-by=.metadata.creationTimestamp
```

| Symptom | What to check |
| --- | --- |
| Pod remains Pending or is rejected | Admission policy, node taints, available resources, and resource quotas |
| Image pull fails | Registry access, image availability, and node architecture |
| `Forbidden` errors | The included roles/bindings and any additional authorization policies; inspect impersonation failures for policy scans |
| No control-plane targets | The discovery labels and whether the control plane is accessible |
| No exact upstream CIS benchmark mapping | Check the pinned release's version mapping; update the image or review a manual benchmark override |
| Missing files or unexpected check results | Host mounts, distribution-specific paths, benchmark selection, and the finding's reason |
| `DeadlineExceeded` or wait timeout | Node health, scheduling, API connectivity, and the configured scan timeout |
| Missing JSON reports | Child Job TTL, parent log availability, failed scans, and interrupted log collection |

## Uninstall

Export any reports you need first. From the repository root:

```bash
kubectl delete -k manifests/
```

This deletes the `kube-bench` namespace and **all resources inside it**, including active/manual Jobs, plus the included cluster-scoped RBAC resources. Local exported logs and JSON files are unaffected.
