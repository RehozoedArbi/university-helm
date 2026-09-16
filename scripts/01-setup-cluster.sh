#!/bin/bash
set -euo pipefail

# ============================================================
# Setup complet : cluster k3d (1 noeud) + Calico + metrics-server
# + OpenTelemetry Operator + university-app + university-monitoring
# + ArgoCD
#
# Ordre intentionnel : OTel Operator + Instrumentation sont déployés
# AVANT university-app, ce qui permet l'injection automatique des
# agents au premier scheduling des pods (pas de rollout restart).
# ============================================================

CLUSTER_NAME="university-cluster"
NAMESPACE="university-app"
MONITORING_NAMESPACE="monitoring"
OTEL_NAMESPACE="opentelemetry-operator-system"
ARGOCD_NAMESPACE="argocd"
ARGOCD_PORT="8085"
CHART_PATH="$(cd "$(dirname "$0")/.." && pwd)/university-app"
MONITORING_REPO="https://github.com/RehozoedArbi/univ-monitoring-opentelemetry.git"
MONITORING_CLONE_DIR="/tmp/university-monitoring-deploy"
CALICO_VERSION="v3.28.0"
K3S_POD_CIDR="10.42.0.0/16"

log() { echo -e "\n\033[1;34m[setup]\033[0m $1"; }
ok()  { echo -e "\033[1;32m  ✓ $1\033[0m"; }
err() { echo -e "\033[1;31m  ✗ $1\033[0m"; }

# ------------------------------------------------------------
# Attend qu'une commande réussisse (poll actif), sans jamais
# se contenter d'un délai fixe. Sort le script en erreur si le
# timeout est dépassé (pas de "faux succès" silencieux).
# Usage: wait_until "description" timeout_s interval_s cmd [args...]
# ------------------------------------------------------------
wait_until() {
  local desc="$1"; local timeout="$2"; local interval="$3"; shift 3
  local waited=0
  until "$@" &>/dev/null; do
    if [ "$waited" -ge "$timeout" ]; then
      err "Timeout (${timeout}s) en attendant: ${desc}"
      return 1
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
  ok "$desc"
}

# ------------------------------------------------------------
# Attend que des pods correspondant au selector existent PUIS
# qu'ils soient tous Ready. Corrige le bug où kubectl wait
# échouait instantanément faute de ressources encore créées.
# ------------------------------------------------------------
wait_pods_ready_selector() {
  local ns="$1" selector="$2" timeout="${3:-360}"
  wait_until "pods (${selector}) présents dans ${ns}" 90 3 \
    bash -c "kubectl get pods -n '${ns}' -l '${selector}' --no-headers 2>/dev/null | grep -q ." \
    || exit 1

  log "Attente Ready: pods (${selector}) dans ${ns}"
  if ! kubectl wait --for=condition=Ready pods -l "${selector}" -n "${ns}" --timeout="${timeout}s"; then
    err "Des pods (${selector}) ne sont pas Ready dans ${ns} :"
    kubectl get pods -n "${ns}" -l "${selector}" -o wide
    kubectl get events -n "${ns}" --sort-by='.lastTimestamp' | tail -20
    exit 1
  fi
  ok "Pods (${selector}) Ready dans ${ns}"
}

wait_pods_ready_all() {
  local ns="$1" timeout="${2:-360}"
  wait_until "au moins un pod présent dans ${ns}" 90 3 \
    bash -c "kubectl get pods -n '${ns}' --no-headers 2>/dev/null | grep -q ." \
    || exit 1

  log "Attente Ready: tous les pods dans ${ns}"
  if ! kubectl wait --for=condition=Ready pods --all -n "${ns}" --timeout="${timeout}s"; then
    err "Certains pods ne sont pas Ready dans ${ns} :"
    kubectl get pods -n "${ns}" -o wide
    kubectl get events -n "${ns}" --sort-by='.lastTimestamp' | tail -20
    exit 1
  fi
  ok "Tous les pods sont Ready dans ${ns}"
}

# ============================================================
log "1. Vérification des prérequis (docker, k3d, kubectl, helm)"

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

if ! command -v k3d &>/dev/null;    then install_k3d;    else ok "k3d déjà présent";    fi
if ! command -v kubectl &>/dev/null; then install_kubectl; else ok "kubectl déjà présent"; fi
if ! command -v helm &>/dev/null;   then install_helm;   else ok "helm déjà présent";   fi
if ! command -v git &>/dev/null; then
  err "git n'est pas installé. Installe-le (apt install git / yum install git) puis relance."
  exit 1
fi
ok "git présent"

