# nginx-ubi9

nginx static-file / SPA web server on Red Hat UBI9-micro — a UBI-rooted, digest-pinned
replacement for `nginxinc/nginx-unprivileged:alpine`. Runs **non-root (uid 1001)** on
**port 8080** and serves a single-page app with history fallback out of the box.

## Pull

```bash
podman pull ghcr.io/nq-rdl/nginx-ubi9:latest
```

## Supported tags

- `1.26.3` — specific nginx version, latest UBI9 patch
- `1.26` — latest patch of nginx 1.26.x
- `latest` — latest nginx version, latest UBI9 patch

Pin by `@sha256:…` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi-micro:9.5` |
| Runtime | nginx 1.26.3 (UBI9 AppStream module stream) |
| Platforms | linux/amd64 |
| User | 1001 (non-root) |
| Port | 8080 |
| Document root | `/usr/share/nginx/html` |

## Built-in config

The image ships a generic SPA config (`/etc/nginx/conf.d/default.conf`):

- SPA history fallback — `try_files $uri $uri/ /index.html`
- gzip compression
- Security headers — `X-Frame-Options`, `X-Content-Type-Options`, `X-XSS-Protection`
- Long-cache rule for fingerprinted static assets
- `GET /health` → `200 healthy`

Rootless operation is handled in `/etc/nginx/nginx.conf`: the PID file and all `*_temp_path`
spool directories live under `/tmp`, and logs go to stdout/stderr.

## Usage as a runtime image

```dockerfile
# build your SPA in an earlier stage, then:
FROM ghcr.io/nq-rdl/nginx-ubi9@sha256:<digest>
COPY --from=builder /app/build /usr/share/nginx/html
# default ENTRYPOINT serves on :8080 as uid 1001 — nothing else required
```

### Adding an in-cluster API reverse proxy (optional)

The base config intentionally ships **no** `/api/` proxy — the upstream is consumer-specific. An
nginx `location` must live inside a `server { }` block, so nginx will not merge a stray snippet
into the shipped server automatically. The cleanest way to add a proxy is to **replace**
`/etc/nginx/conf.d/default.conf` with your own copy that keeps the SPA setup and adds the
`/api/` location:

```dockerfile
COPY default.conf /etc/nginx/conf.d/default.conf   # your copy, based on the image's default
```

```nginx
# your default.conf — the same :8080 server, plus an /api/ proxy
server {
    listen 8080;
    # ... SPA fallback, security headers and /health, copied from the image's default.conf ...

    location /api/ {
        proxy_pass         http://rdl-backend.rdl.svc:80/;
        proxy_http_version 1.1;
        proxy_set_header   Host $host;
    }
}
```

## Verify

```bash
gh attestation verify oci://ghcr.io/nq-rdl/nginx-ubi9:latest \
  --repo nq-rdl/container-images
```
