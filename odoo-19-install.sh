#!/bin/bash
################################################################################
# Script de instalación de Odoo 19 en Ubuntu 22.04/24.04 (funciona en otros)
# Basado en Yenthe, adaptado a Odoo 19 con systemd y dependencias oficiales.
# Autor (adaptación): ChatGPT (para Ricardo)
################################################################################

#------------- Variables editables -------------
OE_USER="odoo"
OE_HOME="/$OE_USER"
OE_HOME_EXT="/$OE_USER/${OE_USER}-server"
OE_PORT="8069"
LONGPOLLING_PORT="8072"
OE_VERSION="19.0"
IS_ENTERPRISE="True"        # Cambia a False si no usarás enterprise
INSTALL_POSTGRESQL_SIXTEEN="True"
INSTALL_WKHTMLTOPDF="True"
INSTALL_NGINX="False"
ENABLE_SSL="False"          # Requiere Nginx=True
WEBSITE_NAME="_"            # tu-dominio.com
ADMIN_EMAIL="odoo@example.com"

OE_CONFIG="${OE_USER}-server"
OE_SUPERADMIN="admin"
GENERATE_RANDOM_PASSWORD="True"

# Logs
INSTALL_LOG_FILE="/var/log/odoo_install.log"
ERROR_LOG_FILE="/var/log/odoo_install_error.log"

#------------- Utilidades de logging -------------
log_message() {
  local message=$1
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "$timestamp - $message" | tee -a "$INSTALL_LOG_FILE"
}
handle_error() {
  local error_message=$1
  local error_code=$2
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "$timestamp - ERROR: $error_message (Exit Code: $error_code)" | tee -a "$ERROR_LOG_FILE"
}

set -e
trap 'handle_error "Command failed" $?' ERR

sudo touch "$INSTALL_LOG_FILE" "$ERROR_LOG_FILE"
sudo chmod 666 "$INSTALL_LOG_FILE" "$ERROR_LOG_FILE"

log_message "Iniciando instalación de Odoo $OE_VERSION ..."

#------------- Detección de distro / URLs wkhtmltopdf -------------
UBU_CODENAME="$(lsb_release -c -s 2>/dev/null || echo "")"
UBU_RELEASE="$(lsb_release -r -s 2>/dev/null || echo "")"

# wkhtmltopdf 0.12.6.1-3 recomendado para Odoo 16+ (aplica a 19)
# (Paquetes build oficiales con Qt parcheado)
case "$UBU_CODENAME" in
  jammy) WKHTML_DEB="wkhtmltox_0.12.6.1-3.jammy_amd64.deb" ;;
  noble) WKHTML_DEB="wkhtmltox_0.12.6.1-3.noble_amd64.deb" ;;
  *)     WKHTML_DEB="" ;; # Se intentará fallback más abajo
esac
WKHTML_BASE_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3"

#------------- Update del sistema -------------
log_message "Actualizando servidor..."
{
  sudo apt-get update
  sudo apt-get upgrade -y
} >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE"

#------------- PostgreSQL -------------
log_message "Instalando PostgreSQL..."
if [ "$INSTALL_POSTGRESQL_SIXTEEN" = "True" ]; then
  {
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
    echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y postgresql-16
  } >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE" || { handle_error "Falló instalación de PostgreSQL 16" $?; exit 1; }
else
  sudo apt-get install -y postgresql postgresql-client >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE"
fi

# Usuario de BD (no pasa nada si ya existe)
log_message "Creando usuario de PostgreSQL para Odoo (si no existe)..."
sudo su - postgres -c "createuser -s $OE_USER" 2>/dev/null || true

#------------- Usuario de sistema Odoo -------------
log_message "Creando usuario de sistema $OE_USER..."
{
  if id "$OE_USER" &>/dev/null; then
    echo "Usuario $OE_USER ya existe"
  else
    sudo adduser --system --quiet --shell=/bin/bash --home="$OE_HOME" --gecos 'ODOO' --group "$OE_USER"
    sudo adduser "$OE_USER" sudo
  fi
  sudo mkdir -p "$OE_HOME" "/var/log/$OE_USER"
  sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME" "/var/log/$OE_USER"
} >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE" || { handle_error "Falló creación de usuario de sistema" $?; exit 1; }

