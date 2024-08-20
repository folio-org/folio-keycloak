#!/bin/bash
set -e

# Install AWS CLI
echo "Installing AWS CLI..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

echo "Downloading file from S3..."
aws s3 cp s3://observability-folio-eis-us-east-1-dev/opentelemetry-javaagent-1.28.0.jar /opt/javaagents/

echo "Setting JAVA_OPTS environment variable..."
export JAVA_OPTS_APPEND="-javaagent:/opt/javaagents/opentelemetry-javaagent-1.28.0.jar"
echo "JAVA_OPTS set to: $JAVA_OPTS_APPEND"

# Optionally, you can add the environment variable to /etc/environment
# echo "JAVA_OPTS_APPEND=$JAVA_OPTS_APPEND" | sudo tee -a /etc/environment

echo "AWS CLI installed, file downloaded from S3, and JAVA_OPTS set successfully."
