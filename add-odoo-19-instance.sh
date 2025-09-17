#!/bin/bash
################################################################################
# Script to add an Odoo 19 instance to an existing server setup
#-------------------------------------------------------------------------------
# Usage:
#   sudo ./add-odoo-instance.sh
################################################################################

set -e

#------------------------ Helpers ------------------------#
generate_random_password() { openssl rand -base64 16; }

install_package() {
  local PACKAGE=$1
  if ! dpkg -s "$PACKAGE" &> /dev/null; then
    echo "$PACKAGE not found. Installing..."
    sudo apt update
    sudo apt install -y "$PACKAGE"
  fi
}

#--------------------- Base packages ---------------------#
install_package "lsof"
install_package "python3-venv"
install_package "nginx"
install_package "snapd"

# Certbot
if ! command -v certbot &>/dev/null; then
  echo "Installing Certbot..."
  sudo snap install core
  sudo snap refresh core
  sudo snap install --classic certbot
  sudo ln -sf /snap/bin/certbot /usr/bin/certbot
fi

#--------------------- Variables base --------------------#
OE_USER="odoo"
INSTALL_WKHTMLTOPDF="True"
OE_VERSION="19.0"              # <- actualizado a 19.0
IS_ENTERPRISE="False"
GENERATE_RANDOM_PASSWORD="True"

BASE_ODOO_PORT=8069
BASE_GEVENT_PORT=8072          # por defecto CLI Odoo 19 (websocket/longpoll) :contentReference[oaicite:5]{index=5}

OE_HOME="/odoo"
# Ruta del código fuente. Ajusta si tu árbol es distinto.
# Recomendado: /odoo/odoo-19.0 (o /odoo/odoo-server si ya lo usas).
OE_HOME_EXT="${OE_HOME}/odoo-19.0"

# Addons enterprise (si existiera)
ENTERPRISE_ADDONS="${OE_HOME}/enterprise/addons"

SERVER_IP=$(hostname -I | awk '{print $1}')

declare -a EXISTING_INSTANCE_NAMES
declare -a EXISTING_OE_PORTS
declare -a EXISTING_GEVENT_PORTS

# Detectar instancias existentes con patrón odoo-server-NOMBRE.conf y/o *.conf por compatibilidad
for CONFIG_FILE in /etc/${OE_USER}-server-*.conf /etc/odoo*.conf /etc/${OE_USER}-*.conf; do
  [ -f "$CONFIG_FILE" ] || continue
  # nombre de instancia a partir del conf
  BASENAME=$(basename "$CONFIG_FILE")
  NAME="${BASENAME%.conf}"
  # quita prefijos comunes
  NAME="${NAME#${OE_USER}-server-}"
  NAME="${NAME#${OE_USER}-}"
  NAME="${NAME#odoo-}"
  NAME="${NAME#odoo}"
  NAME="${NAME##_}" ; NAME="${NAME##-}"
  [ -n "$NAME" ] || NAME="default"

  EXISTING_INSTANCE_NAMES+=("$NAME")

  # Prioriza http_port (Odoo 19); si no, intenta xmlrpc_port (legado)
  PORT=$(grep -E '^(http_port|xmlrpc_port)\s*=' "$CONFIG_FILE" | tail -n1 | awk -F'= *' '{print $2}')
  GEVENT=$(grep -E '^(gevent_port|longpolling_port)\s*=' "$CONFIG_FILE" | tail -n1 | awk -F'= *' '{print $2}')
  [ -n "$PORT" ] && EXISTING_OE_PORTS+=("$PORT")
  [ -n "$GEVENT" ] && EXISTING_GEVENT_PORTS+=("$GEVENT")
done

#--------------------- Port selection --------------------#
find_available_port() {
  local BASE_PORT=$1
  local -n EXISTING=$2
  local PORT=$BASE_PORT
  while true; do
    if [[ " ${EXISTING[@]} " =~ " $PORT " ]] || lsof -i TCP:$PORT >/dev/null 2>&1; then
      PORT=$((PORT+1))
    else
      echo "$PORT"; return 0
    fi
  done
}

