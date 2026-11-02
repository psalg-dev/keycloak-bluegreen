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
          readinessProbe:
            httpGet: { path: /.well-known/openid-configuration, port: http }
            periodSeconds: 5
          resources:
            requests: { cpu: 250m, memory: 512Mi }
            limits: { memory: 768Mi }
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
