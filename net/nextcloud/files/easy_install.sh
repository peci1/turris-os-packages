#!/bin/sh

echo "This script will setup Nextcloud for you automatically."
echo "It will try to create MySQL database, change files on your filesystem and more."
echo "If you know what you are doing, you can set it up manually."
echo "This script is meant to help beginners to get started fast."
echo
echo "If you are sure you want to continue with simplified automatic setup, type uppercase yes"
echo
read answer
if [ $answer \!= YES ]; then
    echo "You decided not to proceed, so not doing anything"
    exit 0
fi

# Enable dependencies
/etc/init.d/mysqld start
/etc/init.d/mysqld enable
/etc/init.d/php7-fpm start
/etc/init.d/php7-fpm enable
/etc/init.d/lighttpd restart

DELAY=5

# Make sure we have passwords at hand
DBPASS="`head -c 128 /dev/urandom | tr -dc _A-Z-a-z-0-9`"
if [ -z "$1" ]; then
    echo "What should be admins login?"
    read ALOGIN
else
    ALOGIN="$1"
fi
if [ -z "$2" ]; then
    echo "What should be admins password?"
    read APASS
else
    APASS="$2"
fi

# Hack MySQL database
/etc/init.d/mysqld stop 2> /dev/null
sleep $DELAY
sudo -u mysql mysqld --skip-networking --skip-grant-tables --socket=/tmp/mysql_nextcloud.sock > /dev/null 2>&1 &
PID="$!"
sleep $DELAY
echo "
CREATE DATABASE nextcloud; \
FLUSH PRIVILEGES;
CREATE USER 'nextcloud'@'localhost' IDENTIFIED BY '$DBPASS'; \
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';
" | mysql -u root -B --socket=/tmp/mysql_nextcloud.sock
sleep 5
kill "$PID"
i=0
while [ "$i" -lt 60 ] && [ -n "`grep mysql /proc/$PID/cmdline 2> /dev/null`" ]; do
  sleep 1
  [ "$i" -lt 30 ] || kill "$PID"
done
if [ -n "`grep mysql /proc/$PID/cmdline 2> /dev/null`" ]; then
  kill -9 "$PID"
fi
/etc/init.d/mysqld start 2> /dev/null
sleep $DELAY

# Setup the server
cd /srv/www/nextcloud
sudo -u nobody php-cli ./occ maintenance:install --database=mysql --database-name=nextcloud --database-user=nextcloud --admin-user="$ALOGIN" --admin-pass="$APASS" --database-pass="$DBPASS" --database-host=127.0.0.1 --database-port=3306 --no-interaction
IP="`uci -q get network.lan.ipaddr`"
if [ -z "$IP" ]; then
    echo "Autodetection of your router IP failed, what is your routers IP address?"
    read IP
fi
sudo -u nobody php-cli ./occ config:system:set --value $IP trusted_domains 1

/etc/init.d/php7-fpm restart
/etc/init.d/lighttpd restart

echo "Your Nextcloud installation should be available at http://$IP/nextcloud"
echo "Your username is '$ALOGIN' and password '$APASS'"
