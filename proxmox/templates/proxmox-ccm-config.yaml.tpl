clusters:
  - url: ${split("=", proxmox_api_token)[0]}
    insecure: false
    token_id: "${element(split("=", proxmox_api_token), 0)}"
    token_secret: "${length(split("=", proxmox_api_token)) > 1 ? element(split("=", proxmox_api_token), 1) : ""}"
    region: ${cluster_name}
