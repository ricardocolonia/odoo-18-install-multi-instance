#!/bin/bash
################################################################################
# Script para agregar una instancia Odoo 19 sobre un CORE ya instalado
# - Crea venv por instancia
# - Instala requirements (con fallback si falla psycopg2/python-ldap)
# - Crea servicio systemd, Nginx (opcional) y SSL (opcional)
################################################################################

set -e

# ---------------------- Config base ----------------------
OE_USER="odoo"
OE_HOME="/odoo"                                   # CORE instalado aquí
OE_HOME_EXT="${OE_HOME}/${OE_USER}-server"        # Código community (branch 19.0)
ENTERPRISE_ADDONS="${OE_HOME}/enterprise/addons"  # Si tienes enterprise clonado
OE_VERSION="19.0"

BASE_ODOO_PORT=8069
BASE_GEVENT_PORT=8072

# ---------------------- Helpers --------------------------
generate_random_password() { openssl rand -base64 16; }

install_pkg_if_missing() {
  local PKG="$1"
  if ! dpkg -s "$PKG" &>/dev/null; then
    echo "$PKG no encontrado. Instalando..."
    sudo apt-get update
    sudo apt-get install -y "$PKG"
  fi
}

find_available_port() {
  local BASE="$1"; shift
  local -n USED="$1"
  local P="$BASE"
  while true; do
    if [[ " ${USED[@]} " =~ " ${P} " ]] || lsof -iTCP:$P -sTCP:LISTEN >/dev/null 2>&1; then
      P=$((P+1))
    else
      echo "$P"; break
    fi
  done
}

# ------------------- Prechequeos del host -------------------
echo "Verificando dependencias del sistema para compilar wheels..."
PYV=$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')
sudo apt-get update
sudo apt-get install -y \
  lsof nginx snapd python3-venv "python${PYV}-dev" \
  build-essential gcc pkg-config \
  libpq-dev libldap2-dev libsasl2-dev libssl-dev \
  libxml2-dev libxslt1-dev zlib1g-dev libjpeg-dev

# Certbot (si luego se elige SSL)
if ! command -v certbot &>/dev/null; then
  echo "Instalando Certbot..."
  sudo snap install core; sudo snap refresh core
  sudo snap install --classic certbot
  sudo ln -sf /snap/bin/certbot /usr/bin/certbot
fi

# ------------------- Detectar instancias previas -------------------
declare -a EXISTING_NAMES EXISTING_OE_PORTS EXISTING_GEVENT_PORTS
for cfg in /etc/${OE_USER}-server-*.conf; do
  [ -f "$cfg" ] || continue
  name=$(basename "$cfg" | sed "s/${OE_USER}-server-//; s/\.conf//")
  EXISTING_NAMES+=("$name")
  EXISTING_OE_PORTS+=("$(grep -E '^(http_port|xmlrpc_port)\b' "$cfg" | awk -F'= *' '{print $2}' | tail -n1)")
  EXISTING_GEVENT_PORTS+=("$(grep -E '^gevent_port\b' "$cfg" | awk -F'= *' '{print $2}')")
done

