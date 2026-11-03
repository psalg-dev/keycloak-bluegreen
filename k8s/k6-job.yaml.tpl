# k6 load Job (envsubst: LOGIN_RATE REFRESH_VUS LOGOUT_VUS APP_VUS DURATION). Rendered + applied by scripts/load.sh start.
# Talks to the public URLs via ingress (CoreDNS rewrite), so it needs no kc-<color>-keycloak-client label.
# TLS: Go honours SSL_CERT_FILE, so k6 trusts the demo CA without insecureSkipTLSVerify (verified with k6 2.3.0).
# ponytail: k6's lines go to a file on an emptyDir and the container then sleeps; `load.sh collect` cats the file.
# kubelet rotates container logs at 10Mi and `kubectl logs` serves only the current file, and a 10 min run writes ~10 MB.
apiVersion: batch/v1
kind: Job
metadata:
  name: k6
  namespace: load
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 3600
  template:
    metadata:
      labels: { app: k6 }
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:2.3.0
          command: [sh, -c]
          args:
            - k6 run --quiet --log-format=raw /scripts/flows.js 2>/out/k6.log; echo "k6 exited $?" >>/out/k6.log; exec sleep 3600
          env:
            - { name: LOGIN_RATE, value: "${LOGIN_RATE}" }
            - { name: REFRESH_VUS, value: "${REFRESH_VUS}" }
            - { name: LOGOUT_VUS, value: "${LOGOUT_VUS}" }
            - { name: APP_VUS, value: "${APP_VUS}" }
            - { name: DURATION, value: "${DURATION}" }
            - { name: SSL_CERT_FILE, value: /ca/ca.crt }
            - name: K6_APP_SECRET
              valueFrom: { secretKeyRef: { name: k6-app, key: secret } }
            - name: LEGACY_USER_PASSWORD
              valueFrom: { secretKeyRef: { name: legacy-idp, key: user-password } }
          volumeMounts:
            - { name: scripts, mountPath: /scripts }
            - { name: ca, mountPath: /ca }
            - { name: out, mountPath: /out }
          resources:
            requests: { cpu: 500m, memory: 512Mi }
            limits: { memory: 2Gi }
      volumes:
        - { name: scripts, configMap: { name: k6-flows } }
        - { name: ca, secret: { secretName: demo-ca } }
        - { name: out, emptyDir: {} }
