# Test apps (docs/test-apps-contract.md): instruments that measure what a real OIDC client and resource server see during
# a cutover. NOT part of blue/green. Namespace apps, Secrets demo-ca/localtest-tls/test-apps: scripts/up.sh.
# ponytail: 1 replica each, in-memory sessions; they are instruments, not what is under test.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: testclient
  namespace: apps
spec:
  replicas: 1
  selector:
    matchLabels: { app: testclient }
  template:
    metadata:
      labels: { app: testclient }
    spec:
      containers:
        - name: testclient
          image: ${TESTCLIENT_IMAGE}
          imagePullPolicy: Never
          ports:
            - { name: http, containerPort: 8080 }
          env:
            - name: TESTCLIENT_BC_SECRET
              valueFrom: { secretKeyRef: { name: test-apps, key: testclient-bc } }
            - name: TESTCLIENT_FC_SECRET
              valueFrom: { secretKeyRef: { name: test-apps, key: testclient-fc } }
          volumeMounts:
            - { name: demo-ca, mountPath: /etc/demo-ca, readOnly: true } # truststore (SSL bundle demo-ca)
          readinessProbe:
            httpGet: { path: /actuator/health, port: http }
            periodSeconds: 5
          resources: # native image: ~0.1 s start, RSS well under 128Mi idle
            requests: { cpu: 50m, memory: 96Mi }
            limits: { memory: 256Mi }
      volumes:
        - { name: demo-ca, secret: { secretName: demo-ca } }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: testresource
  namespace: apps
spec:
  replicas: 1
  selector:
    matchLabels: { app: testresource }
  template:
    metadata:
      labels: { app: testresource }
    spec:
      containers:
        - name: testresource
          image: ${TESTRESOURCE_IMAGE}
          imagePullPolicy: Never
          ports:
            - { name: http, containerPort: 8080 }
          env:
            - name: TESTRESOURCE_SECRET
              valueFrom: { secretKeyRef: { name: test-apps, key: testresource } }
          volumeMounts:
            - { name: demo-ca, mountPath: /etc/demo-ca, readOnly: true }
          readinessProbe:
            httpGet: { path: /actuator/health, port: http }
            periodSeconds: 5
          resources:
            requests: { cpu: 50m, memory: 96Mi }
            limits: { memory: 256Mi }
      volumes:
        - { name: demo-ca, secret: { secretName: demo-ca } }
---
# :80 for the ingress, :8080 for Keycloak's back-channel logout (http://testclient.apps.svc:8080/..., contract)
apiVersion: v1
kind: Service
metadata:
  name: testclient
  namespace: apps
spec:
  selector: { app: testclient }
  ports:
    - { name: http, port: 80, targetPort: http }
    - { name: http-direct, port: 8080, targetPort: http }
---
apiVersion: v1
kind: Service
metadata:
  name: testresource
  namespace: apps
spec:
  selector: { app: testresource }
  ports:
    - { name: http, port: 80, targetPort: http }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: test-apps
  namespace: apps
spec:
  ingressClassName: nginx
  tls:
    - hosts: [app.localtest.me, api.localtest.me]
      secretName: localtest-tls
  rules:
    - host: app.localtest.me
      http:
        paths:
          - { path: /, pathType: Prefix, backend: { service: { name: testclient, port: { name: http } } } }
    - host: api.localtest.me
      http:
        paths:
          - { path: /, pathType: Prefix, backend: { service: { name: testresource, port: { name: http } } } }
---
# Only the ingress controller and Keycloak (back-channel logout POSTs to testclient) may connect. Spring's back-channel
# handler ends each session by calling itself on localhost, not via the Service, so no rule for the apps themselves.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: test-apps
  namespace: apps
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: ingress-nginx } }
          podSelector: { matchLabels: { app.kubernetes.io/component: controller } }
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: keycloak } }
          podSelector: { matchLabels: { app.kubernetes.io/name: keycloak } }
      ports:
        - { port: 8080 }
