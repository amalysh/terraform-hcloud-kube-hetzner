locals {
  ubuntu_cloudinit_write_files_common = <<EOT
# Script to rename the private interface to eth1 and unify NetworkManager connection naming
- path: /etc/cloud/rename_interface.sh
  content: |
    #!/bin/bash
    set -euo pipefail

    sleep 11

    INTERFACE=$(ip link show | awk '/^3:/{print $2}' | sed 's/://g')
    MAC=$(cat /sys/class/net/$INTERFACE/address)

    cat <<EOF > /etc/udev/rules.d/70-persistent-net.rules
    SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="$MAC", NAME="eth1"
    EOF

    ip link set $INTERFACE down
    ip link set $INTERFACE name eth1
    ip link set eth1 up
    # this is needed to make the connection name match the interface name
    nmcli device up eth1

    myrepeat () {
        # Current time + 300 seconds (5 minutes)
        local END_SECONDS=$((SECONDS + 300))
        while true; do
            >&2 echo "loop"
            if (( "$SECONDS" > "$END_SECONDS" )); then
                >&2 echo "timeout reached"
                exit 1
            fi
            # run command and check return code 
            if $@ ; then
                >&2 echo "break"
                break
            else
                >&2 echo "got failure exit code, repeating"
                sleep 0.5
            fi
        done
    }

    myrename () {
      local eth="$1"
      local eth_connection=$(nmcli -g GENERAL.CONNECTION device show $eth || echo '')
      nmcli connection modify "$eth_connection" \
        con-name $eth \
        connection.interface-name $eth
    }

    myrepeat myrename eth0
    myrepeat myrename eth1

    systemctl restart NetworkManager

  permissions: "0744"

# Disable ssh password authentication
- content: |
    Port ${var.ssh_port}
    PasswordAuthentication no
    X11Forwarding no
    MaxAuthTries ${var.ssh_max_auth_tries}
    AllowTcpForwarding no
    AllowAgentForwarding no
    AuthorizedKeysFile .ssh/authorized_keys
  path: /etc/ssh/sshd_config.d/kube-hetzner.conf

# Create the k3s registries file if needed
%{if var.k3s_registries != ""}
# Create k3s registries file
- content: ${base64encode(var.k3s_registries)}
  encoding: base64
  path: /etc/rancher/k3s/registries.yaml
%{endif}

# Tell cloud-init to use NetworkManager as network renderer on subsequent boots
- content: |
    system_info:
      network:
        renderers: ['network-manager']
  path: /etc/cloud/cloud.cfg.d/99-network-manager.cfg

# Configure NetworkManager DNS handling
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

  ubuntu_cloudinit_runcmd_common = <<EOT
# Ubuntu runs several default services that are not needed for K3s. Disable them to free up RAM & CPU.
- [systemctl, disable, '--now', 'snapd', 'snapd.seeded', 'snapd.socket']
- [systemctl, disable, '--now', 'apport']
- [systemctl, disable, '--now', 'ufw']
- [systemctl, stop, 'rpcbind', 'rpcbind.socket']
- [systemctl, disable, '--now', 'rpcbind', 'rpcbind.socket']
- [systemctl, mask, 'rpcbind', 'rpcbind.socket']

# DNS will be managed by NetworkManager (via DHCP) or write_files (when dns_servers is defined).
- [systemctl, disable, '--now', 'systemd-resolved']
- [rm, '-f', '/etc/resolv.conf']

# Bounds the amount of logs that can survive on the system
- [sed, '-i', 's/#SystemMaxUse=/SystemMaxUse=3G/g', /etc/systemd/journald.conf]
- [sed, '-i', 's/#MaxRetentionSec=/MaxRetentionSec=1week/g', /etc/systemd/journald.conf]

# Rename private network interface to eth1
- [chmod, '+x', '/etc/cloud/rename_interface.sh']
- ['/etc/cloud/rename_interface.sh']

# Restart the sshd service to apply the new config
- [systemctl, 'restart', 'sshd', 'ssh']

# Make sure the network is up
- [systemctl, restart, NetworkManager]
- [systemctl, status, NetworkManager]
- [ip, route, add, default, via, '172.31.1.1', dev, 'eth0']

# Cleanup some logs
- [truncate, '-s', '0', '/var/log/audit/audit.log']
EOT
}
