#!/bin/bash
set -e

# The public interface is the one with the IPv4 default route. Traffic arriving on it
# is judged by the mirrored hcloud firewall rules alone, as on a cloud server behind
# that firewall: its source address is never trusted as cluster-internal, the rules
# match the connection's pre-DNAT source and port, and only DNAT (NodePort, hostPort,
# externalIPs) may forward from it. Without that, DNAT turns a packet to the public
# address into forwarded traffic that the input rules never see. Cluster traffic,
# load balancer targets included, must use the private network or the WireGuard mesh.
# Cilium's kube-proxy replacement translates NodePorts in eBPF before these hooks, so
# it is not covered here.
PUBLIC_IFACE=$(ip -4 route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
if [ -z "$PUBLIC_IFACE" ]; then
  echo "ERROR: no IPv4 default route, cannot determine the public interface" >&2
  exit 1
fi
# Refuse when the cluster network is routed via that interface too: treating it as
# public would cut the node off from the cluster.
CLUSTER_IFACE=$(ip -4 route get ${cidrhost(network_ipv4_cidr, 1)} 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
if [ "$CLUSTER_IFACE" = "$PUBLIC_IFACE" ]; then
  echo "ERROR: $PUBLIC_IFACE carries both the default route and ${network_ipv4_cidr}" >&2
  exit 1
fi

# Use nft if available (Ubuntu 24.04+, modern distros), fall back to iptables-legacy
if command -v nft &>/dev/null; then

### nftables implementation
# One transaction: the first two lines replace an existing table, so a ruleset that
# fails to load leaves the previous one in place.
nft -f - <<NFTEOF
table inet k3s-firewall
delete table inet k3s-firewall
table inet k3s-firewall {
  # Mirror hcloud firewall rules (external-facing)
  chain public-input {
${has_external ? "    udp dport ${wireguard_port} accept" : ""}
%{~ for rule in rules }
%{~ if rule.direction == "in" && !(rule.protocol == "udp" && rule.port == tostring(wireguard_port)) }
%{~ for src in rule.source_ips }
%{~ if !strcontains(src, ":") }
%{~ if contains(["tcp", "udp"], rule.protocol) }
    meta l4proto ${rule.protocol}%{ if rule.port != null && rule.port != "" } ct original proto-dst ${rule.port}%{ endif } ct original ip saddr ${src} accept
%{~ else }
    ip protocol ${rule.protocol} ip saddr ${src} accept
%{~ endif }
%{~ endif }
%{~ endfor }
%{~ endif }
%{~ endfor }

    counter drop
  }

  # The same rules for forwarded traffic, which only DNAT may create
  chain public-forward {
%{~ for rule in rules }
%{~ if rule.direction == "in" && contains(["tcp", "udp"], rule.protocol) && !(rule.protocol == "udp" && rule.port == tostring(wireguard_port)) }
%{~ for src in rule.source_ips }
%{~ if !strcontains(src, ":") }
    ct status dnat meta l4proto ${rule.protocol}%{ if rule.port != null && rule.port != "" } ct original proto-dst ${rule.port}%{ endif } ct original ip saddr ${src} accept
%{~ endif }
%{~ endfor }
%{~ endif }
%{~ endfor }

    counter drop
  }

  chain input {
    type filter hook input priority -1; policy accept;

    # Base rules
    ct state established,related accept
    iif lo accept

    iifname "$PUBLIC_IFACE" jump public-input

    # Cluster-internal traffic
    ip saddr ${network_ipv4_cidr} accept
    ip saddr ${wireguard_network_cidr} accept
    ip saddr ${cluster_ipv4_cidr} accept
    ip saddr ${service_ipv4_cidr} accept

    # Default drop
    counter drop
  }

  chain forward {
    type filter hook forward priority -1; policy accept;

    ct state established,related accept

    iifname "$PUBLIC_IFACE" jump public-forward

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
${has_external ? "    udp sport ${wireguard_port} accept" : ""}

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
# Ensure /etc/nftables.conf actually loads our drop-in on boot. Ubuntu's
# default /etc/nftables.conf does a `flush ruleset` and does NOT include
# /etc/nftables.d/, so without this the k3s-firewall table is lost on every
# reboot and the node falls back to an open input policy (SSH exposed).
if ! grep -qF '/etc/nftables.d/*.conf' /etc/nftables.conf 2>/dev/null; then
  echo 'include "/etc/nftables.d/*.conf"' >> /etc/nftables.conf
fi
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
iptables-legacy -N K3S-FW-PUBLIC-IN 2>/dev/null || iptables-legacy -F K3S-FW-PUBLIC-IN
iptables-legacy -N K3S-FW-PUBLIC-FWD 2>/dev/null || iptables-legacy -F K3S-FW-PUBLIC-FWD

### Base rules
iptables-legacy -A K3S-FW-INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables-legacy -A K3S-FW-OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables-legacy -A K3S-FW-FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables-legacy -A K3S-FW-INPUT -i lo -j ACCEPT
iptables-legacy -A K3S-FW-OUTPUT -o lo -j ACCEPT

### Public interface: only the mirrored hcloud firewall rules
iptables-legacy -A K3S-FW-INPUT -i "$PUBLIC_IFACE" -j K3S-FW-PUBLIC-IN
iptables-legacy -A K3S-FW-FORWARD -i "$PUBLIC_IFACE" -j K3S-FW-PUBLIC-FWD

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
iptables-legacy -A K3S-FW-PUBLIC-IN -p udp --dport ${wireguard_port} -j ACCEPT
iptables-legacy -A K3S-FW-OUTPUT -p udp --dport ${wireguard_port} -j ACCEPT
iptables-legacy -A K3S-FW-OUTPUT -p udp --sport ${wireguard_port} -j ACCEPT
%{~ endif }

%{~ for rule in rules }
%{~ if rule.direction == "in" && !(rule.protocol == "udp" && rule.port == tostring(wireguard_port)) }
%{~ for src in rule.source_ips }
%{~ if !strcontains(src, ":") }
%{~ if contains(["tcp", "udp"], rule.protocol) }
iptables-legacy -A K3S-FW-PUBLIC-IN -p ${rule.protocol} -m conntrack%{ if rule.port != null && rule.port != "" } --ctorigdstport ${replace(rule.port, "-", ":")}%{ endif } --ctorigsrc ${src} -j ACCEPT
iptables-legacy -A K3S-FW-PUBLIC-FWD -p ${rule.protocol} -m conntrack --ctstate DNAT%{ if rule.port != null && rule.port != "" } --ctorigdstport ${replace(rule.port, "-", ":")}%{ endif } --ctorigsrc ${src} -j ACCEPT
%{~ else }
iptables-legacy -A K3S-FW-PUBLIC-IN -p ${rule.protocol} -s ${src} -j ACCEPT
%{~ endif }
%{~ endif }
%{~ endfor }
%{~ endif }
%{~ if rule.direction == "out" && !(rule.protocol == "udp" && rule.port == tostring(wireguard_port)) }
%{~ for dst in rule.destination_ips }
%{~ if !strcontains(dst, ":") }
iptables-legacy -A K3S-FW-OUTPUT -p ${rule.protocol}%{ if rule.port != null && rule.port != "" } --dport ${replace(rule.port, "-", ":")}%{ endif } -d ${dst} -j ACCEPT
%{~ endif }
%{~ endfor }
%{~ endif }
%{~ endfor }

iptables-legacy -A K3S-FW-PUBLIC-IN -j DROP
iptables-legacy -A K3S-FW-PUBLIC-FWD -j DROP
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

# Persist across reboots. Neither MicroOS nor a bare iptables install restores
# /etc/iptables/rules.v4 on boot by default (that needs the iptables-persistent/
# netfilter-persistent package, which isn't present here), so without this the
# K3S-FW chains are lost on reboot and the input policy falls back to open (SSH
# exposed). Install a minimal oneshot unit that restores the saved rules early,
# before the network comes up.
cat > /etc/systemd/system/k3s-firewall.service <<'UNITEOF'
[Unit]
Description=Restore k3s bare-metal iptables firewall
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'iptables-legacy-restore < /etc/iptables/rules.v4'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload 2>/dev/null || true
systemctl enable k3s-firewall.service 2>/dev/null || true

fi

echo "Firewall configured successfully"
