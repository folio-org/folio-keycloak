ARG KEYCLOAK_VERSION=25.0.1

FROM registry.access.redhat.com/ubi9/ubi-minimal AS ubi-build
ADD https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip /tmp/awscli-x86_64.zip
ADD https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip /tmp/awscli-aarch64.zip
RUN microdnf install -y unzip && \
    mkdir -p /mnt/rootfs && \
    unzip /tmp/awscli-x86_64.zip -d /mnt/rootfs/awscli-x86_64 && \
    unzip  /tmp/awscli-aarch64.zip -d /mnt/rootfs/awscli-aarch64 && \
    rm -rf /tmp
 
FROM quay.io/keycloak/keycloak:$KEYCLOAK_VERSION as builder
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_FEATURES=scripts,token-exchange,admin-fine-grained-authz
COPY --chown=keycloak:keycloak libs/folio-scripts.jar /opt/keycloak/providers/
COPY --chown=keycloak:keycloak conf/* /opt/keycloak/conf/
COPY --chown=keycloak:keycloak cache-ispn-jdbc.xml /opt/keycloak/conf/cache-ispn-jdbc.xml

RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:$KEYCLOAK_VERSION

COPY --from=builder --chown=keycloak:keycloak /opt/keycloak/ /opt/keycloak/
COPY --from=ubi-build /mnt/rootfs /

RUN mkdir /opt/keycloak/bin/folio
COPY --chown=keycloak:keycloak folio/configure-realms.sh /opt/keycloak/bin/folio/
COPY --chown=keycloak:keycloak folio/setup-admin-client.sh /opt/keycloak/bin/folio/
COPY --chown=keycloak:keycloak folio/start.sh /opt/keycloak/bin/folio/
COPY --chown=keycloak:keycloak custom-theme /opt/keycloak/themes/custom-theme
COPY --chown=keycloak:keycloak custom-theme-sso-only /opt/keycloak/themes/custom-theme-sso-only

USER root
RUN chmod -R 550 /opt/keycloak/bin/folio
# Choose the right binary based on architecture
RUN mkdir /opt/javaagents && \
    chown -R keycloak:keycloak /opt/javaagents && \
    chmod -R 755 /opt/javaagents && \
    uname -m | grep -q x86_64 && \
    ./awscli-x86_64/aws/install -i /usr/local/aws-cli -b /usr/local/bin || \
    ./awscli-aarch64/aws/install -i /usr/local/aws-cli -b /usr/local/bin
USER keycloak

ENTRYPOINT ["/opt/keycloak/bin/folio/start.sh"]
