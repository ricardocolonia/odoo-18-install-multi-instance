#!/bin/bash
################################################################################
# Script para crear una instancia de Odoo 18 en Ubuntu 24.04 LTS
#-------------------------------------------------------------------------------
# Este script crea una nueva instancia de Odoo 18 con su propio entorno virtual,
# directorio de instancia, configuración personalizada y configuración de Nginx.
#-------------------------------------------------------------------------------
# Uso:
# 1. Guárdalo como create_odoo_instance.sh
#    sudo nano create_odoo_instance.sh
# 2. Haz el script ejecutable:
#    sudo chmod +x create_odoo_instance.sh
# 3. Ejecuta el script:
#    sudo ./create_odoo_instance.sh
################################################################################

# Salir inmediatamente si un comando falla
set -e

# Función para generar una contraseña aleatoria
generate_random_password() {
    openssl rand -base64 16
}

# Variables base
OE_USER="odoo18"
OE_HOME="/odoo"
OE_BASE_CODE="${OE_HOME}"  # Directorio donde está el código base de Odoo
BASE_ODOO_PORT=8069
BASE_GEVENT_PORT=8072  # Puerto base para gevent (longpolling)
PYTHON_VERSION="3.11"

# Asegurarse de que la versión requerida de Python esté instalada
if ! command -v python${PYTHON_VERSION} &> /dev/null; then
    echo "Python ${PYTHON_VERSION} no está instalado. Instalando Python ${PYTHON_VERSION}..."
    sudo apt update
    sudo apt install software-properties-common -y
    sudo add-apt-repository ppa:deadsnakes/ppa -y
    sudo apt update
    sudo apt install python${PYTHON_VERSION} python${PYTHON_VERSION}-venv python${PYTHON_VERSION}-dev -y
fi

# Verificar e instalar Certbot y Nginx si no están instalados
if ! command -v certbot &> /dev/null; then
    echo "Certbot no está instalado. Instalando Certbot..."
    sudo apt update
    sudo apt install certbot python3-certbot-nginx -y
fi

if ! command -v nginx &> /dev/null; then
    echo "Nginx no está instalado. Instalando Nginx..."
    sudo apt update
    sudo apt install nginx -y
    sudo systemctl enable nginx
    sudo systemctl start nginx
fi

# Obtener la dirección IP del servidor
SERVER_IP=$(hostname -I | awk '{print $1}')

# Función para encontrar un puerto disponible
find_available_port() {
    local BASE_PORT=$1
    while true; do
        if lsof -i TCP:$BASE_PORT >/dev/null 2>&1; then
            BASE_PORT=$((BASE_PORT + 1))
        else
            echo "$BASE_PORT"
            break
        fi
    done
}

# Solicitar el nombre de la instancia
read -p "Ingresa el nombre para la nueva instancia (por ejemplo, odoo1): " INSTANCE_NAME

