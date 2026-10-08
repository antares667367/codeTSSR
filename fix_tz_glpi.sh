#!/usr/bin/env bash
# =============================================================================
#  glpi_fix_timezone.sh
#  Script interactif : corrige le décalage horaire d'un serveur GLPI 10/11
#   1. Fuseau horaire du système Linux + NTP
#   2. date.timezone dans PHP (apache2 / fpm / cli)
#   3. Chargement des fuseaux horaires dans MariaDB/MySQL
#   4. Droit SELECT sur mysql.time_zone_name pour l'utilisateur GLPI
#   5. php bin/console database:enable_timezones (en utilisateur web)
#   6. Fuseau par défaut dans la configuration GLPI
#   THOMAS ALDEGUER 2026
#  Usage : sudo bash glpi_fix_timezone.sh [-y]
#     -y : répond « oui » à toutes les questions (mode non interactif)
# =============================================================================

set -u

# ---------- Apparence & helpers ---------------------------------------------
R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; BOLD=$'\e[1m'; N=$'\e[0m'
LOG="/var/log/glpi_fix_timezone_$(date +%Y%m%d_%H%M%S).log"
AUTO_YES=0
[[ "${1:-}" == "-y" ]] && AUTO_YES=1

log()   { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
info()  { echo "${B}ℹ${N}  $*"; log "INFO  $*"; }
ok()    { echo "${G}✔${N}  $*"; log "OK    $*"; }
warn()  { echo "${Y}⚠${N}  $*"; log "WARN  $*"; }
err()   { echo "${R}✘${N}  $*"; log "ERROR $*"; }
title() { echo; echo "${BOLD}${B}=== $* ===${N}"; log "=== $* ==="; }

ask_yes_no() {   # ask_yes_no "Question" [défaut o/n]
    local q="$1" def="${2:-o}" rep
    if (( AUTO_YES )); then return 0; fi
    local hint="[O/n]"; [[ "$def" == "n" ]] && hint="[o/N]"
    read -rp "${Y}?${N}  $q $hint " rep
    rep="${rep:-$def}"
    [[ "${rep,,}" =~ ^(o|oui|y|yes)$ ]]
}

ask_value() {    # ask_value "Question" "valeur par défaut" -> echo réponse
    local q="$1" def="$2" rep
    if (( AUTO_YES )); then echo "$def"; return; fi
    read -rp "${Y}?${N}  $q [${def}] " rep
    echo "${rep:-$def}"
}

# ---------- Vérifications initiales -----------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "${R}Ce script doit être lancé avec sudo :${N} sudo bash $0"
    exit 1
fi
touch "$LOG" 2>/dev/null || LOG="/tmp/glpi_fix_timezone.log"

echo "${BOLD}Correction du fuseau horaire GLPI${N}  (journal : $LOG)"

# ---------- 0. Détection de l'environnement ---------------------------------
title "0. Détection de l'environnement"

# Dossier GLPI
GLPI_DIR=""
for d in /var/www/html/glpi /var/www/glpi /usr/share/glpi /srv/www/glpi; do
    [[ -f "$d/bin/console" ]] && { GLPI_DIR="$d"; break; }
done
if [[ -z "$GLPI_DIR" ]]; then
    found=$(find / -type f -path "*/bin/console" -path "*glpi*" 2>/dev/null | head -1)
    [[ -n "$found" ]] && GLPI_DIR="$(dirname "$(dirname "$found")")"
fi
GLPI_DIR=$(ask_value "Dossier de GLPI" "${GLPI_DIR:-/var/www/html/glpi}")
if [[ ! -f "$GLPI_DIR/bin/console" ]]; then
    err "bin/console introuvable dans $GLPI_DIR"; exit 1
fi
ok "GLPI : $GLPI_DIR"

# Fichier config_db.php
CONF_DB=""
for f in /etc/glpi/config_db.php "$GLPI_DIR/config/config_db.php"; do
    [[ -f "$f" ]] && { CONF_DB="$f"; break; }
done
[[ -z "$CONF_DB" ]] && CONF_DB=$(find / -name config_db.php -path "*glpi*" 2>/dev/null | head -1)
CONF_DB=$(ask_value "Fichier config_db.php" "${CONF_DB:-/etc/glpi/config_db.php}")
if [[ ! -f "$CONF_DB" ]]; then
    err "config_db.php introuvable"; exit 1
fi

get_conf() { sed -n "s/.*\$$1[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" "$CONF_DB" | head -1; }
DB_USER=$(get_conf dbuser)
DB_HOST=$(get_conf dbhost)
DB_NAME=$(get_conf dbdefault)
ok "Base : utilisateur=${BOLD}$DB_USER${N}  hôte=${BOLD}$DB_HOST${N}  base=${BOLD}$DB_NAME${N}"

DB_LOCAL=1
case "${DB_HOST%%:*}" in
    localhost|127.0.0.1|::1|"") DB_LOCAL=1 ;;
    *) DB_LOCAL=0; warn "La base est sur une autre machine ($DB_HOST) : les étapes 3 et 4 devront y être faites." ;;
