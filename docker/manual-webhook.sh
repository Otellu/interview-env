#!/bin/bash
# docker/manual-webhook.sh
# Manual webhook calling script for interview environment

set -uo pipefail

echo "🔧 Manual webhook calling script started at $(date)"

# Get the metadata token
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Validate token
if [ -z "$TOKEN" ]; then
  echo "❌ Failed to retrieve EC2 metadata token"
  exit 1
fi

# Set the webhook URL from environment or use fallback
WEBHOOK_URL="${WEBHOOK_URL:-https://cruit-europe.com/api/containers/webhooks}"

# Get instance ID and public IP
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)

# Validate values
if [ -z "$INSTANCE_ID" ] || [ -z "$PUBLIC_IP" ]; then
  echo "❌ Failed to retrieve instance metadata"
  exit 1
fi

# Extract subdomain prefix and UUID from SUBDOMAIN
SESSION_ID=$(echo "$SUBDOMAIN" | sed 's/\.[^.]*$//')

# Validate required environment variables
echo "📋 Environment variables:"
echo "  SUBDOMAIN: ${SUBDOMAIN:-'NOT SET'}"
echo "  INTERVIEW_TAKEN_ID: ${INTERVIEW_TAKEN_ID:-'NOT SET'}"
echo "  WEBHOOK_URL: ${WEBHOOK_URL:-'NOT SET'}"
echo "  REPO_URL: ${REPO_URL:-'NOT SET'}"

# Exit if SUBDOMAIN is missing
if [ -z "${SUBDOMAIN:-}" ]; then
  echo "❌ SUBDOMAIN environment variable is required but not set!"
  exit 1
fi

# Check if webhook payload file exists
WEBHOOK_PAYLOAD_FILE="/tmp/webhook-payload.json"
if [ ! -f "$WEBHOOK_PAYLOAD_FILE" ]; then
  echo "❌ Webhook payload file not found: $WEBHOOK_PAYLOAD_FILE"
  echo "📋 Please ensure the payload file exists before running this script"
  exit 1
fi

echo "📋 Reading webhook payload from: $WEBHOOK_PAYLOAD_FILE"
echo "📋 Payload content:"
cat "$WEBHOOK_PAYLOAD_FILE" | jq '.' 2>/dev/null || cat "$WEBHOOK_PAYLOAD_FILE"

# Send webhook once
echo "📡 Sending webhook to: $WEBHOOK_URL"

WEBHOOK_RESPONSE=$(curl -s -L -w "\n%{http_code}" -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d @"$WEBHOOK_PAYLOAD_FILE")

# Extract HTTP status code (last line)
HTTP_STATUS=$(echo "$WEBHOOK_RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$WEBHOOK_RESPONSE" | head -n -1)

if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 201 ]; then
  echo "✅ Webhook sent successfully (HTTP $HTTP_STATUS)"
  echo "📋 Response: $RESPONSE_BODY"
  echo "📁 Payload file remains at: $WEBHOOK_PAYLOAD_FILE"
else
  echo "❌ Webhook failed (HTTP $HTTP_STATUS)"
  echo "📋 Response: $RESPONSE_BODY"
  echo "📁 You can manually send the webhook using the payload file: $WEBHOOK_PAYLOAD_FILE"
  echo "📋 Manual curl command:"
  echo "curl -X POST $WEBHOOK_URL \\"
  echo "  -H \"Content-Type: application/json\" \\"
  echo "  -d @$WEBHOOK_PAYLOAD_FILE"
fi

echo "🔧 Manual webhook script completed at $(date)" 