#--------------------- Prompt usuario --------------------#
read -p "Enter the name for the new instance (e.g., odoo19a): " INSTANCE_NAME
[[ "$INSTANCE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Invalid name."; exit 1; }

# enterprise?
read -p "Do you have an enterprise license for this instance DB? (yes/no): " ENTERPRISE_CHOICE
if [[ "$ENTERPRISE_CHOICE" =~ ^(yes|y)$ ]]; then HAS_ENTERPRISE_LICENSE="True"; else HAS_ENTERPRISE_LICENSE="False"; fi

# duplicado?
if [[ " ${EXISTING_INSTANCE_NAMES[@]} " =~ " ${INSTANCE_NAME} " ]]; then
  echo "Instance '$INSTANCE_NAME' already exists."; exit 1
fi

OE_CONFIG="${OE_USER}-server-${INSTANCE_NAME}"

OE_PORT=$(find_available_port $BASE_ODOO_PORT EXISTING_OE_PORTS)
GEVENT_PORT=$(find_available_port $BASE_GEVENT_PORT EXISTING_GEVENT_PORTS)

echo "Assigned Ports:"
echo "  HTTP Port: $OE_PORT"
echo "  Gevent (longpoll/websocket) Port: $GEVENT_PORT"

# SSL
read -p "Enable SSL with Certbot for '$INSTANCE_NAME'? (yes/no): " SSL_CHOICE
if [[ "$SSL_CHOICE" =~ ^(yes|y)$ ]]; then
  ENABLE_SSL="True"
  read -p "Domain (e.g., mycompany.com): " WEBSITE_NAME
  read -p "Also include www.$WEBSITE_NAME ? (yes/no): " WWW_CHOICE
  read -p "Admin email for certbot: " ADMIN_EMAIL

  [[ "$WEBSITE_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || { echo "Invalid domain."; exit 1; }
  if [[ "$WWW_CHOICE" =~ ^(yes|y)$ ]]; then
    DOMAIN_ARGS="-d $WEBSITE_NAME -d www.$WEBSITE_NAME"
    NGINX_SERVER_NAME="$WEBSITE_NAME www.$WEBSITE_NAME"
  else
    DOMAIN_ARGS="-d $WEBSITE_NAME"
    NGINX_SERVER_NAME="$WEBSITE_NAME"
  fi
  [[ "$ADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo "Invalid email."; exit 1; }
else
  ENABLE_SSL="False"
  WEBSITE_NAME=$SERVER_IP
  NGINX_SERVER_NAME=$SERVER_IP
fi

# master password
if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
  OE_SUPERADMIN=$(generate_random_password)
  echo "Generated random superadmin password."
else
  read -s -p "Enter the superadmin password: " OE_SUPERADMIN; echo
fi

# Usuario de BD por instancia (con password)
DB_PASSWORD=$(generate_random_password)
echo "Generated random PostgreSQL password."

# Crear rol de BD
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${INSTANCE_NAME}'" | grep -q 1; then
  echo "PostgreSQL user '${INSTANCE_NAME}' already exists. Skipping."
else
  sudo -u postgres psql -c "CREATE USER ${INSTANCE_NAME} WITH CREATEDB NOSUPERUSER NOCREATEROLE PASSWORD '${DB_PASSWORD}';"
fi

echo -e "\n==== Configuring ODOO 19 instance '$INSTANCE_NAME' ===="

#----------------- Directorios por instancia -----------------#
INSTANCE_DIR="${OE_HOME}/${INSTANCE_NAME}"
sudo mkdir -p "${INSTANCE_DIR}/custom/addons"
sudo chown -R $OE_USER:$OE_USER "${INSTANCE_DIR}"

#----------------- venv por instancia -----------------#
INSTANCE_VENV="${INSTANCE_DIR}/venv"
echo "Creating venv for '$INSTANCE_NAME' ..."
sudo -u $OE_USER python3 -m venv "$INSTANCE_VENV"

# Instalar requirements: primero local (si existe), si no desde GitHub (branch 19.0)
REQ_LOCAL="${OE_HOME_EXT}/requirements.txt"
if [ -f "$REQ_LOCAL" ]; then
  echo "Installing Python deps from local requirements.txt ..."
  sudo -u $OE_USER bash -c "source ${INSTANCE_VENV}/bin/activate && pip install --upgrade pip wheel && pip install -r ${REQ_LOCAL}"
else
  echo "Local requirements.txt not found at ${REQ_LOCAL}."
  echo "Installing deps from remote Odoo ${OE_VERSION} requirements.txt ..."
  sudo -u $OE_USER bash -c "source ${INSTANCE_VENV}/bin/activate && pip install --upgrade pip wheel && pip install -r https://raw.githubusercontent.com/odoo/odoo/${OE_VERSION}/requirements.txt"
fi
# (Odoo 19 requiere Python >=3.10; requirements oficiales por branch) :contentReference[oaicite:6]{index=6}

#----------------- addons_path -----------------#
if [ "$HAS_ENTERPRISE_LICENSE" = "True" ] && [ -d "$ENTERPRISE_ADDONS" ]; then
  ADDONS_PATH="${ENTERPRISE_ADDONS},${OE_HOME_EXT}/addons,${INSTANCE_DIR}/custom/addons"
else
  ADDONS_PATH="${OE_HOME_EXT}/addons,${INSTANCE_DIR}/custom/addons"
fi

#----------------- odoo.conf por instancia -----------------#
echo -e "\n---- Creating server config file: /etc/${OE_CONFIG}.conf ----"
sudo bash -c "cat > /etc/${OE_CONFIG}.conf" <<EOF
[options]
admin_passwd = ${OE_SUPERADMIN}
db_host = localhost
db_user = ${INSTANCE_NAME}
db_password = ${DB_PASSWORD}
;list_db = False
http_port = ${OE_PORT}
gevent_port = ${GEVENT_PORT}
logfile = /var/log/${OE_USER}/${OE_CONFIG}.log
addons_path = ${ADDONS_PATH}
limit_memory_hard = 2677721600
limit_memory_soft = 1829145600
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
max_cron_threads = 1
workers = 2
EOF

if [ "$ENABLE_SSL" = "True" ]; then
  sudo bash -c "echo 'dbfilter = ^%h\$' >> /etc/${OE_CONFIG}.conf"
  sudo bash -c "echo 'proxy_mode = True' >> /etc/${OE_CONFIG}.conf"
fi

sudo chown $OE_USER:$OE_USER /etc/${OE_CONFIG}.conf
sudo chmod 640 /etc/${OE_CONFIG}.conf

#----------------- systemd service -----------------#
echo -e "\n---- Creating systemd service: ${OE_CONFIG}.service ----"
SERVICE_FILE="${OE_CONFIG}.service"
sudo bash -c "cat > /etc/systemd/system/${SERVICE_FILE}" <<EOF
[Unit]
Description=Odoo 19 - Instance ${INSTANCE_NAME}
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
SyslogIdentifier=${OE_CONFIG}
PermissionsStartOnly=true
User=${OE_USER}
Group=${OE_USER}
ExecStart=${INSTANCE_VENV}/bin/python ${OE_HOME_EXT}/odoo-bin -c /etc/${OE_CONFIG}.conf
WorkingDirectory=${OE_HOME_EXT}
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ${SERVICE_FILE}
sudo systemctl start ${SERVICE_FILE}

if ! sudo systemctl is-active --quiet ${SERVICE_FILE}; then
  echo "Service ${SERVICE_FILE} failed to start. Logs:"
  sudo journalctl -u ${SERVICE_FILE} --no-pager | tail -n 100
  exit 1
fi

echo "Odoo service for instance '$INSTANCE_NAME' started successfully."

#----------------- Nginx -----------------#
setup_nginx_defaults() {
  sudo bash -c "cat > /etc/nginx/conf.d/upstreams.conf" <<'EOF'
# WebSocket/Longpoll helper
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}
EOF
  sudo nginx -t
  sudo systemctl reload nginx
}

if [ "$ENABLE_SSL" = "True" ]; then
  echo -e "\n---- Nginx vhost (HTTP, for certbot) ----"
  setup_nginx_defaults
  NCONF="/etc/nginx/sites-available/${WEBSITE_NAME}"
  sudo rm -f "$NCONF" "/etc/nginx/sites-enabled/${WEBSITE_NAME}" || true
  sudo bash -c "cat > $NCONF" <<EOF
# Odoo 19 - ${INSTANCE_NAME} (pre-SSL)
upstream odoo_${INSTANCE_NAME} { server 127.0.0.1:${OE_PORT}; }
upstream odoochat_${INSTANCE_NAME} { server 127.0.0.1:${GEVENT_PORT}; }

server {
  listen 80;
  server_name ${WEBSITE_NAME};

  access_log /var/log/nginx/${INSTANCE_NAME}.access.log;
  error_log  /var/log/nginx/${INSTANCE_NAME}.error.log;

  location / {
    proxy_pass http://odoo_${INSTANCE_NAME};
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_redirect off;
  }

  # Longpoll/Websocket (Odoo 19 usa gevent_port) :contentReference[oaicite:7]{index=7}
  location /longpolling {
    proxy_pass http://odoochat_${INSTANCE_NAME};
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
  }

  gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
  gzip on;
}
EOF
  sudo ln -s "$NCONF" "/etc/nginx/sites-enabled/${WEBSITE_NAME}"
  sudo nginx -t && sudo systemctl restart nginx

  echo -e "\n---- Certbot ----"
  sudo certbot certonly --nginx $DOMAIN_ARGS --non-interactive --agree-tos --email $ADMIN_EMAIL --redirect

  echo -e "\n---- Nginx vhost (HTTPS) ----"
  sudo bash -c "cat > $NCONF" <<EOF
# Odoo 19 - ${INSTANCE_NAME} (SSL)
upstream odoo_${INSTANCE_NAME} { server 127.0.0.1:${OE_PORT}; }
upstream odoochat_${INSTANCE_NAME} { server 127.0.0.1:${GEVENT_PORT}; }

server {
  listen 80;
  server_name ${NGINX_SERVER_NAME};
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl;
  server_name ${NGINX_SERVER_NAME};

  ssl_certificate /etc/letsencrypt/live/${WEBSITE_NAME}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${WEBSITE_NAME}/privkey.pem;
  ssl_session_timeout 30m;
  ssl_protocols TLSv1.2 TLSv1.3;

  access_log /var/log/nginx/${INSTANCE_NAME}.access.log;
  error_log  /var/log/nginx/${INSTANCE_NAME}.error.log;

  location / {
    proxy_pass http://odoo_${INSTANCE_NAME};
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_redirect off;
  }

  location /longpolling {
    proxy_pass http://odoochat_${INSTANCE_NAME};
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
  }

  gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
  gzip on;
}
EOF
  sudo nginx -t && sudo systemctl restart nginx
  echo "Nginx with SSL is up."
else
  setup_nginx_defaults
  echo -e "\n---- Nginx vhost (HTTP only) ----"
  NCONF="/etc/nginx/sites-available/${INSTANCE_NAME}"
  sudo rm -f "$NCONF" "/etc/nginx/sites-enabled/${INSTANCE_NAME}" || true
  sudo bash -c "cat > $NCONF" <<EOF
# Odoo 19 - ${INSTANCE_NAME}
upstream odoo_${INSTANCE_NAME} { server 127.0.0.1:${OE_PORT}; }
upstream odoochat_${INSTANCE_NAME} { server 127.0.0.1:${GEVENT_PORT}; }

server {
  listen 80;
  server_name ${SERVER_IP};

  access_log /var/log/nginx/${INSTANCE_NAME}.access.log;
  error_log  /var/log/nginx/${INSTANCE_NAME}.error.log;

  location / {
    proxy_pass http://odoo_${INSTANCE_NAME};
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_redirect off;
  }

  location /longpolling {
    proxy_pass http://odoochat_${INSTANCE_NAME};
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
  }

  gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
  gzip on;
}
EOF
  sudo ln -s "$NCONF" "/etc/nginx/sites-enabled/${INSTANCE_NAME}"
  sudo nginx -t && sudo systemctl restart nginx
  echo "Nginx HTTP-only is up."
fi

echo "-----------------------------------------------------------"
echo "Instance '$INSTANCE_NAME' has been added successfully!"
echo "-----------------------------------------------------------"
echo "Ports:"
echo "  HTTP Port: $OE_PORT"
echo "  Gevent (Longpoll/WebSocket) Port: $GEVENT_PORT"
echo ""
echo "Service:"
echo "  Name: ${SERVICE_FILE}"
echo "  Conf: /etc/${OE_CONFIG}.conf"
echo "  Log:  /var/log/${OE_USER}/${OE_CONFIG}.log"
echo ""
echo "Custom Addons: ${INSTANCE_DIR}/custom/addons/"
echo ""
echo "Database:"
echo "  User: $INSTANCE_NAME"
echo "  Pass: $DB_PASSWORD"
echo ""
echo "Superadmin (master):"
echo "  Password: $OE_SUPERADMIN"
echo ""
if [ "$ENABLE_SSL" = "True" ]; then
  echo "Nginx vhost: /etc/nginx/sites-available/${WEBSITE_NAME}"
  echo "Access URL:  https://${WEBSITE_NAME}"
else
  echo "Nginx vhost: /etc/nginx/sites-available/${INSTANCE_NAME}"
  echo "Access URL:  http://${SERVER_IP}:${OE_PORT}"
fi
echo "-----------------------------------------------------------"