esac

# Utilisateur du serveur web
WEB_USER=""
for u in www-data apache nginx wwwrun; do
    id "$u" &>/dev/null && { WEB_USER="$u"; break; }
done
WEB_USER=$(ask_value "Utilisateur du serveur web" "${WEB_USER:-www-data}")
ok "Utilisateur web : $WEB_USER"

# Client SQL & outil tzinfo
if command -v mariadb &>/dev/null; then SQL=mariadb; else SQL=mysql; fi
if   command -v mariadb-tzinfo-to-sql &>/dev/null; then TZ2SQL=mariadb-tzinfo-to-sql
elif command -v mysql_tzinfo_to_sql   &>/dev/null; then TZ2SQL=mysql_tzinfo_to_sql
else TZ2SQL=""; fi

# Service web / base
WEB_SVC=""; for s in apache2 httpd nginx; do systemctl list-unit-files "$s.service" &>/dev/null \
    && systemctl list-unit-files "$s.service" | grep -q "$s" && { WEB_SVC="$s"; break; }; done
DB_SVC="";  for s in mariadb mysql mysqld; do systemctl list-unit-files "$s.service" 2>/dev/null \
    | grep -q "^$s" && { DB_SVC="$s"; break; }; done
FPM_SVCS=$(systemctl list-unit-files 2>/dev/null | awk '/php.*fpm\.service/{print $1}')

# Accès root à la base
SQL_ROOT=("$SQL" -u root)
sql_root() { "${SQL_ROOT[@]}" "$@"; }
if (( DB_LOCAL )); then
    if ! sql_root -e "SELECT 1" &>/dev/null; then
        read -rsp "${Y}?${N}  Mot de passe root MariaDB/MySQL : " DBPW; echo
        export MYSQL_PWD="$DBPW"
        if ! sql_root -e "SELECT 1" &>/dev/null; then
            err "Connexion root à la base impossible."; exit 1
        fi
    fi
    ok "Connexion root à la base : OK"
fi

TZ_TARGET=$(ask_value "Fuseau horaire souhaité" "Europe/Paris")
if [[ ! -f "/usr/share/zoneinfo/$TZ_TARGET" ]]; then
    warn "/usr/share/zoneinfo/$TZ_TARGET absent."
    if ask_yes_no "Installer le paquet tzdata ?"; then
        if command -v apt-get &>/dev/null; then apt-get install -y tzdata >>"$LOG" 2>&1
        else dnf install -y tzdata >>"$LOG" 2>&1 || yum install -y tzdata >>"$LOG" 2>&1; fi
    fi
    [[ -f "/usr/share/zoneinfo/$TZ_TARGET" ]] || { err "Fuseau $TZ_TARGET inconnu."; exit 1; }
fi

# ---------- 1. Système -------------------------------------------------------
title "1. Fuseau horaire du système"
CUR_TZ=$(timedatectl show -p Timezone --value 2>/dev/null)
info "Actuel : ${CUR_TZ:-inconnu}  —  Heure : $(date)"
if [[ "$CUR_TZ" != "$TZ_TARGET" ]] && ask_yes_no "Passer le système en $TZ_TARGET ?"; then
    timedatectl set-timezone "$TZ_TARGET" && ok "Système réglé sur $TZ_TARGET"
else
    [[ "$CUR_TZ" == "$TZ_TARGET" ]] && ok "Déjà correct"
fi
if ask_yes_no "Activer la synchronisation NTP ?"; then
    timedatectl set-ntp true 2>>"$LOG" && ok "NTP activé" || warn "NTP non activé (voir journal)"
fi

