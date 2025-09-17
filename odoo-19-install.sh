#!/bin/bash
################################################################################
# Instalación CORE de Odoo 19 (sin crear instancias/servicios/systemd/nginx)
# - Muestra progreso (tee) y guarda logs
# - Prepara: PostgreSQL (opcional 16), Python+venv, requirements, wkhtmltopdf,
#   código community 19.0 y enterprise (opcional)
################################################################################

#===================== Variables editables =====================#
OE_USER="odoo"
OE_HOME="/$OE_USER"
OE_HOME_EXT="/$OE_USER/${OE_USER}-server"   # Código community (branch 19.0)
OE_VERSION="19.0"

IS_ENTERPRISE="True"                         # Cambia a False si no usarás enterprise
INSTALL_POSTGRESQL_SIXTEEN="True"
INSTALL_WKHTMLTOPDF="True"

# Logs
INSTALL_LOG_FILE="/var/log/odoo_install.log"
ERROR_LOG_FILE="/var/log/odoo_install_error.log"

#===================== Logging & errores =====================#
set -e
log_message() {
  echo "$(date '+%F %T') - $1" | tee -a "$INSTALL_LOG_FILE"
}
handle_error() {
  echo "$(date '+%F %T') - ERROR: $1" | tee -a "$ERROR_LOG_FILE"
}
trap 'handle_error "Falló el comando en línea $LINENO (exit=$?)"' ERR

sudo mkdir -p /var/log
sudo touch "$INSTALL_LOG_FILE" "$ERROR_LOG_FILE"
sudo chmod 666 "$INSTALL_LOG_FILE" "$ERROR_LOG_FILE"

log_message "=== Iniciando instalación CORE Odoo $OE_VERSION (sin instancias) ==="

#===================== Detección distro / wkhtml =====================#
UBU_CODENAME="$(lsb_release -c -s 2>/dev/null || echo "")"
case "$UBU_CODENAME" in
  jammy) WKHTML_DEB="wkhtmltox_0.12.6.1-3.jammy_amd64.deb" ;;
  noble) WKHTML_DEB="wkhtmltox_0.12.6.1-3.noble_amd64.deb" ;;
  *)     WKHTML_DEB="" ;; # fallback apt
esac
WKHTML_BASE_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3"

#===================== Paquetes base / Update =====================#
log_message "Actualizando el sistema..."
sudo apt-get update 2>&1 | tee -a "$INSTALL_LOG_FILE"
sudo apt-get upgrade -y 2>&1 | tee -a "$INSTALL_LOG_FILE"

log_message "Instalando utilidades base..."
sudo apt-get install -y \
  curl wget ca-certificates software-properties-common \
  2>&1 | tee -a "$INSTALL_LOG_FILE"

#===================== PostgreSQL =====================#
log_message "Instalando PostgreSQL..."
if [ "$INSTALL_POSTGRESQL_SIXTEEN" = "True" ]; then
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg 2>&1 | tee -a "$INSTALL_LOG_FILE"
  echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null
  sudo apt-get update 2>&1 | tee -a "$INSTALL_LOG_FILE"
  sudo apt-get install -y postgresql-16 2>&1 | tee -a "$INSTALL_LOG_FILE"
else
  sudo apt-get install -y postgresql 2>&1 | tee -a "$INSTALL_LOG_FILE"
fi

# Crea rol superuser para administración general (no instancia)
log_message "Creando usuario de PostgreSQL '$OE_USER' (si no existe)..."
sudo -u postgres createuser -s "$OE_USER" 2>/dev/null || true

#===================== Usuario de sistema Odoo =====================#
log_message "Creando usuario de sistema $OE_USER..."
if id "$OE_USER" &>/dev/null; then
  echo "Usuario $OE_USER ya existe" | tee -a "$INSTALL_LOG_FILE"
