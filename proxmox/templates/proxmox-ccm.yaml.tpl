---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: proxmox-cloud-controller-manager
  namespace: kube-system
spec:
  chart: proxmox-cloud-controller-manager
  repo: https://charts.sergelogvinov.github.io/
  version: "${version}"
  targetNamespace: kube-system
  bootstrap: true
  valuesContent: |-
    ${values}