# Validar el nombre de la instancia
if [[ ! "$INSTANCE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Nombre de instancia inválido. Solo se permiten letras, números, guiones bajos y guiones."
    exit 1
fi

# Solicitar el dominio para la instancia
read -p "Ingresa el dominio para la instancia (por ejemplo, odoo.miempresa.com): " INSTANCE_DOMAIN

# Validar nombre de dominio
if [[ ! "$INSTANCE_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo "Nombre de dominio inválido."
    exit 1
fi

# Solicitar si tiene licencia Enterprise
read -p "¿Tienes una licencia Enterprise para esta instancia? (sí/no): " ENTERPRISE_CHOICE
if [[ "$ENTERPRISE_CHOICE" =~ ^(sí|si|s)$ ]]; then
    HAS_ENTERPRISE="True"
else
    HAS_ENTERPRISE="False"
fi

# Preguntar si desea habilitar SSL para esta instancia
read -p "¿Deseas habilitar SSL con Certbot para la instancia '$INSTANCE_NAME'? (sí/no): " SSL_CHOICE
if [[ "$SSL_CHOICE" =~ ^(sí|si|s)$ ]]; then
    ENABLE_SSL="True"
    # Solicitar correo electrónico para Certbot
    read -p "Ingresa tu dirección de correo electrónico para Certbot: " ADMIN_EMAIL
    # Validar correo electrónico
    if ! [[ "$ADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo "Dirección de correo electrónico inválida."
        exit 1
    fi
else
    ENABLE_SSL="False"
fi

# Generar contraseña de superadministrador
SUPERADMIN_PASS=$(generate_random_password)
echo "Contraseña de superadministrador generada."

# Generar contraseña para PostgreSQL
DB_PASSWORD=$(generate_random_password)
echo "Contraseña de base de datos generada."

# Crear usuario de PostgreSQL para la instancia
sudo -u postgres psql -c "CREATE USER $INSTANCE_NAME WITH CREATEDB PASSWORD '$DB_PASSWORD';"
echo "Usuario de PostgreSQL '$INSTANCE_NAME' creado."

# Crear directorio de instancia
INSTANCE_DIR="${OE_HOME}/${INSTANCE_NAME}"
sudo mkdir -p "${INSTANCE_DIR}"
sudo chown -R $OE_USER:$OE_USER "${INSTANCE_DIR}"

# Crear directorio de addons personalizados
CUSTOM_ADDONS_DIR="${INSTANCE_DIR}/custom/addons"
sudo mkdir -p "${CUSTOM_ADDONS_DIR}"
sudo chown -R $OE_USER:$OE_USER "${CUSTOM_ADDONS_DIR}"

# Si tiene licencia Enterprise, crear directorio de addons Enterprise
if [ "$HAS_ENTERPRISE" = "True" ]; then
    ENTERPRISE_ADDONS_DIR="${INSTANCE_DIR}/enterprise/addons"
    sudo mkdir -p "${ENTERPRISE_ADDONS_DIR}"
    sudo chown -R $OE_USER:$OE_USER "${INSTANCE_DIR}/enterprise"
    echo "Directorio de addons Enterprise creado en '${ENTERPRISE_ADDONS_DIR}'."
    echo "Por favor, clona el código Enterprise en '${ENTERPRISE_ADDONS_DIR}'."
fi

# Crear entorno virtual para la instancia
VENV_DIR="${INSTANCE_DIR}/venv"
sudo -u $OE_USER python${PYTHON_VERSION} -m venv "${VENV_DIR}"
echo "Entorno virtual creado en '${VENV_DIR}'."

# Actualizar pip en el entorno virtual
sudo -u $OE_USER "${VENV_DIR}/bin/pip" install --upgrade pip

# Instalar wheel en el entorno virtual
sudo -u $OE_USER "${VENV_DIR}/bin/pip" install wheel

# Instalar dependencias en el entorno virtual
sudo -u $OE_USER "${VENV_DIR}/bin/pip" install -r "${OE_BASE_CODE}/requirements.txt"

# Instalar gevent en el entorno virtual
sudo -u $OE_USER "${VENV_DIR}/bin/pip" install gevent

echo "Dependencias instaladas en el entorno virtual."

# Encontrar puertos disponibles
ODOO_PORT=$(find_available_port $BASE_ODOO_PORT)
GEVENT_PORT=$(find_available_port $BASE_GEVENT_PORT)

# Crear archivo de configuración de Odoo
CONFIG_FILE="/etc/${OE_USER}-${INSTANCE_NAME}.conf"
sudo bash -c "cat > ${CONFIG_FILE}" <<EOF
[options]
admin_passwd = ${SUPERADMIN_PASS}
db_host = localhost
db_port = False
db_user = ${INSTANCE_NAME}
db_password = ${DB_PASSWORD}
addons_path = ${OE_BASE_CODE}/addons,${CUSTOM_ADDONS_DIR}
http_port = ${ODOO_PORT}
gevent_port = ${GEVENT_PORT}
logfile = /var/log/${OE_USER}/${INSTANCE_NAME}.log
limit_memory_hard = 2677721600
limit_memory_soft = 1829145600
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
max_cron_threads = 1
workers = 2
EOF

# Si tiene licencia Enterprise, agregar ruta de addons Enterprise
if [ "$HAS_ENTERPRISE" = "True" ]; then
    sudo sed -i "s|addons_path = .*|&,$ENTERPRISE_ADDONS_DIR|" ${CONFIG_FILE}
fi

# Si SSL está habilitado, configurar proxy_mode y dbfilter
if [ "$ENABLE_SSL" = "True" ]; then
    echo "proxy_mode = True" | sudo tee -a ${CONFIG_FILE}
    echo "dbfilter = ^%h\$" | sudo tee -a ${CONFIG_FILE}
fi

sudo chown $OE_USER:$OE_USER ${CONFIG_FILE}
sudo chmod 640 ${CONFIG_FILE}

echo "Archivo de configuración creado en '${CONFIG_FILE}'."

# Crear directorio de logs
sudo mkdir -p /var/log/${OE_USER}
sudo chown ${OE_USER}:${OE_USER} /var/log/${OE_USER}

# Crear archivo de servicio systemd
SERVICE_FILE="/etc/systemd/system/${OE_USER}-${INSTANCE_NAME}.service"
sudo bash -c "cat > ${SERVICE_FILE}" <<EOF
[Unit]
Description=Odoo18 - ${INSTANCE_NAME}
After=network.target

[Service]
Type=simple
User=${OE_USER}
Group=${OE_USER}
ExecStart=${VENV_DIR}/bin/python ${OE_BASE_CODE}/odoo-bin -c ${CONFIG_FILE}
WorkingDirectory=${OE_BASE_CODE}
StandardOutput=journal+console
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ${OE_USER}-${INSTANCE_NAME}.service
sudo systemctl start ${OE_USER}-${INSTANCE_NAME}.service

echo "Servicio '${OE_USER}-${INSTANCE_NAME}.service' creado y iniciado."

# Configurar Nginx
NGINX_AVAILABLE="/etc/nginx/sites-available/${INSTANCE_DOMAIN}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${INSTANCE_DOMAIN}"

# Crear configuración mínima de Nginx
sudo bash -c "cat > ${NGINX_AVAILABLE}" <<EOF
# Odoo server
upstream odoo_${INSTANCE_NAME} {
    server 127.0.0.1:${ODOO_PORT};
}
upstream odoochat_${INSTANCE_NAME} {
    server 127.0.0.1:${GEVENT_PORT};
}
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name ${INSTANCE_DOMAIN};

    access_log /var/log/nginx/${INSTANCE_NAME}.access.log;
    error_log /var/log/nginx/${INSTANCE_NAME}.error.log;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    # Añadir cabeceras para el modo proxy de Odoo
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_redirect off;

    location / {
        proxy_pass http://odoo_${INSTANCE_NAME};
    }

    location /longpolling {
        proxy_pass http://odoochat_${INSTANCE_NAME};
    }

    location ~* /web/static/ {
        proxy_cache_valid 200 90m;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://odoo_${INSTANCE_NAME};
    }
}
EOF

sudo ln -s ${NGINX_AVAILABLE} ${NGINX_ENABLED}
sudo nginx -t
sudo systemctl restart nginx

echo "Configuración mínima de Nginx creada."

# Si SSL está habilitado, obtener certificado y actualizar configuración
if [ "$ENABLE_SSL" = "True" ]; then
    echo "Obteniendo certificado SSL con Certbot..."
    sudo certbot certonly --nginx -d ${INSTANCE_DOMAIN} --non-interactive --agree-tos --email ${ADMIN_EMAIL}

    # Actualizar configuración de Nginx con SSL
    sudo bash -c "cat > ${NGINX_AVAILABLE}" <<EOF
# Odoo server
upstream odoo_${INSTANCE_NAME} {
    server 127.0.0.1:${ODOO_PORT};
}
upstream odoochat_${INSTANCE_NAME} {
    server 127.0.0.1:${GEVENT_PORT};
}
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

# http -> https
server {
    listen 80;
    server_name ${INSTANCE_DOMAIN};
    rewrite ^(.*) https://\$host\$1 permanent;
}

server {
    listen 443 ssl;
    server_name ${INSTANCE_DOMAIN};
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    # SSL parameters
    ssl_certificate /etc/letsencrypt/live/${INSTANCE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${INSTANCE_DOMAIN}/privkey.pem;
    ssl_session_timeout 30m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;

    # log
    access_log /var/log/nginx/${INSTANCE_NAME}.access.log;
    error_log /var/log/nginx/${INSTANCE_NAME}.error.log;

    # Redirect websocket requests to odoo gevent port
    location /websocket {
        proxy_pass http://odoochat_${INSTANCE_NAME};
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
        proxy_cookie_flags session_id samesite=lax secure;
    }

    # Redirect requests to odoo backend server
    location / {
        # Add Headers for odoo proxy mode
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_redirect off;
        proxy_pass http://odoo_${INSTANCE_NAME};

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
        proxy_cookie_flags session_id samesite=lax secure;
    }

    # common gzip
    gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
    gzip on;
}
EOF

    sudo nginx -t
    sudo systemctl restart nginx
    echo "Configuración de Nginx actualizada con SSL."
fi

echo "-----------------------------------------------------------"
echo "¡La instancia '$INSTANCE_NAME' se ha creado exitosamente!"
echo "-----------------------------------------------------------"
echo "Puertos:"
echo "  Puerto Odoo (http_port): $ODOO_PORT"
echo "  Puerto Gevent (gevent_port): $GEVENT_PORT"
echo ""
echo "Información del servicio:"
echo "  Nombre del servicio: ${OE_USER}-${INSTANCE_NAME}.service"
echo "  Archivo de configuración: ${CONFIG_FILE}"
echo "  Archivo de log: /var/log/${OE_USER}/${INSTANCE_NAME}.log"
echo ""
echo "Carpeta de addons personalizados: ${CUSTOM_ADDONS_DIR}"
if [ "$HAS_ENTERPRISE" = "True" ]; then
    echo "Carpeta de addons Enterprise: ${ENTERPRISE_ADDONS_DIR}"
fi
echo ""
echo "Información de la base de datos:"
echo "  Usuario de la base de datos: $INSTANCE_NAME"
echo "  Contraseña de la base de datos: $DB_PASSWORD"
echo ""
echo "Información de superadministrador:"
echo "  Contraseña de superadministrador: $SUPERADMIN_PASS"
echo ""
echo "Administra el servicio de Odoo con los siguientes comandos:"
echo "  Iniciar:   sudo systemctl start ${OE_USER}-${INSTANCE_NAME}.service"
echo "  Detener:   sudo systemctl stop ${OE_USER}-${INSTANCE_NAME}.service"
echo "  Reiniciar: sudo systemctl restart ${OE_USER}-${INSTANCE_NAME}.service"
echo ""
if [ "$ENABLE_SSL" = "True" ]; then
    echo "Archivo de configuración de Nginx: ${NGINX_AVAILABLE}"
    echo "URL de acceso: https://${INSTANCE_DOMAIN}"
else
    echo "Archivo de configuración de Nginx: ${NGINX_AVAILABLE}"
    echo "URL de acceso: http://${INSTANCE_DOMAIN}"
fi
echo "-----------------------------------------------------------"