else
  sudo adduser --system --quiet --shell=/bin/bash --home="$OE_HOME" --gecos 'ODOO' --group "$OE_USER" 2>&1 | tee -a "$INSTALL_LOG_FILE"
  sudo adduser "$OE_USER" sudo 2>&1 | tee -a "$INSTALL_LOG_FILE"
fi
sudo mkdir -p "$OE_HOME" "/var/log/$OE_USER"
sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME" "/var/log/$OE_USER"

#===================== Python (>=3.10) + libs =====================#
log_message "Instalando Python (>=3.10) y librerías del sistema..."
if ! python3 -c 'import sys; exit(0 if sys.version_info>=(3,10) else 1)'; then
  sudo add-apt-repository -y ppa:deadsnakes/ppa 2>&1 | tee -a "$INSTALL_LOG_FILE"
  sudo apt-get update 2>&1 | tee -a "$INSTALL_LOG_FILE"
  sudo apt-get install -y python3.12 python3.12-dev python3.12-venv 2>&1 | tee -a "$INSTALL_LOG_FILE"
  sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 20 2>&1 | tee -a "$INSTALL_LOG_FILE"
else
  # Asegura venv para la versión por defecto
  sudo apt-get install -y python3-venv 2>&1 | tee -a "$INSTALL_LOG_FILE"
fi

# Libs del sistema necesarias por Odoo
sudo apt-get install -y \
  build-essential git pkg-config \
  libldap2-dev libsasl2-dev libssl-dev libpq-dev \
  libjpeg-dev zlib1g-dev libxml2-dev libxslt1-dev libzip-dev \
  xfonts-75dpi xfonts-base nodejs npm 2>&1 | tee -a "$INSTALL_LOG_FILE"

#===================== venv (compartido CORE) =====================#
log_message "Creando entorno virtual compartido en $OE_HOME/venv ..."
sudo -u "$OE_USER" python3 -m venv "$OE_HOME/venv" 2>&1 | tee -a "$INSTALL_LOG_FILE"

# Asegura pip dentro del venv (por si faltara)
sudo -u "$OE_USER" "$OE_HOME/venv/bin/python" -m ensurepip --upgrade 2>&1 | tee -a "$INSTALL_LOG_FILE"
# Actualiza herramientas básicas
sudo -u "$OE_USER" "$OE_HOME/venv/bin/pip" install --upgrade pip wheel setuptools 2>&1 | tee -a "$INSTALL_LOG_FILE"

#===================== rtlcss =====================#
log_message "Instalando rtlcss (npm global)..."
sudo npm install -g rtlcss 2>&1 | tee -a "$INSTALL_LOG_FILE"

#===================== wkhtmltopdf =====================#
#===================== wkhtmltopdf =====================#
if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
  ARCH="$(dpkg --print-architecture || echo amd64)"
  log_message "Instalando wkhtmltopdf (arquitectura: $ARCH)..."
  if [ "$ARCH" = "amd64" ]; then
    WKHTML_DEB="wkhtmltox_0.12.6.1-2.jammy_amd64.deb"
    WKHTML_BASE_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2"
    curl -fL -o /tmp/wkhtml.deb "${WKHTML_BASE_URL}/${WKHTML_DEB}" 2>&1 | tee -a "$INSTALL_LOG_FILE"
    sudo apt-get install -y /tmp/wkhtml.deb 2>&1 | tee -a "$INSTALL_LOG_FILE" || {
      handle_error "Fallo instalando .deb; usando paquete de repos."
      sudo apt-get install -y wkhtmltopdf 2>&1 | tee -a "$INSTALL_LOG_FILE"
    }
    rm -f /tmp/wkhtml.deb
  else
    echo "Arquitectura $ARCH detectada; instalando wkhtmltopdf desde repos (sin Qt parcheado)." | tee -a "$INSTALL_LOG_FILE"
    sudo apt-get install -y wkhtmltopdf 2>&1 | tee -a "$INSTALL_LOG_FILE"
  fi
  command -v wkhtmltopdf >/dev/null && wkhtmltopdf --version 2>&1 | tee -a "$INSTALL_LOG_FILE" || true
