ARG KEYCLOAK_VERSION=25.0.1
FROM registry.access.redhat.com/ubi9 AS ubi-micro-build
# Install 'unzip' with minimal dependencies and maximum parallel downloads
RUN mkdir /mnt/rootfs && yum install --installroot /mnt/rootfs -installroot /mnt/rootfs unzip
# RUN dnf install --installroot /mnt/rootfs \
#                 --releasever 9 \
#                 --setopt=install_weak_deps=False \
#                 --setopt=max_parallel_downloads=10 \
#                 --nodocs \
#                 -y unzip && \
#     dnf --installroot /mnt/rootfs clean all && \
#     rm -rf /mnt/rootfs/var/cache/dnf
    
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


# Copy AWS CLI binaries from the build stage
COPY --from=ubi-micro-build /mnt/rootfs /mnt/rootfs
ADD https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip /tmp/awscliv2.zip
RUN /mnt/rootfs/usr/bin/unzip /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install --bin-dir /mnt/rootfs/usr/local/bin --install-dir /mnt/rootfs/usr/local/aws-cli && \
    rm -rf /tmp/aws /tmp/awscliv2.zip
RUN /mnt/rootfs/usr/local/bin/aws --version


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
