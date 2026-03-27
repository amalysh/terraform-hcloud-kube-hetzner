[Interface]
Address = ${address}
PrivateKey = ${private_key}
%{ for peer in cp_peers ~}

[Peer]
PublicKey = ${peer.public_key}
Endpoint = ${peer.endpoint}
AllowedIPs = ${peer.allowed_ips}
PersistentKeepalive = 25
%{ endfor ~}
%{ for peer in agent_peers ~}

[Peer]
PublicKey = ${peer.public_key}
Endpoint = ${peer.endpoint}
AllowedIPs = ${peer.allowed_ips}
PersistentKeepalive = 25
%{ endfor ~}
