#!/usr/bin/env bash
# =============================================================================
#  glpi-https.sh — Passage de GLPI en HTTPS (Debian 13, Apache, PHP-FPM)
#
#  Deux modes :
#    1) Let's Encrypt (certbot) : serveur joignable depuis Internet sur le port 80
#    2) Certificat auto-signé    : lab, réseau interne, tests
#  Dans les deux cas : redirection HTTP -> HTTPS et session.cookie_secure = On
#  (recommandation du tutoriel une fois GLPI en HTTPS).
#
#  Usage : sudo ./glpi-https.sh   (appelé aussi à la fin de glpi-install.sh)
# =============================================================================
set -Eeuo pipefail

GLPI_FQDN="${GLPI_FQDN:-}"
GLPI_WEBROOT="${GLPI_WEBROOT:-/var/www/glpi}"
HTTPS_MODE="${HTTPS_MODE:-}"        # letsencrypt | selfsigned
LE_EMAIL="${LE_EMAIL:-}"
CERT_DAYS="${CERT_DAYS:-825}"

if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_0=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi
info() { printf '%s[INFO]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[ERR ]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
trap 'die "Échec à la ligne $LINENO (commande : $BASH_COMMAND)"' ERR

ask() {
  local __var="$1" __q="$2" __def="${!1:-}" __ans
  read -r -p "$__q [${__def}] : " __ans || true
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

[[ $EUID -eq 0 ]] || die "Ce script doit être lancé en root (sudo)."

# --- Paramètres --------------------------------------------------------------
if [[ -z "$GLPI_FQDN" ]]; then
  # on propose le ServerName du premier vhost GLPI trouvé
  GLPI_FQDN="$(grep -l "DocumentRoot ${GLPI_WEBROOT}/public" /etc/apache2/sites-enabled/*.conf 2>/dev/null \
               | head -n1 | xargs -r grep -m1 -oP 'ServerName\s+\K\S+' || true)"
  ask GLPI_FQDN "Nom DNS de GLPI"
fi
[[ -n "$GLPI_FQDN" ]] || die "Nom DNS obligatoire."
VHOST="/etc/apache2/sites-available/${GLPI_FQDN}.conf"
[[ -f "$VHOST" ]] || die "VirtualHost introuvable : ${VHOST} (lancez d'abord glpi-install.sh)."

SERVER_IPS="$(hostname -I 2>/dev/null | xargs || true)"
PHPV="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_FPM_SOCK="/run/php/php${PHPV}-fpm.sock"

if [[ -z "$HTTPS_MODE" ]]; then
  echo "Type de certificat :"
  echo "  1) Let's Encrypt (serveur joignable depuis Internet)"
  echo "  2) Auto-signé (lab / réseau interne)"
  choice=""; ask choice "Votre choix (1/2)"
  case "$choice" in
    1) HTTPS_MODE="letsencrypt" ;;
    2) HTTPS_MODE="selfsigned" ;;
    *) die "Choix invalide." ;;
  esac
fi

export DEBIAN_FRONTEND=noninteractive
a2enmod -q ssl headers rewrite >/dev/null

# --- Let's Encrypt -------------------------------------------------------------
if [[ "$HTTPS_MODE" == "letsencrypt" ]]; then
  [[ -n "$LE_EMAIL" ]] || ask LE_EMAIL "Adresse e-mail pour Let's Encrypt"
  apt-get -y -q install certbot python3-certbot-apache
  systemctl reload apache2
  # certbot crée <fqdn>-le-ssl.conf à partir du vhost :80 et ajoute la redirection
  certbot --apache -d "$GLPI_FQDN" -m "$LE_EMAIL" --agree-tos --redirect -n
  ok "Certificat Let's Encrypt installé (renouvellement automatique via certbot.timer)."

# --- Auto-signé ----------------------------------------------------------------
elif [[ "$HTTPS_MODE" == "selfsigned" ]]; then
  SSL_DIR="/etc/ssl/glpi"
  SAN="DNS:${GLPI_FQDN}"
  for ip in $SERVER_IPS; do SAN+=",IP:${ip}"; done
  mkdir -p "$SSL_DIR"; chmod 700 "$SSL_DIR"
  openssl req -x509 -nodes -newkey rsa:4096 -sha256 -days "$CERT_DAYS" \
    -keyout "${SSL_DIR}/${GLPI_FQDN}.key" -out "${SSL_DIR}/${GLPI_FQDN}.crt" \
    -subj "/CN=${GLPI_FQDN}" -addext "subjectAltName=${SAN}" 2>/dev/null
  chmod 600 "${SSL_DIR}/${GLPI_FQDN}.key"
  cp -a "$VHOST" "${VHOST}.bak-$(date +%Y%m%d-%H%M%S)"

  cat > "$VHOST" <<EOF
<VirtualHost *:80>
    ServerName ${GLPI_FQDN}
    ServerAlias ${SERVER_IPS} localhost
    # redirige vers HTTPS en gardant le nom ou l'IP tapé par l'utilisateur
    RewriteEngine On
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName ${GLPI_FQDN}
    ServerAlias ${SERVER_IPS} localhost

    DocumentRoot ${GLPI_WEBROOT}/public

    SSLEngine on
    SSLCertificateFile    ${SSL_DIR}/${GLPI_FQDN}.crt
    SSLCertificateKeyFile ${SSL_DIR}/${GLPI_FQDN}.key

    <Directory ${GLPI_WEBROOT}/public>
        Require all granted

        RewriteEngine On

        # Ensure authorization headers are passed to PHP.
        # Some Apache configurations may filter them and break usage of API, CalDAV, ...
        RewriteCond %{HTTP:Authorization} ^(.+)\$
        RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]

        # Redirect all requests to GLPI router, unless file exists.
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)\$ index.php [QSA,L]
    </Directory>

    <FilesMatch \.php\$>
        SetHandler "proxy:unix:${PHP_FPM_SOCK}|fcgi://localhost/"
    </FilesMatch>

    Header always set Strict-Transport-Security "max-age=31536000"

    ErrorLog \${APACHE_LOG_DIR}/glpi_error.log
    CustomLog \${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
EOF
  apache2ctl configtest
  ok "Certificat auto-signé créé dans ${SSL_DIR} (valable ${CERT_DAYS} jours)."
  warn "Les navigateurs afficheront un avertissement tant que ce certificat n'est pas approuvé."
else
  die "HTTPS_MODE invalide : ${HTTPS_MODE}"
fi

# --- Cookies de session sécurisés ---------------------------------------------
INI="/etc/php/${PHPV}/fpm/conf.d/99-glpi.ini"
if [[ -f "$INI" ]] && grep -q '^session.cookie_secure' "$INI"; then
  sed -i 's/^session.cookie_secure.*/session.cookie_secure = On/' "$INI"
else
  printf 'session.cookie_secure = On\n' >> "$INI"
fi
systemctl restart "php${PHPV}-fpm"
systemctl reload apache2
ok "session.cookie_secure activé. GLPI est servi sur https://${GLPI_FQDN}/"
info "Pensez à mettre à jour l'URL de l'application dans GLPI : Configuration > Générale > URL de l'application."
