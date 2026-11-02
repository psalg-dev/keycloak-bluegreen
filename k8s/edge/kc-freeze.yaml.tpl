# Applied only during a freeze (scripts/lib/kc.sh freeze): longer Prefix paths win over Ingress kc's /keycloak,
# so these go to kc-maint (503) while everything else keeps flowing to kc-active. ${PATHS} is a JSON array (valid YAML).
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kc-freeze
  namespace: keycloak
spec:
  ingressClassName: nginx
  tls:
    - hosts: [kc-net1.localtest.me, kc-net2.localtest.me]
      secretName: localtest-tls
  rules:
    - host: kc-net1.localtest.me
      http:
        paths: ${PATHS}
    - host: kc-net2.localtest.me
      http:
        paths: ${PATHS}
