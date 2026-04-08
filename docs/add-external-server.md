# External Bare Metal Server Integration via WireGuard

This guide describes how to add **external bare metal servers** (any provider, any location) as Kubernetes agent nodes. External nodes connect to the cluster via auto-configured WireGuard tunnels.

Terraform handles all provisioning automatically: WireGuard key generation, tunnel setup, k3s installation, firewall rules, and node cleanup on removal.

---

## Prerequisites

- **External server** with a fresh Ubuntu 24.04 or MicroOS installation and SSH root access
- The server must have a **public IPv4 address** reachable from the cluster control planes
- **UDP port 51825** (default, configurable) must be open on the external server and control planes
- **Network CNI**:
  - Flannel: works out of the box
  - Cilium: works
  - Calico: untested

---

## Configuration

Add the following to your `kube.tf`:

```hcl
external_nodepools = [
  {
    name      = "workers"
    os        = "ubuntu"        # "ubuntu" or "microos"
    full_mesh = false           # See "Network modes" below
    nodes = {
      0 = {
        ipv4_address = "198.51.100.10"   # External server public IP
        # Optional settings:
        # labels            = ["workload=gpu"]
        # taints            = ["dedicated=external:NoSchedule"]
        # kubelet_args      = ["system-reserved=cpu=500m,memory=1Gi"]
        # enable_longhorn   = true
        # ssh_port          = 22
        # selinux           = false
      }
      1 = {
        ipv4_address = "198.51.100.11"
      }
    }
  }
]

# Optional: customize WireGuard settings
# wireguard_port         = 51825            # UDP port for WG tunnels
# wireguard_network_cidr = "172.22.0.0/24"  # WG overlay addressing
```

### Node naming

Nodes are automatically named `${cluster_name}-${pool_name}-${node_key}`, e.g. `mycluster-workers-0`.

### WireGuard IP allocation

External nodes get overlay IPs automatically from `wireguard_network_cidr` (default `172.22.0.0/24`):
- Control planes: `172.22.0.1`, `172.22.0.2`, `172.22.0.3`, ...
- External nodes: `172.22.0.101`, `172.22.0.102`, ...

---

## Network modes

### Cilium CNI

When using **Cilium**, `full_mesh = true` is **required** on all external node pools (enforced by validation). Cilium's BPF datapath routes pod traffic through its own VXLAN/WireGuard overlay, which needs direct wg-mesh tunnels to all cluster nodes.

```
External Node  ──wg-mesh──>  Control Planes (k3s API + Cilium overlay transport)
               ──wg-mesh──>  Cloud Agents   (Cilium overlay transport)
               ──wg-mesh──>  Robot Nodes    (Cilium overlay transport)
```

- Full wg-mesh provides encrypted connectivity between external nodes and all cluster nodes
- Cilium `nodeEncryption` stays **enabled** — cloud, robot, and CP nodes encrypt all traffic via Cilium WireGuard
- External nodes **automatically opt out** of Cilium node encryption (via `instance.hetzner.cloud/provided-by=external` label). Their Cilium BPF doesn't intercept host traffic, so wg-mesh works without WG-in-WG conflicts
- Plain VXLAN between external and cluster nodes travels through wg-mesh tunnels (encrypted by wg-mesh)
- Control plane wg-mesh uses the CP's private IP as its interface address (not the WG overlay IP) so that Cilium's WireGuard `allowed_ips` match correctly for any residual pod traffic

### Flannel/Calico CNI — Gateway mode (`full_mesh = false`, default)

```
External Node  ──WG tunnel──>  Control Plane (gateway)  ──>  Other nodes
```

- Each external node has a WireGuard tunnel to **all control planes**
- Traffic to other cluster nodes is routed through the control planes
- Simpler setup, fewer tunnels
- Good for most use cases

### Flannel/Calico CNI — Full mesh mode (`full_mesh = true`)

