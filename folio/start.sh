#!/bin/bash
# Check if OTEL_AGENT_EXTENSION_VERSION and OTEL_BUCKET_NAME environment variables are set
if [ -n "$OTEL_AGENT_EXTENSION_VERSION" ] && [ -n "$OTEL_AGENT_VERSION" ] && [ -n "$OTEL_BUCKET_NAME" ]; then
  if [[ "$OTEL_AGENT_EXTENSION_VERSION" == *SNAPSHOT* ]]; then
    AGENT_EXTENSION_FOLDER="snapshots"
  else
    AGENT_EXTENSION_FOLDER="releases"
  fi
  AGENT_EXTENSION_FILE_NAME=$(aws s3 ls s3://$OTEL_BUCKET_NAME/$AGENT_EXTENSION_FOLDER/ | grep "$OTEL_AGENT_EXTENSION_VERSION" | sed 's/  */ /g' | cut -d ' ' -f4)
  AGENT_FILE_NAME=$(aws s3 ls s3://$OTEL_BUCKET_NAME/ | grep "opentelemetry-javaagent-$OTEL_AGENT_VERSION" | sed 's/  */ /g' | cut -d ' ' -f4)

  # If agent file found, copy it and add as Javaagent
  if [ -n "$AGENT_EXTENSION_FILE_NAME" ] && [ -n "$AGENT_FILE_NAME" ]; then
    AGENT_PATH="/opt/javaagents/$AGENT_FILE_NAME"
    AGENT_EXTENSION_PATH="/opt/javaagents/$AGENT_EXTENSION_FILE_NAME"

    aws s3 cp s3://$OTEL_BUCKET_NAME/$AGENT_EXTENSION_FOLDER/$AGENT_EXTENSION_FILE_NAME $AGENT_EXTENSION_PATH
    aws s3 cp s3://$OTEL_BUCKET_NAME/$AGENT_FILE_NAME $AGENT_PATH
    JAVA_OPTS_APPEND="-javaagent:$AGENT_PATH -Dotel.javaagent.extensions=$AGENT_EXTENSION_PATH $JAVA_OPTS_APPEND"
  else
    echo "Opentelemetry java agent extension $OTEL_AGENT_EXTENSION_VERSION or java agent $OTEL_AGENT_VERSION not found in S3 bucket"
  fi
else
  echo "OTEL_AGENT_EXTENSION_VERSION environment variable is not set"
fi

if [[ -z "$KC_FOLIO_BE_ADMIN_CLIENT_SECRET" ]]; then
  echo "$(date +%F' '%T,%3N) ERROR [start.sh] Environment variable KC_FOLIO_BE_ADMIN_CLIENT_SECRET is not set, check 
  the configuration"
  exit 1
fi
/opt/keycloak/bin/folio/configure-realms.sh &

kcCache=ispn
kcCacheConfigFile=cache-ispn-jdbc.xml

echo "Starting in non FIPS mode"
/opt/keycloak/bin/kc.sh start \
  --optimized \
  --http-enabled=false \
  --https-key-store-type=BCFKS \
  --https-key-store-file="${KC_HTTPS_KEY_STORE:-/opt/keycloak/conf/test.server.keystore}" \
  --https-key-store-password="${KC_HTTPS_KEY_STORE_PASSWORD:-SecretPassword}" \
  --spi-password-hashing-pbkdf2-sha256-max-padding-length=14 \
  --cache="$kcCache" \
  --cache-config-file="$kcCacheConfigFile" \
  --log-level=INFO,org.keycloak.common.crypto:TRACE,org.keycloak.crypto:TRACE
