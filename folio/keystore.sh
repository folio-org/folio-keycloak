#!/bin/bash
# Using self-signed certificates is for dev purposes only,
# so replace these certificates with proper certificates when moving to a production environment.

script="keystore.sh"
keycloakHost="${KC_HOSTNAME}"
keypass="${KC_HTTPS_KEY_STORE_PASSWORD}"
keystore=/opt/keycloak/conf/server.keystore

function generateKeystore() {
  if checkKeystore; then
    echo "$(date +%F' '%T,%3N) INFO  [$script] Keystore $keystore exists."
    return 0;
  else
    echo "$(date +%F' '%T,%3N) INFO  [$script] Keystore password is invalid. Re-creating keystore."
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

function checkKeystore() {
  if ! test -f "$keystore"; then
    return 0;
  fi

  keytool -list -keystore $keystore \
    -storetype BCFKS \
    -providername BCFIPS \
    -providerclass org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
    -provider org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
    -providerpath /opt/keycloak/providers/bc-fips-*.jar \
    -storepass "$keypass" \
    -J-Djava.security.properties=/tmp/kc.keystore-create.java.security
}

echo "$(date +%F' '%T,%3N) INFO  [$script] Generating BCFKS keystore for hostname: '$keycloakHost'"
if generateKeystore; then
  echo "$(date +%F' '%T,%3N) INFO  [$script] BCFKS keystore generation finished."
fi

