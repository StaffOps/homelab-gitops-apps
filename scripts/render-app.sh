#!/usr/bin/env bash
# Render an app the way Argo CD does and check it, without touching the cluster.
#
#   scripts/render-app.sh --list                 apps (top-level directories with a helmfile, "_*" skipped)
#   scripts/render-app.sh <app>                  every release of the app
#   scripts/render-app.sh <app> --out <file>     keep the rendered manifests
#   scripts/render-app.sh --all                  render every app (what CI would run)
#
# Runs "helmfile template --include-crds" (the plugin's HELMFILE_TEMPLATE_OPTIONS) with the platform's
# capabilities. Checks: render succeeds, every document parses, no unpinned images, no Secret with literal data,
# no escaped template left, each release has its <app>/<release>/ directory (ApplicationSet apps in
# homelab-gitops creates one Application per such directory), the release namespace is the app directory, and no
# cluster-scoped object other than Namespace (AppProject apps refuses them).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHARTS="$ROOT"
API_ARGS='--api-versions postgresql.cnpg.io/v1 --api-versions keda.sh/v1alpha1 --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/PrometheusRule --api-versions monitoring.coreos.com/v1/ServiceMonitor --api-versions gateway.networking.k8s.io/v1 --api-versions cert-manager.io/v1 --api-versions external-secrets.io/v1 --api-versions metallb.io/v1beta1'

fail() { echo "✘ $*" >&2; exit 1; }

list_apps() {
    (cd "$CHARTS" && find . -mindepth 2 -maxdepth 2 -name helmfile.yaml.gotmpl) | sed 's|^\./||; s|/[^/]*$||' | grep -v '^_' | sort -u
}

case "${1:-}" in
    --list) list_apps; exit 0 ;;
    --all)
        rc=0
        for app in $(list_apps); do
            echo "=== $app"
            "$0" "$app" >/dev/null 2>"$(mktemp)" && echo "✔ $app" || { echo "✘ $app"; rc=1; }
        done
        exit $rc
        ;;
    "") fail "usage: scripts/render-app.sh <path> [--out <file>] | --list | --all" ;;
esac

APP="$1"
DIR="$CHARTS/$APP"
[ -f "$DIR/helmfile.yaml.gotmpl" ] || fail "no $APP/helmfile.yaml.gotmpl (apps: $(list_apps | tr '\n' ' '))"
OUT=""
[ "${2:-}" = "--out" ] && OUT="${3:?--out needs a file}"

for t in helmfile helm yq; do command -v "$t" >/dev/null || fail "$t not found"; done

umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RENDER="$TMP/render.yaml"

echo "Rendering $APP…"
(cd "$DIR" && helmfile template --include-crds --args "$API_ARGS" >"$RENDER" 2>"$TMP/err") || {
    grep -vE 'Adding repo|has been added|already exists|Building dependency|Templating release' "$TMP/err" |
        grep -viE 'password|token' | tail -25 >&2
    fail "render failed"
}

yq -e '.' "$RENDER" >/dev/null 2>&1 || fail "rendered output is not valid YAML"

images() {
    # helm test hooks are skipped: Argo CD never applies them
    yq -N 'select(.kind != "CustomResourceDefinition") | select((.metadata.annotations["helm.sh/hook"] // "") | test("^test") | not) | .. | select(tag == "!!map" and has("image")) | .image | select(tag == "!!str")' \
        "$RENDER" 2>/dev/null
}

echo
echo "Objects:"
yq -N '.kind' "$RENDER" | grep -v '^null$' | sort | uniq -c | sort -rn | sed 's/^/  /'
echo
echo "Images:"
{ images | grep -v -E '^(null)?$' || echo "(none)"; } | sort -u | sed 's/^/  /'

problems=0
if images | grep -E ':latest(@|$)|^[^:@]+$' | grep -v -E '^(null)?$'; then
    echo "✘ images without a pinned tag (above)" >&2
    problems=$((problems + 1))
fi
literal=$(yq -N 'select(.kind == "Secret" and (.data != null or .stringData != null)) | .metadata.name' "$RENDER" | grep -v '^null$' || true)
[ -z "$literal" ] || echo "! Secrets with literal data — check none holds a credential: $(echo "$literal" | tr '\n' ' ')" >&2
if grep -n '{{`' "$RENDER" >&2; then
    echo "✘ escaped template left in the output (above)" >&2
    problems=$((problems + 1))
fi
# Layout the ApplicationSet relies on: every release has <app>/<release>/ and lives in namespace <app>
releases=$(cd "$DIR" && helmfile list --output json 2>/dev/null | yq -p json -N '.[] | .name + " " + .namespace') ||
    { echo "✘ helmfile list failed" >&2; problems=$((problems + 1)); }
while read -r rel ns; do
    [ -n "$rel" ] || continue
    [ -d "$DIR/$rel" ] || { echo "✘ release $rel has no directory $APP/$rel/ (no Application would be created)" >&2; problems=$((problems + 1)); }
    [ "$ns" = "$APP" ] || { echo "✘ release $rel namespace '$ns' is not '$APP'" >&2; problems=$((problems + 1)); }
done <<<"$releases"
# Cluster-scoped kinds (only Namespace is allowed by AppProject apps; a chart that needs more belongs in homelab-gitops)
cluster=$(yq -N '.kind' "$RENDER" | grep -x -E 'CustomResourceDefinition|ClusterRole|ClusterRoleBinding|MutatingWebhookConfiguration|ValidatingWebhookConfiguration|ValidatingAdmissionPolicy|ValidatingAdmissionPolicyBinding|APIService|StorageClass|PersistentVolume|PriorityClass|RuntimeClass|IngressClass|GatewayClass|ClusterIssuer|ClusterSecretStore|ClusterExternalSecret|ClusterPolicy|ClusterTriggerAuthentication|ClusterServingRuntime|ClusterImagePolicy' | sort -u || true)
[ -z "$cluster" ] || { echo "✘ cluster-scoped kinds that AppProject apps refuses: $(echo "$cluster" | tr '\n' ' ')" >&2; problems=$((problems + 1)); }

[ -n "$OUT" ] && cp "$RENDER" "$OUT" && echo && echo "Manifests saved to $OUT"
[ "$problems" -eq 0 ] || exit 1
echo
echo "✔ $APP renders"
