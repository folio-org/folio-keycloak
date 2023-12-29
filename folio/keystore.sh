#!/bin/bash

script="keystore.sh"
keycloakHost="${KC_HOSTNAME:-keycloak}"
storePass="${KC_KEYSTORE_STORE_PASS:passwordpassword}"
keyPass="${KC_KEYSTORE_KEY_PASS:passwordpassword}"

function keystoreRun() {
  keytool -keystore /opt/keycloak/conf/server.keystore \
    -storetype bcfks \
    -providername BCFIPS \
    -providerclass org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
    -provider org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
    -providerpath /opt/keycloak/providers/bc-fips-*.jar \
    -alias "$keycloakHost" \
    -genkeypair -sigalg SHA512withRSA -keyalg RSA -storepass "$storePass" \
    -dname CN="$keycloakHost" -keypass "$keyPass" \
    -J-Djava.security.properties=/tmp/kc.keystore-create.java.security
}

echo "$(date +%F' '%T,%3N) INFO  [$script] Generating BCFKS keystore for hostname: '$keycloakHost'"
if keystoreRun; then
  echo "$(date +%F' '%T,%3N) INFO  [$script] BCFKS keystore generation finished."
fi

