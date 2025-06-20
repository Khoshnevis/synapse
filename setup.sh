#!/usr/bin/env bash
#   setup_synapse_stack.sh ― one‑shot installer / updater for
#   Synapse + Element + LiveKit + coturn + mautrix‑whatsapp + Traefik
#   -----------------------------------------------------------------
#   • Idempotent: you can re‑run it after edits or upgrades
#   • Adds all fixes discussed 2025‑06‑20
#   -----------------------------------------------------------------
set -euo pipefail

###############################################################################
#  0.  Fixed parameters – edit DOMAIN / ADMIN_EMAIL only                      #
###############################################################################
DOMAIN="raikaco.org"
ADMIN_EMAIL="admin@raikaco.org"

###############################################################################
#  1.  Generate fresh secrets (if they don't exist yet)                       #
###############################################################################
if [ ! -f synapse/.env ]; then
  echo "→ Generating secrets (.env)"
  POSTGRES_PASSWORD=$(openssl rand -hex 12)
  AUTH_SECRET=$(openssl rand -hex 16)             # shared TURN & LiveKit secret
  WA_AS_TOKEN=$(openssl rand -hex 32)
  WA_HS_TOKEN=$(openssl rand -hex 32)

  mkdir -p synapse
  cat > synapse/.env <<EOF
SERVER_NAME=${DOMAIN}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
AUTH_SECRET=${AUTH_SECRET}
WA_AS_TOKEN=${WA_AS_TOKEN}
WA_HS_TOKEN=${WA_HS_TOKEN}
EOF
fi
source synapse/.env              # shell‑export the values for later steps

###############################################################################
#  2.  Lay out directory structure                                            #
###############################################################################
mkdir -p synapse/{data/synapse,data/postgres,traefik,coturn,livekit,mautrix-whatsapp,element}
touch  synapse/traefik/acme.json
chmod 600 synapse/traefik/acme.json        # Traefik requirement

###############################################################################
#  3.  (Re)generate homeserver.yaml if missing                                #
###############################################################################
if [ ! -f synapse/data/synapse/homeserver.yaml ]; then
  echo "→ Generating homeserver.yaml"
  docker run --rm -v "$(pwd)/synapse/data/synapse:/data" \
      -e SYNAPSE_SERVER_NAME=${DOMAIN} \
      -e SYNAPSE_REPORT_STATS=no \
      matrixdotorg/synapse:latest generate
fi

# 3a. ensure Postgres backend (overwrites default SQLite stanza)
awk -v pw="${POSTGRES_PASSWORD}" '
  BEGIN {r=0}
  /^database:/ {
    print "database:\n  name: psycopg2\n  args:\n    user: synapse\n    password: " pw "\n    database: synapse\n    host: postgres\n    port: 5432\n    cp_min: 5\n    cp_max: 10"
    r=1; next
  }
  r && /^#/ {r=0}
  !r {print}

' synapse/data/synapse/homeserver.yaml > /tmp/hs && mv /tmp/hs synapse/data/synapse/homeserver.yaml

# 3b. ensure media store lives under /data
grep -q '^media_store_path:' synapse/data/synapse/homeserver.yaml || \
  sed -i '1imedia_store_path: /data/media_store' synapse/data/synapse/homeserver.yaml

# 3c. Explicitly opt‑out of stats (fixes reboot loop)
grep -q '^report_stats:' synapse/data/synapse/homeserver.yaml || \
  sed -i '1ireport_stats: false' synapse/data/synapse/homeserver.yaml

###############################################################################
#  4.  Traefik static config                                                  #
###############################################################################
cat > synapse/traefik/traefik.yml <<EOF
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: letsencrypt
api:
  dashboard: true
certificatesResolvers:
  letsencrypt:
    acme:
      email: ${ADMIN_EMAIL}
      storage: "/acme.json"
      httpChallenge:
        entryPoint: web
providers:
  docker:
    exposedByDefault: false
EOF

###############################################################################
#  5.  coturn                                                                 #
###############################################################################
cat > synapse/coturn/turnserver.conf <<EOF
listening-port=3478
tls-listening-port=5349
fingerprint
use-auth-secret
static-auth-secret=${AUTH_SECRET}
realm=${DOMAIN}
EOF

###############################################################################
#  6.  LiveKit                                                                #
###############################################################################
cat > synapse/livekit/config.yaml <<EOF
port: 7880
rtc:
  tcp_port: 7881
  udp_port: 7881
  port_range_start: 50000
  port_range_end: 60000
keys:
  devkey: ${AUTH_SECRET}
turn:
  enabled: true
  domain: turn.${DOMAIN}
  secret: ${AUTH_SECRET}
  port: 3478
  tls_port: 5349
EOF

