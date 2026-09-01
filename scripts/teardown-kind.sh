#!/usr/bin/env bash
# Delete the local kind cluster created by bootstrap-kind.sh.
set -euo pipefail
kind delete cluster --name capstone
