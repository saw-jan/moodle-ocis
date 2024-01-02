#!/bin/bash

export EXTRA_HOST=host.docker.internal

export MOODLE_DOCKER_WWWROOT=$PWD/moodle
export MOODLE_DOCKER_DB=pgsql
export MOODLE_DOCKER_PHP_VERSION=8.1
export MOODLE_DOCKER_WEB_HOST=$EXTRA_HOST
export MOODLE_DOCKER_WEB_PORT=8000
export MOODLE_DOCKER_SELENIUM_VNC_PORT=5900
export MOODLE_DOCKER_BROWSER=chrome

MOODLE_DOCKER_DIR=$PWD/moodle-docker
MOODLE_BRANCH=MOODLE_402_STABLE

MOODLE_COMPOSE_CMD=$MOODLE_DOCKER_DIR/bin/moodle-docker-compose
MOODLE_DB_WAIT_CMD=$MOODLE_DOCKER_DIR/bin/moodle-docker-wait-for-db

# check docker compose version
# REQUIRED: >=2.19
docker_compose_version=$(docker compose version --short)
major=$(echo "$docker_compose_version" | cut -d. -f1)
minor=$(echo "$docker_compose_version" | cut -d. -f2)
if [ "$major" != "2" ] || [ "$minor" -lt "19" ]; then
    echo "[ERR] docker compose >=2.19 is REQUIRED, but found $docker_compose_version"
    exit 1
fi

# check extra hosts
match=$(grep "$EXTRA_HOST" /etc/hosts)
if [ "$match" == "" ] || echo "$match" | grep -q '#'; then
    echo "Adding '$EXTRA_HOST' to /etc/hosts"
    echo -e "127.0.0.1	$EXTRA_HOST" | sudo tee -a /etc/hosts >/dev/null
fi

# check ocis certs
OCIS_CERTS_DIR=$PWD/ocis/certs
if [ ! -f "$OCIS_CERTS_DIR"/ocis.crt ] || [ ! -f "$OCIS_CERTS_DIR"/ocis.pem ]; then
    rm -rf "$OCIS_CERTS_DIR"
    mkdir -p "$OCIS_CERTS_DIR"
    openssl req -x509 -newkey rsa:2048 -keyout "$OCIS_CERTS_DIR"/ocis.pem -out "$OCIS_CERTS_DIR"/ocis.crt -nodes -days 365 -subj "/CN=$EXTRA_HOST"
fi

# moodle setup
if [ ! -d "$MOODLE_DOCKER_WWWROOT" ]; then
    git clone https://github.com/moodle/moodle.git --branch "$MOODLE_BRANCH" --single-branch --depth=1
    cd moodle/repository/ || exit
    git clone https://github.com/owncloud/moodle-repository_ocis.git ocis
    cd ../../ || exit
fi
if [ ! -d "$MOODLE_DOCKER_DIR" ]; then
    git clone https://github.com/moodlehq/moodle-docker.git
fi
if [ ! -f "$MOODLE_DOCKER_WWWROOT/config.php" ]; then
    cp "$MOODLE_DOCKER_DIR"/config.docker-template.php "$MOODLE_DOCKER_WWWROOT"/config.php
    sed -i 's/"http:\/\/{$host}";/"https:\/\/{$host}";\n\t$CFG->sslproxy = true;/g' "$MOODLE_DOCKER_WWWROOT"/config.php
fi

if [ ! -f "$MOODLE_DOCKER_DIR/local.yml" ]; then
    cat >"$MOODLE_DOCKER_DIR/local.yml" <<EOF
services:
  webserver:
    labels:
      traefik.enable: true
      traefik.http.routers.webserver.tls: true
      traefik.http.routers.webserver.rule: Host(\`$EXTRA_HOST\`)
      traefik.http.routers.webserver.entrypoints: websecure
      traefik.http.services.webserver.loadbalancer.server.port: 80
    ports: !reset [] # reset port mapping
    extra_hosts:
      - $EXTRA_HOST:host-gateway
    environment:
      MOODLE_DISABLE_CURL_SECURITY: true
      MOODLE_OCIS_URL: https://$EXTRA_HOST:9200
      MOODLE_OCIS_CLIENT_ID: sdk
      MOODLE_OCIS_CLIENT_SECRET: UBntmLjC2yYCeHwsyj73Uwo9TAaecAetRwMw0xYcvNL9yRdLSUi0hUAHfvCHFeFh

  selenium:
    extra_hosts:
      - $EXTRA_HOST:host-gateway

  traefik:
    image: traefik:v2.9.1
    command:
      - '--pilot.dashboard=false'
      - '--log.level=ERROR'
      - '--api.dashboard=true'
      - '--api.insecure=true'
      - '--providers.docker=true'
      - '--providers.docker.exposedbydefault=false'
      - '--entrypoints.web.address=:80'
      - '--entrypoints.websecure.address=:443'
      - '--entrypoints.websecure.http.middlewares=https_config@docker'
      - '--entrypoints.websecure.http.tls.options=default'
    labels:
      traefik.enable: true
      traefik.http.routers.http_catchall.middlewares: https_config
      traefik.http.middlewares.https_config.headers.sslRedirect: true
    ports:
      - 8000:443
      - 8080:8080 # traefik dashboard
    extra_hosts:
      - $EXTRA_HOST:host-gateway
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF
fi

# cleanup
docker compose -f ocis/ocis.yml down -v
"$MOODLE_COMPOSE_CMD" down -v

# early exit if we are shutting down
if [ "$1" == "down" ]; then
    exit 0
fi

# start moodle services
"$MOODLE_COMPOSE_CMD" up -d

"$MOODLE_COMPOSE_CMD" cp "$OCIS_CERTS_DIR"/ocis.crt webserver:/usr/local/share/ca-certificates/
"$MOODLE_COMPOSE_CMD" exec webserver update-ca-certificates

# start ocis
docker compose -f ocis/ocis.yml up -d
timeout=30
start_time=$(date +%s)
while [ "$(curl -sk https://$EXTRA_HOST:9200/ocs/v1.php/cloud/capabilities -w %\{http_code\} -o /dev/null)" != "200" ]; do
    curr_time=$(date +%s)
    elapsed_time=$(($curr_time - $start_time))
    if [ $elapsed_time -gt $timeout ]; then
        echo "[ERR] ocis was not ready after $timeout seconds"
        exit 1
    fi
    sleep 1
done

# install moodle
"$MOODLE_DB_WAIT_CMD"
"$MOODLE_COMPOSE_CMD" exec webserver \
    php admin/cli/install_database.php \
    --agree-license \
    --fullname="Docker moodle" \
    --shortname="docker_moodle" \
    --summary="Docker moodle site" \
    --adminpass="admin" \
    --adminemail="admin@example.com"

# configure HTTP security
"$MOODLE_COMPOSE_CMD" exec webserver php admin/cli/cfg.php --name=curlsecurityblockedhosts --set=""
"$MOODLE_COMPOSE_CMD" exec webserver php admin/cli/cfg.php --name=curlsecurityallowedport --set="9200"

# init behat tests
# uncomment the following line if you want to run behat tests
# "$MOODLE_COMPOSE_CMD" exec webserver php admin/tool/behat/cli/init.php
