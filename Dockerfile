ARG KEYCLOAK_VERSION=25.0.1

# Stage 1: Use a more feature-rich Red Hat UBI image to install AWS CLI
FROM registry.access.redhat.com/ubi9/ubi-minimal AS ubi-build
# Install required tools and AWS CLI from the package manager
RUN microdnf install -y unzip
ADD https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip /tmp/awscli.zip
RUN ls -la /tmp
RUN mkdir -p /mnt/rootfs
RUN unzip /tmp/awscli.zip -d /mnt/rootfs
RUN ls -la /mnt/rootfs
 
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
# Copy Python and AWS CLI from the build stage
COPY --from=ubi-build /mnt/rootfs /
RUN ls -la /aws
RUN ./aws/install

COPY --from=builder --chown=keycloak:keycloak /opt/keycloak/ /opt/keycloak/
RUN mkdir /opt/keycloak/bin/folio
COPY --chown=keycloak:keycloak folio/configure-realms.sh /opt/keycloak/bin/folio/
COPY --chown=keycloak:keycloak folio/setup-admin-client.sh /opt/keycloak/bin/folio/
COPY --chown=keycloak:keycloak folio/start.sh /opt/keycloak/bin/folio/
COPY --chown=keycloak:keycloak custom-theme /opt/keycloak/themes/custom-theme
COPY --chown=keycloak:keycloak custom-theme-sso-only /opt/keycloak/themes/custom-theme-sso-only

USER root
RUN chmod -R 550 /opt/keycloak/bin/folio
USER keycloak

ENTRYPOINT ["/opt/keycloak/bin/folio/start.sh"]
