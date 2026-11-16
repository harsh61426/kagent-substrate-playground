#!/usr/bin/env bash
#
# Remove the kind cluster created by setup.sh (and its dedicated kubeconfig).
# Nothing else on your machine is touched.
#
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kagent}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/kagent.kubeconfig}"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "no kind cluster named '$CLUSTER_NAME'"
fi

if [ -f "$KUBECONFIG_FILE" ]; then
  rm -f "$KUBECONFIG_FILE"
  echo "removed $KUBECONFIG_FILE"
fi
