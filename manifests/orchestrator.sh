#!/bin/sh
set -e

# Configure API access using the mounted ServiceAccount credentials.
umask 077
export KUBECONFIG=/tmp/kube-bench-kubeconfig
cat > "${KUBECONFIG}" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: in-cluster
    cluster:
      server: https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}
      certificate-authority: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
users:
  - name: orchestrator
    user:
      tokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
contexts:
  - name: in-cluster
    context:
      cluster: in-cluster
      user: orchestrator
current-context: in-cluster
EOF

# Initialize the run identifier and technical failure counters.
namespace="kube-bench"
run_id="$(date -u +%Y%m%d%H%M%S)"
scan_failures=0
failed_jobs=""

# Validate configuration before creating any scan Jobs.
# Use the same configured image for every scanner Job.
: "${KUBE_BENCH_IMAGE:?Scanner image is required}"
case "${KUBE_BENCH_IMAGE}" in
  *[!a-zA-Z0-9./:_@-]*) echo "Invalid scanner image reference" >&2; exit 1 ;;
esac

benchmark="${KUBE_BENCH_BENCHMARK:-auto}"
: "${KUBE_BENCH_CPU_REQUEST:?CPU request is required}"
: "${KUBE_BENCH_MEMORY_REQUEST:?Memory request is required}"
: "${KUBE_BENCH_CPU_LIMIT:?CPU limit is required}"
: "${KUBE_BENCH_MEMORY_LIMIT:?Memory limit is required}"
case "${benchmark}" in
  *[!a-zA-Z0-9._-]*) echo "Invalid benchmark name" >&2; exit 1 ;;
esac
case "${KUBE_BENCH_SCAN_TIMEOUT:-}" in
  ''|*[!0-9]*) echo "Scan timeout must be a positive integer" >&2; exit 1 ;;
esac
case "${KUBE_BENCH_SCAN_TTL:-}" in
  ''|*[!0-9]*) echo "Scan TTL must be an integer of at least 60 seconds" >&2; exit 1 ;;
esac
if [ "${KUBE_BENCH_SCAN_TIMEOUT}" -le 0 ] || [ "${KUBE_BENCH_SCAN_TTL}" -lt 60 ]; then
  echo "Scan timeout must be positive; scan TTL must be at least 60 seconds" >&2
  exit 1
fi
for quantity in "${KUBE_BENCH_CPU_REQUEST}" "${KUBE_BENCH_MEMORY_REQUEST}" "${KUBE_BENCH_CPU_LIMIT}" "${KUBE_BENCH_MEMORY_LIMIT}"; do
  # Prevent YAML/shell injection; the API server validates resource quantities.
  case "${quantity}" in
    *[!a-zA-Z0-9.+-]*) echo "Invalid resource quantity: ${quantity}" >&2; exit 1 ;;
  esac
done

