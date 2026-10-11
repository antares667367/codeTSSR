# Déploiement automatisé de GLPI 11 sur Debian 13

Scripts tirés du tutoriel IT-Connect « Installation pas-à-pas de GLPI 11 sur Debian 13 »
(https://www.it-connect.fr/installation-pas-a-pas-de-glpi-10-sur-debian-12/), automatisés et complétés.

| Fichier | Rôle |
|---|---|
| `glpi-install.sh` | Installation complète, interactive ou automatique |
| `glpi-https.sh` | Passage en HTTPS (Let's Encrypt ou auto-signé), appelable seul ou en fin d'installation |
| `glpi.conf.exemple` | Fichier de réponses pour une installation sans questions |

## Utilisation

```bash
# copier le dossier sur le serveur Debian 13, puis :
chmod +x glpi-install.sh glpi-https.sh
sudo ./glpi-install.sh                       # interactif : chaque question propose une valeur par défaut

# ou entièrement automatique :
cp glpi.conf.exemple glpi.conf && chmod 600 glpi.conf && nano glpi.conf
sudo ./glpi-install.sh -c glpi.conf -y
```

À la fin, les identifiants (MariaDB et compte `glpi`) sont dans `/root/glpi-install-resume.txt`
(lisible par root uniquement). Le journal complet est dans `/var/log/glpi-deploy.log`.

## Ce que fait `glpi-install.sh`

| Étape du tutoriel | Automatisation |
|---|---|
| Mise à jour, Apache, PHP 8.4-FPM, MariaDB | `apt` + contrôle PHP ≥ 8.2 et des extensions obligatoires de GLPI 11 (dont `bcmath`, `mbstring`, `openssl`) |
| Extensions PHP | curl, gd, intl, mysql, zip, bcmath, mbstring, xml, bz2 ; `ldap` et `apcu` en option |
| `mariadb-secure-installation` | Équivalent non interactif en SQL (root reste en authentification par socket) |
| Base + utilisateur | `CREATE DATABASE` utf8mb4 + `CREATE USER` / `GRANT`, mot de passe généré si non fourni |
| Téléchargement GLPI | Dernière version publiée sur GitHub (ou version fixée), repli sur 11.0.4 si GitHub est injoignable |
| `/etc/glpi`, `/var/lib/glpi`, `/var/log/glpi` | Déplacement de `config` et `files`, création de `inc/downstream.php` et `local_define.php` |
| VirtualHost Apache | Vhost du tutoriel (DocumentRoot `/public`, réécriture vers le routeur, PHP-FPM), `000-default` désactivé |
| `php.ini` | Fichier dédié `/etc/php/8.4/fpm/conf.d/99-glpi.ini` : `cookie_httponly`, `cookie_samesite=Lax`, taille d'upload |
| Assistant web | Remplacé par `bin/console db:install` (mode `cli`), ou laissé au navigateur (mode `web`) |
| Post-installation | Nouveau mot de passe du compte `glpi`, comptes `tech`/`normal`/`post-only` désactivés, `install.php` supprimé, `system:check_requirements` |

Ajouts par rapport au tutoriel :

- **Cron** : `/etc/cron.d/glpi` lance `front/cron.php` toutes les minutes et les actions automatiques passent en mode CLI.
- **Fuseaux horaires** : chargement des tables de MariaDB et `bin/console database:enable_timezones`.
- **Permissions plus strictes** : le code dans `/var/www/glpi` appartient à root, seuls `marketplace`, `/etc/glpi`, `/var/lib/glpi` et `/var/log/glpi` sont modifiables par `www-data`. Le tutoriel donne tout `/var/www/glpi` à `www-data`.
- **URL de l'application** renseignée automatiquement dans GLPI (http ou https).

## Ce que fait `glpi-https.sh`

- Let's Encrypt : `certbot --apache --redirect` (le serveur doit être joignable depuis Internet sur le port 80).
- Auto-signé : certificat RSA 4096 dans `/etc/ssl/glpi/`, vhost :443 + redirection depuis :80, en-tête HSTS.
- Dans les deux cas : `session.cookie_secure = On`, comme le tutoriel le recommande une fois en HTTPS.

## Reste à faire à la main

- Dans GLPI, désactiver les données de démonstration si le bandeau est affiché.
- Sauvegarder `/etc/glpi/glpicrypt.key` : sans elle, les mots de passe chiffrés stockés dans GLPI sont perdus.
- Ranger les identifiants de `/root/glpi-install-resume.txt` dans un coffre-fort, puis supprimer ce fichier.

## Limites connues

- Les scripts sont vérifiés avec `bash -n` et `shellcheck`, mais n'ont pas été exécutés sur une vraie Debian 13 : faites un premier essai sur une VM.
- En mode `cli`, le mot de passe MariaDB est passé en argument à `bin/console` et reste visible quelques secondes dans la liste des processus.
- Le nom de la commande `database:enable_timezones` vient de GLPI 10. Si GLPI 11 l'a renommée, le script affiche un avertissement et continue.
