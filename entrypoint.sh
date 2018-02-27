#!/bin/sh

function fixperms() {
  for folder in /data/config /data/data /data/session /data/tmp /data/userapps /tpls/data /var/lib/nginx /var/tmp/nginx /var/www; do
    if $(find ${folder} ! -user $1 -o ! -group $2 | egrep '.' -q); then
      echo "Fixing permissions in $folder..."
      chown -R $1.$2 "${folder}"
    else
      echo "Permissions already fixed in ${folder}."
    fi
  done
}

USERNAME=${USERNAME:-"docker"}
PUID=${PUID:-1000}
PGID=${PGID:-1000}
TZ=${TZ:-"UTC"}
MEMORY_LIMIT=${MEMORY_LIMIT:-"256M"}
UPLOAD_MAX_SIZE=${UPLOAD_MAX_SIZE:-"512M"}
OPCACHE_MEM_SIZE=${OPCACHE_MEM_SIZE:-"128"}
APC_SHM_SIZE=${APC_SHM_SIZE:-"128M"}
HSTS_HEADER=${HSTS_HEADER:-"max-age=15768000; includeSubDomains"}

DB_TYPE=${DB_TYPE:-"sqlite"}
DB_HOST=${DB_HOST:-"db"}
DB_NAME=${DB_NAME:-"nextcloud"}
DB_USER=${DB_USER:-"nextcloud"}
DB_PASSWORD=${DB_PASSWORD:-"asupersecretpassword"}

SSMTP_PORT=${SSMTP_PORT:-"25"}
SSMTP_HOSTNAME=${SSMTP_HOSTNAME:-"$(hostname -f)"}
SSMTP_TLS=${SSMTP_TLS:-"NO"}

# Timezone
echo "Setting timezone to ${TZ}..."
ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime
echo ${TZ} > /etc/timezone

# Create docker user
echo "Creating ${USERNAME} user and group (uid=${PUID} ; gid=${PGID})..."
addgroup -g ${PGID} ${USERNAME}
adduser -D -s /bin/sh -G ${USERNAME} -u ${PUID} ${USERNAME}

# PHP
echo "Setting PHP-FPM configuration..."
sed -e "s/@MEMORY_LIMIT@/$MEMORY_LIMIT/g" \
  -e "s/@UPLOAD_MAX_SIZE@/$UPLOAD_MAX_SIZE/g" \
  /tpls/etc/php7/php-fpm.d/www.conf > /etc/php7/php-fpm.d/www.conf

# OpCache
echo "Setting OpCache configuration..."
sed -e "s/@OPCACHE_MEM_SIZE@/$OPCACHE_MEM_SIZE/g" \
  /tpls/etc/php7/conf.d/opcache.ini > /etc/php7/conf.d/opcache.ini

# APCu
echo "Setting APCu configuration..."
sed -e "s/@APC_SHM_SIZE@/$APC_SHM_SIZE/g" \
  /tpls/etc/php7/conf.d/apcu.ini > /etc/php7/conf.d/apcu.ini

# Nginx
echo "Setting Nginx configuration..."
sed -e "s/@UPLOAD_MAX_SIZE@/$UPLOAD_MAX_SIZE/g" \
  -e "s/@HSTS_HEADER@/$HSTS_HEADER/g" \
  /tpls/etc/nginx/nginx.conf > /etc/nginx/nginx.conf

# SSMTP
echo "Setting SSMTP configuration..."
if [ -z "$SSMTP_HOST" ] ; then
  echo "WARNING: SSMTP_HOST must be defined if you want to send emails"
  cp -f /etc/ssmtp/ssmtp.conf.or /etc/ssmtp/ssmtp.conf
else
  cat > /etc/ssmtp/ssmtp.conf <<EOL
mailhub=${SSMTP_HOST}:${SSMTP_PORT}
hostname=${SSMTP_HOSTNAME}
FromLineOverride=YES
AuthUser=${SSMTP_USER}
AuthPass=${SSMTP_PASSWORD}
UseTLS=${SSMTP_TLS}
UseSTARTTLS=${SSMTP_TLS}
EOL
fi

# Init Nextcloud
echo "Initializing Nextcloud files / folders..."
mkdir -p /data/config /data/data /data/session /data/tmp /data/userapps /etc/supervisord /var/log/supervisord
if [ ! -d /data/themes ]; then
  if [ -d /var/www/themes ]; then
    mv -f /var/www/themes /data/
  fi
  mkdir -p /data/themes
elif [ -d /var/www/themes ]; then
  rm -rf /var/www/themes
fi
ln -sf /data/config/config.php /var/www/config/config.php &>/dev/null
ln -sf /data/themes /var/www/themes &>/dev/null
ln -sf /data/userapps /var/www/userapps &>/dev/null

# Install Nextcloud if config not found
firstInstall=0
if [ ! -f /data/config/config.php ]; then
  # https://docs.nextcloud.com/server/12/admin_manual/configuration_server/automatic_configuration.html
  firstInstall=1
  echo "Creating automatic configuration..."
  cat > /var/www/config/autoconfig.php <<EOL
<?php
\$AUTOCONFIG = array(
    'directory' => '/data/data',
    'dbtype' => '${DB_TYPE}',
    'dbname' => '${DB_NAME}',
    'dbuser' => '${DB_USER}',
    'dbpass' => '${DB_PASSWORD}',
    'dbhost' => '${DB_HOST}',
    'dbtableprefix' => '',
);
EOL
  sed -e "s#@TZ@#$TZ#g" /tpls/data/config/config.php > /data/config/config.php
  chown -R ${PUID}.${PGID} /data /var/lib/nginx /var/tmp/nginx /var/www

  echo "Installing Nextcloud ${NEXTCLOUD_VERSION}..."
  su - ${USERNAME} -s /bin/sh -c "cd /var/www && php index.php &>/dev/null"
else
  fixperms ${PUID} ${PGID}
fi

# Upgrade Nextcloud if installed
if [ "$(occ status --no-ansi | grep 'installed: true')" != "" ]; then
  echo "Upgrading Nextcloud..."
  occ upgrade --no-ansi
fi

# Override several config values of Nextcloud
echo "Bootstrapping configuration..."
su - ${USERNAME} -s /bin/sh -c "php -f /tpls/bootstrap.php" > /tmp/config.php
mv /tmp/config.php /data/config/config.php
sed -i -e "s#@TZ@#$TZ#g" /data/config/config.php

# Sidecar cron container ?
if [ "$1" == "/usr/local/bin/cron" ]; then
  echo ">>"
  echo ">> Sidecar cron container detected for Nextcloud"
  echo ">>"

  # Init
  rm -rf ${CRONTAB_PATH}
  mkdir -m 0644 -p ${CRONTAB_PATH}
  touch ${CRONTAB_PATH}/${USERNAME}

  # Cron
  if [ ! -z "$CRON_PERIOD" ]; then
    echo "Creating Nextcloud cron task with the following period fields : $CRON_PERIOD"
    printf "${CRON_PERIOD} php -f /var/www/cron.php" >> ${CRONTAB_PATH}/${USERNAME}
  else
    echo "CRON_PERIOD env var empty..."
  fi

  # Fix perms
  chmod -R 0644 ${CRONTAB_PATH}
  fixperms ${PUID} ${PGID}
else
  # Fix perms
  fixperms ${PUID} ${PGID}

  # First install ?
  if [ ${firstInstall} ]; then
    echo ">>"
    echo ">> Open your browser to configure your admin account"
    echo ">>"
  fi
fi

exec "$@"
