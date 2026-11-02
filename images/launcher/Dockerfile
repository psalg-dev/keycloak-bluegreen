FROM alpine:3.24.3

ARG TARGETARCH=amd64
ARG KIND_VERSION=v0.33.0
ARG KUBECTL_VERSION=v1.37.2
ARG HELM_VERSION=v4.3.1

RUN apk add --no-cache bash curl jq openssl gettext git coreutils docker-cli docker-cli-buildx \
 && curl -fsSLo /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${TARGETARCH}" \
 && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" | tar -xz -C /usr/local/bin --strip-components=1 "linux-${TARGETARCH}/helm" \
 && chmod +x /usr/local/bin/kind /usr/local/bin/kubectl /usr/local/bin/helm

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
WORKDIR /repo
ENTRYPOINT ["bash", "/usr/local/bin/entrypoint.sh"]