for cmd in k3d kubectl helm git; do
  if ! command -v "$cmd" &>/dev/null; then
    err "$cmd toujours introuvable après tentative d'installation automatique."
    exit 1
  fi
done
ok "k3d, kubectl, helm, git présents"

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
wait_until "API server accessible" 60 2 kubectl get nodes || exit 1

# ------------------------------------------------------------
log "4. Installation de Calico (CNI, nécessaire pour les NetworkPolicy)"
if kubectl get ns calico-system &>/dev/null; then
  ok "Calico déjà présent"
else
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
  log "Ajustement du CIDR Calico pour correspondre à k3s (${K3S_POD_CIDR})"
  wait_pods_ready_selector "kube-system" "k8s-app=calico-node" 60 || true
  kubectl set env daemonset/calico-node -n kube-system \
    CALICO_IPV4POOL_CIDR="${K3S_POD_CIDR}"
fi

wait_pods_ready_selector "kube-system" "k8s-app=calico-node" 360

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
  kubectl patch deployment metrics-server -n kube-system --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  ok "metrics-server installé (mode --kubelet-insecure-tls, adapté au cluster local uniquement)"
fi

kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=120s
wait_until "metrics-server sert des métriques" 90 5 kubectl top nodes || exit 1

# ------------------------------------------------------------
log "7. Ajout des dépôts Helm pour le monitoring"
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update open-telemetry
ok "Dépôt open-telemetry ajouté"

# ------------------------------------------------------------
log "8. Installation de l'OpenTelemetry Operator"
if helm status opentelemetry-operator -n "${OTEL_NAMESPACE}" &>/dev/null; then
  ok "OTel Operator déjà installé"
else
  helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
    --namespace "${OTEL_NAMESPACE}" \
    --create-namespace \
    --version 0.65.0 \
    --set manager.collectorImage.repository="otel/opentelemetry-collector-contrib" \
    --set admissionWebhooks.certManager.enabled=false \
    --set admissionWebhooks.autoGenerateCert.enabled=true \
    --wait --timeout=120s
  ok "OTel Operator installé"
fi

log "Attente que l'OTel Operator (pods + webhook) soit vraiment prêt"
wait_pods_ready_selector "${OTEL_NAMESPACE}" "app.kubernetes.io/name=opentelemetry-operator" 360

# ------------------------------------------------------------
log "9. Création du namespace university-app"
# Doit exister avant le déploiement de university-monitoring,
# qui cible ce namespace pour la configuration OTel.
# On pose les labels/annotations attendus par Helm pour éviter
# l'erreur "invalid ownership metadata" au helm install.
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "${NAMESPACE}" \
  app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate namespace "${NAMESPACE}" \
  meta.helm.sh/release-name=university-app \
  meta.helm.sh/release-namespace="${NAMESPACE}" --overwrite
ok "Namespace ${NAMESPACE} prêt (labels Helm posés)"

# ------------------------------------------------------------
log "10. Clone du chart university-monitoring depuis GitHub"
rm -rf "${MONITORING_CLONE_DIR}"
git clone "${MONITORING_REPO}" "${MONITORING_CLONE_DIR}"
ok "Repo cloné dans ${MONITORING_CLONE_DIR}"

MONITORING_CHART_PATH="${MONITORING_CLONE_DIR}"
if [ -f "${MONITORING_CLONE_DIR}/university-monitoring/Chart.yaml" ]; then
  MONITORING_CHART_PATH="${MONITORING_CLONE_DIR}/university-monitoring"
elif [ -f "${MONITORING_CLONE_DIR}/Chart.yaml" ]; then
  MONITORING_CHART_PATH="${MONITORING_CLONE_DIR}"
else
  err "Impossible de localiser Chart.yaml dans le repo cloné."
  find "${MONITORING_CLONE_DIR}" -name "Chart.yaml" | head -10
  exit 1
fi
ok "Chart trouvé : ${MONITORING_CHART_PATH}"

# ------------------------------------------------------------
log "11. Déploiement du chart university-monitoring"
helm upgrade --install university-monitoring "${MONITORING_CHART_PATH}" \
  --namespace "${MONITORING_NAMESPACE}" \
  --create-namespace \
  --wait --timeout=360s
ok "Chart university-monitoring déployé"

wait_pods_ready_all "${MONITORING_NAMESPACE}" 360

# ------------------------------------------------------------
log "12. Déploiement de la ressource Instrumentation OTel"

INSTR_YAML=$(helm template university-monitoring "${MONITORING_CHART_PATH}" \
  --show-only templates/otel-instrumentation/instrumentation.yaml)

