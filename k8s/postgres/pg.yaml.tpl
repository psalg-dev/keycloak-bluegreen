apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${DB}
  namespace: ${NS}
spec:
  instances: ${PG_INSTANCES} # scripts/lib/kc.sh: 3 (default), 2 (PROFILE=laptop)
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
