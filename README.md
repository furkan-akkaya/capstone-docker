# Cloud-Native Capstone — Hardened Docker → Production-Grade Kubernetes

![ci](https://github.com/furkan-akkaya/capstone-docker/actions/workflows/ci.yaml/badge.svg)

A small `nginx → Flask API → PostgreSQL + Redis` stack, taken from a **security-hardened Docker Compose** deployment all the way to a **production-shaped Kubernetes** deployment — with zero-trust network segmentation, Pod Security Admission, autoscaling, and a GitOps-ready Kustomize layout.

The application is deliberately tiny so the interesting part is the **operational and security engineering around it**, not the business logic.

---

## The application

Three HTTP endpoints served by Flask + Gunicorn:

| Endpoint    | What it does                                        |
|-------------|-----------------------------------------------------|
| `/health`   | Liveness/readiness signal — `{"status":"ok"}`       |
| `/`         | Increments a **Redis** counter — proves cache wiring |
| `/db-check` | Runs `SELECT 1` on **PostgreSQL** — proves DB wiring |

---

## Two deployment stages, one codebase

This repo tells a progression. The same four services, the same nginx config, deployed two ways.

### Stage 1 — Hardened Docker Compose

```bash
cp .env.example .env      # then edit POSTGRES_PASSWORD
make compose-up
curl http://localhost:8080/health
```

Layered network isolation with three bridge networks:

```
          host :8080
              │
        ┌─────▼─────┐   public         (only nginx is here)
        │   nginx   │
        └─────┬─────┘
              │         app_net  (internal: true — no route to the internet)
        ┌─────▼─────┐
        │    api    │
        └─────┬─────┘
              │         data_net (internal: true — fully isolated)
      ┌───────┴────────┐
┌─────▼─────┐   ┌──────▼─────┐
│ postgres  │   │   redis    │
└───────────┘   └────────────┘
```

`postgres` and `redis` sit on an `internal: true` network — **unreachable from the host or the internet**, by design.

### Stage 2 — Kubernetes

```bash
# Local, from scratch: creates a kind cluster, builds+loads the image,
# installs ingress-nginx, deploys the dev overlay, and smoke-tests it.
make kind-up

# Or apply to any existing cluster:
kubectl apply -k k8s/overlays/dev     # or overlays/prod
```

The three Docker networks become **NetworkPolicies**; the volume becomes a **PVC**; the healthchecks become **probes**; `depends_on` becomes readiness gating; and the whole thing gains autoscaling, disruption budgets, and Pod Security Admission.

---

## Security posture

Applied consistently across **both** stages:

| Control                     | Docker Compose                     | Kubernetes                                             |
|-----------------------------|------------------------------------|--------------------------------------------------------|
| Run as non-root             | fixed UIDs (`999`, `101`, `1000`)  | `runAsNonRoot` + explicit `runAsUser` per workload     |
| Drop Linux capabilities     | `cap_drop: ALL`                    | `capabilities.drop: [ALL]`                             |
| No privilege escalation     | `no-new-privileges:true`           | `allowPrivilegeEscalation: false`                     |
| Read-only root filesystem   | `read_only: true` + `tmpfs`        | `readOnlyRootFilesystem: true` + `emptyDir`           |
| Syscall filtering           | Docker default seccomp             | `seccompProfile: RuntimeDefault`                       |
| Enforced at admission       | —                                  | **Pod Security Admission: `restricted`** on the namespace |
| Least-privilege API access  | —                                  | dedicated SA per workload, `automountServiceAccountToken: false` |
| Minimal image               | multi-stage build (no gcc/libpq-dev in final image)                        ||
| Secrets                     | `.env` (gitignored)                | `Secret` refs (swap in Sealed Secrets / ESO / SOPS)    |

### Why the hardening matters — the attacker's perspective

None of this is decoration. Each control answers a concrete attack. The point of
the whole design is **defense in depth**: not "prevent every breach" (impossible),
but make sure that a single compromise doesn't cascade into total loss.

| Control | The attack it defeats |
|---|---|
| **Network segmentation** (postgres/redis on an internal-only tier) | Lateral movement. If an attacker pops the edge (nginx), they still **can't pivot to the database** — the data tier isn't even routable from there. Most real breaches are exactly "perimeter popped → walked to the DB"; this cuts that path. |
| **Run as non-root** | Post-exploitation power. Code execution inside the API container lands as an unprivileged user — it can't read root-owned files, can't bind privileged ports, can't tamper with the OS. |
| **Drop ALL capabilities** | Kernel-level abuse. Even *if* the process were root, `CAP_NET_RAW` (packet sniffing/spoofing), `CAP_SYS_ADMIN` (mounts, many escapes), etc. are gone — so the standard container-escape toolbox mostly doesn't work. |
| **`no-new-privileges`** | Privilege escalation. Defeats the classic "exploit a setuid binary to become root" step — the kernel refuses privilege gains for this process tree. |
| **Read-only root filesystem** | Persistence. An attacker can't drop a webshell, backdoor, or modified binary — the disk won't accept writes. Malware that needs to write to survive simply can't. |
| **Seccomp `RuntimeDefault`** | Container escapes. Dangerous/rare syscalls used by kernel exploits are filtered before they reach the kernel. |
| **Pod Security Admission `restricted`** (K8s) | Malicious/misconfigured manifests. A pod that asks for `privileged`, `hostPath`, or root is **rejected at admission** — the guardrail is enforced by the API server, not left to reviewer discipline. |
| **ServiceAccount token automount off** (K8s) | Cluster takeover. A compromised API pod has **no Kubernetes bearer token to steal**, so it can't enumerate secrets or attack the control plane — closing off a huge class of K8s lateral movement. |
| **Secrets out of git** (`.env` / Sealed Secrets / ESO) | Credential leakage. DB passwords never live in the repo as plaintext. |
| **Minimal multi-stage image** (no compiler, no package manager in the final image) | Living-off-the-land. There's no `gcc`, `apt`, or build toolchain for an attacker to compile an exploit or pull tools with. |
| **Resource requests/limits** (K8s) | Resource-exhaustion DoS & cryptomining. A runaway or hijacked container is capped by cgroups and can't starve its neighbours. |

**Walk the kill chain.** Suppose an attacker finds RCE in the Flask app — the worst realistic starting point:

1. They have a shell — but as **uid 1000, non-root**, with **all capabilities dropped**.
2. They try to escalate via a setuid binary → **blocked by `no-new-privileges`**.
3. They try to drop a persistent backdoor → **read-only filesystem refuses the write**.
4. They try to pivot to the database → nginx can't even see it, and from the API tier they reach **only** postgres/redis on the exact ports allowed — nothing else, and never the internet (default-deny egress).
5. On Kubernetes, they look for a service-account token to attack the cluster → **there isn't one mounted**.

Every step after the initial foothold hits a wall. That's the whole point.

### Zero-trust networking (Kubernetes)

`k8s/base/network-policies.yaml` starts with a **default-deny** on all pods (ingress *and* egress), then opens only the required paths:

```
internet ──▶ nginx :8080 ──▶ api :5000 ──┬─▶ postgres :5432
                                          └─▶ redis    :6379
```

- Every pod can reach **only** DNS by default.
- `postgres` and `redis` accept connections **exclusively from `api`**.
- Nothing in the namespace can egress to the internet.

> Requires a NetworkPolicy-enforcing CNI (Calico / Cilium). kind's default `kindnet` accepts the policy objects but does not enforce them — see the note in `scripts/bootstrap-kind.sh`.

---

## Proof of isolation — verify it yourself

The claims above aren't just asserted; they're checked against the running stack.

```bash
make compose-up
make verify-isolation      # or: ./scripts/verify-isolation.sh
```

The script probes the live containers and fails loudly if any control isn't
actually enforced:

```
1. End-to-end path works (internet → nginx → api → postgres/redis)
  ✔ PASS  /health responds
  ✔ PASS  / responds (redis counter)
  ✔ PASS  /db-check responds (postgres)

2. Data tier is NOT exposed to the host  (defeats: direct DB attack from outside)
  ✔ PASS  postgres 5432 refused from host
  ✔ PASS  redis 6379 refused from host

3. Network segmentation  (defeats: lateral movement after edge compromise)
  ✔ PASS  nginx cannot reach postgres (not on data_net)
  ✔ PASS  nginx cannot reach redis (not on data_net)
  ✔ PASS  api can reach postgres + redis (only it is on data_net)

4. Container hardening on the API  (defeats: privilege escalation & persistence)
  ✔ PASS  api runs as non-root (uid=1000)
  ✔ PASS  api rootfs read-only (cannot drop backdoor)
  ✔ PASS  all Linux capabilities dropped (cap_drop: ALL)
  ✔ PASS  privilege escalation disabled (no-new-privileges)
  ✔ PASS  read-only root filesystem enforced by runtime

Summary: 13 passed, 0 failed
All isolation & hardening controls verified.
```

## Repository layout

```
.
├── api/                      # Flask app + multi-stage Dockerfile
├── docker-compose.yml        # Stage 1: hardened Compose stack
├── k8s/
│   ├── base/                 # Stage 2: environment-agnostic manifests
│   │   ├── namespace.yaml            # Pod Security Admission: restricted
│   │   ├── serviceaccounts.yaml      # per-workload SA, token automount off
│   │   ├── secret.yaml               # DB creds (demo placeholder)
│   │   ├── postgres.yaml             # StatefulSet + headless Service + PVC
│   │   ├── redis.yaml                # Deployment + Service
│   │   ├── api.yaml                  # Deployment + Service + probes
│   │   ├── nginx.yaml                # Deployment + Service (+ generated ConfigMap)
│   │   ├── nginx.conf                # single source of truth (Compose + K8s)
│   │   ├── ingress.yaml              # cluster-edge entrypoint
│   │   ├── network-policies.yaml     # zero-trust segmentation
│   │   ├── pdb.yaml                  # PodDisruptionBudgets
│   │   └── kustomization.yaml
│   └── overlays/
│       ├── dev/              # 1 replica per tier — laptop / kind
│       └── prod/             # HA replicas + HPA + immutable registry tag
├── kind/                     # local cluster config
├── scripts/
│   ├── bootstrap-kind.sh     # one-command local cluster + deploy
│   ├── teardown-kind.sh
│   └── verify-isolation.sh   # proves the isolation/hardening controls hold
├── .github/workflows/ci.yaml # render + schema-validate every overlay, build image
└── Makefile
```

Run `make help` to see every task.

---

## Cloud-native concepts demonstrated

- **StatefulSet + `volumeClaimTemplates`** for the database, with `fsGroup` handling volume ownership — the native replacement for the one-shot `pg-init` chown container the Compose stack needed.
- **Kustomize base + overlays** — one source of truth, environment differences expressed as patches (replicas, autoscaling, image tags). No templating engine, GitOps-ready.
- **Probes** — `startupProbe` guards a slow first boot, then `liveness`/`readiness` take over; traffic is only routed to Ready pods.
- **Horizontal Pod Autoscaler** (prod) — CPU-driven scaling with a scale-down stabilization window.
- **PodDisruptionBudget** — keeps a replica serving through node drains and upgrades.
- **Pod Security Admission (`restricted`)** — hardening enforced at the API server, not just hoped for.
- **NetworkPolicy** — explicit, least-privilege east-west traffic.
- **Immutable, registry-hosted image tags** in prod vs. locally-built `:latest` in dev.

---

## Validate locally (no cluster needed)

```bash
# Render both overlays and schema-check every object
kubectl kustomize k8s/overlays/dev  | kubeconform -strict -summary -ignore-missing-schemas
kubectl kustomize k8s/overlays/prod | kubeconform -strict -summary -ignore-missing-schemas
```

CI runs exactly this on every push and pull request.

---

## The debugging story (Stage 1)

The hardening didn't "just work" — several controls collided in instructive ways, each diagnosed by **reading container logs**, not guessing:

1. **Redis/Postgres official images start as root and drop to a non-root user** (`gosu`/`setresuid`); `cap_drop: ALL` blocked that step → started the containers **directly** as the target user (`user: "999:999"`), never touching root.
2. **Postgres couldn't chown its freshly-mounted volume** (it never ran as root, so it lacked the privilege) → added a one-shot `pg-init` busybox to pre-own the volume. *(In Kubernetes, `fsGroup` makes this unnecessary.)*
3. **gVisor (`runsc`) broke the API container's DNS** to Docker's embedded resolver (`Temporary failure in name resolution`) → gVisor was deliberately removed for that service while every other control stayed.
4. **The nginx healthcheck resolved `localhost` to IPv6 (`::1`) and was refused** → pinned to `127.0.0.1`.

---

## Requirements

- **Stage 1:** Docker + Docker Compose
- **Stage 2:** `kubectl`; plus `kind` for a local cluster; `kustomize` + `kubeconform` for offline validation
