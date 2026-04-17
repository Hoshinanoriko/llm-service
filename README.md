# LLM Service

A production-style LLM inference system with a chat frontend, Kubernetes deployment, observability, CI/CD, and model-routing canary deployments.

## Architecture

```
Browser
  └─► OpenWebUI (chat UI)                      :30300
        └─► Router (model-field dispatch)       :30800
              ├─► backend-v1 (opt-125m)         ClusterIP :8000
              └─► backend-v2 (opt-350m)         ClusterIP :8000

Prometheus (scrapes :9090 on backend pods)      ClusterIP — port-forward for dev access
  └─► Grafana (dashboard)                       ClusterIP — port-forward for dev access
```

All components run as pods in a Kubernetes (kind) cluster. The router reads the `model` field from each request and dispatches to the correct backend — no traffic reaches a backend directly from outside the cluster.

Prometheus and Grafana are ClusterIP only (not exposed externally). Use `make port-forward-prometheus` and `make port-forward-grafana` for local dev access.

## Components

| Component | Technology | Purpose |
|---|---|---|
| Backend | FastAPI + HuggingFace transformers | LLM inference, OpenAI-compatible API |
| Router | FastAPI + httpx | Model-field routing, proxies to correct backend |
| Frontend | OpenWebUI | Chat interface — users pick a model from the dropdown |
| Observability | Prometheus + Grafana | Metrics on a separate internal port (9090) |
| Orchestration | Kubernetes (kind) | Scheduling, restarts, internal DNS, service routing |
| CI/CD | GitHub Actions | Lint → test → build and push Docker image to GHCR |

## Local Development (Docker Compose)

The fastest way to run everything on your laptop — no Kubernetes needed.

**Prerequisites:** Docker Desktop

```bash
docker compose up --build
```

| Service | URL |
|---|---|
| Chat UI | http://localhost:3000 |
| Backend API | http://localhost:8000 |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3001 (admin/admin) |

Stop everything:

```bash
docker compose down
```

## Kubernetes Deployment (kind)

Runs a full Kubernetes cluster locally inside Docker.

