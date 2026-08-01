#!/bin/bash
set -euo pipefail

# ============================================================
# Setup complet : cluster k3d (1 noeud) + Calico (pour que les
# NetworkPolicy soient réellement appliquées) + metrics-server
# (requis par les HPA) + déploiement du chart Helm university-app.
# ============================================================

CLUSTER_NAME="university-cluster"
NAMESPACE="university-app"
CHART_PATH="$(cd "$(dirname "$0")/.." && pwd)/university-app"
CALICO_VERSION="v3.28.0"
K3S_POD_CIDR="10.42.0.0/16"   # CIDR par défaut de k3s, doit matcher Calico

log() { echo -e "\n\033[1;34m[setup]\033[0m $1"; }
ok()  { echo -e "\033[1;32m  ✓ $1\033[0m"; }
err() { echo -e "\033[1;31m  ✗ $1\033[0m"; }

# ------------------------------------------------------------
log "1. Vérification des prérequis (docker, k3d, kubectl, helm)"

# Docker n'est jamais auto-installé : trop dépendant de l'OS, nécessite
# souvent sudo + gestion de groupe + redémarrage du service. On vérifie
# juste sa présence et son bon fonctionnement.
if ! command -v docker &>/dev/null; then
  err "docker n'est pas installé. Installe-le manuellement (https://docs.docker.com/engine/install/) puis relance ce script."
  exit 1
fi
if ! docker info &>/dev/null; then
  err "docker est installé mais le daemon ne répond pas (démarre-le, ou vérifie tes permissions sudo/groupe docker)."
  exit 1
fi
ok "docker présent et opérationnel"

install_k3d() {
  log "Installation de k3d (script officiel)"
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
}

install_kubectl() {
  log "Installation de kubectl"
  local kver
  kver=$(curl -sL https://dl.k8s.io/release/stable.txt)
  curl -sLO "https://dl.k8s.io/release/${kver}/bin/linux/amd64/kubectl"
  chmod +x kubectl
  sudo mv kubectl /usr/local/bin/kubectl
}

install_helm() {
  log "Installation de helm (script officiel)"
  curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

if ! command -v k3d &>/dev/null; then
  install_k3d
else
  ok "k3d déjà présent"
fi

if ! command -v kubectl &>/dev/null; then
  install_kubectl
else
  ok "kubectl déjà présent"
fi

if ! command -v helm &>/dev/null; then
  install_helm
else
  ok "helm déjà présent"
fi

# Revérification finale : si l'install automatique a échoué (OS non
# Linux/amd64, pas de sudo, etc.), on s'arrête proprement plutôt que de
# continuer avec un outil manquant.
for cmd in k3d kubectl helm; do
  if ! command -v "$cmd" &>/dev/null; then
    err "$cmd toujours introuvable après tentative d'installation automatique."
    err "Installe-le manuellement puis relance ce script."
    exit 1
  fi
done
ok "k3d, kubectl, helm présents"

# ------------------------------------------------------------
log "2. Création du cluster k3d (1 noeud, Flannel désactivé pour Calico)"
if k3d cluster list | grep -q "^${CLUSTER_NAME}"; then
  ok "Le cluster ${CLUSTER_NAME} existe déjà, on le réutilise"
else
  k3d cluster create "${CLUSTER_NAME}" \
    --servers 1 \
    --agents 0 \
    --k3s-arg "--flannel-backend=none@server:*" \
    --k3s-arg "--disable-network-policy@server:*" \
    --port "8080:80@loadbalancer"
  ok "Cluster créé"
fi

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null

# ------------------------------------------------------------
log "3. Attente que les noeuds soient enregistrés"
for i in $(seq 1 30); do
  if kubectl get nodes &>/dev/null; then
    ok "API server accessible"
    break
  fi
  sleep 2
done

# ------------------------------------------------------------
log "4. Installation de Calico (CNI, nécessaire pour les NetworkPolicy)"
if kubectl get ns calico-system &>/dev/null; then
  ok "Calico déjà présent"
else
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

  # Le CIDR par défaut du manifest Calico ne correspond pas à celui de k3s :
  # on le corrige pour que le routage des pods fonctionne.
  log "Ajustement du CIDR Calico pour correspondre à k3s (${K3S_POD_CIDR})"
  kubectl set env daemonset/calico-node -n kube-system \
    CALICO_IPV4POOL_CIDR="${K3S_POD_CIDR}" 2>/dev/null || true
fi

log "Attente que Calico soit opérationnel (peut prendre 1-2 min)"
kubectl wait --for=condition=Ready pods -l k8s-app=calico-node -n kube-system --timeout=180s || {
  err "Calico met du temps à démarrer, vérifie 'kubectl get pods -n kube-system' si le script bloque plus loin"
}
ok "Calico opérationnel"

# ------------------------------------------------------------
log "5. Attente que le noeud soit Ready (réseau opérationnel)"
kubectl wait --for=condition=Ready nodes --all --timeout=120s
ok "Noeud Ready"

# ------------------------------------------------------------
log "6. Installation de metrics-server (nécessaire pour les HPA)"
if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
  ok "metrics-server déjà installé"
else
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  # k3d utilise des certificats auto-signés en interne : nécessaire en local.
  kubectl patch deployment metrics-server -n kube-system --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  ok "metrics-server installé (mode --kubelet-insecure-tls, adapté au cluster local uniquement)"
fi

log "Attente que metrics-server soit prêt"
kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=120s
ok "metrics-server prêt"

# ------------------------------------------------------------
log "7. Déploiement du chart Helm university-app"
helm upgrade --install university-app "${CHART_PATH}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --wait=false
ok "Chart Helm appliqué"

# ------------------------------------------------------------
log "8. Attente que tous les pods applicatifs soient Ready (jusqu'à 3 min)"
kubectl wait --for=condition=Ready pods --all -n "${NAMESPACE}" --timeout=180s || {
  err "Certains pods ne sont pas encore Ready. Diagnostic ci-dessous :"
  kubectl get pods -n "${NAMESPACE}"
  kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -20
  exit 1
}
ok "Tous les pods sont Ready"

# ------------------------------------------------------------
log "9. Résumé du déploiement"
echo ""
kubectl get pods -n "${NAMESPACE}" -o wide
echo ""
kubectl get svc -n "${NAMESPACE}"
echo ""
kubectl get hpa -n "${NAMESPACE}"
echo ""
kubectl get ingress -n "${NAMESPACE}"

FRONTEND_HOST=$(kubectl get ingress -n "${NAMESPACE}" -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "university.local")

echo ""
ok "Déploiement terminé avec succès"
echo ""
echo "  Pour accéder au frontend :"
echo "    1. Ajoute cette ligne à /etc/hosts :"
echo "       127.0.0.1 ${FRONTEND_HOST}"
echo "    2. Ouvre : http://${FRONTEND_HOST}:8080"
echo ""