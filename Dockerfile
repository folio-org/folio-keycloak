ARG KEYCLOAK_VERSION=23.0.6
FROM quay.io/keycloak/keycloak:$KEYCLOAK_VERSION as builder

ENV KC_DB=postgres
ENV KC_CACHE=ispn
ENV KC_HEALTH_ENABLED=true
ENV KC_FEATURES=scripts,token-exchange,admin-fine-grained-authz,fips
ENV KC_FIPS_MODE=strict
ENV KC_HTTPS_KEY_STORE_TYPE=BCFKS

COPY ./cache-ispn-jdbc.xml /opt/keycloak/conf/cache-ispn-jdbc.xml

ENV KC_CACHE_CONFIG_FILE=cache-ispn-jdbc.xml

COPY ./libs/* /opt/keycloak/providers/
COPY ./conf/kc.keystore-create.java.security /tmp/kc.keystore-create.java.security

RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:$KEYCLOAK_VERSION

COPY --from=builder /opt/keycloak/lib/quarkus /opt/keycloak/lib/quarkus

RUN mkdir /opt/keycloak/bin/folio
COPY folio /opt/keycloak/bin/folio
COPY ./custom-theme /opt/keycloak/themes/custom-theme
COPY ./libs/* /opt/keycloak/providers/
COPY ./conf/keycloak-fips.keystore.* /opt/keycloak/conf/server.keystore
COPY ./conf/kc.java.security /opt/keycloak/conf/kc.java.security

USER root
RUN chmod -R 550 /opt/keycloak/bin/folio

USER 1000

ENTRYPOINT [ "/opt/keycloak/bin/folio/start.sh", "start", \
"--optimized", "--https-key-store-password=${KC_HTTPS_KEY_STORE_PASSWORD}", \
"--spi-password-hashing-pbkdf2-sha256-max-padding-length=14", \
"-Djava.security.properties=/opt/keycloak/conf/kc.java.security" ]
