# Image for container end-to-end tests: systemd, nginx, PHP-FPM, MySQL, cron.
# PostgreSQL, PHP 8.4, redis and age are installed by the tests themselves,
# exactly as simai-env would install them on a server.
ARG UBUNTU=24.04
FROM ubuntu:${UBUNTU}
ARG PHP=8.3
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq systemd systemd-sysv nginx \
      php${PHP}-fpm php${PHP}-cli php${PHP}-mysql php${PHP}-curl php${PHP}-mbstring \
      php${PHP}-xml php${PHP}-zip php${PHP}-intl mysql-server acl cron sudo curl \
      openssl rsync python3 perl git >/dev/null && apt-get clean
RUN rm -f /etc/nginx/sites-enabled/default
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
