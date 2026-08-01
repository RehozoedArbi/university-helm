# university-app — déploiement K8s (k3d + Helm)

## Structure

```
university-helm/
├── university-app/          # Chart Helm
│   ├── Chart.yaml
│   ├── values.yaml           # Toute la config (images, ressources, replicas...)
│   └── templates/
│       ├── namespace.yaml
│       ├── network-policies.yaml       # Deny-all + autorisations explicites
│       ├── postgres/
│       │   ├── secret.yaml
│       │   ├── configmap-init.yaml
│       │   ├── statefulset.yaml
│       │   └── service.yaml            # Headless
│       ├── student-service/
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   └── hpa.yaml
│       ├── teacher-admin-service/
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   └── hpa.yaml
│       ├── enrollment-service/
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   └── hpa.yaml
│       └── frontend/
│           ├── deployment.yaml
│           ├── service.yaml
│           └── ingress.yaml
└── scripts/
    ├── 01-setup-cluster.sh   # Crée tout, du cluster au déploiement
    └── 02-teardown.sh        # Détruit le cluster proprement
```

Helm rend automatiquement tous les fichiers `.yaml` sous `templates/`,
quelle que soit leur profondeur de sous-dossier — ce découpage par
composant n'a donc aucun impact fonctionnel, seulement sur la lisibilité.

## Prérequis

- `docker`, `k3d`, `kubectl`, `helm` installés
- Les 4 images doivent être présentes sur Docker Hub sous `darbi/university-*`
  (déjà fait, tag `latest` actuellement)

## ⚠️ Avant de lancer — points à vérifier

1. **Mot de passe par défaut** : `values.yaml` contient des mots de passe
   placeholder (`CHANGE_ME_*`). Remplace-les avant tout usage sérieux, via
   `--set postgres.auth.postgresPassword=...` au moment du `helm install`,
   ou dans une copie de `values.yaml` non commitée.
2. **Tag `latest`** : à remplacer par des tags versionnés (`v1`, `v2`...)
   dès que tu prépares ton scénario de rollback — `latest` ne permet pas de
   distinguer deux versions.
3. **Valide le chart avant de déployer** :
   ```bash
   helm lint university-app/
   helm template university-app/ | kubectl apply --dry-run=client -f -
   ```

## Utilisation

**Tout déployer** (cluster + Calico + metrics-server + app) :
```bash
chmod +x scripts/*.sh
./scripts/01-setup-cluster.sh
```

**Tout détruire** :
```bash
./scripts/02-teardown.sh
```

## Vérifier que tout fonctionne

```bash
kubectl get pods -n university-app
kubectl get hpa -n university-app
kubectl get networkpolicy -n university-app
```

Accès au frontend : ajoute `127.0.0.1 university.local` à `/etc/hosts`,
puis ouvre `http://university.local:8080`.

## Notes techniques importantes

- **Calico remplace Flannel** : nécessaire pour que les `NetworkPolicy`
  soient réellement appliquées (Flannel, le CNI par défaut de k3d, les
  ignore silencieusement).
- **1 seul noeud k3d** : décision assumée, pas de test de résilience
  multi-noeuds dans ce projet.
- **1 seul pod Postgres (StatefulSet + PVC)** : pas de haute disponibilité,
  cohérent avec un usage de test/démo, pas de production.
- **`readOnlyRootFilesystem: true`** sur les 4 services applicatifs : les
  chemins nécessitant de l'écriture (`/tmp`, cache nginx) sont montés en
  `emptyDir` séparément.
