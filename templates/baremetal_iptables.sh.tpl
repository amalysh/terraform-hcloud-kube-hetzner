#!/bin/bash
set -e

# Use nft if available (Ubuntu 24.04+, modern distros), fall back to iptables-legacy
if command -v nft &>/dev/null; then

### nftables implementation
# Delete existing table if re-running
nft delete table inet k3s-firewall 2>/dev/null || true

nft -f - <<'NFTEOF'
table inet k3s-firewall {
  chain input {
    type filter hook input priority -1; policy accept;

    # Base rules
    ct state established,related accept
    iif lo accept

    # Cluster-internal traffic
    ip saddr ${network_ipv4_cidr} accept
    ip saddr ${wireguard_network_cidr} accept
    ip saddr ${cluster_ipv4_cidr} accept
    ip saddr ${service_ipv4_cidr} accept
${has_external ? "    udp dport ${wireguard_port} accept" : ""}

    # Mirror hcloud firewall rules (external-facing)
%{~ for rule in rules }
%{~ if rule.direction == "in" && !(rule.protocol == "udp" && rule.port == tostring(wireguard_port)) }
%{~ for src in rule.source_ips }
%{~ if !strcontains(src, ":") }
    ${rule.protocol == "icmp" ? "ip protocol icmp" : "${rule.protocol} dport ${rule.port}"} ip saddr ${src} accept
%{~ endif }
%{~ endfor }
%{~ endif }
%{~ endfor }

    # Default drop
    counter drop
  }

  chain forward {
    type filter hook forward priority -1; policy accept;

    ct state established,related accept

    # Cluster-internal traffic
    ip saddr ${network_ipv4_cidr} accept
    ip daddr ${network_ipv4_cidr} accept
    ip saddr ${wireguard_network_cidr} accept
    ip daddr ${wireguard_network_cidr} accept
    ip saddr ${cluster_ipv4_cidr} accept
    ip daddr ${cluster_ipv4_cidr} accept
    ip saddr ${service_ipv4_cidr} accept
    ip daddr ${service_ipv4_cidr} accept

    counter drop
  }

  chain output {
    type filter hook output priority -1; policy accept;

    ct state established,related accept
    oif lo accept

    # Cluster-internal traffic
    ip daddr ${network_ipv4_cidr} accept
    ip daddr ${wireguard_network_cidr} accept
    ip daddr ${cluster_ipv4_cidr} accept
    ip daddr ${service_ipv4_cidr} accept
${has_external ? "    udp dport ${wireguard_port} accept" : ""}

    # Mirror hcloud firewall rules (external-facing)
%{~ for rule in rules }
%{~ if rule.direction == "out" && !(rule.protocol == "udp" && rule.port == tostring(wireguard_port)) }
%{~ for dst in rule.destination_ips }
%{~ if !strcontains(dst, ":") }
    ${rule.protocol == "icmp" ? "ip protocol icmp" : "${rule.protocol} dport ${rule.port}"} ip daddr ${dst} accept
%{~ endif }
%{~ endfor }
%{~ endif }
%{~ endfor }

%{~ if restrict_outbound }
    counter drop
%{~ else }
    counter accept
%{~ endif }
  }
}
NFTEOF

# Persist nftables rules
mkdir -p /etc/nftables.d
nft list table inet k3s-firewall > /etc/nftables.d/k3s-firewall.conf
# Ensure nftables service loads our rules on boot
systemctl enable nftables 2>/dev/null || true

else

### iptables-legacy fallback (MicroOS or older systems)
# Install iptables-legacy if needed
apt-get install -y iptables 2>/dev/null || zypper install -y iptables 2>/dev/null || true

### Create/flush custom chains
iptables-legacy -N K3S-FW-INPUT 2>/dev/null || iptables-legacy -F K3S-FW-INPUT
iptables-legacy -N K3S-FW-OUTPUT 2>/dev/null || iptables-legacy -F K3S-FW-OUTPUT
iptables-legacy -N K3S-FW-FORWARD 2>/dev/null || iptables-legacy -F K3S-FW-FORWARD

### Base rules
iptables-legacy -A K3S-FW-INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables-legacy -A K3S-FW-OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables-legacy -A K3S-FW-FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables-legacy -A K3S-FW-INPUT -i lo -j ACCEPT
iptables-legacy -A K3S-FW-OUTPUT -o lo -j ACCEPT