# Select an exact upstream mapping or use the manual benchmark override.
select_benchmark() {
  config_dir="/opt/kube-bench/cfg"
  if [ "${benchmark}" = "auto" ]; then
    if ! kubernetes_version="$(kubectl version --request-timeout=10s -o json | jq -er '.serverVersion.gitVersion')"; then
      echo "Cannot determine Kubernetes API server version for automatic benchmark selection" >&2
      return 1
    fi
    if ! kubernetes_minor="$(printf '%s' "${kubernetes_version}" | jq -Rer 'capture("^v?(?<major>[0-9]+)\\.(?<minor>[0-9]+)(?:[.+-]|$)") | .major + "." + .minor')"; then
      echo "Cannot parse Kubernetes version: ${kubernetes_version}" >&2
      return 1
    fi
    # Read only exact keys from the upstream version_mapping bundled with this image.
    # Do not use kube-bench's fallback to mappings for older Kubernetes versions.
    if ! benchmark="$(awk -F '"' -v version="${kubernetes_minor}" '
      /^version_mapping:[[:space:]]*$/ { in_mapping = 1; next }
      in_mapping && /^[^[:space:]#]/ { exit }
      in_mapping && ("v" $2) == ("v" version) && $4 ~ /^cis-[0-9][a-zA-Z0-9._-]*$/ { print $4; exit }
    ' "${config_dir}/config.yaml")"; then
      echo "Cannot read upstream benchmark mapping: ${config_dir}/config.yaml" >&2
      return 1
    fi
    if [ -z "${benchmark}" ]; then
      echo "No exact upstream CIS benchmark mapping for Kubernetes ${kubernetes_version} (${kubernetes_minor}) in ${config_dir}/config.yaml" >&2
      echo "Update the pinned kube-bench image or set KUBE_BENCH_BENCHMARK explicitly after reviewing compatibility" >&2
      return 1
    fi
    echo "Auto-selected CIS benchmark: Kubernetes ${kubernetes_version} -> ${benchmark} (bundled upstream mapping)"
  else
    echo "Manual CIS benchmark override: ${benchmark}"
  fi

  # Check that this image includes all required benchmark target files.
  required_targets="node policies"
  if [ -n "${control_plane_nodes}" ]; then
    required_targets="${required_targets} master etcd controlplane"
  fi
  for benchmark_target in ${required_targets}; do
    if [ ! -r "${config_dir}/${benchmark}/${benchmark_target}.yaml" ]; then
      echo "Benchmark ${benchmark} has no readable ${benchmark_target}.yaml in this kube-bench image" >&2
      return 1
    fi
  done
}

# Record a technical failure and allow remaining scans to continue.
record_failure() {
  scan_failures=$((scan_failures + 1))
  failed_jobs="${failed_jobs} $1"
  echo "Continuing after failed scan: $1" >&2
}

# Wait for a child Job to succeed or fail, with a polling deadline.
wait_for_job() {
  job_name="$1"
  # The Job deadline handles Pods; this deadline also bounds missing Jobs/API errors.
  wait_deadline=$(($(date -u +%s) + KUBE_BENCH_SCAN_TIMEOUT + 60))
  while [ "$(date -u +%s)" -lt "${wait_deadline}" ]; do
    if job_status="$(kubectl -n "${namespace}" get job "${job_name}" --ignore-not-found --request-timeout=10s -o json)"; then
      if [ -z "${job_status}" ]; then
        echo "Job ${job_name} disappeared before results were collected" >&2
        return 1
      fi
      if printf '%s' "${job_status}" | jq -e '.status.conditions[]? | select(.type == "Failed" and .status == "True")' >/dev/null; then
        echo "Job ${job_name} failed" >&2
        return 1
      fi
      if printf '%s' "${job_status}" | jq -e '(.status.succeeded // 0) >= 1' >/dev/null; then
        return 0
      fi
    else
      echo "Unable to read status for ${job_name}; retrying until the wait deadline" >&2
    fi
    sleep 5
  done
  echo "Timed out waiting for ${job_name}" >&2
  return 1
}

# Require one complete JSON report block with the expected structure.
validate_report_log() {
  awk '
    $0 == "--- BEGIN JSON REPORT ---" {
      if (state != 0) exit 1
      state = 1
      next
    }
    $0 == "--- END JSON REPORT ---" {
      if (state != 1) exit 1
      state = 2
      next
    }
    state == 1 { print }
    END { if (state != 2) exit 1 }
  ' "$1" > "$2" &&
    jq -se 'length == 1 and (.[0] | type == "object" and (.Controls | type == "array") and (.Totals | type == "object" and ([.total_pass, .total_fail, .total_warn, .total_info] | all(type == "number"))))' "$2" >/dev/null
}

# Collect and validate child logs, print them, and clean up temporary files.
collect_job_results() {
  job_name="$1"
  job_failed=0
  if ! wait_for_job "${job_name}"; then
    job_failed=1
  fi
  echo "=== Results: ${job_name} ==="
  if ! result_dir="$(mktemp -d /tmp/kube-bench-results.XXXXXX)"; then
    echo "Unable to create temporary report directory for ${job_name}" >&2
    record_failure "${job_name}"
    return 0
  fi
  if ! kubectl -n "${namespace}" logs "job/${job_name}" -c kube-bench --request-timeout=30s --pod-running-timeout=10s > "${result_dir}/scan.log"; then
    echo "Unable to collect report/logs for ${job_name}" >&2
    job_failed=1
  fi
  if ! validate_report_log "${result_dir}/scan.log" "${result_dir}/report.json"; then
    echo "Missing, incomplete, or invalid JSON report for ${job_name}" >&2
    job_failed=1
  fi
  if ! cat "${result_dir}/scan.log"; then
    echo "Unable to print collected logs for ${job_name}" >&2
    job_failed=1
  fi
  rm -rf "${result_dir}"
  if [ "${job_failed}" -ne 0 ]; then
    record_failure "${job_name}"
  fi
}

# Create one scanner Job pinned to a specific node and benchmark target.
create_node_job() {
  job_name="$1"
  node_name="$2"
  target="$3"

  if ! cat <<EOF | kubectl create --request-timeout=10s -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: kube-bench
    app.kubernetes.io/component: node-scan
    kube-bench-run-id: "${run_id}"
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: ${KUBE_BENCH_SCAN_TTL}
  activeDeadlineSeconds: ${KUBE_BENCH_SCAN_TIMEOUT}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kube-bench
        app.kubernetes.io/component: node-scan
        kube-bench-run-id: "${run_id}"
    spec:
      # Inspect host processes and their command-line flags.
      hostPID: true
      nodeName: ${node_name}
      # Node checks use host files and processes, without Kubernetes API access.
      automountServiceAccountToken: false
      restartPolicy: Never
      containers:
        - name: kube-bench
          image: "${KUBE_BENCH_IMAGE}"
          command:
            - /bin/sh
            - -ec
            - |
              kube-bench run --benchmark ${benchmark} --targets ${target} --json --outputfile /tmp/report.json
              jq -er '.Totals | if ([.total_pass, .total_fail, .total_warn, .total_info] | all(type == "number")) then "CIS summary: PASS=\(.total_pass) FAIL=\(.total_fail) WARN=\(.total_warn) INFO=\(.total_info)" else error("Invalid report totals") end' /tmp/report.json
              echo '--- BEGIN JSON REPORT ---'
              cat /tmp/report.json
              echo '--- END JSON REPORT ---'
          resources:
            requests:
              cpu: "${KUBE_BENCH_CPU_REQUEST}"
              memory: "${KUBE_BENCH_MEMORY_REQUEST}"
            limits:
              cpu: "${KUBE_BENCH_CPU_LIMIT}"
              memory: "${KUBE_BENCH_MEMORY_LIMIT}"
          # Read host configuration and identity files through read-only mounts.
          volumeMounts:
            # Kubernetes component data directories.
            - name: var-lib-cni
              mountPath: /var/lib/cni
              readOnly: true
            - name: var-lib-etcd
              mountPath: /var/lib/etcd
              readOnly: true
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: var-lib-kube-scheduler
              mountPath: /var/lib/kube-scheduler
              readOnly: true
            - name: var-lib-kube-controller-manager
              mountPath: /var/lib/kube-controller-manager
              readOnly: true
            # Service definitions and cluster configuration.
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
            - name: lib-systemd
              mountPath: /lib/systemd
              readOnly: true
            - name: srv-kubernetes
              mountPath: /srv/kubernetes
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
            # Keep host binaries separate from the image's own tools.
            - name: usr-bin
              mountPath: /usr/local/mount-from-host/bin
              readOnly: true
            # CNI configuration and plugin binaries.
            - name: etc-cni-netd
              mountPath: /etc/cni/net.d
              readOnly: true
            - name: opt-cni-bin
              mountPath: /opt/cni/bin
              readOnly: true
            # Resolve host user and group names for ownership checks.
            - name: etc-passwd
              mountPath: /etc/passwd
              readOnly: true
            - name: etc-group
              mountPath: /etc/group
              readOnly: true
      volumes:
        - name: var-lib-cni
          hostPath:
            path: /var/lib/cni
        - name: var-lib-etcd
          hostPath:
            path: /var/lib/etcd
        - name: var-lib-kubelet
          hostPath:
            path: /var/lib/kubelet
        - name: var-lib-kube-scheduler
          hostPath:
            path: /var/lib/kube-scheduler
        - name: var-lib-kube-controller-manager
          hostPath:
            path: /var/lib/kube-controller-manager
        - name: etc-systemd
          hostPath:
            path: /etc/systemd
        - name: lib-systemd
          hostPath:
            path: /lib/systemd
        - name: srv-kubernetes
          hostPath:
            path: /srv/kubernetes
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
        - name: usr-bin
          hostPath:
            path: /usr/bin
        - name: etc-cni-netd
          hostPath:
            path: /etc/cni/net.d
        - name: opt-cni-bin
          hostPath:
            path: /opt/cni/bin
        - name: etc-passwd
          hostPath:
            path: /etc/passwd
            type: File
        - name: etc-group
          hostPath:
            path: /etc/group
            type: File
EOF
  then
    echo "Failed to create scan job: ${job_name}" >&2
    record_failure "${job_name}"
    return 0
  fi
  collect_job_results "${job_name}"
}

# Run cluster-level policy checks through the dedicated ServiceAccount.
create_policy_job() {
  job_name="$1"

  if ! cat <<EOF | kubectl create --request-timeout=10s -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: kube-bench
    app.kubernetes.io/component: policies-scan
    kube-bench-run-id: "${run_id}"
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: ${KUBE_BENCH_SCAN_TTL}
  activeDeadlineSeconds: ${KUBE_BENCH_SCAN_TIMEOUT}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kube-bench
        app.kubernetes.io/component: policies-scan
        kube-bench-run-id: "${run_id}"
    spec:
      serviceAccountName: kube-bench-policies
      restartPolicy: Never
      containers:
        - name: kube-bench
          image: "${KUBE_BENCH_IMAGE}"
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          command:
            - /bin/sh
            - -ec
            - |
              umask 077
              token="\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
              ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              server="https://\${KUBERNETES_SERVICE_HOST}:\${KUBERNETES_SERVICE_PORT}"
              kubectl config set-cluster in-cluster --server="\${server}" --certificate-authority="\${ca}" --kubeconfig=/tmp/kubeconfig
              kubectl config set-credentials kube-bench --token="\${token}" --kubeconfig=/tmp/kubeconfig
              kubectl config set-context in-cluster --cluster=in-cluster --user=kube-bench --kubeconfig=/tmp/kubeconfig
              kubectl config use-context in-cluster --kubeconfig=/tmp/kubeconfig
              export KUBECONFIG=/tmp/kubeconfig
              kube-bench run --benchmark ${benchmark} --targets policies --json --outputfile /tmp/report.json
              jq -er '.Totals | if ([.total_pass, .total_fail, .total_warn, .total_info] | all(type == "number")) then "CIS summary: PASS=\(.total_pass) FAIL=\(.total_fail) WARN=\(.total_warn) INFO=\(.total_info)" else error("Invalid report totals") end' /tmp/report.json
              echo '--- BEGIN JSON REPORT ---'
              cat /tmp/report.json
              echo '--- END JSON REPORT ---'
          resources:
            requests:
              cpu: "${KUBE_BENCH_CPU_REQUEST}"
              memory: "${KUBE_BENCH_MEMORY_REQUEST}"
            limits:
              cpu: "${KUBE_BENCH_CPU_LIMIT}"
              memory: "${KUBE_BENCH_MEMORY_LIMIT}"
EOF
  then
    echo "Failed to create scan job: ${job_name}" >&2
    record_failure "${job_name}"
    return 0
  fi
  collect_job_results "${job_name}"
}

# Discover all nodes and identify control-plane nodes by their labels.
nodes_json="$(kubectl get nodes --request-timeout=10s -o json)"
all_nodes="$(printf '%s' "${nodes_json}" | jq -r '.items[].metadata.name')"
control_plane_nodes="$(printf '%s' "${nodes_json}" | jq -r '.items[] | select((.metadata.labels // {}) | has("node-role.kubernetes.io/control-plane") or has("node-role.kubernetes.io/master")) | .metadata.name')"
if [ -z "${all_nodes}" ]; then
  echo "No nodes discovered; audit cannot run" >&2
  exit 1
fi
select_benchmark

if [ -z "${control_plane_nodes}" ]; then
  echo "No labelled control-plane nodes discovered; master/etcd/controlplane checks will be skipped" >&2
fi

# Scan each control-plane node sequentially: master, etcd, then controlplane.
for node in ${control_plane_nodes}; do
  node_prefix="$(printf '%s' "${node}" | tr '[:upper:]._' '[:lower:]---' | cut -c1-16)"
  node_hash="$(printf '%s' "${node}" | sha256sum | cut -c1-7)"
  safe_node="${node_prefix}-${node_hash}"
  create_node_job "kube-bench-${run_id}-${safe_node}-master" "${node}" master
  create_node_job "kube-bench-${run_id}-${safe_node}-etcd" "${node}" etcd
  create_node_job "kube-bench-${run_id}-${safe_node}-controlplane" "${node}" controlplane
done

# Run node checks on every node, including control-plane nodes.
for node in ${all_nodes}; do
  node_prefix="$(printf '%s' "${node}" | tr '[:upper:]._' '[:lower:]---' | cut -c1-16)"
  node_hash="$(printf '%s' "${node}" | sha256sum | cut -c1-7)"
  safe_node="${node_prefix}-${node_hash}"
  create_node_job "kube-bench-${run_id}-${safe_node}-node" "${node}" node
done

# Finish with one cluster-wide policies scan.
create_policy_job "kube-bench-${run_id}-policies"

# Set the final execution status from technical failures, independently of CIS findings.
if [ "${scan_failures}" -gt 0 ]; then
  echo "CIS scan completed with ${scan_failures} failed job(s):${failed_jobs}" >&2
  exit 1
fi
echo "CIS scan completed successfully"
