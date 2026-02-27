module "cloudinit_common" {
  source             = "./common/modules/cloudinit-common"
  ssh_port           = var.ssh_port
  ssh_max_auth_tries = var.ssh_max_auth_tries
  dns_servers        = var.dns_servers
  k3s_registries     = var.k3s_registries
}

locals {
  ubuntu_cloudinit_write_files_common = <<EOT
${module.cloudinit_common.write_files}
# Hetzner: Script to rename the private interface to eth1 and unify NetworkManager connection naming
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
EOT

  ubuntu_cloudinit_runcmd_common = <<EOT
${module.cloudinit_common.runcmd}
# Hetzner: interface rename
- [chmod, '+x', '/etc/cloud/rename_interface.sh']

# Hetzner: default route
- [ip, route, add, default, via, '172.31.1.1', dev, 'eth0']

# Cleanup some logs
- [truncate, '-s', '0', '/var/log/audit/audit.log']
EOT
}
