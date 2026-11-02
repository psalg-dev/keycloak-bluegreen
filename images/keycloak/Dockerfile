# Official Keycloak re-laid into the Bitnami layout: the Bitnami chart hard-codes /opt/bitnami/keycloak/*
# and its init container sources /opt/bitnami/scripts/liblog.sh.
ARG KC_VERSION=26.8.1
FROM quay.io/keycloak/keycloak:${KC_VERSION}

# Build-time options. The chart env (KC_CACHE, KC_CACHE_STACK, KC_METRICS_ENABLED, KC_HTTP_RELATIVE_PATH) must
# match these: under `start --optimized` a differing value is ignored, and for http-relative-path 26.8.1 even
# exits with code 2 after the warning, swallowing the real error.
ARG KC_BUILD_OPTS="--db=postgres --cache=ispn --cache-stack=jdbc-ping --health-enabled=true --metrics-enabled=true --http-relative-path=/keycloak --features=stateless"

USER root
COPY liblog.sh /opt/bitnami/scripts/liblog.sh
RUN cp -a /opt/keycloak /opt/bitnami/keycloak \
 && /opt/bitnami/keycloak/bin/kc.sh build ${KC_BUILD_OPTS} \
 && chmod -R a+rX /opt/bitnami

USER 1001
ENTRYPOINT ["/opt/bitnami/keycloak/bin/kc.sh"]