# ---------- 2. PHP -----------------------------------------------------------
title "2. date.timezone dans PHP"
mapfile -t PHP_INIS < <(ls /etc/php/*/{apache2,fpm,cli}/php.ini /etc/php.ini 2>/dev/null)
if (( ${#PHP_INIS[@]} == 0 )); then
    warn "Aucun php.ini trouvé."
else
    for ini in "${PHP_INIS[@]}"; do
        cur=$(grep -E '^[[:space:]]*date\.timezone' "$ini" | head -1)
        info "$ini → ${cur:-non défini}"
    done
    if ask_yes_no "Écrire date.timezone = $TZ_TARGET dans ces fichiers (avec sauvegarde) ?"; then
        for ini in "${PHP_INIS[@]}"; do
            cp -a "$ini" "$ini.bak.$(date +%s)"
            if grep -qE '^[;[:space:]]*date\.timezone' "$ini"; then
                sed -i -E "s|^[;[:space:]]*date\.timezone[[:space:]]*=.*|date.timezone = $TZ_TARGET|" "$ini"
            else
                printf '\n[Date]\ndate.timezone = %s\n' "$TZ_TARGET" >> "$ini"
            fi
            ok "$ini mis à jour"
        done
        for s in $WEB_SVC $FPM_SVCS; do
            systemctl restart "$s" && ok "Service $s redémarré" || warn "Redémarrage de $s impossible"
        done
    fi
fi

# ---------- 3. Fuseaux dans la base -----------------------------------------
title "3. Fuseaux horaires dans MariaDB/MySQL"
if (( ! DB_LOCAL )); then
    warn "Base distante : à faire sur $DB_HOST :"
    echo "    mariadb-tzinfo-to-sql /usr/share/zoneinfo | sudo mariadb -u root mysql"
else
    COUNT=$(sql_root -N -e "SELECT COUNT(*) FROM mysql.time_zone_name;" 2>/dev/null || echo 0)
    info "Fuseaux actuellement chargés : $COUNT"
    if (( COUNT == 0 )) || ask_yes_no "Recharger les fuseaux quand même ?" n; then
        if [[ -z "$TZ2SQL" ]]; then
            err "Ni mariadb-tzinfo-to-sql ni mysql_tzinfo_to_sql trouvés."
        else
            info "Chargement via $TZ2SQL (des 'Skipping it' sont normaux)…"
            "$TZ2SQL" /usr/share/zoneinfo 2>>"$LOG" | sql_root mysql 2>>"$LOG"
            COUNT=$(sql_root -N -e "SELECT COUNT(*) FROM mysql.time_zone_name;" 2>/dev/null || echo 0)
            (( COUNT > 0 )) && ok "$COUNT fuseaux chargés" || err "Échec du chargement (voir $LOG)"
        fi
    fi

# ---------- 4. Droits --------------------------------------------------------
    title "4. Droit SELECT pour l'utilisateur GLPI"
    mapfile -t HOSTS < <(sql_root -N -e "SELECT Host FROM mysql.user WHERE User='$DB_USER';" 2>/dev/null)
    if (( ${#HOSTS[@]} == 0 )); then
        warn "Utilisateur '$DB_USER' introuvable dans mysql.user"
        HOSTS=("$(ask_value "Hôte du compte GLPI" "localhost")")
    fi
    info "Comptes trouvés : $(printf "'$DB_USER'@'%s' " "${HOSTS[@]}")"
    if ask_yes_no "Accorder SELECT sur mysql.time_zone_name ?"; then
        for h in "${HOSTS[@]}"; do
            sql_root -e "GRANT SELECT ON mysql.time_zone_name TO '$DB_USER'@'$h';" 2>>"$LOG" \
                && ok "GRANT pour '$DB_USER'@'$h'" || err "GRANT échoué pour '$DB_USER'@'$h'"
        done
        sql_root -e "FLUSH PRIVILEGES;"
        [[ -n "$DB_SVC" ]] && systemctl restart "$DB_SVC" && ok "Service $DB_SVC redémarré"
    fi
fi

# ---------- 5. Activation dans GLPI -----------------------------------------
title "5. Activation des fuseaux dans GLPI"
if ask_yes_no "Lancer database:enable_timezones en tant que $WEB_USER ?"; then
    if (cd "$GLPI_DIR" && sudo -u "$WEB_USER" php bin/console database:enable_timezones --no-interaction) 2>&1 | tee -a "$LOG"; then
        ok "Commande exécutée (vérifiez le message ci-dessus)"
    else
        err "La commande a échoué (voir ci-dessus)"
    fi
fi

# ---------- 6. Fuseau par défaut GLPI ---------------------------------------
title "6. Fuseau par défaut dans GLPI"
if ask_yes_no "Définir $TZ_TARGET comme fuseau par défaut de GLPI ?"; then
    if (cd "$GLPI_DIR" && sudo -u "$WEB_USER" php bin/console config:set timezone "$TZ_TARGET") >>"$LOG" 2>&1; then
        ok "Fuseau GLPI réglé sur $TZ_TARGET"
    else
        warn "Impossible via la console : faites-le dans l'interface :"
        echo "    Configuration → Générale → Valeurs par défaut → Fuseau horaire = $TZ_TARGET"
    fi
fi

# ---------- Récapitulatif ----------------------------------------------------
title "Récapitulatif"
echo "  Système : $(timedatectl show -p Timezone --value 2>/dev/null)  —  $(date)"
echo "  PHP CLI : $(php -r 'echo ini_get("date.timezone") ?: "non défini";')"
(( DB_LOCAL )) && echo "  Base    : $(sql_root -N -e 'SELECT COUNT(*) FROM mysql.time_zone_name;' 2>/dev/null) fuseaux chargés"
echo
echo "${BOLD}À faire ensuite :${N}"
echo "  • Mes préférences (GLPI) → fuseau horaire $TZ_TARGET ou valeur par défaut"
echo "  • Sur chaque VM : http://localhost:62354 → Force an Inventory"
echo "  • Comparer « Dernier inventaire » dans GLPI avec l'heure réelle"
echo
echo "Journal complet : $LOG"
