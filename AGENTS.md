# AGENTS.md — homelab-gitops-apps

Rules for AI agents and operators (Claude Code loads it through `CLAUDE.md`).

Workload applications of the StaffOps homelab. The platform (Argo CD, Vault, Keycloak, Istio, observability,
PostgreSQL operator, backups) lives in [StaffOps/homelab-gitops](https://github.com/StaffOps/homelab-gitops); this
repo only holds apps. Argo CD (ApplicationSet `apps`, AppProject `apps` in the platform repo) deploys `main`.

## How an app reaches the cluster

```
<app>/                         # = namespace
    helmfile.yaml.gotmpl       # loads ../environment.yaml; one release per directory below
    <app>/values.yaml.gotmpl   # release "<app>" (the app's chart)
    <app>-raw/                 # release "<app>-raw" (bedag/raw): HTTPRoute, ServiceMonitor, ExternalSecret…
        values.yaml.gotmpl
        resources/*.yaml
```

- The ApplicationSet matches `*/*`: **every directory inside an app directory is a release** and becomes one
  Application named after it (`--selector name=<dir>`), in namespace `<app>`. Directory name = release name, and it
  must be unique in Argo CD (prefix it with the app name). Directories starting with `_` are skipped (templates,
  drafts).
- New app: copy `_template/` to `<app>/`, replace `my-app`, render, commit + push. Remove an app: delete its
  directory (the Application goes away, its resources stay; delete the namespace explicitly).

## Hard rules

1. **Always target context `k8s01` explicitly** (`kubectl --context k8s01`); the kubeconfig holds other clusters.
2. **Never commit or push without the operator's explicit authorization.** Commit only the files of the change, by
   explicit path; Conventional Commits; no AI co-author lines.
3. **Render before every push**: `scripts/render-app.sh <app>` (or `--all`).
4. **What is on `main` is what runs** (auto-sync, selfHeal, prune).
5. **No secrets in git.** Credentials come from Vault through External Secrets; literal `Secret` data is a finding.
6. **4-space indentation** in YAML/gotmpl and bash. **Pinned versions** of charts and images, never `latest`.
7. Nothing from employers or other organizations (names, domains, accounts, internal links): it is a personal lab.
8. **Apps never change the platform.** AppProject `apps` refuses platform/system namespaces and every
   cluster-scoped object except the app's Namespace (no CRDs, ClusterRoles, webhooks, StorageClasses,
   ClusterSecretStores). If an app needs one, it goes to homelab-gitops as a platform change.

## Conventions

- **Platform contract**: `environment.yaml` (domain, gateway, storage class) mirrors values of the platform repo;
  change them there first.
- **Exposure**: HTTPRoute to Gateway `public` (`sectionName: https`), hostname `<app>.<domain>`. Never an Ingress or
  a LoadBalancer Service.
- **Databases**: a CloudNativePG `Cluster` in the app's `-raw` release (operator in the platform).
- **Observability**: ServiceMonitor/PodMonitor and a PrometheusRule (Prometheus selects every namespace); a
  dashboard is a platform change (homelab-gitops `helm-charts/monitoring/monitoring-raw/dashboards/`).
- **Single node**: 1 replica, no PodDisruptionBudgets; storage `local-path` (no replication).
- **Secrets**: Vault `secret/homelab/apps/<namespace>/<name>` through the namespace's own SecretStore `vault`
  (ServiceAccount `vault-reader`, Vault role `apps`; see `_template/my-app-raw/resources/secrets.yaml`). An app reads
  only its own path; the platform's ClusterSecretStore `vault` refuses app namespaces. Values are written by the
  operator (`vault kv put secret/homelab/apps/<namespace>/<name> key=value`), never in git.
- A `{{ … }}` inside a YAML comment of a `.gotmpl` file is still executed.
