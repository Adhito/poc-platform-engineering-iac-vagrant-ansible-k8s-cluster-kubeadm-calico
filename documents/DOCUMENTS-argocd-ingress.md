# ArgoCD Ingress — Access Runbook

Exposes ArgoCD at a `nip.io` hostname through the cluster's ingress-nginx controller,
**in addition to** the NodePort URL (`https://localhost:30002`), which keeps working.

Current URL (this cluster): **https://infra-utility-argocd.192.168.56.240.nip.io**

> Browsers show a self-signed certificate warning on this URL (and on the NodePort URL) —
> that is expected. ArgoCD serves its own self-signed TLS; ingress-nginx forwards to it over
> HTTPS via the `nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"` annotation. Click through it.

## How this is normally applied (automated)

This Ingress is created automatically by Ansible on every `vagrant up` / `vagrant provision devnodeworker02`:

- Template: [`argocd-ingress-nip.yaml.j2`](../script-manifest/utility-argocd/argocd-ingress-nip.yaml.j2)
- Applied by: `ansible/roles/addon_argocd/tasks/main.yaml`

The hostname is built from two values:

| Part | Source | Current value |
|---|---|---|
| host label | `argocd_ingress_host` in `ansible/roles/addon_argocd/defaults/main.yaml` | `infra-utility-argocd` |
| LB IP | `network.existing_ingress_nginx_lb_ip` in `settings.yaml` (shared cluster) **or** the `ingress_nginx_lb_ip` fact from `addon_ingress_nginx` (fresh cluster) | `192.168.56.240` |

Naming convention: utility tools are prefixed `infra-utility-<tool>` so they group together and are easy to recall.

## Manual apply (without a full provision)

Run from the control plane (`vagrant ssh devnodemaster01`) or any host with the kubeconfig:

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - infra-utility-argocd.192.168.56.240.nip.io
  rules:
    - host: infra-utility-argocd.192.168.56.240.nip.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF
```

The object name (`argocd-server-ingress`) is stable, so re-applying with a different host
updates it in place rather than creating a duplicate.

## Verify

```bash
kubectl get ingress -n argocd
# HOSTS should read infra-utility-argocd.192.168.56.240.nip.io
# ADDRESS should show 192.168.56.240
```

Then open `https://infra-utility-argocd.192.168.56.240.nip.io` in the host browser.

## Troubleshooting

- **503 / no backend**: the `argocd-server` Service is missing its port-80 mapping.
  Run `vagrant provision devnodeworker02` once to re-apply the NodePort patch (which also
  recreates this Ingress), or `kubectl get svc argocd-server -n argocd` to inspect the ports.
- **Hostname doesn't resolve**: `nip.io` resolves `<anything>.<ip>.nip.io` to `<ip>` via public DNS.
  Confirm the host has internet DNS and that `192.168.56.240` is the ingress-nginx controller's
  LoadBalancer IP (`kubectl get svc ingress-nginx-controller -n ingress-nginx`).
