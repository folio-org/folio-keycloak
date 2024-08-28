ARG KEYCLOAK_VERSION=25.0.1

# Stage 1: Use a more feature-rich Red Hat UBI image to install AWS CLI
FROM registry.access.redhat.com/ubi9/ubi-minimal AS ubi-build
# Install required tools and AWS CLI from the package manager
RUN microdnf install -y unzip
ADD https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip /tmp/awscli.zip
RUN ls -la /tmp
 
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
COPY --from=ubi-build /usr/local/bin/aws /usr/local/bin/aws
COPY --from=ubi-build /usr/local/lib/python3.9 /usr/local/lib/python3.9
COPY --from=ubi-build /usr/local/lib64/python3.9 /usr/local/lib64/python3.9
COPY --from=ubi-build /usr/bin/python3 /usr/bin/python3
COPY --from=ubi-build /usr/lib64/libpython3.9.so.1.0 /usr/lib64/libpython3.9.so.1.0
# Set up environment variables and verify AWS CLI installation
ENV PATH="/usr/local/bin:$PATH"
# Verify that AWS CLI is installed correctly
RUN aws --version

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