###############################################################################
#  7.  Element‑Web                                                            #
###############################################################################
cat > synapse/element/config.json <<EOF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://synapse.${DOMAIN}",
      "server_name": "${DOMAIN}"
    }
  },
  "brand": "Raika Chat",
  "default_theme": "light"
}
EOF

###############################################################################
#  8.  mautrix‑whatsapp                                                       #
###############################################################################
mkdir -p synapse/mautrix-whatsapp/whatsmeow
cat > synapse/mautrix-whatsapp/config.yaml <<EOF
homeserver:
  address: https://synapse.${DOMAIN}
  domain: ${DOMAIN}

appservice:
  id: whatsapp
  as_token: ${WA_AS_TOKEN}
  hs_token: ${WA_HS_TOKEN}
  bot_username: "wa_bot"

database:
  type: sqlite
  uri: file:mautrix-whatsapp.db

bridge:
  permissions:
    "@admin:${DOMAIN}": admin
    "*": user
EOF

# 8a. Pre‑generate the app‑service registration
docker run --rm -v "$(pwd)/synapse/mautrix-whatsapp:/data" \
  dock.mau.dev/mautrix/whatsapp:latest \
  /usr/bin/mautrix-whatsapp -g -c /data/config.yaml -r /data/wa-registration.yaml

# 8b. Tell Synapse to load the registration exactly once
grep -q 'wa-registration.yaml' synapse/data/synapse/homeserver.yaml || \
  sed -i '/^app_service_config_files:/!b;n; a\  - /data/wa-registration.yaml' \
    synapse/data/synapse/homeserver.yaml || \
  printf "\napp_service_config_files:\n  - /data/wa-registration.yaml\n" >> synapse/data/synapse/homeserver.yaml

###############################################################################
#  9.  docker‑compose stack                                                   #
###############################################################################
cat > synapse/docker-compose.yml <<'EOF'
services:
  postgres:
    image: postgres:15-alpine
    restart: unless-stopped
    env_file: .env
    environment:
      POSTGRES_DB: synapse
      POSTGRES_USER: synapse
    volumes: [ "./data/postgres:/var/lib/postgresql/data" ]

  synapse:
    image: matrixdotorg/synapse:latest
    restart: unless-stopped
    depends_on: [postgres]
    env_file: .env
    volumes: [ "./data/synapse:/data" ]
    labels:
      traefik.enable: "true"
      traefik.http.routers.synapse.rule: "Host(`synapse.${SERVER_NAME}`)"
      traefik.http.routers.synapse.entrypoints: "websecure"
      traefik.http.services.synapse.loadbalancer.server.port: "8008"

  element:
    image: vectorim/element-web:latest
    restart: unless-stopped
    volumes: [ "./element/config.json:/app/config.json:ro" ]
    labels:
      traefik.enable: "true"
      traefik.http.routers.element.rule: "Host(`app.${SERVER_NAME}`)"
      traefik.http.routers.element.entrypoints: "websecure"

  mautrix-whatsapp:
    image: dock.mau.dev/mautrix/whatsapp:latest
    restart: unless-stopped
    volumes: [ "./mautrix-whatsapp:/data" ]
    labels:
      traefik.enable: "true"
      traefik.http.routers.wa.rule: "Host(`wa.${SERVER_NAME}`)"
      traefik.http.routers.wa.entrypoints: "websecure"

  livekit:
    image: livekit/livekit-server:latest
    command: ["--config", "/etc/livekit/config.yaml"]
    restart: unless-stopped
    volumes: [ "./livekit/config.yaml:/etc/livekit/config.yaml:ro" ]
    labels:
      traefik.enable: "true"
      traefik.http.routers.livekit.rule: "Host(`livekit.${SERVER_NAME}`)"
      traefik.http.routers.livekit.entrypoints: "websecure"
    ports: [ "7881:7881/udp" ]   # RTP/RTCP

  coturn:
    image: instrumentisto/coturn:latest
    restart: unless-stopped
    network_mode: host
    command: ["-c", "/etc/coturn/turnserver.conf"]
    volumes: [ "./coturn/turnserver.conf:/etc/coturn/turnserver.conf:ro" ]

  traefik:
    image: traefik:v3.4
    restart: unless-stopped
    ports: [ "80:80", "443:443" ]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./traefik/acme.json:/acme.json
EOF

###############################################################################
# 10.  Pull + bootstrap                                                       #
###############################################################################
echo "→ Pulling images & starting stack"
docker compose -f synapse/docker-compose.yml pull
docker compose -f synapse/docker-compose.yml up -d

echo -e "\n✅  All services are (re)starting."
echo    "   → Element:  https://app.${DOMAIN}"
echo    "   → Traefik:  https://traefik.${DOMAIN}  (enable auth first!)"
echo    "   → IMPORTANT: make sure every sub‑domain A‑record now points to the"
echo    "     single public IP of this host before relying on HTTPS."