#------------- Python 3 (>=3.10) y dependencias -------------
log_message "Instalando Python (>=3.10) y libs..."
{
  PYV=$(python3 -c 'import sys; print("%d.%d"%(sys.version_info[0],sys.version_info[1]))' 2>/dev/null || echo "0.0")
  if python3 -c 'import sys; exit(0 if (sys.version_info>=(3,10)) else 1)'; then
    echo "Python3 del sistema es >=3.10 ($PYV)."
  else
    # En 22.04 hay 3.10; en 24.04 ya hay 3.12. Si faltara, instalamos 3.12 de PPA.
    sudo add-apt-repository -y ppa:deadsnakes/ppa
    sudo apt-get update
    sudo apt-get install -y python3.12 python3.12-dev python3.12-venv
    sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 20
  fi

  sudo apt-get install -y \
    build-essential git wget curl pkg-config \
    libldap2-dev libsasl2-dev libssl-dev libpq-dev \
    libjpeg-dev zlib1g-dev libxml2-dev libxslt1-dev libzip-dev \
    xfonts-75dpi xfonts-base nodejs npm
} >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE" || { handle_error "Falló instalación de Python/libs" $?; exit 1; }

#------------- venv y requirements de Odoo 19 -------------
log_message "Creando entorno virtual e instalando requirements de Odoo $OE_VERSION..."
{
  # Usar la python3 actual (>=3.10)
  PYBIN="$(command -v python3)"
  sudo -u "$OE_USER" "$PYBIN" -m venv "$OE_HOME/venv"
  sudo -u "$OE_USER" "$OE_HOME/venv/bin/pip" install --upgrade pip wheel setuptools
} >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE" || { handle_error "Falló creación de venv" $?; exit 1; }

#------------- node + rtlcss (para idiomas RTL) -------------
log_message "Instalando rtlcss (npm)..."
{
  sudo npm install -g rtlcss
} >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE" || { handle_error "Falló instalación de rtlcss" $?; exit 1; }

#------------- wkhtmltopdf (0.12.6.1-3 recomendado) -------------
if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
  log_message "Instalando wkhtmltopdf (0.12.6.1-3 con Qt parcheado)..."
  if [ -n "$WKHTML_DEB" ]; then
    {
      cd /tmp
      wget -q "${WKHTML_BASE_URL}/${WKHTML_DEB}"
      sudo apt-get install -y ./${WKHTML_DEB}
      rm -f "${WKHTML_DEB}"
    } >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE" || { handle_error "Falló instalación de wkhtmltopdf .deb" $?; exit 1; }
  else
    {
      echo "Advertencia: distro no detectada como jammy/noble. Intentando instalar wkhtmltopdf desde repos (puede NO tener Qt parcheado)."
      sudo apt-get install -y wkhtmltopdf
    } >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE" || { handle_error "Falló instalación de wkhtmltopdf" $?; exit 1; }
  fi
fi

#------------- Obtener código de Odoo -------------
log_message "Clonando Odoo $OE_VERSION..."
{
  if [ ! -d "$OE_HOME_EXT" ]; then
    sudo git clone --depth 1 --branch "$OE_VERSION" https://github.com/odoo/odoo "$OE_HOME_EXT/"
    sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME_EXT/"
  else
    echo "Directorio $OE_HOME_EXT ya existe."
  fi
} >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE" || { handle_error "Falló clon de Odoo" $?; exit 1; }

# Requirements oficiales desde el repo (recomendado por doc)
log_message "Instalando requirements.txt de Odoo $OE_VERSION..."
{
  sudo -u "$OE_USER" "$OE_HOME/venv/bin/pip" install -r "https://raw.githubusercontent.com/odoo/odoo/${OE_VERSION}/requirements.txt"
} >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE" || { handle_error "Falló instalación de requirements de Odoo" $?; exit 1; }

