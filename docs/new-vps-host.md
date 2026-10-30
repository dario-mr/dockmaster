# New VPS host runbook

This runbook covers bringing up a fresh **single-node Dockmaster k3s server**. It assumes an Ubuntu
or Debian image and uses the repository bootstrap scripts for host preparation, k3s, and Flux.

This creates an empty cluster; application data is not imported. Restore any required application
backups before switching public DNS.

## 1. Provision and prepare the host

- Create a VPS with a supported Ubuntu/Debian release, a sudo user, and your SSH public key.
- Keep out-of-band console access available until tailnet SSH and the firewall are verified.
- Record its public IP and connect with `ssh <linux-user>@<public-ip>`.
- Set a stable Linux hostname before installing k3s; the bootstrap waits for a node with this name.
  For example, use `dockmaster-vps-1`:

  ```bash
  sudo hostnamectl set-hostname dockmaster-vps-1
  sudo apt update
  sudo apt full-upgrade -y
  sudo reboot
  ```

Initially allow TCP 22 from your current address in the VPS network firewall so you can connect
and set up Tailscale. Keep public TCP 80 and 443 available for the web apps and ACME HTTP-01
certificate validation. Do not expose Kubernetes API TCP 6443 to the internet.

## 2. Add Tailscale and a tailnet SSH alias

Install Tailscale using its [Linux installation instructions](https://tailscale.com/kb/1031/install-linux),
then authenticate the VPS and give it a stable tailnet name:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --hostname=dockmaster-vps-1
tailscale status
tailscale ip -4
```

If `tailscale up` prints an authentication URL, open it in a browser you control and approve the
new machine. Confirm it appears in the tailnet before changing SSH or firewall rules.

On the SSH client, add an alias in `~/.ssh/config`. Replace the placeholders with the VPS's tailnet
DNS name or stable Tailscale IP, the Linux username, and the private key used at provisioning:

```sshconfig
Host dockmaster-vps
    HostName <tailnet-dns-name-or-ip>
    User <linux-user>
    IdentityFile <existing-private-key>
    IdentitiesOnly yes
```

Verify a new session with `ssh dockmaster-vps` before relying on tailnet access.

## 3. Clone Dockmaster and prepare GitOps inputs

On the VPS:

```bash
git clone https://github.com/dario-mr/dockmaster.git
cd dockmaster
```

Review `DOMAIN` in `clusters/production/kustomization.yaml`. Create the real secret files from the
templates and fill them with this cluster's values:

```bash
cp secrets/crowdsec-secrets.template.yaml secrets/crowdsec-secrets.yaml
cp secrets/geoipupdate-secret.template.yaml secrets/geoipupdate-secret.yaml
cp secrets/observability-secrets.template.yaml secrets/observability-secrets.yaml
cp secrets/page-checker-secrets.template.yaml secrets/page-checker-secrets.yaml
cp secrets/telegram-token.template.yaml secrets/telegram-token.yaml
cp secrets/wordle-duel-service-secrets.template.yaml secrets/wordle-duel-service-secrets.yaml
```

Set the Telegram destination chat ID in `observability/flux-notifications.yaml`. The bootstrap
checks that every template has a matching real file before continuing. Real secret files are
git-ignored; never commit them.

Create a GitHub token with the repository access required by Flux bootstrap. Keep it out of the
repository and pass it only to the bootstrap process:

```bash
read -r -s -p 'GitHub token: ' GITHUB_TOKEN
printf '\n'
export GITHUB_TOKEN
sudo -E bash scripts/bootstrap.sh
unset GITHUB_TOKEN
```

The script installs the pinned k3s release after verifying the installer checksum. It also installs
`curl`, `git`, `open-iscsi`, and `ufw`; configures journald and container log limits; creates the
Traefik log directory; bootstraps Flux; and waits for the infrastructure layer. k3s supplies
containerd, so Docker is not a prerequisite. Observability and apps are intentionally left
suspended until infrastructure is ready.

Resume them and verify the cluster:

```bash
sudo bash scripts/reconcile-apps.sh
sudo bash scripts/verify.sh
kubectl get nodes -o wide
kubectl get pods -A
flux get kustomizations
```

## 4. Restrict SSH to Tailscale

The current `scripts/bootstrap.sh` firewall setup allows the UFW `OpenSSH` profile, which is
publicly reachable unless removed. While keeping the original SSH session open, add an SSH rule on
the Tailscale interface and remove the public rule:

```bash
sudo ufw allow in on tailscale0 to any port 22 proto tcp
sudo ufw delete allow OpenSSH
sudo ufw status verbose
```

Open a second terminal and verify `ssh dockmaster-vps` still works. Only then remove public TCP 22
from the VPS network firewall. Keep out-of-band console access available for recovery.

The bootstrap opens TCP 80 and 443 for public ingress and allows the configured k3s pod and service
CIDRs. TCP 6443 stays closed by default; set `K8S_API_ALLOW_CIDR` only when a trusted client needs
direct API access. Never set it to `0.0.0.0/0`. For this single-node setup, no public k3s control
plane or database ports are needed. See [K3s requirements](https://docs.k3s.io/installation/requirements).

## 5. Point DNS and verify HTTPS

DNS can be moved after the cluster is healthy. Before expecting a production certificate, point
every hostname listed in
[`certificate-production.yaml`](../infrastructure/cert-manager-resources/certificate-production.yaml)
to the new VPS and make sure public TCP 80 and 443 reach it. This certificate uses ACME HTTP-01,
so validation remains pending until those names resolve to this VPS. CNAMEs pointing to the domain
apex follow its address; preserve unrelated email, verification, and other-hosting records during
the DNS change.

After DNS updates, check resolution and the certificate:

```bash
DOMAIN=example.com
dig +short A "$DOMAIN"
dig +short A "grafana.$DOMAIN"
kubectl -n kube-system get certificate dockmaster-production
kubectl -n kube-system describe certificate dockmaster-production
```

When the certificate is `Ready=True`, verify the app URLs over HTTPS.

## Recovery and references

- If remote SSH fails, use out-of-band console access; do not open port 22 publicly as a permanent
  fix.
- Keep port 6443 private. Manage the cluster on the host or over Tailscale/SSH.
- [Tailscale Linux install](https://tailscale.com/kb/1031/install-linux)
- [K3s requirements](https://docs.k3s.io/installation/requirements)
