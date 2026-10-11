#!/usr/bin/env bash
# =============================================================================
#  glpi-install.sh — Déploiement interactif de GLPI 11 sur Debian 13
#
#  Basé sur le tutoriel IT-Connect « Installation pas-à-pas de GLPI 11 sur
#  Debian 13 », automatisé et adapté :
#    - socle LAMP (Apache 2 + PHP-FPM + MariaDB)
#    - base de données et utilisateur dédiés
#    - téléchargement de la dernière version de GLPI 11
#    - séparation code / config / données / logs (hors racine web)
#    - VirtualHost Apache pointant sur /public + PHP-FPM
#    - durcissement des cookies de session PHP
#    - installation de la base en ligne de commande (ou via le navigateur)
#    - post-installation : mots de passe, install.php, cron, fuseaux horaires
#
#  Usage :
#    sudo ./glpi-install.sh                 # mode interactif
#    sudo ./glpi-install.sh -c glpi.conf    # valeurs par défaut lues dans un fichier
#    sudo ./glpi-install.sh -c glpi.conf -y # sans aucune question (automatique)
# =============================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Valeurs par défaut (surchargées par le fichier -c ou par l'environnement)
# ----------------------------------------------------------------------------
GLPI_VERSION="${GLPI_VERSION:-latest}"      # "latest" ou ex. 11.0.4
GLPI_FALLBACK_VERSION="11.0.4"              # utilisée si GitHub est injoignable
GLPI_FQDN="${GLPI_FQDN:-}"                  # ex. support.mondomaine.fr
GLPI_WEBROOT="${GLPI_WEBROOT:-/var/www/glpi}"
GLPI_CONFIG_DIR="${GLPI_CONFIG_DIR:-/etc/glpi}"
GLPI_VAR_DIR="${GLPI_VAR_DIR:-/var/lib/glpi}"
GLPI_LOG_DIR="${GLPI_LOG_DIR:-/var/log/glpi}"
DB_NAME="${DB_NAME:-glpi}"
DB_USER="${DB_USER:-glpi_adm}"
DB_PASS="${DB_PASS:-}"                      # vide = généré aléatoirement
GLPI_LANG="${GLPI_LANG:-fr_FR}"
INSTALL_LDAP="${INSTALL_LDAP:-n}"
INSTALL_APCU="${INSTALL_APCU:-o}"
SECURE_MARIADB="${SECURE_MARIADB:-o}"
DISABLE_DEFAULT_SITE="${DISABLE_DEFAULT_SITE:-o}"
UPLOAD_MAX="${UPLOAD_MAX:-20M}"
DB_INSTALL_MODE="${DB_INSTALL_MODE:-cli}"   # cli | web
ENABLE_TIMEZONES="${ENABLE_TIMEZONES:-o}"
SETUP_CRON="${SETUP_CRON:-o}"
GLPI_ADMIN_PASS="${GLPI_ADMIN_PASS:-}"      # nouveau mot de passe du compte "glpi"
DISABLE_DEFAULT_USERS="${DISABLE_DEFAULT_USERS:-o}"
SETUP_HTTPS="${SETUP_HTTPS:-n}"
SERVER_IPS=""
HTTPS_MODE="${HTTPS_MODE:-}"                # letsencrypt | selfsigned (vide = demandé)
LE_EMAIL="${LE_EMAIL:-}"

