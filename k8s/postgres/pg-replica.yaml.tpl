# Green's own DB for a minor/major switch: a CNPG replica cluster streaming from the active DB, promoted at the copy
# point (spec.replica.enabled=false). Same database, roles and passwords (physical copy).
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${DB}
  namespace: ${NS}
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
    pg_basebackup:
      source: ${SRC}
  replica:
    enabled: true
    source: ${SRC}
  externalClusters:
    - name: ${SRC}
      connectionParameters:
        host: ${SRC}-rw.${NS}.svc
        user: streaming_replica
        sslmode: verify-full
        dbname: postgres
      sslKey: { name: ${SRC}-replication, key: tls.key }
      sslCert: { name: ${SRC}-replication, key: tls.crt }
      sslRootCert: { name: ${SRC}-ca, key: ca.crt }
  storage:
    size: 2Gi
  resources:
    requests: { cpu: 250m, memory: 512Mi }
    limits: { memory: 1Gi }
  affinity:
    enablePodAntiAffinity: true
    podAntiAffinityType: required
    topologyKey: topology.kubernetes.io/zone