### Auto-allow cluster-internal traffic
iptables-legacy -A K3S-FW-INPUT -s ${network_ipv4_cidr} -j ACCEPT
iptables-legacy -A K3S-FW-OUTPUT -d ${network_ipv4_cidr} -j ACCEPT
iptables-legacy -A K3S-FW-FORWARD -s ${network_ipv4_cidr} -j ACCEPT
iptables-legacy -A K3S-FW-FORWARD -d ${network_ipv4_cidr} -j ACCEPT
iptables-legacy -A K3S-FW-INPUT -s ${wireguard_network_cidr} -j ACCEPT
iptables-legacy -A K3S-FW-OUTPUT -d ${wireguard_network_cidr} -j ACCEPT
iptables-legacy -A K3S-FW-FORWARD -s ${wireguard_network_cidr} -j ACCEPT
iptables-legacy -A K3S-FW-FORWARD -d ${wireguard_network_cidr} -j ACCEPT
iptables-legacy -A K3S-FW-INPUT -s ${cluster_ipv4_cidr} -j ACCEPT
iptables-legacy -A K3S-FW-OUTPUT -d ${cluster_ipv4_cidr} -j ACCEPT
iptables-legacy -A K3S-FW-FORWARD -s ${cluster_ipv4_cidr} -j ACCEPT
iptables-legacy -A K3S-FW-FORWARD -d ${cluster_ipv4_cidr} -j ACCEPT
iptables-legacy -A K3S-FW-INPUT -s ${service_ipv4_cidr} -j ACCEPT
iptables-legacy -A K3S-FW-OUTPUT -d ${service_ipv4_cidr} -j ACCEPT
iptables-legacy -A K3S-FW-FORWARD -s ${service_ipv4_cidr} -j ACCEPT
iptables-legacy -A K3S-FW-FORWARD -d ${service_ipv4_cidr} -j ACCEPT

%{~ if has_external }
iptables-legacy -A K3S-FW-INPUT -p udp --dport ${wireguard_port} -j ACCEPT
iptables-legacy -A K3S-FW-OUTPUT -p udp --dport ${wireguard_port} -j ACCEPT
%{~ endif }

%{~ for rule in rules }
%{~ if rule.direction == "in" && !(rule.protocol == "udp" && rule.port == tostring(wireguard_port)) }
%{~ for src in rule.source_ips }
%{~ if !strcontains(src, ":") }
iptables-legacy -A K3S-FW-INPUT -p ${rule.protocol}%{ if rule.port != null && rule.port != "" } --dport ${rule.port}%{ endif } -s ${src} -j ACCEPT
%{~ endif }
%{~ endfor }
%{~ endif }
%{~ if rule.direction == "out" && !(rule.protocol == "udp" && rule.port == tostring(wireguard_port)) }
%{~ for dst in rule.destination_ips }
%{~ if !strcontains(dst, ":") }
iptables-legacy -A K3S-FW-OUTPUT -p ${rule.protocol}%{ if rule.port != null && rule.port != "" } --dport ${rule.port}%{ endif } -d ${dst} -j ACCEPT
%{~ endif }
%{~ endfor }
%{~ endif }
%{~ endfor }

iptables-legacy -A K3S-FW-INPUT -j DROP
iptables-legacy -A K3S-FW-FORWARD -j DROP
%{~ if restrict_outbound }
iptables-legacy -A K3S-FW-OUTPUT -j DROP
%{~ else }
iptables-legacy -A K3S-FW-OUTPUT -j ACCEPT
%{~ endif }

iptables-legacy -D INPUT -j K3S-FW-INPUT 2>/dev/null || true
iptables-legacy -I INPUT 1 -j K3S-FW-INPUT
iptables-legacy -D OUTPUT -j K3S-FW-OUTPUT 2>/dev/null || true
iptables-legacy -I OUTPUT 1 -j K3S-FW-OUTPUT
iptables-legacy -D FORWARD -j K3S-FW-FORWARD 2>/dev/null || true
iptables-legacy -I FORWARD 1 -j K3S-FW-FORWARD

mkdir -p /etc/iptables
iptables-legacy-save > /etc/iptables/rules.v4

fi

echo "Firewall configured successfully"
