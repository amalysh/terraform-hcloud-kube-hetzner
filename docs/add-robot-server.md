# Hetzner Robot Dedicated Server Integration

This guide describes how to add Hetzner **Robot dedicated servers** as Kubernetes agent nodes. Robot servers connect to the cluster via a Hetzner vSwitch (L2 bridge to the hcloud private network).

Terraform handles all provisioning automatically: VLAN setup, k3s installation, firewall rules, and node cleanup on removal.

---

## Prerequisites

- **Hetzner vSwitch** created in the Robot web-UI ([Hetzner Docs](https://docs.hetzner.com/robot/dedicated-server/network/vswitch))
  - Note down the **vSwitch ID** (typically 10000+) and the **VLAN ID** (starts from 4000 by default)
  - The vSwitch must be connected to the Robot server(s) you want to use
- **Robot server** with a fresh Ubuntu 24.04 or MicroOS installation and SSH root access
- **Network CNI**:
  - Flannel: works out of the box
  - Cilium: works, MTU is auto-configured to 1350
  - Calico: untested

### Optional: Robot CCM Integration

If you want Robot nodes as **direct load balancer targets** (instead of routing via cloud nodes), you additionally need:

- **Webservice User** created in Hetzner Robot account settings (for API access)
- Set `robot_ccm_enabled = true` with `robot_user` and `robot_password`
- Set `server_number` on each robot node (the numeric server ID from the Robot web panel)

Without Robot CCM, nodes are still fully functional and reachable via the overlay network through cloud nodes that are LB targets.

---

## Configuration

Add the following to your `kube.tf`:

```hcl
# Required: vSwitch connection
vswitch_id = 12345       # Your vSwitch ID
vlan_id    = 4000         # Your VLAN ID

# Robot node pools
robot_nodepools = [
  {
    name = "workers"
    os   = "ubuntu"       # "ubuntu" or "microos"
    nodes = {
      0 = {
        ipv4_address  = "203.0.113.10"   # Robot server public IP
        server_number = 1234567           # Required when robot_ccm_enabled = true
        # Optional settings:
        # network_interface = "enp6s0"   # Auto-detected if not set
        # labels            = ["workload=compute"]
        # taints            = ["dedicated=robot:NoSchedule"]
        # kubelet_args      = ["system-reserved=cpu=500m,memory=1Gi"]
        # enable_longhorn   = true
        # ssh_port          = 22
        # selinux           = false
      }
      1 = {
        ipv4_address  = "203.0.113.11"
        server_number = 7654321
      }
    }
  }
]

# Optional: Enable Robot CCM for direct LB targets
# robot_ccm_enabled = true
# robot_user        = "your-robot-user"
# robot_password    = "your-robot-password"
```

### Node naming

Nodes are automatically named `${cluster_name}-${pool_name}-${node_key}`, e.g. `mycluster-workers-0`.

> [!IMPORTANT]
> When `robot_ccm_enabled = true`, each node must have `server_number` set to the numeric Hetzner Robot server ID (visible in the Robot web panel URL, e.g., `https://robot.hetzner.com/server/1234567`).

### Private IP allocation

Robot nodes get private IPs automatically from the vSwitch subnet (default `10.201.0.0/16`):
- Gateway: `10.201.0.1` (managed by hcloud network)
- First node: `10.201.0.102`, second: `10.201.0.103`, etc.

---

## What Terraform does automatically

1. **Base setup**: Installs required packages, configures SSH, sets hostname
2. **Reboots** the node if kernel updates were applied (Ubuntu `package_upgrade`)
3. **VLAN setup**: Configures the vSwitch VLAN interface using NetworkManager (`nmcli`) with correct MTU (auto-calculated: 1400 for Flannel, 1350 for Cilium)
4. **k3s agent**: Deploys config and installs k3s with proper kubelet args, labels (`instance.hetzner.cloud/provided-by=robot`), and provider ID (`baremetal://` or `hrobot://` prefix)
5. **Firewall**: Applies nftables rules mirroring the hcloud firewall, allowing cluster CIDRs and pod/service traffic
6. **Registries**: Deploys k3s registry mirrors if configured
7. **Longhorn**: Configures Longhorn storage if `enable_longhorn = true`
8. **Cleanup on destroy**: Drains and deletes the k8s node, stops k3s, removes data

---

## Load Balancer behavior

| `robot_ccm_enabled` | LB targets | How robot nodes receive traffic |
|---|---|---|
| `false` (default) | Cloud nodes only | LB -> cloud node -> overlay network -> robot pod |
| `true` (with credentials) | Cloud nodes + robot IPs | LB -> robot node directly (+ overlay fallback) |

Both modes work. The default (`false`) is simpler and doesn't require Robot API credentials.

---

## Storage

- **Hetzner Cloud Volumes** do **not** work on Robot servers (CSI driver limitation)
- The label `instance.hetzner.cloud/provided-by=robot` is automatically applied to prevent CSI pods from scheduling on Robot nodes
- Use **Longhorn** for distributed storage. Enable per node with `enable_longhorn = true`
- Longhorn disk configuration can be customized via `longhorn_disks_config` per node

---

## Network details

### MTU

MTU is auto-calculated based on the CNI plugin:
- **Flannel**: 1400 (vSwitch maximum)
- **Cilium**: 1350 (additional overhead for encapsulation)

### Routes

When Robot nodes are present, `HCLOUD_NETWORK_ROUTES_ENABLED` is set to `false` in the CCM to prevent route conflicts. The CNI overlay handles inter-node routing.

### Firewall

Robot nodes get nftables rules that mirror the hcloud firewall configuration. Rules automatically include:
- SSH access from allowed CIDRs
- Cluster internal traffic (pod CIDR, service CIDR, private network)
- ICMPv4 (ping)
- NodePort ranges if configured

---

## Caveats

- When destroying the cluster, it takes a few minutes for the vSwitch binding to be released on the Robot side
- The Robot server must have a fresh OS install — Terraform handles all package installation
- Robot nodes do not support IPv6-only mode
- **Test your network thoroughly** before adding Robot nodes to production clusters

---

## Manual setup (without Terraform)

<details>
<summary>Click to expand manual configuration steps</summary>

If you prefer to configure Robot nodes manually instead of using `robot_nodepools`:

### 1. HCCM settings

- Set `robot_ccm_enabled = true` and provide `robot_user` / `robot_password`
- Or manually update the `hcloud` Kubernetes secret with `robot-user` and `robot-password`
- Set `robot.enabled: true` in `hetzner_ccm_values`
- Refer to [HCCM docs](https://github.com/hetznercloud/hcloud-cloud-controller-manager)

### 2. Connect vSwitch

1. Choose a subnet CIDR for Robot nodes (e.g., `10.201.0.0/16`)
2. Connect the Cloud network to the vSwitch in the Hetzner web-UI ([Hetzner docs](https://docs.hetzner.com/cloud/networks/connect-dedi-vswitch))

### 3. Configure VLAN on Robot node

```bash
# Example for Ubuntu using nmcli (VLAN ID 4000, interface enp6s0)
nmcli connection add type vlan con-name vlan4000 ifname vlan4000 vlan.parent enp6s0 vlan.id 4000
nmcli connection modify vlan4000 802-3-ethernet.mtu 1400
nmcli connection modify vlan4000 ipv4.addresses '10.201.0.2/16'
nmcli connection modify vlan4000 ipv4.gateway '10.201.0.1'
nmcli connection modify vlan4000 ipv4.method manual
# Route all 10.x IPs through the vSwitch gateway
nmcli connection modify vlan4000 +ipv4.routes "10.0.0.0/8 10.201.0.1"
nmcli connection down vlan4000 && nmcli connection up vlan4000
```

### 4. Create k3s config

Create `/etc/rancher/k3s/config.yaml` on the Robot node:

```yaml
flannel-iface: enp6s0     # Your main interface (Flannel only)
prefer-bundled-bin: true
kubelet-arg:
  - volume-plugin-dir=/var/lib/kubelet/volumeplugins
  - kube-reserved=cpu=50m,memory=300Mi,ephemeral-storage=1Gi
node-label:
  - k3s_upgrade=true
  - instance.hetzner.cloud/provided-by=robot
node-taint: []
server: https://<API_SERVER_IP>:6443
token: <CLUSTER_TOKEN>
```

### 5. Verify connectivity

```bash
# From Robot node, ping a control plane
ping 10.255.0.101

# From a control plane, ping the Robot node
ping 10.201.0.102
```

</details>

---

## References

- [Hetzner Cloud Controller Manager](https://github.com/hetznercloud/hcloud-cloud-controller-manager)
- [Hetzner vSwitch & Robot Networking](https://docs.hetzner.com/cloud/networks/connect-dedi-vswitch)
- [Hetzner CSI Driver: Root Server Integration](https://github.com/hetznercloud/csi-driver/blob/main/docs/kubernetes/README.md#integration-with-root-servers)
- [External bare metal nodes via WireGuard](add-external-server.md)
