ARG BUILD_FROM=ghcr.io/hassio-addons/base:15.0.7
FROM ${BUILD_FROM}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Outils nécessaires
RUN apk add --no-cache \
    bash \
    jq \
    tzdata \
    nodejs-lts \
    npm \
  || apk add --no-cache \
    bash \
    jq \
    tzdata \
    "nodejs~22" \
    "npm~10"

# Node-RED 4.x
RUN npm install -g node-red@4.1.4 \
  && npm cache clean --force

# Dépendances Node-RED utiles au module
# - home assistant websocket / http
# - traitements divers
WORKDIR /opt
RUN npm i --omit=dev --no-audit --no-fund \
    node-red-contrib-home-assistant-websocket \
  && npm cache clean --force

# Add-on
COPY . /addon
RUN chmod a+x /addon/run.sh

WORKDIR /addon
ENTRYPOINT ["/addon/run.sh"]
