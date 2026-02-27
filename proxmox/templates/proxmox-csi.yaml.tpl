---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: proxmox-csi-plugin
  namespace: kube-system
spec:
  chart: proxmox-csi-plugin
  repo: https://charts.sergelogvinov.github.io/
  version: "${version}"
  targetNamespace: kube-system
  bootstrap: true
  valuesContent: |-
    ${values}
