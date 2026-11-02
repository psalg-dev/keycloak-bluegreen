# Build context: repo root. `docker build -f images/keycloak/Dockerfile --build-arg KC_VERSION=.. --build-arg KC_MAJOR=.. .`
# Official Keycloak re-laid into the Bitnami layout: the Bitnami chart hard-codes /opt/bitnami/keycloak/*
# and its init container sources /opt/bitnami/scripts/liblog.sh.
ARG KC_VERSION=26.8.1

# Provider jar for the Keycloak major (tests run during the build, so a broken provider never becomes an image) + theme.
FROM maven:3.9.16-eclipse-temurin-25 AS ext
ARG KC_MAJOR=26
WORKDIR /src
COPY providers/pom.xml .
RUN mvn -B -q -P kc${KC_MAJOR} dependency:go-offline
COPY providers/src src
ARG PROVIDER_VERSION=1
RUN mvn -B -q -P kc${KC_MAJOR} -DPROVIDER_VERSION=${PROVIDER_VERSION} verify \
 && cp target/kc-demo-ext-*-kc${KC_MAJOR}.jar /kc-demo-ext.jar
COPY themes/demo /themes/demo
ARG THEME_VERSION=1
RUN sed -i "s/^themeVersion=.*/themeVersion=${THEME_VERSION}/" /themes/demo/login/theme.properties

FROM quay.io/keycloak/keycloak:${KC_VERSION}

# Build-time options. The chart env (KC_CACHE, KC_CACHE_STACK, KC_METRICS_ENABLED, KC_HTTP_RELATIVE_PATH) must
# match these: under `start --optimized` a differing value is ignored, and for http-relative-path 26.8.1 even
# exits with code 2 after the warning, swallowing the real error.
ARG KC_BUILD_OPTS="--db=postgres --cache=ispn --cache-stack=jdbc-ping --health-enabled=true --metrics-enabled=true --http-relative-path=/keycloak --features=stateless"

USER root
COPY images/keycloak/liblog.sh /opt/bitnami/scripts/liblog.sh
# mv, not cp: one copy of Keycloak in the image (a copy doubled its size and every trivy finding). Nothing uses
# /opt/keycloak afterwards: the chart templates and our values/scripts only reference /opt/bitnami/keycloak.
RUN mv /opt/keycloak /opt/bitnami/keycloak
# provider jar + theme must be in place before `kc.sh build`
COPY --from=ext /kc-demo-ext.jar /opt/bitnami/keycloak/providers/kc-demo-ext.jar
COPY --from=ext /themes/demo /opt/bitnami/keycloak/themes/demo
RUN /opt/bitnami/keycloak/bin/kc.sh build ${KC_BUILD_OPTS} \
 && chmod -R a+rX /opt/bitnami

USER 1001
ENTRYPOINT ["/opt/bitnami/keycloak/bin/kc.sh"]
