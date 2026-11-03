# Legacy Spring auth server stand-in. NOT part of blue/green: it is the outside world Keycloak brokers to.
# ponytail: 1 replica, in-memory sessions; it is not what's under test.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-idp
  namespace: legacy
spec:
  replicas: 1
  selector:
    matchLabels: { app: legacy-idp }
  template:
    metadata:
      labels: { app: legacy-idp }
    spec:
      containers:
        - name: legacy-idp
          image: ${LEGACY_IMAGE}
          imagePullPolicy: Never
          ports:
            - { name: http, containerPort: 8080 }
          env:
            - name: LEGACY_USER_PASSWORD
              valueFrom: { secretKeyRef: { name: legacy-idp, key: user-password } }
            - name: LEGACY_CLIENT_SECRET
              valueFrom: { secretKeyRef: { name: legacy-idp, key: client-secret } }
            # 768Mi OOM-killed the JVM at 18 logins/s (build #40: exit 137 at 11:05:15Z, ~350 concurrent login
            # forms -> 200 Tomcat threads x 1Mi stacks); the pod restarted and its 503s failed 5 gate rules.
            # Heap stays at 65% of the new limit, thread stacks are halved, so the stand-in keeps up.
            - name: JAVA_TOOL_OPTIONS
              value: -XX:MaxRAMPercentage=65 -Xss512k
          readinessProbe:
            httpGet: { path: /.well-known/openid-configuration, port: http }
            periodSeconds: 5
          resources:
            requests: { cpu: 250m, memory: 768Mi }
            limits: { memory: 1536Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: legacy-idp
  namespace: legacy
spec:
  selector: { app: legacy-idp }
  ports:
    - { name: http, port: 80, targetPort: http }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: legacy-idp
  namespace: legacy
spec:
  ingressClassName: nginx
  tls:
    - hosts: [legacy-net1.localtest.me, legacy-net2.localtest.me]
      secretName: localtest-tls
  rules:
    - host: legacy-net1.localtest.me
      http:
        paths:
          - { path: /, pathType: Prefix, backend: { service: { name: legacy-idp, port: { name: http } } } }
    - host: legacy-net2.localtest.me
      http:
        paths:
          - { path: /, pathType: Prefix, backend: { service: { name: legacy-idp, port: { name: http } } } }