**Prerequisites:** Docker Desktop, [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation), [kubectl](https://kubernetes.io/docs/tasks/tools/)

```bash
brew install kind kubectl
```

**First-time setup:**

```bash
make cluster-up
```

**Deploy:**

```bash
make dev-up
```

This builds the backend image, loads it into kind, and applies all manifests. Wait ~2 minutes for the model to finish downloading before sending requests.

| Service | URL |
|---|---|
| Chat UI | http://localhost:30300 |
| Backend API | http://localhost:30800 |
| Prometheus | `make port-forward-prometheus` → http://localhost:9090 |
| Grafana | `make port-forward-grafana` → http://localhost:3000 |

Prometheus and Grafana are internal-only (ClusterIP). Use the port-forward commands above to open a dev tunnel — press Ctrl+C to close it.

**Useful commands:**

```bash
make status                  # show pod health
make logs                    # stream backend logs
make port-forward-prometheus # tunnel to Prometheus (separate terminal)
make port-forward-grafana    # tunnel to Grafana (separate terminal)
make dev-down                # tear down cluster
```

## Canary Deployment (model-routing)

The canary system replaces the single backend with a router plus two versioned backends. Users choose which model they want — traffic is never split randomly.

```bash
make canary-deploy
```

This builds the router image, deploys it alongside `backend-v1` (opt-125m) and `backend-v2` (opt-350m), and wires up the routing table. Both models appear in the OpenWebUI dropdown immediately.

**Roll back** — remove v2, all traffic stays on v1:

```bash
make canary-rollback
```

**Roll forward** — v2 becomes the only available model:

```bash
make canary-forward
```

Roll-back and roll-forward update the router's routing table via `kubectl set env` and trigger a router pod restart (~15 seconds). No inference pods are restarted.

### How the routing works

The router reads the `model` field from each `POST /v1/chat/completions` request body and looks it up in its `ROUTES` environment variable:

```
ROUTES=facebook/opt-125m=http://backend-v1:8000,facebook/opt-350m=http://backend-v2:8000
```

If the model name is not in the table, the router returns HTTP 404 with the list of available models.

### Canary lifecycle

| State | Available models | Traffic |
|---|---|---|
| `make dev-up` | `facebook/opt-125m` | → backend |
| `make canary-deploy` | `facebook/opt-125m` + `facebook/opt-350m` | user chooses |
| `make canary-rollback` | `facebook/opt-125m` only | → backend-v1 |
| `make canary-forward` | `facebook/opt-350m` only | → backend-v2 |

## Observability

Metrics are served on a dedicated internal port (9090) — separate from the public API port (8000). This keeps request rates, error counts, and latency data off the public interface.

Two custom metrics are defined in `backend/server.py`:

| Metric | Type | Description |
|---|---|---|
| `llm_requests_total` | Counter | Total requests, split by `status` label (success/error) |
| `llm_request_duration_seconds` | Histogram | End-to-end latency distribution |

The router adds a third:

| Metric | Type | Description |
|---|---|---|
| `router_requests_total` | Counter | Requests per model per status — shows per-model traffic during canary |

**Grafana setup** (one-time after `make port-forward-grafana`):
1. Open http://localhost:3000, login `admin` / `admin`
2. Connections → Data sources → Add → Prometheus → URL: `http://prometheus:9090`
3. Query `rate(llm_requests_total[1m])` to see live request rate

## CI/CD (GitHub Actions)

On every push or pull request to `main`:

```
lint → test → build-and-push (push to main only)
```

| Job | What it does |
|---|---|
| `lint` | Runs `ruff check` on `backend/` |
| `test` | Runs `pytest backend/test_server.py` — no GPU or model download needed |
| `build-and-push` | Builds Docker image and pushes to GHCR |

Built images are published at:
```
ghcr.io/hoshinanoriko/llm-backend:latest
ghcr.io/hoshinanoriko/llm-backend:<commit-sha>
```

## Running Tests Locally

```bash
backend/.venv/bin/python -m pytest backend/test_server.py -v
```

Tests mock `torch` and `transformers` via `sys.modules` injection — neither package needs to be installed and no model is downloaded. Total runtime is under 1 second.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `MODEL_NAME` | `facebook/opt-125m` | HuggingFace model weights to load (must be a valid HF identifier) |
| `MODEL_ID` | same as `MODEL_NAME` | Logical name advertised in the API — what the router and OpenWebUI see |
| `USE_VLLM` | `false` | Set to `true` to use vLLM async engine (requires x86 Linux + CUDA GPU) |
| `VERSION` | `v1` | Deployment label returned in `/health` — identifies which pod handled a request |
| `METRICS_PORT` | `9090` | Port for Prometheus scraping |
| `START_METRICS_SERVER` | `true` | Set to `false` in tests to skip port binding |

`MODEL_NAME` and `MODEL_ID` are intentionally separate: `MODEL_NAME` controls which weights are downloaded from HuggingFace; `MODEL_ID` controls what name the API advertises. This lets two deployments load the same weights but appear as different models to the router.

## Project Structure

```
llm-service/
├── backend/
│   ├── server.py          # FastAPI server: /health, /v1/models, /v1/chat/completions
│   ├── test_server.py     # Unit tests (mocked — no GPU or model download needed)
│   ├── requirements.txt   # Python dependencies
│   └── Dockerfile         # CPU by default; GPU via --build-arg BASE_IMAGE=vllm/...
├── router/
│   ├── server.py          # Model-field router: reads "model", proxies to backend Service
│   ├── requirements.txt   # fastapi, httpx, prometheus-client
│   └── Dockerfile
├── k8s/
│   ├── backend.yaml       # Single-backend Deployment + NodePort Service (dev mode)
│   ├── frontend.yaml      # OpenWebUI Deployment + NodePort Service
│   ├── prometheus.yaml    # Prometheus + Grafana Deployments (ClusterIP)
│   ├── kind-config.yaml   # kind cluster config with host port mappings
│   └── canary/
│       ├── backend-v1.yaml  # Stable backend + ClusterIP Service
│       ├── backend-v2.yaml  # Canary backend + ClusterIP Service
│       └── router.yaml      # Router Deployment (sits behind the backend Service)
├── .github/workflows/
│   └── ci.yaml            # GitHub Actions: lint → test → build-and-push
├── docker-compose.yaml    # Local multi-container dev setup (no Kubernetes)
├── prometheus.yaml        # Prometheus scrape config for docker-compose
├── Makefile               # All operational commands
└── README.md
```

## How a Request Flows (canary mode)

1. User picks `facebook/opt-350m` in OpenWebUI and sends a message
2. OpenWebUI sends `POST /v1/chat/completions` with `{"model": "facebook/opt-350m", ...}` to the backend NodePort Service (port 30800)
3. The Service routes to the router pod (which carries the `app: backend` label)
4. The router looks up `facebook/opt-350m` in its routing table → finds `http://backend-v2:8000`
5. The router proxies the full request to `backend-v2` (ClusterIP — not externally reachable)
6. `backend-v2` runs inference via `asyncio.to_thread` (non-blocking, concurrent-safe) and returns the OpenAI-format response
7. The router passes the response back to OpenWebUI unchanged
8. Prometheus scrapes `backend-v2:9090` every 15 seconds; Grafana reads from Prometheus
