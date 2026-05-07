# sample-app-k8s

Template application repository for `yh-cluster`. Demonstrates all infrastructure patterns
used in this homelab's GitOps setup.

## What this app does

A simple nginx web page that:

- **Fetches** a secret from 1Password via External Secrets Operator
- **Displays** the SHA-256 hash of the secret value
- **Proves persistence** via a Longhorn PVC (shows last-modified time of a sentinel file)
- **Exposes Prometheus metrics** via nginx-prometheus-exporter sidecar

## Covered patterns

| Pattern | Resource |
|---|---|
| Secret management | `ExternalSecret` → `sample-app-secret` |
| Persistent storage | `PersistentVolumeClaim` (Longhorn, 1Gi) |
| TLS certificate | `Certificate` (cert-manager, Let's Encrypt) |
| Multi-container pod | init (busybox PVC init) + main (nginx) + sidecar (exporter) |
| LAN access | Cilium `Gateway` + `HTTPRoute` (`sample-app.yh.k8s.tsuru.run`) |
| Internet access | Cloudflare Tunnel `HTTPRoute` (`sample-app-yh-k8s.tsuru.run`) |
| Network policy | `CiliumNetworkPolicy` (default-deny + allow-list) |
| Metrics | `ServiceMonitor` + `PrometheusRule` |

## Repository structure

```
src/                        # Source code built into ghcr.io/robo358/sample-app-k8s
├── Dockerfile              # FROM nginxinc/nginx-unprivileged:1.27-alpine
├── nginx.conf              # global nginx config (unprivileged temp paths)
├── default.conf            # server block (port 8080 + /stub_status)
├── docker-entrypoint.sh    # renders index.html from template at startup
└── index.html.tmpl         # HTML template (placeholders replaced at runtime)

manifests/                  # Kubernetes manifests (applied by Flux via homelab-gitops)
├── kustomization.yaml      # namespace + images: tag pin (updated by GHA bot commit)
├── externalsecret.yaml
├── certificate.yaml
├── pvc.yaml
├── deployment.yaml
├── service.yaml
├── gateway.yaml
├── httproute.yaml
├── httproute-tunnel.yaml
├── ciliumnetworkpolicy.yaml
├── servicemonitor.yaml
└── prometheusrule.yaml

.github/workflows/
└── build.yml               # build → push to ghcr.io → update manifests/kustomization.yaml
```

## Image build & release

GitHub Actions triggers on `push to main` when `src/**` changes:

1. Build `ghcr.io/robo358/sample-app-k8s:sha-<short>` and `:main`
2. Update `manifests/kustomization.yaml` `images[0].newTag` to `sha-<short>` (`[skip ci]` commit)
3. Flux in `yh-cluster` picks up the new tag within ~1 minute

## Using as a template

See `homelab-gitops/README.md` → "アプリケーションを追加する" for the complete step-by-step guide.

Quick summary:

```bash
git clone --depth=1 https://github.com/ROBO358/sample-app-k8s /tmp/tmpl
cp -r /tmp/tmpl/. ~/k8s/<app-name>-k8s/
rm -rf ~/k8s/<app-name>-k8s/.git
cd ~/k8s/<app-name>-k8s

# Replace every occurrence of "sample-app" with your app name
# (covers manifests/*.yaml including image name in kustomization.yaml and build.yml)
APP=<app-name>
sed -i "s/sample-app/${APP}/g" manifests/*.yaml README.md .github/workflows/build.yml

# Replace Cilium Gateway LB IP with your chosen IP
sed -i "s/192.168.1.102/192.168.1.XXX/g" manifests/gateway.yaml

git init && git remote add origin https://github.com/ROBO358/${APP}-k8s.git
git add -A && git commit -m "feat: initial commit from sample-app-k8s template"
git push -u origin main
```

Then follow Steps 4-8 in the homelab-gitops README.

## Deployment design notes

These choices are non-obvious and matter when using this repo as a template:

| Topic | Setting | Reason |
|---|---|---|
| `securityContext.runAsUser: 101` | nginx container | `runAsNonRoot: true` requires a numeric UID; `nginx-unprivileged` runs as UID 101 |
| `securityContext.fsGroup: 101` | pod spec | Longhorn volumes are root-owned by default; `fsGroup` chowns the mount to GID 101 so all containers can write |
| `emptyDir` at `/usr/share/nginx/html` | nginx container | The directory inside the image is root-owned; entrypoint writes `index.html` there at startup |
| `entrypoint` reads PVC, never writes | `docker-entrypoint.sh` | `pvc-init` (UID 65534) owns `.mtime`; nginx (UID 101) can't update it — entrypoint reads mtime with `date -r` |
| `strategy.rollingUpdate.maxSurge: 0` | Deployment | RWO PVC causes RollingUpdate deadlock (new pod can't attach volume until old pod releases it, but old pod won't terminate until new pod is Ready); `maxSurge: 0` makes the old pod terminate first |
| `strategy.type: RollingUpdate` (not `Recreate`) | Deployment | Kubernetes validation forbids `type=Recreate` and `rollingUpdate` coexisting. A Deployment first created without `strategy` has server-owned `rollingUpdate` defaults; patching only `type: Recreate` via SSA leaves those defaults in place and fails validation. `maxSurge: 0` achieves the same behaviour without changing `type`, avoiding the conflict |

## Prerequisites in the cluster

These must be in place before this app can be deployed (all managed by homelab-gitops):

- ESO `ClusterSecretStore onepassword` Ready
- Longhorn StorageClass `longhorn` available
- cert-manager `ClusterIssuer letsencrypt-prod` Ready
- Cilium Gateway API (`GatewayClass cilium`) Ready
- Cloudflare Gateway (`GatewayClass cloudflare`, `Gateway yh-cluster`) Ready
- `ReferenceGrant allow-httproute-from-sample-app` in `cloudflare-gateway` ns
- 1Password item `eso-smoke-test` in `yh-cluster` vault with a `notesPlain` field
