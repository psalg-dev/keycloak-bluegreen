apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${DB}
  namespace: keycloak
spec:
  instances: 3
  postgresql:
    synchronous:
      method: any
      number: 1
      dataDurability: required
    parameters:
      max_connections: "300"
  bootstrap:
    initdb:
      database: keycloak
      owner: keycloak
  storage:
    size: 2Gi
  resources:
    requests: { cpu: 250m, memory: 512Mi }
    limits: { memory: 1Gi }
  affinity:
    enablePodAntiAffinity: true
    podAntiAffinityType: required
    topologyKey: topology.kubernetes.io/zone
