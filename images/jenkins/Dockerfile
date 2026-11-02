FROM docker:29.9.2-cli AS dockercli

FROM jenkins/jenkins:2.580.2-lts-jdk21

ARG TARGETARCH=amd64
ARG KIND_VERSION=v0.33.0
ARG KUBECTL_VERSION=v1.37.2
ARG HELM_VERSION=v4.3.1

# ponytail: runs as root (see compose.yaml), so no USER switch back to jenkins.
USER root

COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=dockercli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx

RUN apt-get update \
 && apt-get install -y --no-install-recommends jq gettext-base \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSLo /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${TARGETARCH}" \
 && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" | tar -xz -C /usr/local/bin --strip-components=1 "linux-${TARGETARCH}/helm" \
 && chmod +x /usr/local/bin/kind /usr/local/bin/kubectl /usr/local/bin/helm \
 && git config --system --add safe.directory '*'

RUN jenkins-plugin-cli --plugins configuration-as-code job-dsl workflow-aggregator git timestamper

ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true"