ASSUME_YES=0
LOG_FILE="/var/log/glpi-deploy.log"
SUMMARY_FILE="/root/glpi-install-resume.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------------------------------------------------------
# Affichage
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_BOLD=$'\e[1m'; C_0=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_BOLD=""; C_0=""
fi
info()  { printf '%s[INFO]%s %s\n'  "$C_B" "$C_0" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n'  "$C_G" "$C_0" "$*"; }
warn()  { printf '%s[WARN]%s %s\n'  "$C_Y" "$C_0" "$*" >&2; }
die()   { printf '%s[ERR ]%s %s\n'  "$C_R" "$C_0" "$*" >&2; exit 1; }
title() { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_0"; }

trap 'die "Échec à la ligne $LINENO (commande : $BASH_COMMAND). Voir $LOG_FILE"' ERR

# ask VAR "Question" — propose la valeur actuelle de VAR comme défaut
ask() {
  local __var="$1" __q="$2" __def="${!1:-}" __ans
  if (( ASSUME_YES )); then return 0; fi
  read -r -p "$__q [${__def}] : " __ans || true
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

# ask_secret VAR "Question" — saisie masquée, vide = conserver / générer
ask_secret() {
  local __var="$1" __q="$2" __a1 __a2
  if (( ASSUME_YES )); then return 0; fi
  while true; do
    read -r -s -p "$__q (vide = généré automatiquement) : " __a1 || true; echo
    [[ -z "$__a1" ]] && return 0
    read -r -s -p "Confirmez : " __a2 || true; echo
    if [[ "$__a1" == "$__a2" ]]; then printf -v "$__var" '%s' "$__a1"; return 0; fi
    warn "Les deux saisies ne correspondent pas, recommencez."
  done
}

# yes VAR "Question" — o/n, la valeur de VAR sert de défaut
ask_yn() {
  local __var="$1" __q="$2" __def="${!1:-n}" __ans
  if (( ASSUME_YES )); then return 0; fi
  while true; do
    read -r -p "$__q (o/n) [${__def}] : " __ans || true
    __ans="${__ans:-$__def}"
    case "${__ans,,}" in
      o|oui|y|yes) printf -v "$__var" 'o'; return 0 ;;
      n|non|no)    printf -v "$__var" 'n'; return 0 ;;
    esac
  done
}
is_yes() { [[ "${1,,}" == o* || "${1,,}" == y* ]]; }

gen_pass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}" || true; }
sql_escape() { local s="${1//\\/\\\\}"; printf '%s' "${s//\'/\'\'}"; }

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ----------------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------------
while getopts ":c:yh" opt; do
  case "$opt" in
    c) [[ -r "$OPTARG" ]] || die "Fichier de configuration illisible : $OPTARG"
       # shellcheck disable=SC1090
       source "$OPTARG" ;;
    y) ASSUME_YES=1 ;;
    h) usage ;;
    *) die "Option inconnue. Voir -h." ;;
  esac
done

# ----------------------------------------------------------------------------
# 0. Vérifications préalables
# ----------------------------------------------------------------------------
preflight() {
  title "Vérifications préalables"
  [[ $EUID -eq 0 ]] || die "Ce script doit être lancé en root (sudo)."
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "debian" || "${VERSION_ID:-}" != "13" ]]; then
    warn "Système détecté : ${PRETTY_NAME:-inconnu}. Ce script est prévu pour Debian 13 (Trixie)."
    local cont="n"; ask_yn cont "Continuer quand même ?"
    is_yes "$cont" || exit 1
  else
    ok "Debian 13 détectée (${PRETTY_NAME})."
  fi
  if [[ -d "$GLPI_WEBROOT" ]]; then
    warn "$GLPI_WEBROOT existe déjà : une installation précédente est peut-être présente."
  fi
  touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
}