fi

#===================== Código Odoo community =====================#
log_message "Clonando Odoo $OE_VERSION en $OE_HOME_EXT ..."
if [ ! -d "$OE_HOME_EXT" ]; then
  sudo git clone --depth 1 --branch "$OE_VERSION" https://github.com/odoo/odoo "$OE_HOME_EXT/" 2>&1 | tee -a "$INSTALL_LOG_FILE"
  sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME_EXT/"
else
  echo "Directorio $OE_HOME_EXT ya existe; se omite clon." | tee -a "$INSTALL_LOG_FILE"
fi

#===================== requirements Odoo 19 =====================#
log_message "Instalando requirements.txt de Odoo $OE_VERSION ..."
sudo -u "$OE_USER" "$OE_HOME/venv/bin/pip" install -r "https://raw.githubusercontent.com/odoo/odoo/${OE_VERSION}/requirements.txt" \
  2>&1 | tee -a "$INSTALL_LOG_FILE"

#===================== Enterprise (opcional) =====================#
if [ "$IS_ENTERPRISE" = "True" ]; then
  log_message "Clonando Odoo Enterprise (requiere acceso a github.com/odoo/enterprise) ..."
  sudo -u "$OE_USER" mkdir -p "$OE_HOME/enterprise/addons"
  if [ ! -d "$OE_HOME/enterprise/addons/.git" ]; then
    set +e
    GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch "$OE_VERSION" https://github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
    RET=$?
    echo "$GITHUB_RESPONSE" | tee -a "$INSTALL_LOG_FILE"
    set -e
    if [ $RET -ne 0 ]; then
      handle_error "No se pudo clonar enterprise (¿sin credenciales?). Puedes reintentarlo más tarde."
    else
      # libs típicas usadas por enterprise
      sudo -u "$OE_USER" "$OE_HOME/venv/bin/pip" install num2words ofxparse dbfread firebase_admin pyOpenSSL pdfminer.six \
        2>&1 | tee -a "$INSTALL_LOG_FILE"
    fi
  else
    echo "Enterprise ya presente en $OE_HOME/enterprise/addons." | tee -a "$INSTALL_LOG_FILE"
  fi
fi

#===================== Permisos finales =====================#
log_message "Ajustando permisos en $OE_HOME ..."
sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME" 2>&1 | tee -a "$INSTALL_LOG_FILE"

#===================== Resumen / Siguientes pasos =====================#
log_message "=== CORE Odoo $OE_VERSION instalado (sin instancias) ==="
echo "-----------------------------------------------------------"
echo "Listo. Componentes preparados:"
echo "  - Python/venv:        $OE_HOME/venv"
echo "  - Community code:     $OE_HOME_EXT (branch $OE_VERSION)"
if [ "$IS_ENTERPRISE" = "True" ]; then
  echo "  - Enterprise addons:  $OE_HOME/enterprise/addons (si el clon fue exitoso)"
fi
echo "  - wkhtmltopdf:        $(command -v wkhtmltopdf || echo 'no instalado')"
echo "  - Usuario PostgreSQL: $OE_USER (rol superuser)"
echo
echo "Logs:"
echo "  - Main:  $INSTALL_LOG_FILE"
echo "  - Error: $ERROR_LOG_FILE"
echo
echo "Siguientes pasos:"
echo "  1) Usa tu script de 'add instance' para crear instancias (conf, puertos, servicio)."
echo "  2) Si usas Enterprise y falló el clon, ejecuta manualmente:"
echo "     sudo -u $OE_USER git clone --depth 1 --branch $OE_VERSION https://github.com/odoo/enterprise $OE_HOME/enterprise/addons"
echo "-----------------------------------------------------------"
