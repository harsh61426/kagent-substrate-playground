# kagent + Agent Substrate: local trial on kind

Scripts and manifests to try [kagent](https://kagent.dev) 1.0 and **Agent
Substrate** on a laptop. You get a local Kubernetes cluster, a local LLM served
by Ollama, and a first agent you can chat with. Nothing is sent to an external
model provider.

- **kagent** is a Kubernetes-native framework for running AI agents.
- **Agent Substrate** is kagent 1.0's runtime layer. It runs each agent session
  as a sandboxed actor (gVisor by default) and handles suspend, resume and
  snapshots. The kagent CLI installs it for you into the `ate-system` namespace.

> Status: assembled from the commands used in a manual walkthrough on macOS
> (Apple Silicon, Docker Desktop). The script has not been run end to end as a
> single unit. If a step fails, run it on its own (`./setup.sh <step>`) and see
> Troubleshooting.

## What gets installed

| Component | Version | Where |
|---|---|---|
| kind cluster | node image `kindest/node:v1.37.0` (kind v0.32.0 or newer) | Docker |
| kagent + Agent Substrate | v1.0.0 | namespaces `kagent`, `ate-system` |
| dev PostgreSQL (bundled) | `postgres:18-alpine` | namespace `kagent` |
| Ollama | `ollama/ollama:latest`, model `llama3.2:3b` | namespace `ollama` |
| First agent | Harness + AgentTemplate + Agent | namespace `kagent` |

Substrate needs Kubernetes **1.37 or newer** (the `PodCertificateRequest` and
`ClusterTrustBundle` APIs), which is why the node image is pinned.

## Prerequisites

- macOS or Linux with **Docker** running. Give it **8 GB+ of memory** and
  4+ CPUs (Docker Desktop: Settings > Resources). Ollama, Substrate and the
  database run side by side.
- `kubectl`, `helm`, `jq`, `curl`. `kind` is installed with Homebrew if missing.
- Internet access to `ghcr.io`, `cr.agentgateway.dev`, Docker Hub and
  `raw.githubusercontent.com`. About 570 MB of images are pulled for Substrate
  alone, plus the Ollama image and the model.
- **x86-64-v2 CPU.** On x86 hosts, some Substrate images (agentgateway, aws-cli)
  crash with `Fatal glibc error: CPU does not support x86-64-v2` if the VM
  exposes a generic CPU such as "Common KVM processor". Apple Silicon is not
  affected. See Troubleshooting.

## Quick start

```bash
./setup.sh
```

This runs these steps in order. Each can be run alone with `./setup.sh <step>`:

| Step | What it does |
|---|---|
| `preflight` | Checks tools, Docker and its memory; installs `kind` via Homebrew if missing |
| `cluster` | Creates the kind cluster with its own kubeconfig, and checks the certificate APIs |
| `install_cli` | Installs the kagent CLI (v1.0.0) |
| `install_kagent` | Installs kagent and Substrate, then waits for every pod to be healthy |
| `ollama` | Deploys Ollama, pulls the model, creates the `ModelConfig` |
| `agent` | Applies the Harness, AgentTemplate and Agent and waits for `READY` |
| `chat` | Creates a session and sends two messages |

Settings you can override as environment variables: `CLUSTER_NAME`,
`NODE_IMAGE`, `KAGENT_VERSION`, `KUBECONFIG_FILE`, `MODEL`,
`MODEL_CONFIG_NAME`, `MIN_DOCKER_MEM_GB`.

Clean up with `./teardown.sh`, which deletes the kind cluster and the
kubeconfig the script created.

### The script never touches your other clusters

It writes its own kubeconfig (`~/kagent.kubeconfig` by default) and passes
`--context kind-kagent` to every `kubectl` call. If you work with other clusters
and your shell wraps `kubectl` with a guard (a `ctx` helper, aliases, a
`KUBECONFIG` set in your profile), run the script from a clean shell:

```bash
env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" bash ./setup.sh
```

In a new terminal afterwards, point `kubectl` at the trial cluster with:

```bash
export KUBECONFIG="$HOME/kagent.kubeconfig"
kubectl config current-context   # should print kind-kagent
```

## The manual steps, for reference

What the script does, if you prefer to type it yourself:

```bash
# 1. cluster
kind create cluster --name kagent --image kindest/node:v1.37.0 --kubeconfig ~/kagent.kubeconfig
export KUBECONFIG=~/kagent.kubeconfig
kubectl api-resources --api-group=certificates.k8s.io   # expect clustertrustbundles, podcertificaterequests

# 2. kagent CLI
curl https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent | bash -s -- --version v1.0.0

# 3. install kagent + Substrate (config/ holds the two files)
cd config
export OLLAMA_API_KEY=placeholder
kagent --config kagent-config.yaml install --namespace kagent
kubectl rollout status deployment/kagent-controller -n kagent --timeout=300s
cd ..

# 4. Ollama and the model config
kubectl apply -f manifests/ollama.yaml
kubectl rollout status deployment/ollama -n ollama --timeout=300s
kubectl exec -n ollama deploy/ollama -- ollama pull llama3.2:3b
sed -e 's|__MODEL__|llama3.2:3b|' -e 's|__NAME__|llama32-model-config|' manifests/modelconfig.yaml | kubectl apply -f -

# 5. first agent
kubectl apply -f manifests/harness.yaml
sed 's|__NAME__|llama32-model-config|' manifests/agenttemplate.yaml | kubectl apply -f -
kubectl apply -f manifests/agent.yaml
kagent agent get my-first-agent

# 6. chat
SESSION_ID=$(kagent agent session create --agent my-first-agent -o json | jq -r '.session.id')
kagent agent invoke --session "$SESSION_ID" --task "What is 2+2?"
```

## Design notes

- **CLI install, not Helm.** The kagent docs present the CLI as the evaluation
  path: it installs Substrate and a dev PostgreSQL for you. The Helm path needs
  an external PostgreSQL 15+, CA and JWT pools made with `kubectl ate admin`,
  and separate Substrate releases. Use Helm for anything shared or long-lived.
- **Ollama runs in the cluster.** The docs state a model server on your laptop
  is not reachable from agents, even with a port-forward. The `ModelConfig`
  host is `http://ollama.ollama.svc.cluster.local`.
- **Placeholder `OLLAMA_API_KEY`.** The installer refuses to run without a key
  for the default provider, even though self-hosted Ollama needs none. The
  placeholder only feeds the default `ModelConfig`, which this trial does not
  use. Do not put a real key there; it is stored in a Kubernetes Secret.
- **`defaultModelProvider: Ollama`** in `config/kagent-config.yaml`. Without it
  the installer demands `OPENAI_API_KEY`. Valid values are listed by
  `kagent config schema --component cli`. The provider name is case-sensitive.
- **Model choice.** `llama3.2:3b` supports tool calling and is usable on CPU.
  Models without tool support connect but never call bound tools. A 3B model
  is weak at multi-step tool use; try a larger one for anything beyond a demo.
  The Ollama container has no GPU on macOS.

## Troubleshooting

**`OPENAI_API_KEY is not set` or `OLLAMA_API_KEY is not set`.**
Set `install.defaultModelProvider: Ollama` in `config/kagent-config.yaml` and
export `OLLAMA_API_KEY=placeholder` (the script does both).

**`failed to install substrate ... context deadline exceeded`.**
Helm timed out because some Substrate pods never became ready. List them:
`kubectl get pods -A | grep -v -E 'Running|Completed'`, then read the logs of
the failing pod with `kubectl logs -n ate-system <pod> --previous`.

**`Fatal glibc error: CPU does not support x86-64-v2` in `atenet-router`,
`atenet-egress` and `rustfs-bucket-init`.**
The host CPU model hides SSE4.2, POPCNT and SSSE3. Check with
`lscpu | grep 'Model name'` ("Common KVM processor" is the culprit). Fix it on
the hypervisor by switching the VM's CPU type to host passthrough (or any
x86-64-v2 model) and power-cycling the VM, or run on Apple Silicon.

