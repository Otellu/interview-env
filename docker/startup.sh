#!/bin/bash
# docker/startup.sh
set -uo pipefail

echo "🟢 Interview environment setup started at $(date)"

# These env variables ensure that the code-server instance starts with the correct proxy setup for a create-react-app project
export FRONTEND_PORT="${FRONTEND_PORT:-4200}"
export PUBLIC_URL="/absproxy/$FRONTEND_PORT"
export WDS_SOCKET_PATH="/absproxy/$FRONTEND_PORT/sockjs-node"
export BROWSER="none"
export VSCODE_PROXY_URI="/absproxy/{{port}}"
export NG_APP_BASE_PATH="/absproxy/$FRONTEND_PORT"

# Extract subdomain prefix and UUID from SUBDOMAIN
SESSION_ID=$(echo "$SUBDOMAIN" | sed 's/\.[^.]*$//')

TARGET_DIR="/home/ubuntu/interviewer-env/workspace/$REPO_NAME"
  
# Clone repo only if not already cloned
if [ ! -d "$TARGET_DIR" ]; then
  if [ "${ENVIRONMENT:-}" = "dev" ]; then
    echo ":inbox_tray: Cloning assignment repo (dev branch) into $TARGET_DIR..."
    sudo git clone --branch dev "$REPO_URL" "$TARGET_DIR"
  else
    echo ":inbox_tray: Cloning assignment repo into $TARGET_DIR..."
    sudo git clone "$REPO_URL" "$TARGET_DIR"
  fi
  # Find and start all npm projects inside the repo
  echo ":rocket: Setting up projects inside $TARGET_DIR"
  for dir in "$TARGET_DIR"/*/; do
    if [ -f "$dir/package.json" ]; then
      echo ":file_folder: Found project: $dir"
      (
        cd "$dir"
        echo ":package: Installing dependencies..."
        sudo npm install
      )
    fi
  done

  # Wait for all background `npm start` processes
  wait
else
  echo ":white_check_mark: Repo already exists at $TARGET_DIR"
fi

# Set proper ownership
sudo chown -R coder:coder "$TARGET_DIR"

# Install Node.js
if ! command -v node >/dev/null 2>&1; then
  echo "📦 Installing Node.js..."
  curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
  sudo apt-get install -y nodejs
else
  echo "✅ Node.js is already installed: $(node -v)"
fi

echo "SESSION_ID: $SESSION_ID"

# 🔗 Create the right environment variables for the projects
# using base64 encoded stream to prevent issues with special characters
echo "🔗 Creating environment variables for frontend..."
cd "$TARGET_DIR/frontend"

if [ -n "${FRONTEND_ENV_TEMPLATE:-}" ]; then
  echo "📄 Using provided FRONTEND_ENV_TEMPLATE"
  echo "$FRONTEND_ENV_TEMPLATE" | base64 -d | sudo tee .env > /dev/null
else
  echo "📄 Using default .env template"
  sudo tee .env > /dev/null <<EOF
REACT_APP_API_URL=https://${SESSION_ID}.com/proxy/5000/api
REACT_APP_BASE_PATH=/absproxy/${FRONTEND_PORT}
EOF
fi

# ✅ Use API_URL_VAR_NAME from env to inject session URL into .env
if [ -n "${API_URL_VAR_NAME:-}" ]; then
  SESSION_API_URL="https://${SESSION_ID}.com/proxy/5000/api"
  ENV_PATH="$TARGET_DIR/frontend/.env"
  echo "🔧 Injecting session API URL into $ENV_PATH using var: $API_URL_VAR_NAME"
  # Ensure the file exists
  sudo touch "$ENV_PATH"
  # Remove any existing line for the variable
  sudo sed -i "/^${API_URL_VAR_NAME}=.*/d" "$ENV_PATH"
  # Add the new line
  echo "${API_URL_VAR_NAME}=${SESSION_API_URL}" | sudo tee -a "$ENV_PATH"
  echo "✅ Injected: ${API_URL_VAR_NAME}=${SESSION_API_URL}"
else
  echo "⚠️ Skipping .env injection: API_URL_VAR_NAME not defined"
fi

# ! Angular only, hardcoded, make it dynamic
# 🔧 Update environment.ts file with dynamic session URL
echo "🔧 Updating frontend environment files..."
SESSION_API_URL="https://${SESSION_ID}.com/proxy/5000/api"

# Update environment.ts
ENV_TS_PATH="$TARGET_DIR/frontend/src/environments/environment.ts"
if [ -f "$ENV_TS_PATH" ]; then
  echo "📝 Updating apiUrl in $ENV_TS_PATH to: $SESSION_API_URL"
  
  # Create a temporary file with the updated content
  sudo tee "$ENV_TS_PATH" > /dev/null <<EOF
export const environment = {
  production: false,
  apiUrl: '$SESSION_API_URL',
};
EOF
  
  echo "✅ Updated environment.ts with dynamic session URL"
