ARG KEYCLOAK_VERSION=25.0.1
FROM quay.io/keycloak/keycloak:$KEYCLOAK_VERSION as builder
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_FEATURES=scripts,token-exchange,admin-fine-grained-authz
COPY --chown=keycloak:keycloak libs/folio-scripts.jar /opt/keycloak/providers/
COPY --chown=keycloak:keycloak conf/* /opt/keycloak/conf/
COPY --chown=keycloak:keycloak cache-ispn-jdbc.xml /opt/keycloak/conf/cache-ispn-jdbc.xml

RUN /opt/keycloak/bin/kc.sh build


FROM amazon/aws-cli:2.17.38 as awscli
RUN echo "DEBUG $(aws --version)"
RUN aws --version


FROM quay.io/keycloak/keycloak:$KEYCLOAK_VERSION

COPY --from=builder --chown=keycloak:keycloak /opt/keycloak/ /opt/keycloak/
COPY --from=awscli --chown=keycloak:keycloak /usr/local/bin/aws /usr/local/bin/aws
RUN ls -la /usr/local/bin
RUN ls -la /usr/local/bin/aws
RUN /usr/local/bin/aws --version


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
