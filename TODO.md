# TODO

- fix access-logs dashboard, completely broken for now
- extract domain in a single variable?
- mermaid diagram in readme

## Moving to multi-node

- Switch k3s from SQLite to embedded etcd (--cluster-init on server, rejoin other servers)
- Replace local-path-provisioner with Longhorn (Helm install, Rancher project, integrates natively
  with k3s) for replicated persistent storage
- Replace Klipper (k3s built-in LB) with MetalLB or a cloud provider load balancer
- Add agent nodes: curl -sfL https://get.k3s.io | K3S_URL=... K3S_TOKEN=... sh -
- All existing manifests remain unchanged