#------------- Enterprise (opcional) -------------
if [ "$IS_ENTERPRISE" = "True" ]; then
  log_message "Instalando Odoo Enterprise (requiere acceso a github.com/odoo/enterprise)..."
  {
    sudo -u "$OE_USER" mkdir -p "$OE_HOME/enterprise/addons"
    # El repo enterprise solo trae add-ons; el servidor corre desde community
    GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch "$OE_VERSION" https://github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1 || true)
    while [[ "$GITHUB_RESPONSE" == *"Authentication"* ]]; do
      echo "Autenticación a GitHub falló. Vuelve a intentar (Ctrl+C para abortar)."
      GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch "$OE_VERSION" https://github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1 || true)
    done
    # libs comunes de enterprise dentro del venv
    sudo -u "$OE_USER" "$OE_HOME/venv/bin/pip" install num2words ofxparse dbfread firebase_admin pyOpenSSL pdfminer.six
  } >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE" || { handle_error "Falló instalación de Enterprise" $?; exit 1; }
fi

#------------- Módulos custom -------------
log_message "Creando carpeta de módulos custom..."
{
  sudo -u "$OE_USER" mkdir -p "$OE_HOME/custom/addons"
} >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE"

#------------- Permisos home -------------
log_message "Ajustando permisos del home..."
sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME" >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE"

#------------- Configuración odoo.conf -------------
log_message "Creando /etc/${OE_CONFIG}.conf ..."
{
  sudo bash -c "cat >/etc/${OE_CONFIG}.conf" <<EOF
[options]
; contraseña maestra (db management):
admin_passwd = ${OE_SUPERADMIN}
http_port = ${OE_PORT}
longpolling_port = ${LONGPOLLING_PORT}
logfile = /var/log/${OE_USER}/${OE_CONFIG}.log
; Python 3.x (>=3.10)
; rutas de addons
$( if [ "$IS_ENTERPRISE" = "True" ]; then
     echo "addons_path = ${OE_HOME}/enterprise/addons,${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons"
   else
     echo "addons_path = ${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons"
   fi )
; base de datos
db_user = ${OE_USER}
; db_password opcional si configuras autenticación por contraseña
; db_password = 
EOF

  if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
    OE_SUPERADMIN=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
    sudo sed -i "s/^admin_passwd = .*/admin_passwd = ${OE_SUPERADMIN}/" "/etc/${OE_CONFIG}.conf"
  fi

  sudo chown "$OE_USER:$OE_USER" "/etc/${OE_CONFIG}.conf"
  sudo chmod 640 "/etc/${OE_CONFIG}.conf"
} >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE" || { handle_error "Falló creación de conf" $?; exit 1; }

#------------- Servicio systemd -------------
log_message "Creando servicio systemd odoo19..."
{
  sudo bash -c "cat >/etc/systemd/system/${OE_CONFIG}.service" <<EOF
[Unit]
Description=Odoo ${OE_VERSION} (${OE_CONFIG})
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
User=${OE_USER}
Group=${OE_USER}
ExecStart=${OE_HOME}/venv/bin/python ${OE_HOME_EXT}/odoo-bin --config=/etc/${OE_CONFIG}.conf
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
  sudo systemctl enable "${OE_CONFIG}.service"
} >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE" || { handle_error "Falló creación de servicio systemd" $?; exit 1; }

