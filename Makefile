# Makefile
#
# A Makefile gives you short named commands (called "targets") for common tasks.
# Run any target with: make <target>  e.g.  make cluster-up
#
# .PHONY tells make these are not filenames — they're always commands.
# Without it, make would skip a target if a file with the same name existed.

.PHONY: cluster-up cluster-down build load deploy dev-up dev-down status logs canary-deploy canary-rollback canary-forward

# ── Cluster lifecycle ─────────────────────────────────────────────────────────

# Create a local kind cluster using the port-mapping config we wrote.
# This spins up a full Kubernetes cluster inside Docker on your laptop.
# Takes ~30 seconds. Only needs to be done once.
cluster-up:
	kind create cluster --name llm --config k8s/kind-config.yaml

# Delete the local cluster and free all its resources.
cluster-down:
	kind delete cluster --name llm

# ── Image workflow ────────────────────────────────────────────────────────────

# Build the backend Docker image locally (CPU mode, no GPU required).
# The tag "llm-backend:local" matches what k8s/backend.yaml references.
build:
	docker build -t llm-backend:local ./backend

# Load the backend image into kind from Docker's local cache.
# Only llm-backend:local is loaded this way because it is a single-platform
# image we built ourselves — kind load works reliably for it.
#
# The public images (OpenWebUI, Prometheus, Grafana) are pulled directly by
# Kubernetes on first use. On Apple Silicon Macs, multi-platform images stored
# locally cannot be exported into kind reliably, so we let K8s pull them.
# After the first cluster creation they are cached inside kind and subsequent
# `make dev-up` runs are instant.
load:
	kind load docker-image llm-backend:local --name llm

# Apply all Kubernetes manifests to the cluster.
# We list files explicitly to skip kind-config.yaml, which is a kind-specific
# file that kubectl does not understand.
deploy:
	kubectl apply -f k8s/backend.yaml -f k8s/frontend.yaml -f k8s/prometheus.yaml

# ── Convenience targets ───────────────────────────────────────────────────────

# Full local dev setup in one command:
#   1. Build the image
#   2. Load it into kind
#   3. Deploy all manifests
#   The dependencies after the colon run first, in order.
dev-up: build load deploy
	@echo ""
	@echo "Cluster is up. Access points:"
	@echo "  Backend API : http://localhost:30800"
	@echo "  OpenWebUI   : http://localhost:30300"
	@echo "  Prometheus  : http://localhost:30090"
	@echo "  Grafana     : http://localhost:30030"

# Tear down everything: delete K8s resources and the cluster itself.
dev-down:
	# Delete only the actual K8s manifests — not kind-config.yaml, which is
	# a kind-specific file that kubectl doesn't understand.
	kubectl delete -f k8s/backend.yaml -f k8s/frontend.yaml -f k8s/prometheus.yaml --ignore-not-found
	kind delete cluster --name llm

# ── Debugging helpers ─────────────────────────────────────────────────────────

# Show the state of all pods. Use this to check if pods are Running or crashing.
# Typical pod states:
#   Pending      — waiting to be scheduled (usually: image not found yet)
#   Running      — container started (but may still be loading the model)
#   CrashLoopBackOff — container is crashing repeatedly (check logs)
status:
	kubectl get pods -o wide

# Tail the logs of the backend pod.
# "kubectl logs -l app=backend" selects pods by label.
# "--follow" streams new log lines as they appear (like tail -f).
logs:
	kubectl logs -l app=backend --follow

# ── Canary deployment ─────────────────────────────────────────────────────────

# Start canary: remove the single backend deployment and replace with v1+v2.
# Both have label app=backend so the Service routes to both (50/50 split).
canary-deploy:
	kubectl delete deployment backend --ignore-not-found
	kubectl apply -f k8s/canary/backend-v1.yaml -f k8s/canary/backend-v2.yaml
	@echo "Canary deployed: v1 (stable) + v2 (canary) — 50/50 split"
	@echo "Watch traffic:  for i in \$$(seq 1 20); do curl -s http://localhost:30800/health | python3 -c \"import sys,json; print(json.load(sys.stdin)['version'])\"; done"

# Roll BACK: scale v2 to 0. All traffic goes to v1.
canary-rollback:
	kubectl scale deployment backend-v2 --replicas=0
	@echo "Rolled back — 100% traffic on v1"

# Roll FORWARD: scale v2 to full, remove v1. v2 becomes the new stable.
canary-forward:
	kubectl scale deployment backend-v2 --replicas=1
	kubectl scale deployment backend-v1 --replicas=0
	@echo "Rolled forward — 100% traffic on v2"