# ----------------------------------------------------------------------------
# 1. Questions
# ----------------------------------------------------------------------------
questions() {
  title "Paramètres de l'installation"
  local default_fqdn; default_fqdn="$(hostname -f 2>/dev/null || hostname)"
  GLPI_FQDN="${GLPI_FQDN:-$default_fqdn}"
  ask GLPI_FQDN     "Nom DNS (ServerName) de GLPI"
  ask GLPI_VERSION  "Version de GLPI à installer (latest ou x.y.z)"
  ask DB_NAME       "Nom de la base de données"
  ask DB_USER       "Utilisateur MariaDB de GLPI"
  [[ -n "$DB_PASS" ]] || ask_secret DB_PASS "Mot de passe de l'utilisateur MariaDB"
  ask GLPI_LANG     "Langue par défaut de GLPI"
  ask_yn INSTALL_LDAP "Installer l'extension PHP LDAP (annuaire / Active Directory) ?"
  ask_yn INSTALL_APCU "Installer APCu (cache, recommandé) ?"
  ask_yn SECURE_MARIADB "Sécuriser MariaDB (équivalent mariadb-secure-installation) ?"
  ask_yn DISABLE_DEFAULT_SITE "Désactiver le site Apache par défaut (000-default) ?"
  ask UPLOAD_MAX    "Taille maximale des pièces jointes (upload_max_filesize)"
  ask DB_INSTALL_MODE "Initialiser la base en ligne de commande (cli) ou via le navigateur (web)"
  if [[ "$DB_INSTALL_MODE" == "cli" ]]; then
    ask_yn ENABLE_TIMEZONES "Activer le support des fuseaux horaires dans la base ?"
    [[ -n "$GLPI_ADMIN_PASS" ]] || ask_secret GLPI_ADMIN_PASS "Nouveau mot de passe du super-admin « glpi »"
    ask_yn DISABLE_DEFAULT_USERS "Désactiver les comptes par défaut tech, normal et post-only ?"
  fi
  ask_yn SETUP_CRON "Configurer la tâche cron de GLPI (actions automatiques) ?"
  if [[ -x "$SCRIPT_DIR/glpi-https.sh" ]]; then
    ask_yn SETUP_HTTPS "Configurer HTTPS à la fin (Let's Encrypt ou auto-signé) ?"
  fi

  [[ -n "$DB_PASS" ]] || DB_PASS="$(gen_pass 24)"
  if [[ "$DB_INSTALL_MODE" == "cli" && -z "$GLPI_ADMIN_PASS" ]]; then
    GLPI_ADMIN_PASS="$(gen_pass 16)"
  fi
  [[ "$GLPI_LANG" =~ ^[a-z]{2}_[A-Z]{2}$ ]] || die "Langue invalide : $GLPI_LANG (ex. fr_FR)"
  [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "Nom de base invalide : $DB_NAME"
  [[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || die "Nom d'utilisateur invalide : $DB_USER"
  [[ "$DB_INSTALL_MODE" =~ ^(cli|web)$ ]] || die "Mode d'installation invalide : $DB_INSTALL_MODE"

  title "Récapitulatif"
  cat <<EOF
  URL                : http://${GLPI_FQDN}/
  Version GLPI       : ${GLPI_VERSION}
  Code               : ${GLPI_WEBROOT}
  Configuration      : ${GLPI_CONFIG_DIR}
  Données            : ${GLPI_VAR_DIR}/files
  Logs               : ${GLPI_LOG_DIR}
  Base / utilisateur : ${DB_NAME} / ${DB_USER}
  Initialisation BDD : ${DB_INSTALL_MODE}
  LDAP / APCu        : ${INSTALL_LDAP} / ${INSTALL_APCU}
  Cron / HTTPS       : ${SETUP_CRON} / ${SETUP_HTTPS}
EOF
  local go="o"; ask_yn go "Lancer l'installation ?"
  is_yes "$go" || { info "Installation annulée."; exit 0; }
}

# ----------------------------------------------------------------------------
# 2. Paquets (LAMP + extensions PHP)
# ----------------------------------------------------------------------------
install_packages() {
  title "Mise à jour du système et installation des paquets"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get -y -q upgrade
  local pkgs=(apache2 mariadb-server curl wget ca-certificates tar bzip2 tzdata
              php-fpm php-cli php-curl php-gd php-intl php-mysql php-zip
              php-bcmath php-mbstring php-xml php-bz2)
  is_yes "$INSTALL_LDAP" && pkgs+=(php-ldap)
  is_yes "$INSTALL_APCU" && pkgs+=(php-apcu)
  apt-get -y -q install "${pkgs[@]}"

  PHPV="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  PHP_FPM_SOCK="/run/php/php${PHPV}-fpm.sock"
  ok "PHP ${PHPV} installé (socket FPM : ${PHP_FPM_SOCK})."
  php -r 'exit(version_compare(PHP_VERSION, "8.2.0", ">=") ? 0 : 1);' \
    || die "GLPI 11 nécessite PHP >= 8.2 (version trouvée : ${PHPV})."

  local missing=() mods; mods="$(php -m)"
  for ext in dom fileinfo filter libxml simplexml tokenizer xmlreader xmlwriter \
             curl gd intl mysqli session zlib bcmath mbstring openssl; do
    grep -qix "$ext" <<<"$mods" || missing+=("$ext")
  done
  (( ${#missing[@]} == 0 )) || die "Extensions PHP manquantes : ${missing[*]}"
  ok "Toutes les extensions PHP obligatoires de GLPI 11 sont présentes."
  systemctl enable --now mariadb apache2 "php${PHPV}-fpm" >/dev/null
}

# ----------------------------------------------------------------------------
# 3. MariaDB
# ----------------------------------------------------------------------------
setup_mariadb() {
  title "Configuration de MariaDB"
  if is_yes "$SECURE_MARIADB"; then
    # Équivalent non interactif de mariadb-secure-installation.
    # root reste authentifié par socket unix (comportement par défaut sous Debian).
    mariadb <<'SQL'
DELETE FROM mysql.global_priv WHERE User='';
DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
    ok "MariaDB sécurisée (comptes anonymes, accès root distant et base test supprimés)."
  fi

  local p; p="$(sql_escape "$DB_PASS")"
  mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${p}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${p}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
  ok "Base « ${DB_NAME} » et utilisateur « ${DB_USER} » prêts."

  if is_yes "$ENABLE_TIMEZONES"; then
    info "Chargement des fuseaux horaires dans MariaDB…"
    mariadb-tzinfo-to-sql /usr/share/zoneinfo 2>/dev/null | mariadb mysql
    mariadb -e "GRANT SELECT ON \`mysql\`.\`time_zone_name\` TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
    ok "Fuseaux horaires chargés et accès accordé à ${DB_USER}."
  fi
}

# ----------------------------------------------------------------------------
# 4. Téléchargement et extraction de GLPI
# ----------------------------------------------------------------------------
resolve_version() {
  if [[ "$GLPI_VERSION" == "latest" ]]; then
    local v
    v="$(curl -fsSL https://api.github.com/repos/glpi-project/glpi/releases/latest 2>/dev/null \
         | grep -oP '"tag_name":\s*"\K[^"]+' || true)"
    if [[ -n "$v" ]]; then
      GLPI_VERSION="$v"
    else
      warn "Impossible d'interroger GitHub, utilisation de la version ${GLPI_FALLBACK_VERSION}."
      GLPI_VERSION="$GLPI_FALLBACK_VERSION"
    fi
  fi
  [[ "$GLPI_VERSION" == 11.* ]] || warn "La version ${GLPI_VERSION} n'est pas une 11.x : ce script vise GLPI 11."
  ok "Version retenue : GLPI ${GLPI_VERSION}"
}

download_glpi() {
  title "Téléchargement de GLPI"
  resolve_version
  local url="https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz"
  local tmp; tmp="$(mktemp -d)"
  info "Téléchargement de ${url}"
  wget -q --show-progress -O "${tmp}/glpi.tgz" "$url" || die "Téléchargement impossible : ${url}"

  if [[ -d "$GLPI_WEBROOT" ]]; then
    local bak; bak="${GLPI_WEBROOT}.bak-$(date +%Y%m%d-%H%M%S)"
    local mv_old="o"; ask_yn mv_old "Déplacer l'ancien ${GLPI_WEBROOT} vers ${bak} ?"
    is_yes "$mv_old" || die "Arrêt : ${GLPI_WEBROOT} existe déjà."
    mv "$GLPI_WEBROOT" "$bak"
    warn "Ancien répertoire sauvegardé dans ${bak}"
  fi
  tar -xzf "${tmp}/glpi.tgz" -C "$(dirname "$GLPI_WEBROOT")"
  if [[ "$(dirname "$GLPI_WEBROOT")/glpi" != "$GLPI_WEBROOT" ]]; then
    mv "$(dirname "$GLPI_WEBROOT")/glpi" "$GLPI_WEBROOT"
  fi
  rm -rf "$tmp"
  ok "GLPI extrait dans ${GLPI_WEBROOT}"
}

# ----------------------------------------------------------------------------
# 5. Répertoires hors racine web + fichiers downstream.php / local_define.php
# ----------------------------------------------------------------------------
setup_directories() {
  title "Séparation code / configuration / données / logs"
  mkdir -p "$GLPI_CONFIG_DIR" "$GLPI_VAR_DIR" "$GLPI_LOG_DIR"

  # config : on déplace le contenu fourni (sans écraser une config existante)
  if [[ -d "${GLPI_WEBROOT}/config" ]]; then
    cp -an "${GLPI_WEBROOT}/config/." "$GLPI_CONFIG_DIR/"
    rm -rf "${GLPI_WEBROOT}/config"
  fi
  # files : idem
  if [[ -d "${GLPI_WEBROOT}/files" ]]; then
    if [[ -d "${GLPI_VAR_DIR}/files" ]]; then
      cp -an "${GLPI_WEBROOT}/files/." "${GLPI_VAR_DIR}/files/"
      rm -rf "${GLPI_WEBROOT}/files"
    else
      mv "${GLPI_WEBROOT}/files" "${GLPI_VAR_DIR}/files"
    fi
  fi

  cat > "${GLPI_WEBROOT}/inc/downstream.php" <<EOF
<?php
define('GLPI_CONFIG_DIR', '${GLPI_CONFIG_DIR}/');
if (file_exists(GLPI_CONFIG_DIR . '/local_define.php')) {
    require_once GLPI_CONFIG_DIR . '/local_define.php';
}
EOF

  cat > "${GLPI_CONFIG_DIR}/local_define.php" <<EOF
<?php
define('GLPI_VAR_DIR', '${GLPI_VAR_DIR}/files');
define('GLPI_LOG_DIR', '${GLPI_LOG_DIR}');
EOF
  ok "downstream.php et local_define.php créés."

  # Permissions : le code appartient à root (lecture seule pour le web),
  # seuls les répertoires qui doivent l'être sont inscriptibles par www-data.
  chown -R root:root "$GLPI_WEBROOT"
  find "$GLPI_WEBROOT" -type d -exec chmod 755 {} +
  find "$GLPI_WEBROOT" -type f -exec chmod 644 {} +
  chmod 755 "${GLPI_WEBROOT}/bin/console" 2>/dev/null || true
  mkdir -p "${GLPI_WEBROOT}/marketplace"
  chown -R www-data:www-data "${GLPI_WEBROOT}/marketplace"   # plugins via la marketplace

  chown -R www-data:www-data "$GLPI_CONFIG_DIR" "$GLPI_VAR_DIR" "$GLPI_LOG_DIR"
  chmod 750 "$GLPI_CONFIG_DIR" "$GLPI_VAR_DIR" "$GLPI_LOG_DIR"
  ok "Permissions appliquées."
}

# ----------------------------------------------------------------------------
# 6. PHP-FPM
# ----------------------------------------------------------------------------
setup_php() {
  title "Configuration de PHP-FPM"
  local post_max="$UPLOAD_MAX"
  local ini="/etc/php/${PHPV}/fpm/conf.d/99-glpi.ini"
  cat > "$ini" <<EOF
; Réglages GLPI (généré par glpi-install.sh)
session.cookie_httponly = On
session.cookie_samesite = Lax
; passez à On une fois GLPI servi en HTTPS (glpi-https.sh le fait)
session.cookie_secure = Off
upload_max_filesize = ${UPLOAD_MAX}
post_max_size = ${post_max}
memory_limit = 256M
max_execution_time = 60
EOF
  # même limite mémoire côté CLI pour bin/console et le cron
  printf 'memory_limit = 512M\n' > "/etc/php/${PHPV}/cli/conf.d/99-glpi.ini"
  systemctl restart "php${PHPV}-fpm"
  ok "PHP-FPM configuré (${ini})."
}

# ----------------------------------------------------------------------------
# 7. Apache
# ----------------------------------------------------------------------------
setup_apache() {
  title "Configuration d'Apache"
  local vhost="/etc/apache2/sites-available/${GLPI_FQDN}.conf"
  # GLPI répond aussi sur les IP du serveur : utile tant que le nom DNS
  # n'est pas résolu par les postes clients.
  SERVER_IPS="$(hostname -I 2>/dev/null | xargs || true)"
  cat > "$vhost" <<EOF
<VirtualHost *:80>
    ServerName ${GLPI_FQDN}
    ServerAlias ${SERVER_IPS} localhost

    DocumentRoot ${GLPI_WEBROOT}/public

    # Alias "/glpi" "${GLPI_WEBROOT}/public"

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

    ErrorLog \${APACHE_LOG_DIR}/glpi_error.log
    CustomLog \${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
EOF
  # ServerName global : évite l'avertissement AH00558 (« Could not reliably
  # determine the server's fully qualified domain name »)
  printf 'ServerName %s\n' "$GLPI_FQDN" > /etc/apache2/conf-available/servername.conf
  a2enconf -q servername >/dev/null
  a2enmod -q rewrite proxy_fcgi setenvif >/dev/null
  a2enconf -q "php${PHPV}-fpm" >/dev/null
  a2ensite -q "${GLPI_FQDN}.conf" >/dev/null
  if is_yes "$DISABLE_DEFAULT_SITE"; then a2dissite -q 000-default.conf >/dev/null || true; fi
  # Masquer la version d'Apache
  sed -i 's/^ServerTokens .*/ServerTokens Prod/; s/^ServerSignature .*/ServerSignature Off/' \
    /etc/apache2/conf-available/security.conf
  apache2ctl configtest
  systemctl reload apache2
  ok "VirtualHost ${vhost} actif."
}

# ----------------------------------------------------------------------------
# 8. Initialisation de la base GLPI
# ----------------------------------------------------------------------------
console() { runuser -u www-data -- php "${GLPI_WEBROOT}/bin/console" "$@"; }

install_database() {
  if [[ "$DB_INSTALL_MODE" != "cli" ]]; then
    info "Initialisation de la base à faire dans le navigateur : http://${GLPI_FQDN}/"
    return 0
  fi
  title "Initialisation de la base GLPI (bin/console db:install)"
  local extra=()
  if [[ -f "${GLPI_CONFIG_DIR}/config_db.php" ]]; then
    warn "Une configuration de base existe déjà dans ${GLPI_CONFIG_DIR}."
    local force="n"; ask_yn force "Écraser la configuration ET réinitialiser la base ${DB_NAME} ?"
    is_yes "$force" || die "Arrêt pour ne pas écraser l'installation existante."
    extra+=(--reconfigure --force)
  fi
  console db:install \
    --db-host=localhost --db-name="$DB_NAME" \
    --db-user="$DB_USER" --db-password="$DB_PASS" \
    --default-language="$GLPI_LANG" --no-interaction "${extra[@]}"
  ok "Base GLPI initialisée."

  if is_yes "$ENABLE_TIMEZONES"; then
    if console database:enable_timezones --no-interaction; then
      ok "Fuseaux horaires activés."
    else
      warn "Activation des fuseaux horaires impossible (à refaire : bin/console database:enable_timezones)."
    fi
  fi
}

# ----------------------------------------------------------------------------
# 9. Post-installation
# ----------------------------------------------------------------------------
post_install() {
  title "Post-installation"
  if [[ "$DB_INSTALL_MODE" == "cli" ]]; then
    local hash
    # shellcheck disable=SC2016  # $argv est une variable PHP, pas shell
    hash="$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' -- "$GLPI_ADMIN_PASS")"
    mariadb "$DB_NAME" -e "UPDATE glpi_users SET password='$(sql_escape "$hash")', password_last_update=NOW() WHERE name='glpi';"
    ok "Mot de passe du compte « glpi » modifié."
    if is_yes "$DISABLE_DEFAULT_USERS"; then
      mariadb "$DB_NAME" -e "UPDATE glpi_users SET is_active=0 WHERE name IN ('tech','normal','post-only');"
      ok "Comptes tech, normal et post-only désactivés."
    fi
    rm -f "${GLPI_WEBROOT}/install/install.php"
    ok "install/install.php supprimé."
    console system:check_requirements || warn "Vérifiez les prérequis signalés ci-dessus."
  else
    warn "Après l'assistant web, supprimez install.php : rm ${GLPI_WEBROOT}/install/install.php"
  fi

  if is_yes "$SETUP_CRON"; then
    local cron_php="${GLPI_WEBROOT}/front/cron.php"
    if [[ -f "$cron_php" ]]; then
      cat > /etc/cron.d/glpi <<EOF
# Actions automatiques GLPI (généré par glpi-install.sh)
* * * * * www-data /usr/bin/php ${cron_php} >/dev/null 2>&1
EOF
      chmod 644 /etc/cron.d/glpi
      ok "Cron installé (/etc/cron.d/glpi, toutes les minutes)."
      if [[ "$DB_INSTALL_MODE" == "cli" ]]; then
        # mode 2 = CLI : les actions ne sont plus déclenchées par les visites web
        mariadb "$DB_NAME" -e "UPDATE glpi_crontasks SET mode=2 WHERE state<>0;"
        ok "Actions automatiques passées en mode CLI."
      fi
    else
      warn "${cron_php} introuvable : cron non configuré."
    fi
  fi
}

# ----------------------------------------------------------------------------
# 10. HTTPS (optionnel) et résumé
# ----------------------------------------------------------------------------
summary() {
  local proto="http"
  if is_yes "$SETUP_HTTPS"; then
    if GLPI_FQDN="$GLPI_FQDN" GLPI_WEBROOT="$GLPI_WEBROOT" \
       HTTPS_MODE="${HTTPS_MODE:-}" LE_EMAIL="${LE_EMAIL:-}" "$SCRIPT_DIR/glpi-https.sh"; then
      proto="https"
    else
      warn "La configuration HTTPS a échoué, GLPI reste en HTTP (relancez glpi-https.sh)."
    fi
  fi
  if [[ "$DB_INSTALL_MODE" == "cli" ]]; then
    mariadb "$DB_NAME" -e "UPDATE glpi_configs SET value='${proto}://${GLPI_FQDN}' WHERE context='core' AND name='url_base';"
    ok "URL de l'application réglée sur ${proto}://${GLPI_FQDN}"
  fi
  umask 077
  cat > "$SUMMARY_FILE" <<EOF
Installation GLPI ${GLPI_VERSION} — $(date '+%F %T')
URL                    : ${proto}://${GLPI_FQDN}/
Base de données        : ${DB_NAME}
Utilisateur MariaDB    : ${DB_USER}
Mot de passe MariaDB   : ${DB_PASS}
Compte GLPI super-admin: glpi
Mot de passe "glpi"    : ${GLPI_ADMIN_PASS:-glpi (à changer après l assistant web)}
Code / config / données / logs :
  ${GLPI_WEBROOT} / ${GLPI_CONFIG_DIR} / ${GLPI_VAR_DIR}/files / ${GLPI_LOG_DIR}
EOF
  title "Terminé"
  ok "GLPI ${GLPI_VERSION} est accessible sur ${proto}://${GLPI_FQDN}/"
  local ip
  for ip in ${SERVER_IPS:-}; do info "  ou directement par l'IP : ${proto}://${ip}/"; done
  info "Si le nom ${GLPI_FQDN} ne répond pas (DNS_PROBE_FINISHED_NXDOMAIN), utilisez l'IP"
  info "ou ajoutez « IP ${GLPI_FQDN} » dans le fichier hosts du poste client."
  # Les mots de passe ne sont pas affichés ici pour ne pas finir dans ${LOG_FILE}.
  warn "Identifiants enregistrés dans ${SUMMARY_FILE} (lisible par root uniquement) : cat ${SUMMARY_FILE}"
  warn "Conservez-les dans un coffre-fort de mots de passe puis supprimez ce fichier."
  if [[ "$DB_INSTALL_MODE" == "web" ]]; then
    info "Ouvrez ${proto}://${GLPI_FQDN}/ et suivez l'assistant (serveur SQL : localhost)."
  fi
  info "Pensez à sauvegarder ${GLPI_CONFIG_DIR}/glpicrypt.key : sans elle, les mots de passe chiffrés sont perdus."
}

main() {
  preflight
  questions
  exec > >(tee -a "$LOG_FILE") 2>&1
  install_packages
  setup_mariadb
  download_glpi
  setup_directories
  setup_php
  setup_apache
  install_database
  post_install
  summary
}

main "$@"
