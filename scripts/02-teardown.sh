#!/bin/bash
set -euo pipefail

# ============================================================
# Destruction complète du cluster k3d (repartir sur une base saine).
# ============================================================

CLUSTER_NAME="university-cluster"

log() { echo -e "\n\033[1;34m[teardown]\033[0m $1"; }
ok()  { echo -e "\033[1;32m  ✓ $1\033[0m"; }

if k3d cluster list | grep -q "^${CLUSTER_NAME}"; then
  log "Suppression du cluster ${CLUSTER_NAME}"
  k3d cluster delete "${CLUSTER_NAME}"
  ok "Cluster supprimé"
else
  ok "Aucun cluster ${CLUSTER_NAME} à supprimer"
fi
