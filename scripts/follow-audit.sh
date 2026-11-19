#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 JOB_NAME [KUBECTL_CONTEXT]" >&2
  exit 2
fi

audit_job="$1"
context="${2:-}"
namespace=kube-bench

kubectl() {
  if [ -n "${context}" ]; then
    command kubectl --context "${context}" "$@"
  else
    command kubectl "$@"
  fi
}

startup_deadline=$(($(date -u +%s) + 180))
while :; do
  job_status="$(kubectl -n "${namespace}" get job "${audit_job}" --request-timeout=10s -o json)"
  # A short-lived Pod may finish before the Job is ever observed as ready.
  if printf '%s' "${job_status}" | jq -e '
    (.status.ready // 0) > 0 or
    (.status.succeeded // 0) > 0 or
    any(.status.conditions[]?;
      (.type == "Complete" or .type == "Failed") and .status == "True")
  ' >/dev/null; then
    break
  fi
  if [ "$(date -u +%s)" -ge "${startup_deadline}" ]; then
    echo "Timed out waiting for audit ${audit_job} to start or finish; inspect the Job and namespace events" >&2
    exit 1
  fi
  sleep 2
done

# The exit status describes log retrieval. Inspect the Job for audit success/failure.
kubectl -n "${namespace}" logs -f "job/${audit_job}" --pod-running-timeout=10s
