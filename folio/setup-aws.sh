#!/bin/bash
OTEL_AGENT_EXTENSION_VERSION="1.0-SNAPSHOT.230"
OTEL_AGENT_VERSION="1.28.0"
OTEL_BUCKET_NAME="observability-folio-eis-us-east-1-dev"
# Check if OTEL_AGENT_EXTENSION_VERSION and OTEL_BUCKET_NAME environment variables are set
if [ -n "$OTEL_AGENT_EXTENSION_VERSION" ] && [ -n "$OTEL_AGENT_VERSION" ] && [ -n "$OTEL_BUCKET_NAME" ]; then
  if [[ "$OTEL_AGENT_EXTENSION_VERSION" == *SNAPSHOT* ]]; then
    AGENT_EXTENSION_FOLDER="snapshots"
  else
    AGENT_EXTENSION_FOLDER="releases"
  fi
  echo "DEBUG1"
  aws s3 ls s3://$OTEL_BUCKET_NAME/$AGENT_EXTENSION_FOLDER/ | grep "$OTEL_AGENT_EXTENSION_VERSION" 
  echo "DEBUG2"
  AGENT_EXTENSION_FILE_NAME=$(aws s3 ls s3://$OTEL_BUCKET_NAME/$AGENT_EXTENSION_FOLDER/ | grep "$OTEL_AGENT_EXTENSION_VERSION")
  AGENT_FILE_NAME=$(aws s3 ls s3://$OTEL_BUCKET_NAME/ | grep "opentelemetry-javaagent-$OTEL_AGENT_VERSION")
  echo $AGENT_EXTENSION_FILE_NAME
  echo $AGENT_FILE_NAME
  # If agent file found, copy it and add as Javaagent
  if [ -n "$AGENT_EXTENSION_FILE_NAME" ] && [ -n "$AGENT_FILE_NAME" ]; then
    AGENT_PATH="/opt/javaagents/$AGENT_FILE_NAME"
    AGENT_EXTENSION_PATH="/opt/javaagents/$AGENT_EXTENSION_FILE_NAME"

    aws s3 cp s3://$OTEL_BUCKET_NAME/$AGENT_EXTENSION_FOLDER/$AGENT_EXTENSION_FILE_NAME $AGENT_EXTENSION_PATH
    aws s3 cp s3://$OTEL_BUCKET_NAME/$AGENT_FILE_NAME $AGENT_PATH
    JAVA_OPTS_APPEND="-javaagent:$AGENT_PATH -Dotel.javaagent.extensions=$AGENT_EXTENSION_PATH"
  else
    echo "Opentelemetry java agent extension $OTEL_AGENT_EXTENSION_VERSION or java agent $OTEL_AGENT_VERSION not found in S3 bucket"
  fi
else
  echo "OTEL_AGENT_EXTENSION_VERSION environment variable is not set"
fi
