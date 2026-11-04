# One Oracle instance for the demo. The blue/green "databases" are schemas in FREEPDB1, created by
# scripts/lib/kc.sh create_db; the instance is the platform, like the CNPG operator was.
# 19.3 target: set ORACLE_IMAGE=container-registry.oracle.com/database/enterprise:19.3.0.0 and
# ORACLE_PULL_SECRET=<docker-registry secret>. The default is 23ai Free because 19c has no free XE image
# and the 19.3 EE image needs an Oracle SSO login; the SQL and cutover path are the same.
apiVersion: v1
kind: Service
metadata:
  name: oracle
  namespace: ${NS}
  labels: { app: oracle }
spec:
  clusterIP: None
  selector: { app: oracle }
  ports:
    - name: listener
      port: 1521
      targetPort: 1521
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: oracle
  namespace: ${NS}
  labels: { app: oracle }
spec:
  serviceName: oracle
  replicas: 1
  selector:
    matchLabels: { app: oracle }
  template:
    metadata:
      labels: { app: oracle }
    spec:
      securityContext:
        fsGroup: 54321
        fsGroupChangePolicy: OnRootMismatch
      containers:
        - name: oracle
          image: ${ORACLE_IMAGE}
          imagePullPolicy: IfNotPresent
          securityContext:
            runAsUser: 54321
            runAsGroup: 54321
            allowPrivilegeEscalation: false
          ports:
            - name: listener
              containerPort: 1521
          env:
            # The two image families use different variable names; unknown variables are ignored.
            - { name: ORACLE_PASSWORD, valueFrom: { secretKeyRef: { name: ${ORACLE_ADMIN_SECRET}, key: password } } }
            - { name: ORACLE_PWD, valueFrom: { secretKeyRef: { name: ${ORACLE_ADMIN_SECRET}, key: password } } }
            - { name: ORACLE_SID, value: "${ORACLE_SID}" }
            - { name: ORACLE_PDB, value: "${DB_SERVICE}" }
            - { name: ORACLE_CHARACTERSET, value: AL32UTF8 }
            - { name: INIT_SGA_SIZE, value: "${ORACLE_SGA_MB}" }
            - { name: INIT_PGA_SIZE, value: "${ORACLE_PGA_MB}" }
            - { name: INIT_CPU_COUNT, value: "${ORACLE_CPUS}" }
          resources:
            requests: { cpu: "${ORACLE_CPUS}", memory: "${ORACLE_MEMORY}" }
            limits: { memory: "${ORACLE_MEMORY}" }
          startupProbe:
            exec:
              command: ["bash", "-lc", "echo 'select 1 from dual;' | sqlplus -s / as sysdba | grep -qE '^[[:space:]]*1[[:space:]]*$'"]
            periodSeconds: 10
            timeoutSeconds: 10
            failureThreshold: 180 # first 19c startup creates the database: up to 30 min in KinD
          readinessProbe:
            exec:
              command: ["bash", "-lc", "echo 'select 1 from dual;' | sqlplus -s / as sysdba | grep -qE '^[[:space:]]*1[[:space:]]*$'"]
            periodSeconds: 10
            timeoutSeconds: 10
            failureThreshold: 3
          livenessProbe:
            exec:
              command: ["bash", "-lc", "echo 'select 1 from dual;' | sqlplus -s / as sysdba | grep -qE '^[[:space:]]*1[[:space:]]*$'"]
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 5
          volumeMounts:
            - { name: oradata, mountPath: /opt/oracle/oradata }
            - { name: dshm, mountPath: /dev/shm }
            # gvenzl images run init scripts from the first path; Oracle's official image runs setup scripts from
            # the second. Mounting both makes one bootstrap script work for 19.3 EE and 23ai Free.
            - { name: bootstrap, mountPath: /container-entrypoint-initdb.d }
            - { name: bootstrap, mountPath: /opt/oracle/scripts/setup }
      volumes:
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 1Gi
        - name: bootstrap
          configMap:
            name: oracle-bootstrap
            defaultMode: 0755
      terminationGracePeriodSeconds: 180
  volumeClaimTemplates:
    - metadata:
        name: oradata
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: ${ORACLE_STORAGE}
