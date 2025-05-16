ARG ALPINE_VERSION=3.21.2
ARG KEYCLOAK_VERSION=26.1.4
FROM alpine:$ALPINE_VERSION AS providers_jar_downloader

# Set the working directory
WORKDIR /tmp/keycloak-providers-jars

# FOLIO Keycloak plugins versions to download
ARG KCPLUG_DETECT_FOLIO_USER_VERSION=1.2.0

ARG FOLIO_MAVEN_URL=https://repository.folio.org/repository/maven-releases

# Download plugin JAR files
RUN wget ${FOLIO_MAVEN_URL}/org/folio/authentication/keycloak-detect-folio-user/${KCPLUG_DETECT_FOLIO_USER_VERSION}/keycloak-detect-folio-user-${KCPLUG_DETECT_FOLIO_USER_VERSION}.jar

FROM quay.io/keycloak/keycloak:$KEYCLOAK_VERSION AS builder

ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_FEATURES=scripts,token-exchange,admin-fine-grained-authz

COPY --chown=keycloak:keycloak --from=providers_jar_downloader /tmp/keycloak-providers-jars/ /opt/keycloak/providers/
COPY --chown=keycloak:keycloak libs/folio-scripts.jar /opt/keycloak/providers/
COPY --chown=keycloak:keycloak libs/keycloak-ecs-folio-authenticator.jar /opt/keycloak/providers/
COPY --chown=keycloak:keycloak conf/* /opt/keycloak/conf/
COPY --chown=keycloak:keycloak cache-ispn-jdbc.xml /opt/keycloak/conf/cache-ispn-jdbc.xml

RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:$KEYCLOAK_VERSION

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