**`kubectl: no cluster selected (run 'ctx' first)`.**
Your shell wraps `kubectl` with a guard. Use the clean-shell command above;
don't bypass the guard in your everyday shell.

**Agent stays `READY: False`.**
The first runtime snapshot can take a minute. If it persists:
`kubectl get agent my-first-agent -n kagent -o jsonpath='{.status.conditions}' | jq`.
Look at `ResolvedRefs` (a missing ModelConfig, Harness or WorkerPool),
`Compatible` and `Ready`.

**Agent ignores tools or loses context.**
Use a larger tool-capable model, or raise the context window by adding
`options: {num_ctx: "8192"}` under `spec.ollama` in the `ModelConfig`.

## Try next

- **UI:** `kubectl port-forward -n kagent svc/kagent-ui 8082:8080`, then open
  <http://localhost:8082>.
- **Tools:** bind the built-in Kubernetes tools (RemoteMCPServer
  `kagent-tool-server`) under `spec.tools` in the AgentTemplate. Edits apply
  only to new sessions. The tool server runs as `cluster-admin` by default, so
  keep this to throwaway clusters or enable its read-only mode.
- **Watch Substrate suspend and resume a session:** install the `kubectl-ate`
  plugin from the substrate release page, then
  `kubectl ate get actors --atespace kagent` between messages
  (`ACTOR_STATE_SUSPENDED` while idle).
- **Checkpoints and forks:** available through the gRPC `CheckpointService`
  (needs `grpcReflection: true`, already set in `config/kagent-values.yaml`) and
  the Fork button in the UI.

## References

- kagent installation: <https://kagent.dev/docs/kagent/latest/setup/installation/>
- Ollama provider: <https://kagent.dev/docs/kagent/latest/setup/model-providers/ollama/>
- Your first agent: <https://kagent.dev/docs/kagent/latest/get-started/your-first-agent/>
- kagent repository: <https://github.com/kagent-dev/kagent>
- Substrate repository: <https://github.com/kagent-dev/substrate>