#------------- Nginx (opcional) -------------
if [ "$INSTALL_NGINX" = "True" ]; then
  log_message "Instalando y configurando Nginx como reverse proxy..."
  {
    sudo apt-get install -y nginx
    sudo bash -c "cat >/etc/nginx/sites-available/${WEBSITE_NAME}" <<EOF
server {
  listen 80;
  server_name ${WEBSITE_NAME};

  proxy_set_header X-Forwarded-Host \$host;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_set_header X-Real-IP \$remote_addr;

  add_header X-Frame-Options "SAMEORIGIN";
  add_header X-XSS-Protection "1; mode=block";

  client_max_body_size 128m;
  proxy_read_timeout 900s;
  proxy_connect_timeout 900s;
  proxy_send_timeout 900s;

  location / {
    proxy_pass http://127.0.0.1:${OE_PORT};
    proxy_redirect off;
  }

  location /longpolling {
    proxy_pass http://127.0.0.1:${LONGPOLLING_PORT};
  }

  location ~* \.(js|css|png|jpg|jpeg|gif|ico)$ {
    expires 2d;
    add_header Cache-Control "public, no-transform";
    proxy_pass http://127.0.0.1:${OE_PORT};
  }

  location ~ /[a-zA-Z0-9_-]*/static/ {
    proxy_cache_valid 200 302 60m;
    proxy_cache_valid 404 1m;
    proxy_buffering on;
    expires 7d;
    proxy_pass http://127.0.0.1:${OE_PORT};
  }
}
EOF
    sudo ln -sf "/etc/nginx/sites-available/${WEBSITE_NAME}" "/etc/nginx/sites-enabled/${WEBSITE_NAME}"
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo systemctl reload nginx

    # Activar proxy_mode en Odoo
    sudo bash -c "echo 'proxy_mode = True' >>/etc/${OE_CONFIG}.conf"
  } >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE" || { handle_error "Falló configuración Nginx" $?; exit 1; }
else
  log_message "Nginx no se instalará (INSTALL_NGINX=False)."
fi

#------------- SSL con certbot (opcional) -------------
if [ "$INSTALL_NGINX" = "True" ] && [ "$ENABLE_SSL" = "True" ] && [ "$ADMIN_EMAIL" != "odoo@example.com" ] && [ "$WEBSITE_NAME" != "_" ]; then
  log_message "Habilitando SSL con certbot..."
  {
    sudo apt-get update -y
    sudo apt-get install -y snapd
    sudo snap install core; sudo snap refresh core
    sudo snap install --classic certbot
    sudo apt-get install -y python3-certbot-nginx
    sudo certbot --nginx -d "$WEBSITE_NAME" --noninteractive --agree-tos --email "$ADMIN_EMAIL" --redirect
    sudo systemctl reload nginx
  } >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE" || { handle_error "Falló habilitar SSL" $?; exit 1; }
else
  echo "SSL no habilitado (revisa ENABLE_SSL, WEBSITE_NAME y ADMIN_EMAIL)."
fi

#------------- Arranque -------------
log_message "Arrancando servicio Odoo..."
{
  sudo systemctl start "${OE_CONFIG}.service"
  sudo systemctl status "${OE_CONFIG}.service" --no-pager -l | sed -n '1,15p'
} >>"$INSTALL_LOG_FILE" 2>>"$ERROR_LOG_FILE" || { handle_error "Falló arranque de Odoo" $?; exit 1; }

#------------- Resumen -------------
echo "-----------------------------------------------------------"
echo "¡Listo! Odoo $OE_VERSION en marcha."
echo "Puerto HTTP:           $OE_PORT"
echo "Usuario de servicio:   $OE_USER"
echo "Config:                /etc/${OE_CONFIG}.conf"
echo "Logs:                  /var/log/${OE_USER}"
echo "PostgreSQL user:       $OE_USER"
echo "Código:                $OE_HOME_EXT"
echo "Addons custom:         $OE_HOME/custom/addons"
echo "Admin (master) pass:   $OE_SUPERADMIN"
echo "Systemd service:       ${OE_CONFIG}.service (start/stop/restart/status)"
if [ "$INSTALL_NGINX" = "True" ]; then
  echo "Nginx conf:            /etc/nginx/sites-available/${WEBSITE_NAME}"
fi
echo "Logs de instalación:"
echo "  Main:  $INSTALL_LOG_FILE"
echo "  Error: $ERROR_LOG_FILE"
echo "-----------------------------------------------------------"
