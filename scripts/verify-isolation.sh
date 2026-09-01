#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Proof of isolation & hardening.
#
# Runs a series of checks against the LIVE Docker Compose stack and asserts that
# every security control actually holds — not just that it's written in a config
# file. Each check maps to an attack it is meant to defeat.
#
#   Usage:  make compose-up   &&   ./scripts/verify-isolation.sh
#
# Exits non-zero if ANY control is not enforced.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASE="http://localhost:8080"
pass=0; fail=0
ok(){ printf '  \033[32m✔ PASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31mx FAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
hdr(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

hdr "1. End-to-end path works (internet → nginx → api → postgres/redis)"
curl -fsS "$BASE/health"   >/dev/null 2>&1 && ok "/health responds"              || no "/health failed"
curl -fsS "$BASE/"         >/dev/null 2>&1 && ok "/ responds (redis counter)"    || no "/ failed"
curl -fsS "$BASE/db-check" >/dev/null 2>&1 && ok "/db-check responds (postgres)" || no "/db-check failed"

hdr "2. Data tier is NOT exposed to the host  (defeats: direct DB attack from outside)"
if timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/5432" 2>/dev/null; then
  no "postgres 5432 reachable from host"; exec 3>&- 2>/dev/null
else ok "postgres 5432 refused from host"; fi
if timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/6379" 2>/dev/null; then
  no "redis 6379 reachable from host"; exec 3>&- 2>/dev/null
else ok "redis 6379 refused from host"; fi

hdr "3. Network segmentation  (defeats: lateral movement after edge compromise)"
# nginx lives on public/app_net only — it must not even resolve the data tier.
docker compose exec -T nginx sh -c 'nc -z -w3 postgres 5432' >/dev/null 2>&1 \
  && no "nginx CAN reach postgres" || ok "nginx cannot reach postgres (not on data_net)"
docker compose exec -T nginx sh -c 'nc -z -w3 redis 6379' >/dev/null 2>&1 \
  && no "nginx CAN reach redis" || ok "nginx cannot reach redis (not on data_net)"
# api is the only tier allowed onto data_net.
docker compose exec -T api python3 - >/dev/null 2>&1 <<'PY' \
  && ok "api can reach postgres + redis (only it is on data_net)" || no "api cannot reach data tier"
import socket
for h, p in (("postgres", 5432), ("redis", 6379)):
    socket.create_connection((h, p), 3).close()
PY

hdr "4. Container hardening on the API  (defeats: privilege escalation & persistence)"
uid=$(docker compose exec -T api id -u 2>/dev/null | tr -d '\r')
[ -n "$uid" ] && [ "$uid" != "0" ] && ok "api runs as non-root (uid=$uid)" || no "api runs as root"
# read-only rootfs: an attacker with RCE cannot drop a backdoor file.
docker compose exec -T api sh -c 'touch /app/backdoor' >/dev/null 2>&1 \
  && no "api rootfs is writable (backdoor dropped!)" || ok "api rootfs read-only (cannot drop backdoor)"
# Evidence from the runtime config itself:
docker inspect capstone-api --format '{{json .HostConfig.CapDrop}}' 2>/dev/null | grep -qi 'ALL' \
  && ok "all Linux capabilities dropped (cap_drop: ALL)" || no "capabilities not dropped"
docker inspect capstone-api --format '{{json .HostConfig.SecurityOpt}}' 2>/dev/null | grep -q 'no-new-privileges' \
  && ok "privilege escalation disabled (no-new-privileges)" || no "no-new-privileges missing"
docker inspect capstone-api --format '{{.HostConfig.ReadonlyRootfs}}' 2>/dev/null | grep -q 'true' \
  && ok "read-only root filesystem enforced by runtime" || no "rootfs not read-only"

printf '\n\033[1mSummary:\033[0m %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || { printf '\033[31mSome controls are NOT enforced.\033[0m\n'; exit 1; }
printf '\033[32mAll isolation & hardening controls verified.\033[0m\n'
