# Shared cloud-init write_files and runcmd fragments for Ubuntu nodes.
# Both Hetzner and Proxmox providers use these, concatenating their own
# provider-specific extras before passing to the shared template.

output "write_files" {
  description = "Shared write_files YAML fragment for Ubuntu cloud-init"
  value       = <<EOT
# SSH hardening
- content: |
    Port ${var.ssh_port}
    PasswordAuthentication no
    X11Forwarding no
    MaxAuthTries ${var.ssh_max_auth_tries}
    AllowTcpForwarding no
    AllowAgentForwarding no
    AuthorizedKeysFile .ssh/authorized_keys
  path: /etc/ssh/sshd_config.d/kube-hetzner.conf
%{if var.k3s_registries != ""}
# K3s registries
- content: ${base64encode(var.k3s_registries)}
  encoding: base64
  path: /etc/rancher/k3s/registries.yaml
%{endif}
# NetworkManager DNS handling
# dns=none: manual resolv.conf management (when dns_servers defined)
# dns=default + rc-manager=file: NetworkManager writes DHCP DNS directly to /etc/resolv.conf
- content: |
    [main]
%{if length(var.dns_servers) > 0~}
    dns=none
%{else~}
    dns=default
    rc-manager=file
%{endif~}
  path: /etc/NetworkManager/conf.d/dns.conf
%{if length(var.dns_servers) > 0}
- content: |
    %{for server in var.dns_servers~}
    nameserver ${server}
    %{endfor}
  path: /etc/resolv.conf
  permissions: '0644'
%{endif}
EOT
}

output "runcmd" {
  description = "Shared runcmd YAML fragment for Ubuntu cloud-init"
  value       = <<EOT
# Disable unneeded Ubuntu services to free RAM & CPU
- [systemctl, disable, '--now', 'snapd snapd.seeded snapd.socket']
- [systemctl, disable, '--now', 'apport']
- [systemctl, disable, '--now', 'ufw']

# DNS managed by NetworkManager (via DHCP) or write_files (when dns_servers is defined)
- [systemctl, disable, '--now', 'systemd-resolved']
- [rm, '-f', '/etc/resolv.conf']

# Bounds the amount of logs that can survive on the system
- [sed, '-i', 's/#SystemMaxUse=/SystemMaxUse=3G/g', /etc/systemd/journald.conf]
- [sed, '-i', 's/#MaxRetentionSec=/MaxRetentionSec=1week/g', /etc/systemd/journald.conf]

# Restart sshd with new config
- [systemctl, 'restart', 'sshd']

# Make sure NetworkManager is up
- [systemctl, restart, NetworkManager]
- [systemctl, status, NetworkManager]
EOT
}
