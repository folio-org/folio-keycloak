#!/bin/bash
# Using self-signed certificates is for dev purposes only,
# so replace these certificates with proper certificates when moving to a production environment.

script="keystore.sh"
keycloakHost="${KC_HOSTNAME:-keycloak}"
keypass="${KC_HTTPS_KEY_STORE_PASSWORD:-keystoresecret123}"
keystore=/opt/keycloak/conf/server.keystore

function generateKeystore() {
  if test -f "$keystore"; then
    echo "Removing existing $keystore"
    rm $keystore
  fi
  keytool -keystore $keystore \
    -storetype BCFKS \
    -providername BCFIPS \
    -providerclass org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
    -provider org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
    -providerpath /opt/keycloak/providers/bc-fips-*.jar \
    -alias "$keycloakHost" \
    -genkeypair -sigalg SHA512withRSA -keyalg RSA -storepass "$keypass" \
    -dname CN="$keycloakHost" -keypass "$keypass" \
    -J-Djava.security.properties=/tmp/kc.keystore-create.java.security
}

echo "$(date +%F' '%T,%3N) INFO  [$script] Generating BCFKS keystore for hostname: '$keycloakHost'"
if generateKeystore; then
  echo "$(date +%F' '%T,%3N) INFO  [$script] BCFKS keystore generation finished."
fi