# Le webhook d'admission peut accepter des pods "Ready" un peu avant
# d'accepter réellement des requêtes : on retry l'apply au lieu d'un sleep fixe.
apply_instrumentation() {
  echo "${INSTR_YAML}" | kubectl apply -f -
}
waited=0
until apply_instrumentation; do
  waited=$((waited + 3))
  if [ "$waited" -ge 60 ]; then
    err "Impossible d'appliquer la ressource Instrumentation après 60s (webhook OTel indisponible ?)"
    exit 1
  fi
  sleep 3
done
ok "Ressource Instrumentation appliquée"

kubectl get instrumentation -n "${NAMESPACE}" | grep university-instrumentation \
  && ok "Instrumentation créée dans ${NAMESPACE}" \
  || { err "Instrumentation non trouvée dans ${NAMESPACE}"; exit 1; }

# ------------------------------------------------------------
log "13. Déploiement du chart Helm university-app"
# L'Operator et la ressource Instrumentation sont déjà en place :
# les pods reçoivent l'injection OTel dès leur premier scheduling,
# aucun rollout restart ne sera nécessaire.
helm upgrade --install university-app "${CHART_PATH}" \
  --namespace "${NAMESPACE}" \
  --wait --timeout=360s
ok "Chart university-app déployé"

# ------------------------------------------------------------
log "14. Vérification que tous les pods applicatifs sont Ready"
wait_pods_ready_all "${NAMESPACE}" 360

# ------------------------------------------------------------
log "15. Nettoyage du repo cloné"
rm -rf "${MONITORING_CLONE_DIR}"
ok "Dossier temporaire supprimé"

# ------------------------------------------------------------
log "16. Installation d'ArgoCD"
if kubectl get ns "${ARGOCD_NAMESPACE}" &>/dev/null; then
  ok "Namespace ${ARGOCD_NAMESPACE} déjà présent"
else
  kubectl create namespace "${ARGOCD_NAMESPACE}"
fi

kubectl apply --server-side -n "${ARGOCD_NAMESPACE}" -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

wait_pods_ready_all "${ARGOCD_NAMESPACE}" 360
ok "ArgoCD déployé et Ready"

log "17. Exposition d'ArgoCD sur le port ${ARGOCD_PORT}"
pkill -f "port-forward svc/argocd-server" 2>/dev/null || true
sleep 1
nohup kubectl port-forward svc/argocd-server -n "${ARGOCD_NAMESPACE}" \
  "${ARGOCD_PORT}:80" --address 0.0.0.0 \
  > /tmp/argocd-port-forward.log 2>&1 &
disown

wait_until "port-forward ArgoCD actif sur le port ${ARGOCD_PORT}" 30 2 \
  bash -c "curl -sk https://localhost:${ARGOCD_PORT} -o /dev/null" || {
    err "Le port-forward ArgoCD n'a pas démarré, voir /tmp/argocd-port-forward.log"
    cat /tmp/argocd-port-forward.log
    exit 1
  }
ok "ArgoCD accessible sur https://localhost:${ARGOCD_PORT}"

ARGOCD_PASS=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "(secret déjà supprimé, mot de passe changé)")

# ------------------------------------------------------------
log "18. Résumé du déploiement"
echo ""
echo "=== university-app ==="
kubectl get pods -n "${NAMESPACE}" -o wide
echo ""
kubectl get svc -n "${NAMESPACE}"
echo ""
kubectl get hpa -n "${NAMESPACE}"
echo ""
kubectl get ingress -n "${NAMESPACE}"

echo ""
echo "=== monitoring ==="
kubectl get pods -n "${MONITORING_NAMESPACE}" -o wide
echo ""
kubectl get ingress -n "${MONITORING_NAMESPACE}"

echo ""
echo "=== OTel Instrumentation ==="
kubectl get instrumentation -n "${NAMESPACE}"

echo ""
echo "=== ArgoCD ==="
kubectl get pods -n "${ARGOCD_NAMESPACE}"

FRONTEND_HOST=$(kubectl get ingress -n "${NAMESPACE}" \
  -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "university.local")
GRAFANA_HOST=$(kubectl get ingress -n "${MONITORING_NAMESPACE}" \
  -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "grafana.university.local")

echo ""
ok "Déploiement complet terminé avec succès"
echo ""

echo ""
echo "  Frontend  : http://localhost/8080"
echo "  Grafana   :  http://localhost/8080/grafana"
echo "  ArgoCD    : https://localhost:${ARGOCD_PORT}  (admin / ${ARGOCD_PASS})"
echo "              (port-forward en arrière-plan, log: /tmp/argocd-port-forward.log)"
echo ""