ARG KEYCLOAK_VERSION=23.0.7
FROM quay.io/keycloak/keycloak:$KEYCLOAK_VERSION as builder

ENV KC_DB=postgres
ENV KC_CACHE=ispn
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_FEATURES=scripts,token-exchange,admin-fine-grained-authz,fips
ENV KC_FIPS_MODE=strict
ENV KC_CACHE_CONFIG_FILE=cache-ispn-jdbc.xml

COPY --chown=keycloak:keycloak ./libs/* /opt/keycloak/providers/
COPY --chown=keycloak:keycloak ./conf/* /opt/keycloak/conf/
COPY --chown=keycloak:keycloak ./cache-ispn-jdbc.xml /opt/keycloak/conf/cache-ispn-jdbc.xml

RUN /opt/keycloak/bin/kc.sh build

# Download and extract AWS CLI
FROM alpine:latest as awscli
RUN apk add --no-cache curl unzip
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
RUN unzip awscliv2.zip

FROM quay.io/keycloak/keycloak:$KEYCLOAK_VERSION

# Install AWS CLI
COPY --from=awscli --chown=keycloak:keycloak /aws /aws

COPY --from=builder --chown=keycloak:keycloak /opt/keycloak/ /opt/keycloak/

RUN mkdir /opt/keycloak/bin/folio
COPY --chown=keycloak:keycloak folio /opt/keycloak/bin/folio
COPY --chown=keycloak:keycloak ./custom-theme /opt/keycloak/themes/custom-theme

USER root
RUN /aws/install
RUN chmod -R 550 /opt/keycloak/bin/folio

USER keycloak

ENTRYPOINT ["/opt/keycloak/bin/folio/start.sh"]