# ------------------- Inputs -------------------
read -rp "Nombre para la nueva instancia (p.ej. odoo19a): " INSTANCE_NAME
[[ "$INSTANCE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Nombre inválido."; exit 1; }
[[ " ${EXISTING_NAMES[@]} " =~ " ${INSTANCE_NAME} " ]] && { echo "La instancia '$INSTANCE_NAME' ya existe."; exit 1; }

read -rp "¿Esta instancia usará Enterprise? (yes/no): " ENTERPRISE_CHOICE
HAS_ENTERPRISE_LICENSE="False"; [[ "$ENTERPRISE_CHOICE" =~ ^(yes|y)$ ]] && HAS_ENTERPRISE_LICENSE="True"

OE_CONFIG="${OE_USER}-server-${INSTANCE_NAME}"
OE_PORT=$(find_available_port $BASE_ODOO_PORT EXISTING_OE_PORTS)
GEVENT_PORT=$(find_available_port $BASE_GEVENT_PORT EXISTING_GEVENT_PORTS)
echo "Puertos asignados: HTTP=$OE_PORT  Gevent=$GEVENT_PORT"

read -rp "¿Habilitar SSL con Certbot para '${INSTANCE_NAME}'? (yes/no): " SSL_CHOICE
ENABLE_SSL="False"
if [[ "$SSL_CHOICE" =~ ^(yes|y)$ ]]; then
  ENABLE_SSL="True"
  read -rp "Dominio (e.g., midominio.com): " WEBSITE_NAME
  read -rp "¿Incluir www.${WEBSITE_NAME}? (yes/no): " WWW_CHOICE
  read -rp "Email admin para certbot: " ADMIN_EMAIL

  [[ "$WEBSITE_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || { echo "Dominio inválido."; exit 1; }
  if [[ "$WWW_CHOICE" =~ ^(yes|y)$ ]]; then
    DOMAIN_ARGS="-d $WEBSITE_NAME -d www.$WEBSITE_NAME"
    NGINX_SERVER_NAME="$WEBSITE_NAME www.$WEBSITE_NAME"
  else
    DOMAIN_ARGS="-d $WEBSITE_NAME"
    NGINX_SERVER_NAME="$WEBSITE_NAME"
  fi
  [[ "$ADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo "Email inválido."; exit 1; }
else
  WEBSITE_NAME="$(hostname -I | awk '{print $1}')"
  NGINX_SERVER_NAME="$WEBSITE_NAME"
fi

# ------------------- Credenciales -------------------
if [[ -z "$OE_SUPERADMIN" ]]; then
  OE_SUPERADMIN=$(generate_random_password)
  echo "Generada contraseña master (admin_passwd)."
fi
DB_PASSWORD=$(generate_random_password)
echo "Generada contraseña PostgreSQL."

# Usuario PostgreSQL por instancia (rol con createdb)
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${INSTANCE_NAME}'" | grep -q 1; then
  echo "Rol PostgreSQL '${INSTANCE_NAME}' ya existe."
else
  sudo -u postgres psql -c "CREATE USER ${INSTANCE_NAME} WITH CREATEDB NOSUPERUSER NOCREATEROLE PASSWORD '${DB_PASSWORD}';"
fi

echo -e "\n==== Configurando instancia Odoo 19 '${INSTANCE_NAME}' ===="

# ------------------- Estructura por instancia -------------------
INSTANCE_DIR="${OE_HOME}/${INSTANCE_NAME}"
INSTANCE_VENV="${INSTANCE_DIR}/venv"
sudo mkdir -p "${INSTANCE_DIR}/custom/addons"
sudo chown -R "$OE_USER:$OE_USER" "${INSTANCE_DIR}"

# ------------------- Venv robusto (evita PermissionError) -------------------
echo "Creando venv para '${INSTANCE_NAME}'..."
sudo -u "$OE_USER" -H bash -lc "cd '${INSTANCE_DIR}' && python3 -m venv venv"
sudo -u "$OE_USER" -H bash -lc "cd '${INSTANCE_DIR}' && venv/bin/python -m ensurepip --upgrade"
sudo -u "$OE_USER" -H bash -lc "cd '${INSTANCE_DIR}' && venv/bin/pip install --upgrade pip wheel setuptools"

# ------------------- Requirements -------------------
REQ_LOCAL="${OE_HOME_EXT}/requirements.txt"
if [ -f "$REQ_LOCAL" ]; then
  echo "Instalando deps desde $REQ_LOCAL ..."
  set +e
  sudo -u "$OE_USER" -H bash -lc "cd '${INSTANCE_DIR}' && venv/bin/pip install -r '${REQ_LOCAL}'"
  RET=$?
  set -e
else
  echo "requirements.txt local no encontrado; usando el remoto de Odoo ${OE_VERSION} ..."
  set +e
  sudo -u "$OE_USER" -H bash -lc "cd '${INSTANCE_DIR}' && venv/bin/pip install -r 'https://raw.githubusercontent.com/odoo/odoo/${OE_VERSION}/requirements.txt'"
  RET=$?
  set -e
fi

# Fallbacks si fallan wheels de psycopg2 / python-ldap
if [ $RET -ne 0 ]; then
  echo "Algunas ruedas fallaron al compilar. Aplicando fallbacks puntuales..."
  # psycopg2 binario
  sudo -u "$OE_USER" -H bash -lc "cd '${INSTANCE_DIR}' && venv/bin/pip install 'psycopg2-binary==2.9.9' || true"
  # Reasegurar libs LDAP y reintentar
  sudo apt-get install -y libldap2-dev libsasl2-dev libssl-dev
  sudo -u "$OE_USER" -H bash -lc "cd '${INSTANCE_DIR}' && venv/bin/pip install 'python-ldap==3.4.4' || true"
  # Reintento del resto (sin deps ya satisfechas)
  if [ -f "$REQ_LOCAL" ]; then
    sudo -u "$OE_USER" -H bash -lc "cd '${INSTANCE_DIR}' && venv/bin/pip install --no-deps -r '${REQ_LOCAL}' || true"
  else
    sudo -u "$OE_USER" -H bash -lc "cd '${INSTANCE_DIR}' && venv/bin/pip install --no-deps -r 'https://raw.githubusercontent.com/odoo/odoo/${OE_VERSION}/requirements.txt' || true"
  fi
fi

# Addons path (con o sin enterprise)
if [ "$HAS_ENTERPRISE_LICENSE" = "True" ] && [ -d "$ENTERPRISE_ADDONS" ]; then
  ADDONS_PATH="${OE_HOME_EXT}/addons,${INSTANCE_DIR}/custom/addons,${ENTERPRISE_ADDONS}"
else
  ADDONS_PATH="${OE_HOME_EXT}/addons,${INSTANCE_DIR}/custom/addons"
fi

# ------------------- odoo.conf -------------------
sudo bash -c "cat > /etc/${OE_CONFIG}.conf" <<EOF
[options]
admin_passwd = ${OE_SUPERADMIN}
db_host = localhost
db_user = ${INSTANCE_NAME}
db_password = ${DB_PASSWORD}
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
$( [ "$ENABLE_SSL" = "True" ] && echo "proxy_mode = True" )
EOF
sudo chown "$OE_USER:$OE_USER" "/etc/${OE_CONFIG}.conf"
sudo chmod 640 "/etc/${OE_CONFIG}.conf"
sudo mkdir -p "/var/log/${OE_USER}"; sudo chown -R "$OE_USER:$OE_USER" "/var/log/${OE_USER}"

# ------------------- Servicio systemd -------------------
SERVICE_FILE="${OE_CONFIG}.service"
sudo bash -c "cat > /etc/systemd/system/${SERVICE_FILE}" <<EOF
[Unit]
Description=Odoo ${OE_VERSION} - ${INSTANCE_NAME}
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=${OE_USER}
Group=${OE_USER}
ExecStart=${INSTANCE_VENV}/bin/python ${OE_HOME_EXT}/odoo-bin -c /etc/${OE_CONFIG}.conf
WorkingDirectory=${OE_HOME_EXT}
StandardOutput=journal
StandardError=journal
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_FILE}"
sudo systemctl start "${SERVICE_FILE}"
sudo systemctl is-active --quiet "${SERVICE_FILE}" || { echo "El servicio no arrancó. Revisa: journalctl -u ${SERVICE_FILE}"; exit 1; }
echo "Servicio ${SERVICE_FILE} iniciado."

# ------------------- Nginx + SSL -------------------
setup_nginx_defaults() {
  sudo bash -c "cat > /etc/nginx/conf.d/upstreams.conf" <<'EON'
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}
EON
  sudo nginx -t
  sudo systemctl reload nginx
}

if [ "$ENABLE_SSL" = "True" ]; then
  setup_nginx_defaults
  NCONF="/etc/nginx/sites-available/${WEBSITE_NAME}"
  sudo rm -f "$NCONF" "/etc/nginx/sites-enabled/${WEBSITE_NAME}" || true

  # Paso 1: HTTP para obtener certificados
  sudo bash -c "cat > $NCONF" <<EOF
upstream odoo_${INSTANCE_NAME} { server 127.0.0.1:${OE_PORT}; }
upstream odoochat_${INSTANCE_NAME} { server 127.0.0.1:${GEVENT_PORT}; }

server {
  listen 80;
  server_name ${NGINX_SERVER_NAME};
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

  # Odoo usa /longpolling para gevent
  location /longpolling {
    proxy_pass http://odoochat_${INSTANCE_NAME};
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
  }

  gzip on;
  gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
}
EOF
  sudo ln -s "$NCONF" "/etc/nginx/sites-enabled/${WEBSITE_NAME}"
  sudo nginx -t && sudo systemctl restart nginx

  # Certbot
  sudo certbot certonly --nginx $DOMAIN_ARGS --non-interactive --agree-tos --email "$ADMIN_EMAIL" --redirect

  # Paso 2: HTTPS final (+ redirect)
  sudo bash -c "cat > $NCONF" <<EOF
upstream odoo_${INSTANCE_NAME} { server 127.0.0.1:${OE_PORT}; }
upstream odoochat_${INSTANCE_NAME} { server 127.0.0.1:${GEVENT_PORT}; }

server { listen 80; server_name ${NGINX_SERVER_NAME}; return 301 https://\$host\$request_uri; }

server {
  listen 443 ssl http2;
  server_name ${NGINX_SERVER_NAME};

  ssl_certificate /etc/letsencrypt/live/${WEBSITE_NAME}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${WEBSITE_NAME}/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;

  access_log /var/log/nginx/${INSTANCE_NAME}.access.log;
  error_log  /var/log/nginx/${INSTANCE_NAME}.error.log;

  location /longpolling {
    proxy_pass http://odoochat_${INSTANCE_NAME};
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
  }

  location / {
    proxy_pass http://odoo_${INSTANCE_NAME};
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_redirect off;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
  }

  gzip on;
  gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
}
EOF
  sudo nginx -t && sudo systemctl restart nginx
  echo "Nginx + SSL listo para ${WEBSITE_NAME}"

else
  setup_nginx_defaults
  NCONF="/etc/nginx/sites-available/${INSTANCE_NAME}"
  sudo rm -f "$NCONF" "/etc/nginx/sites-enabled/${INSTANCE_NAME}" || true
  sudo bash -c "cat > $NCONF" <<EOF
upstream odoo_${INSTANCE_NAME} { server 127.0.0.1:${OE_PORT}; }
upstream odoochat_${INSTANCE_NAME} { server 127.0.0.1:${GEVENT_PORT}; }

server {
  listen 80;
  server_name $(hostname -I | awk '{print $1}');

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

  gzip on;
  gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
}
EOF
  sudo ln -s "$NCONF" "/etc/nginx/sites-enabled/${INSTANCE_NAME}"
  sudo nginx -t && sudo systemctl restart nginx
fi

# ------------------- Resumen -------------------
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "-----------------------------------------------------------"
echo "Instancia '${INSTANCE_NAME}' creada correctamente."
echo "Service:     ${SERVICE_FILE}"
echo "Config:      /etc/${OE_CONFIG}.conf"
echo "Logs:        /var/log/${OE_USER}/${OE_CONFIG}.log  (systemd: journalctl -u ${SERVICE_FILE})"
echo "Puertos:     HTTP=${OE_PORT}  Gevent=${GEVENT_PORT}"
echo "DB user:     ${INSTANCE_NAME}"
echo "DB pass:     ${DB_PASSWORD}"
echo "Master pass: ${OE_SUPERADMIN}"
if [ "$ENABLE_SSL" = "True" ]; then
  echo "URL:         https://${WEBSITE_NAME}"
else
  echo "URL:         http://${SERVER_IP}:${OE_PORT}"
fi
echo "-----------------------------------------------------------"