else
  echo "⚠️ environment.ts file not found at $ENV_TS_PATH"
fi

# Update environment.prod.ts
ENV_PROD_TS_PATH="$TARGET_DIR/frontend/src/environments/environment.prod.ts"
if [ -f "$ENV_PROD_TS_PATH" ]; then
  echo "📝 Updating apiUrl in $ENV_PROD_TS_PATH to: $SESSION_API_URL"
  
  # Create a temporary file with the updated content
  sudo tee "$ENV_PROD_TS_PATH" > /dev/null <<EOF
export const environment = {
  production: true,
  apiUrl: '$SESSION_API_URL',
};
EOF
  
  echo "✅ Updated environment.prod.ts with dynamic session URL"
else
  echo "⚠️ environment.prod.ts file not found at $ENV_PROD_TS_PATH"
fi

# 🔗 Create the right environment variables for the backend
# using base64 encoded stream to prevent issues with special characters
echo "🔗 Creating environment variables for backend..."
cd "$TARGET_DIR/backend"

if [ -n "${BACKEND_ENV_TEMPLATE:-}" ]; then
  echo "📄 Using provided BACKEND_ENV_TEMPLATE"
  echo "$BACKEND_ENV_TEMPLATE" | base64 -d | sudo tee .env > /dev/null
else
  echo "📄 Using default .env template"
  sudo tee .env > /dev/null <<EOF
MONGO_URI=mongodb://pizzauser:pizzapass@mongo-db:27017/testdb?authSource=testdb
PORT=5000
JWT_SECRET=secret
EOF
fi

# 📦 Run extra tech-specific install commands (optional)
if [ -n "${EXTRA_INSTALL_COMMANDS:-}" ]; then
  echo "📦 Running EXTRA_INSTALL_COMMANDS..."
  echo "$EXTRA_INSTALL_COMMANDS" | base64 -d | while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      echo "🔧 Running: $line"
      eval "$line"
    fi
  done
else
  echo "ℹ️ No EXTRA_INSTALL_COMMANDS to run"
fi


# 🚀 Start API server in background (from correct directory)
echo "🛠 Starting API Server..."
cd /home/coder && node api-server.js &
API_SERVER_PID=$!

# Wait for API server to start
echo "⏳ Waiting for API server..."
for i in {1..15}; do
  if curl -s http://localhost:9000/health > /dev/null 2>&1; then
    echo "✅ API Server is up!"
    break
  else
    echo "⏱ Waiting for API server... ($i)"
    sleep 2
  fi
done

# Test API server manually if still not working
if ! curl -s http://localhost:9000/health > /dev/null 2>&1; then
  echo "❌ API Server failed to start. Checking process..."
  if ps -p $API_SERVER_PID > /dev/null 2>&1; then
    echo "API server process is running but not responding"
  else
    echo "API server process died. Checking logs..."
    # Try to start it manually to see errors
    echo "Attempting to start API server manually..."
    cd /home/coder && node api-server.js &
    NEW_API_PID=$!
    sleep 3
    if ps -p $NEW_API_PID > /dev/null 2>&1; then
      API_SERVER_PID=$NEW_API_PID
      echo "✅ API Server started manually"
    else
      echo "❌ API Server failed to start manually"
    fi
  fi
fi

# 📦 Install the diff tracker extension
echo "🚀 Installing diff tracker extension..."
/usr/bin/code-server --install-extension /tmp/my-extension.vsix

# 📦 a) Install MongoDB extension
echo "🚀 Installing MongoDB extension..."
/usr/bin/code-server --install-extension mongodb.mongodb-vscode

# 🔧 Setting up IDE settings before starting code-server
echo "🔧 Setting up IDE settings..."
sudo cat > /home/coder/.local/share/code-server/User/settings.json <<EOF
{
  "markdown.preview.openMarkdownLinks": "inPreview",
  "workbench.editorAssociations": {
      "*.md": "vscode.markdown.preview.editor"
  },
  "mdb.presetConnections": [
    {
      "name": "Code Challenge Database",
      "connectionString": "mongodb://pizzauser:pizzapass@mongo-db:27017/testdb?authSource=testdb"
    }
  ],
  "security.workspace.trust.enabled": false,
  "files.autoSave": "off"
}
EOF

# 🔁 Start code-server in background - POINT DIRECTLY TO CHALLENGE DIRECTORY
echo "🚀 Starting Code Server..."
echo "📂 Opening workspace: $TARGET_DIR"
echo "Proxy domain: $SUBDOMAIN"
/usr/bin/code-server \
  --auth none \
  --host 0.0.0.0 \
  --port 8080 \
  --proxy-domain="$SUBDOMAIN" \
  "$TARGET_DIR" "$TARGET_DIR/README.md"&

CODE_SERVER_PID=$!

