# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

このリポジトリは **homelab-gitops (`ROBO358/homelab-gitops`) の `apps/` レイヤに接続するアプリリポジトリのテンプレート**であり、同時に各プラットフォーム機能（ESO / Longhorn / cert-manager / Cilium Gateway / Cloudflare Tunnel / Prometheus）を検証するスモークテストアプリでもある。

- GitHub リポジトリ: `ROBO358/sample-app-k8s`
- コンテナイメージ: `ghcr.io/robo358/sample-app-k8s`（linux/amd64）
- デプロイ先 namespace: `sample-app`（namespace 自体は homelab-gitops 側で管理）

## リポジトリ構成

```
src/               # アプリケーション本体（変更すると CI が走りイメージが更新される）
  Dockerfile       # nginxinc/nginx-unprivileged:1.27-alpine ベース、port 8080
  nginx.conf
  default.conf
  docker-entrypoint.sh   # 起動時に index.html.tmpl を render して nginx を起動
  index.html.tmpl  # __SECRET_HASH__ / __HOSTNAME__ / __BUILT_AT__ / __DATA_MTIME__ を展開

manifests/         # Kubernetes マニフェスト（Flux が直接 apply する）
  kustomization.yaml     # ★ CI が自動で image tag を更新するファイル
  deployment.yaml
  service.yaml
  gateway.yaml
  httproute.yaml
  httproute-tunnel.yaml
  certificate.yaml
  externalsecret.yaml
  pvc.yaml
  ciliumnetworkpolicy.yaml
  servicemonitor.yaml
  prometheusrule.yaml
```

## CI/CD フロー

```
src/** を push
  │
  ▼
GitHub Actions (build.yml)
  ├── Docker build → ghcr.io/robo358/sample-app-k8s:sha-<short_sha>
  ├── ghcr.io/robo358/sample-app-k8s:main タグも付与
  └── kustomize edit set image で manifests/kustomization.yaml の newTag を sha-<short_sha> に更新
        → "chore(image): bump to sha-<short_sha> [skip ci]" でコミット・プッシュ

Flux (homelab-gitops) が 1 分ごとにこのリポジトリをポーリング
  └── manifests/ の変更を sample-app namespace に apply
```

`manifests/` のみ変更した場合は CI は走らず、Flux が直接 apply する。

## manifests/ の各リソース

| ファイル | 内容 |
|---|---|
| `deployment.yaml` | nginx(port 8080) + nginx-exporter(port 9113) の 2 コンテナ。initContainer で PVC に sentinel ファイルを書き込む |
| `service.yaml` | port 80 → 8080 |
| `gateway.yaml` | GatewayClass: cilium、LB IP: `192.168.1.102`、TLS 終端 (sample-app-tls) |
| `httproute.yaml` | `sample-app.yh.k8s.tsuru.run` → sample-app-gateway（LAN アクセス用） |
| `httproute-tunnel.yaml` | `sample-app-yh-k8s.tsuru.run` → cloudflare-gateway/yh-cluster（Cloudflare Tunnel 公開用） |
| `certificate.yaml` | `sample-app.yh.k8s.tsuru.run` を letsencrypt-prod で発行 |
| `externalsecret.yaml` | 1Password `eso-smoke-test/notesPlain` → Secret `sample-app-secret`（ESO 動作確認用） |
| `pvc.yaml` | Longhorn 1Gi PVC（PV 永続化の動作確認用） |
| `ciliumnetworkpolicy.yaml` | ingress: intra-ns / cilium gateway / cloudflare-gateway / prometheus のみ許可 |
| `servicemonitor.yaml` | Prometheus が port 9113 (nginx-exporter) を 30s ごとにスクレイプ |
| `prometheusrule.yaml` | SampleAppDown / SampleAppNoConnections アラート |

## homelab-gitops との責任分界

| 責務 | 配置先 |
|---|---|
| Namespace, PodSecurity | homelab-gitops `apps/sample-app/namespace.yaml` |
| RBAC (SA / ClusterRoleBinding) | homelab-gitops `apps/sample-app/rbac.yaml` |
| ReferenceGrant（cloudflare-gateway 参照許可） | homelab-gitops `apps/sample-app/referencegrant.yaml` |
| GitRepository / Flux Kustomization 定義 | homelab-gitops `apps/sample-app/source.yaml` |
| アプリ workload（Deployment / Service / PVC 等） | **このリポジトリ** `manifests/` |

**このリポジトリの `manifests/` に SA / ClusterRole / Binding を置いてはいけない**。RBAC monotonicity 制約により app リポ側に SA 作成権を委譲すると tenant が自己昇格できるため、RBAC 境界の定義は homelab-gitops 側が保持する。

## このリポジトリを新アプリのテンプレートとして使う手順

homelab-gitops CLAUDE.md「新しいアプリリポジトリを追加する手順」参照。要点:

1. このリポジトリを `ROBO358/<app-name>-k8s` として clone
2. `src/` を実装差し替え
3. `manifests/` 内のホスト名（`sample-app.yh.k8s.tsuru.run` / `sample-app-yh-k8s.tsuru.run`）、LB IP（`192.168.1.102`）、Secret 名、app ラベルを置換
4. homelab-gitops `apps/` に 1 ディレクトリ追加

## docker-entrypoint.sh の動作

nginx 起動前に `index.html.tmpl` を以下の値で展開して `/usr/share/nginx/html/index.html` に書き出す:

- `__SECRET_HASH__`: `/eso/notesPlain`（ESO 注入 Secret）の SHA-256
- `__HOSTNAME__`: Pod 名
- `__BUILT_AT__`: ビルド時刻（Docker build-arg `BUILT_AT` = GitHub commit timestamp）
- `__DATA_MTIME__`: `/var/lib/sample-app/.mtime`（Longhorn PVC）の最終更新時刻

## CiliumNetworkPolicy の変更注意点

ingress ルールは 4 種が必要:
1. intra-namespace（同 namespace 内の通信）
2. `fromEntities: ingress`（Cilium Gateway proxy からの LAN HTTPS）→ port 8080
3. `io.kubernetes.pod.namespace: cloudflare-gateway`（Cloudflare Tunnel cloudflared pods）→ port 8080
4. `app.kubernetes.io/name: prometheus`（Prometheus スクレイプ）→ port 9113

新しいアプリを作るときはこのパターンを踏襲し、不要なルールは削除する。
