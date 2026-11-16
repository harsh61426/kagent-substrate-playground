#!/usr/bin/env bash
#
# Try kagent 1.0 + Agent Substrate on a local kind cluster, with a local
# Ollama model, and deploy a first agent.
#
# Usage:   ./setup.sh            # run everything
#          ./setup.sh <step>     # run one step (see "steps" below)
#
# Safe by design: it uses its OWN kubeconfig file and passes --context to every
# kubectl call, so it never touches your default kube context or other clusters.
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(pwd)"

# ---- configuration (override with environment variables) --------------------
CLUSTER_NAME="${CLUSTER_NAME:-kagent}"
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.37.0}"   # Substrate needs Kubernetes >= 1.37
KAGENT_VERSION="${KAGENT_VERSION:-v1.0.0}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/kagent.kubeconfig}"
MODEL="${MODEL:-llama3.2:3b}"                      # must support tool calling
MODEL_CONFIG_NAME="${MODEL_CONFIG_NAME:-llama32-model-config}"
MIN_DOCKER_MEM_GB="${MIN_DOCKER_MEM_GB:-8}"

export KUBECONFIG="$KUBECONFIG_FILE"
CTX="kind-${CLUSTER_NAME}"

# ---- helpers -----------------------------------------------------------------
log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"; }

# kubectl pinned to the kind context, always.
k() { kubectl --context "$CTX" "$@"; }

# ---- steps -------------------------------------------------------------------
preflight() {
  log "Preflight checks"
  [ "$(uname -m)" = "x86_64" ] && warn "x86_64 host: the agentgateway/aws-cli images need the x86-64-v2 CPU level. VMs using the generic 'kvm64' CPU model will crash-loop (see README)."
  need docker; need kubectl; need helm; need jq; need curl

  docker info >/dev/null 2>&1 || die "Docker daemon is not running (macOS: open -a Docker)"
  local mem_bytes mem_gb
  mem_bytes="$(docker info --format '{{.MemTotal}}')"
  mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
  [ "$mem_gb" -ge "$MIN_DOCKER_MEM_GB" ] \
    || warn "Docker has ~${mem_gb} GB of memory; ${MIN_DOCKER_MEM_GB}+ GB recommended (raise it in Docker Desktop > Resources)"

  if ! command -v kind >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      log "Installing kind with Homebrew"
      brew install kind
    else
      die "kind is not installed (https://kind.sigs.k8s.io/docs/user/quick-start/#installation)"
    fi
  fi
  echo "kind: $(kind version)"
}

cluster() {
  log "Creating kind cluster '${CLUSTER_NAME}' (${NODE_IMAGE})"
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    echo "cluster already exists, skipping create"
    [ -f "$KUBECONFIG_FILE" ] || kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_FILE"
  else
    kind create cluster --name "$CLUSTER_NAME" --image "$NODE_IMAGE" --kubeconfig "$KUBECONFIG_FILE"
  fi

  log "Verifying the certificate APIs that Substrate needs"
  local apis
  apis="$(k api-resources --api-group=certificates.k8s.io)"
  echo "$apis"
  echo "$apis" | grep -q podcertificaterequests || die "PodCertificateRequest API missing: Kubernetes >= 1.37 is required"
  echo "$apis" | grep -q clustertrustbundles   || die "ClusterTrustBundle API missing: Kubernetes >= 1.37 is required"
  k get nodes
}

install_cli() {
  log "Installing the kagent CLI ${KAGENT_VERSION}"
  if command -v kagent >/dev/null 2>&1; then
    echo "already installed: $(kagent version 2>&1 | head -1)"
    return
  fi
  curl -fsSL https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent \
    | bash -s -- --version "$KAGENT_VERSION"
  command -v kagent >/dev/null 2>&1 \
    || die "kagent CLI installed but not on PATH; add its install directory to PATH and re-run"
  kagent version
}

install_kagent() {
  log "Installing kagent + Agent Substrate (this pulls ~570 MB of images; expect several minutes)"
  if k get deployment kagent-controller -n kagent >/dev/null 2>&1; then
    echo "kagent-controller already present, skipping install"
  else
    # The installer insists on a provider API key. With Ollama as the default
    # provider the key is only used for the default ModelConfig, which we do
    # not use. A placeholder is fine; do NOT put a real key here.
    export OLLAMA_API_KEY="${OLLAMA_API_KEY:-placeholder}"
    # valuesFiles in kagent-config.yaml are relative, so run from config/.
    ( cd "$ROOT/config" && kagent --config kagent-config.yaml install --namespace kagent )
  fi

  k rollout status deployment/kagent-controller -n kagent --timeout=600s

  log "Waiting for all kagent and Substrate pods to be healthy"
  local i bad
  for i in $(seq 1 60); do
    bad="$( { k get pods -n kagent --no-headers; k get pods -n ate-system --no-headers; } 2>/dev/null | grep -v -E 'Running|Completed' || true)"
    [ -z "$bad" ] && { echo "all pods healthy"; return; }
    sleep 10
  done
  echo "$bad"
  die "some pods are not healthy; see README > Troubleshooting"
}

ollama() {
  log "Deploying Ollama in the cluster and pulling ${MODEL}"
  k apply -f manifests/ollama.yaml
  k rollout status deployment/ollama -n ollama --timeout=300s
  k exec -n ollama deploy/ollama -- ollama pull "$MODEL"

  log "Creating ModelConfig ${MODEL_CONFIG_NAME}"
  sed -e "s|__MODEL__|${MODEL}|g" -e "s|__NAME__|${MODEL_CONFIG_NAME}|g" manifests/modelconfig.yaml \
    | k apply -f -
}

agent() {
  log "Deploying Harness, AgentTemplate and Agent"
  k apply -f manifests/harness.yaml
  sed -e "s|__NAME__|${MODEL_CONFIG_NAME}|g" manifests/agenttemplate.yaml | k apply -f -
  k apply -f manifests/agent.yaml

  log "Waiting for the agent to be ready (the first runtime snapshot can take a minute or two)"
  local i
  for i in $(seq 1 36); do
    if kagent agent get my-first-agent 2>/dev/null | grep -q 'True'; then
      echo "agent is ready"
      return
    fi
    sleep 5
  done
  k get agent my-first-agent -n kagent -o jsonpath='{.status.conditions}' | jq . || true
  die "agent did not become ready; check the conditions above"
}

chat() {
  log "Creating a session and sending a first message"
  local session_id
  session_id="$(kagent agent session create --agent my-first-agent -o json | jq -r '.session.id')"
  echo "session: $session_id"
  kagent agent invoke --session "$session_id" --task "What is 2+2?"
  kagent agent invoke --session "$session_id" --task "What did I just ask you?"
}

summary() {
  cat <<EOF

Done. To keep working with this cluster in a new terminal:

  export KUBECONFIG="$KUBECONFIG_FILE"
  kubectl --context $CTX get pods -A

Open the UI:

  kubectl --context $CTX port-forward -n kagent svc/kagent-ui 8082:8080
  # then browse to http://localhost:8082

Tear everything down with ./teardown.sh
EOF
}

# ---- main --------------------------------------------------------------------
STEPS="preflight cluster install_cli install_kagent ollama agent chat summary"

if [ $# -gt 0 ]; then
  case " $STEPS " in
    *" $1 "*) "$1" ;;
    *) die "unknown step '$1'. steps: $STEPS" ;;
  esac
else
  for s in $STEPS; do "$s"; done
fi