# Wait for Code Server
echo "⏳ Waiting for Code Server..."
for i in {1..30}; do
  if curl -s http://localhost:8080 > /dev/null 2>&1; then
    echo "✅ Code Server is up!"
    break
  else
    echo "⏱ Waiting... ($i)"
    sleep 2
  fi
done

# ✅ GET SUBDOMAIN FROM ENVIRONMENT VARIABLES
echo "📖 Reading configuration from environment variables..."

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

# Validate required environment variables
echo "📋 Environment variables:"
echo "  SUBDOMAIN: ${SUBDOMAIN:-'NOT SET'}"
echo "  INTERVIEW_TAKEN_ID: ${INTERVIEW_TAKEN_ID:-'NOT SET'}"
echo "  WEBHOOK_URL: ${WEBHOOK_URL:-'NOT SET'}"
echo "  REPO_URL: ${REPO_URL:-'NOT SET'}"

# Exit if SUBDOMAIN is missing
if [ -z "${SUBDOMAIN:-}" ]; then
  echo "❌ SUBDOMAIN environment variable is required but not set!"
  echo "Make sure docker-compose.yml passes SUBDOMAIN from userDataScript"
  exit 1
fi

# Set other variables with fallbacks
INTERVIEW_TAKEN_ID="${INTERVIEW_TAKEN_ID:-unknown}"
CHALLENGE_REPO="${REPO_URL:-https://github.com/Otellu/pizza-shop-challenge.git}"

# Construct the session URL
SESSION_URL="https://${SUBDOMAIN}"

# Read the README.md file if it exists
README_CONTENT=""
if [ -f "$TARGET_DIR/README.md" ]; then
  echo "📖 Reading README.md content..."
  README_CONTENT=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" < "$TARGET_DIR/README.md")
else
  echo "⚠️ README.md not found in $TARGET_DIR"
  README_CONTENT=""
fi

# Prepare webhook payload
WEBHOOK_PAYLOAD=$(cat <<EOF
{
  "instance_id": "$INSTANCE_ID",
  "public_ip": "$PUBLIC_IP",
  "session_url": "$SESSION_URL",
  "subdomain": "${SUBDOMAIN}",
  "interview_taken_id": "$INTERVIEW_TAKEN_ID",
  "challenge_repo": "$CHALLENGE_REPO",
  "workspace_path": "$TARGET_DIR",
  "readme_content": $README_CONTENT,
  "status": "ready",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
}
EOF
)

# Send webhook with retry logic
echo "📡 Sending webhook to: $WEBHOOK_URL"
WEBHOOK_SUCCESS=false
for i in {1..3}; do
  echo "📡 Webhook attempt $i/3..."
  echo "curl -s -L -w POST ${WEBHOOK_URL}";
  WEBHOOK_RESPONSE=$(curl -s -L -w "\n%{http_code}" -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$WEBHOOK_PAYLOAD")
  
  # Extract HTTP status code (last line)
  HTTP_STATUS=$(echo "$WEBHOOK_RESPONSE" | tail -n1)
  RESPONSE_BODY=$(echo "$WEBHOOK_RESPONSE" | head -n -1)
  
  if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 201 ]; then
    echo "✅ Webhook sent successfully (HTTP $HTTP_STATUS)"
    echo "📋 Response: $RESPONSE_BODY"
    WEBHOOK_SUCCESS=true
    break
  else
    echo "❌ Webhook failed (HTTP $HTTP_STATUS)"
    echo "📋 Response: $RESPONSE_BODY"
    if [ $i -lt 3 ]; then
      echo "⏱ Retrying in 5 seconds..."
      sleep 5
    fi
  fi
done

if [ "$WEBHOOK_SUCCESS" = false ]; then
  echo "❌ All webhook attempts failed"
fi

# Function to handle shutdown gracefully
cleanup() {
  echo "🛑 Shutting down services..."
  
  # Kill API server
  if [ ! -z "$API_SERVER_PID" ]; then
    kill $API_SERVER_PID 2>/dev/null || true
    echo "🛑 API Server stopped"
  fi
  
  # Kill code server
  if [ ! -z "$CODE_SERVER_PID" ]; then
    kill $CODE_SERVER_PID 2>/dev/null || true
    echo "🛑 Code Server stopped"
  fi
  
  # Trigger final workspace save
  echo "💾 Triggering final workspace save..."
  curl -s -X POST http://localhost:9000/api/save-workspace \
    -H "Content-Type: application/json" \
    || echo "❌ Final save failed"
  
  exit 0
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT

# Print final status
echo "========================================"
echo "🎉 Setup completed!"
echo "📂 Workspace: $TARGET_DIR"
echo "🔗 Code Server: http://localhost:8080"
echo "🛠 API Server: http://localhost:9000"
echo "🌐 Session URL: $SESSION_URL"
echo "========================================"

# 🔒 Wait for both processes
echo "🔒 All services running. Waiting for shutdown signal..."
wait $CODE_SERVER_PID