```
External Node  ──WG tunnel──>  Control Planes
               ──WG tunnel──>  Cloud Agent Nodes
               ──WG tunnel──>  Other External Nodes
```

- Each external node has direct WireGuard tunnels to **all** cluster nodes (control planes + cloud agents + other external nodes)
- Lower latency for inter-node traffic
- More tunnels to manage, but all automated by Terraform
- Recommended for latency-sensitive workloads or large clusters

---

## External + Autoscaled node connectivity

When a cluster has **both** external nodes and autoscaler nodepools, control planes act as gateways between them. External nodes cannot reach autoscaled nodes directly (different networks).

### How it works

```
External node ──wg-mesh──► CP (gateway) ──eth1──► Autoscaled node
   172.22.0.101              10.255.0.101            10.x.x.x
```

**External → Autoscaled:** External node sends via wg-mesh to the assigned gateway CP. The CP decrypts and forwards via the Hetzner private network to the autoscaled node.

**Autoscaled → External:** Autoscaled node routes to the WG overlay CIDR (`172.22.0.0/24`) via the Hetzner gateway. A `hcloud_network_route` tells the Hetzner gateway to forward this traffic to the assigned CP. The CP forwards through wg-mesh to the external node.

### Gateway assignment

Each external node is initially assigned a gateway CP in round-robin. With 3 CPs and 2 external nodes: external-0 → CP1, external-1 → CP2. Both the Hetzner network route and the wg-mesh AllowedIPs point to the same CP for consistency. The failover CronJob + DaemonSet can change the active gateway at runtime if a CP goes down.

The assigned CP's wg-mesh peer on the external node gets an additional AllowedIPs entry for the full network CIDR (`10.0.0.0/8`). This enables:
- **Outgoing routing**: traffic to autoscaled node IPs goes through the CP's wg-mesh tunnel
- **Reverse path filtering**: WireGuard accepts forwarded return traffic from the CP (source IPs from any cloud node)

Direct peer `/32` routes (other CPs, full_mesh agents) always win via longest prefix match.

### Failover

Two coordinated components handle automatic failover when a gateway CP goes down:

**CronJob** (`wg-gw-route-failover`, runs every minute on CPs):
1. Checks all CP nodes for Ready status via the Kubernetes API
2. If the current gateway CP is NotReady, selects the first healthy CP
3. Updates the `hcloud_network_route` via Hetzner API (using the existing `hcloud` secret — no API token on external nodes)
4. Writes the new gateway CP IP to a ConfigMap (`wg-gw-gateway`)

**DaemonSet** (`wg-gw-watcher`, runs on each external node):
1. Watches the `wg-gw-gateway` ConfigMap every 15 seconds
2. When the gateway CP changes, runs `wg set` on the host to move the broad AllowedIPs (`10.0.0.0/8`) from the old CP peer to the new one
3. Runs with `hostNetwork`, `hostPID`, and `privileged` to execute `nsenter` + `wg` on the host

This ensures both the Hetzner route (return path) and the wg-mesh AllowedIPs (outgoing path) switch together. No API tokens are stored on external nodes.

```
CP goes down
    │
    ▼
CronJob detects NotReady (≤60s)
    │
    ├──► Updates hcloud_network_route (return path)
    │
    └──► Writes new gateway IP to ConfigMap
                │
                ▼
         DaemonSet reads ConfigMap (≤15s)
                │
                └──► wg set: moves AllowedIPs to healthy CP (outgoing path)
                        │
                        ▼
                 Connectivity restored (~90s total)
```


## What Terraform does automatically

