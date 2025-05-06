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

# Apply new DNS config
%{if length(var.dns_servers) > 0}
# Set prepare for manual dns config
- content: |
    [main]
    dns=none
  path: /etc/NetworkManager/conf.d/dns.conf

- content: |
    %{for server in var.dns_servers~}
    nameserver ${server}
    %{endfor}
  path: /etc/resolv.conf
  permissions: '0644'
%{endif}
EOT

  ubuntu_cloudinit_runcmd_common = <<EOT
# Bounds the amount of logs that can survive on the system
- [sed, '-i', 's/#SystemMaxUse=/SystemMaxUse=3G/g', /etc/systemd/journald.conf]
- [sed, '-i', 's/#MaxRetentionSec=/MaxRetentionSec=1week/g', /etc/systemd/journald.conf]

# Allow network interface
- [chmod, '+x', '/etc/cloud/rename_interface.sh']

# Restart the sshd service to apply the new config
- [systemctl, 'restart', 'sshd']

# Make sure the network is up
- [systemctl, restart, NetworkManager]
- [systemctl, status, NetworkManager]
- [ip, route, add, default, via, '172.31.1.1', dev, 'eth0']

# Cleanup some logs
- [truncate, '-s', '0', '/var/log/audit/audit.log']
EOT
}