1. **WireGuard key generation**: Auto-generates asymmetric key pairs for each external node (using the `OJFord/wireguard` provider)
2. **Base setup**: Installs required packages (WireGuard, open-iscsi, etc.), configures SSH, sets hostname
3. **Reboots** the node if kernel updates were applied
4. **WireGuard tunnels**: Deploys `wg-mesh` interface config on external nodes, control planes, and cloud agents/robot nodes (when `full_mesh=true`, required for Cilium)
5. **k3s agent**: Deploys config and installs k3s with `flannel-iface=wg-mesh`, proper labels (`instance.hetzner.cloud/provided-by=external`), and `baremetal://` provider ID
6. **Firewall**: Applies nftables rules allowing WireGuard port, cluster CIDRs, and pod/service traffic
7. **Registries**: Deploys k3s registry mirrors if configured
8. **Longhorn**: Configures Longhorn storage if `enable_longhorn = true`
9. **Gateway routing** (when autoscaler pools exist): Creates `hcloud_network_route` per external node, configures autoscaler cloud-init with gateway routes, deploys route-failover CronJob + DaemonSet for automatic failover
10. **Cleanup on destroy**: Drains and deletes the k8s node, stops k3s, removes WireGuard config

---

## Load Balancer behavior

External nodes are **not** added as direct LB targets. Traffic reaches pods on external nodes via the overlay network:

```
Client -> LB -> Cloud node (ingress) -> WireGuard tunnel -> External node pod
```

This works because the CNI mesh (Flannel/Cilium) routes pod traffic over the WireGuard tunnels transparently.

---

## Storage

- **Hetzner Cloud Volumes** do **not** work on external servers
- The label `instance.hetzner.cloud/provided-by=external` is automatically applied to prevent CSI pods from scheduling on external nodes
- Use **Longhorn** for distributed storage. Enable per node with `enable_longhorn = true`

---

## Network details

### WireGuard

| Setting | Default | Description |
|---|---|---|
| `wireguard_port` | `51825` | UDP port for WG tunnels |
| `wireguard_network_cidr` | `172.22.0.0/24` | Overlay IP range (must not overlap with cluster CIDRs) |

WireGuard keys are auto-generated per node. No manual key management needed.

### Firewall

External nodes get nftables rules that mirror the hcloud firewall configuration plus WireGuard-specific rules:
- WireGuard UDP port from all peers
- Cluster internal traffic (pod CIDR, service CIDR, WG overlay CIDR)
- SSH access from allowed CIDRs
- ICMPv4 (ping)
- NodePort ranges if configured

### Routes

`HCLOUD_NETWORK_ROUTES_ENABLED` is set to `false` in the CCM when external nodes are present. The CNI overlay handles inter-node routing over WireGuard.

---

## Caveats

- External nodes require a **stable public IP** — dynamic IPs will break the WireGuard tunnels
- The external server must have a fresh OS install — Terraform handles all package installation
- External nodes do not support IPv6-only mode
- WireGuard adds ~60 bytes of overhead per packet; MTU on the `wg-mesh` interface is auto-configured
- Adding or removing external nodes triggers WireGuard config updates on control planes (and all nodes in full mesh mode)
- **Autoscaler + external nodes**: Each external node uses one CP as a gateway for autoscaled node traffic. If the gateway CP goes down, the CronJob + DaemonSet automatically switch both the Hetzner route and wg-mesh AllowedIPs to a healthy CP (~90s failover). WireGuard's AllowedIPs trie limits each CIDR to one peer, so true ECMP across CPs is not possible on a single `wg-mesh` interface. Hetzner Cloud requires `hcloud_network_route` for CP forwarding (anti-spoofing drops forwarded packets without it)
- **Test your network thoroughly** before adding external nodes to production clusters

---

## Combining with Robot nodes

You can use both `robot_nodepools` (vSwitch) and `external_nodepools` (WireGuard) in the same cluster. Each type uses its own connectivity method and both coexist transparently on the CNI overlay.

---

## References

- [WireGuard](https://www.wireguard.com/)
- [Hetzner Robot dedicated server guide](add-robot-server.md)
- [OJFord/wireguard Terraform provider](https://registry.terraform.io/providers/OJFord/wireguard/latest)
