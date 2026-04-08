#!/usr/bin/env bash
set -euo pipefail

echo "### RUN.SH SMART ENERGY FINANCE START ###"

if [ -f /usr/lib/bashio/bashio.sh ]; then
  # shellcheck disable=SC1091
  source /usr/lib/bashio/bashio.sh
  logi(){ bashio::log.info "$1"; }
  logw(){ bashio::log.warning "$1"; }
  loge(){ bashio::log.error "$1"; }
else
  logi(){ echo "[INFO] $1"; }
  logw(){ echo "[WARN] $1"; }
  loge(){ echo "[ERROR] $1"; }
fi

logi "Smart Energy Finance: init..."

OPTS="/data/options.json"
TMP="/data/flows.tmp.json"
INSTANCE_FILE="/data/smart_energy_finance_instance_id"
ADDON_DATA_DIR="/data/smart-energy-finance"
DASHBOARDS_DIR="/config/dashboards"

if [ ! -f "$OPTS" ]; then
  loge "options.json introuvable dans /data. Stop."
  exit 1
fi

# ============================================================
# HELPERS
# ============================================================
jq_str_or() {
  local jq_expr="$1"
  local fallback="$2"
  jq -r "($jq_expr // \"\") | if (type==\"string\" and length>0) then . else \"$fallback\" end" "$OPTS"
}

jq_num_or() {
  local jq_expr="$1"
  local fallback="$2"
  jq -r "($jq_expr // $fallback) | tonumber" "$OPTS" 2>/dev/null || echo "$fallback"
}

trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

bool_or_false() {
  local jq_expr="$1"
  jq -r "($jq_expr // false) | if . == true then \"true\" else \"false\" end" "$OPTS"
}

timezone_exists() {
  local tz="$1"
  [ -n "$tz" ] && [ -f "/usr/share/zoneinfo/$tz" ]
}

normalize_timezone() {
  local raw tz upper offset sign hours

  raw="$(trim "${1:-}")"
  [ -z "$raw" ] && { echo "UTC"; return; }

  tz="$raw"
  upper="$(printf '%s' "$tz" | tr '[:lower:]' '[:upper:]')"

  case "$upper" in
    UTC|ETC/UTC|GMT) echo "UTC"; return ;;
    EUROPE/FRANCE|FRANCE) echo "Europe/Paris"; return ;;
    BELGIUM) echo "Europe/Brussels"; return ;;
    GERMANY) echo "Europe/Berlin"; return ;;
    SPAIN) echo "Europe/Madrid"; return ;;
    ITALY) echo "Europe/Rome"; return ;;
    UK|ENGLAND|BRITAIN|GREAT\ BRITAIN) echo "Europe/London"; return ;;
    SOUTH\ AFRICA|AFRICA/SOUTH\ AFRICA|JOHANNESBURG) echo "Africa/Johannesburg"; return ;;
    MOROCCO) echo "Africa/Casablanca"; return ;;
    NEW\ YORK|US/EASTERN|EST) echo "America/New_York"; return ;;
    CHICAGO|US/CENTRAL|CST) echo "America/Chicago"; return ;;
    LOS\ ANGELES|US/PACIFIC|PST) echo "America/Los_Angeles"; return ;;
    MONTREAL) echo "America/Montreal"; return ;;
    DUBAI|UAE) echo "Asia/Dubai"; return ;;
    TOKYO|JAPAN) echo "Asia/Tokyo"; return ;;
    SYDNEY) echo "Australia/Sydney"; return ;;
  esac

  if printf '%s' "$upper" | grep -Eq '^(UTC|GMT)[[:space:]]*[+-][0-9]{1,2}(:00)?$'; then
    offset="$(printf '%s' "$upper" | sed -E 's/^(UTC|GMT)[[:space:]]*([+-][0-9]{1,2})(:00)?$/\2/')"
    sign="${offset:0:1}"
    hours="${offset:1}"
    hours="$(printf '%d' "$hours" 2>/dev/null || echo "")"
    if [ -n "$hours" ] && [ "$hours" -ge 0 ] && [ "$hours" -le 14 ]; then
      if [ "$sign" = "+" ]; then
        echo "Etc/GMT-$hours"
      else
        echo "Etc/GMT+$hours"
      fi
      return
    fi
  fi

  if printf '%s' "$upper" | grep -Eq '^[+-][0-9]{1,2}$'; then
    sign="${upper:0:1}"
    hours="${upper:1}"
    hours="$(printf '%d' "$hours" 2>/dev/null || echo "")"
    if [ -n "$hours" ] && [ "$hours" -ge 0 ] && [ "$hours" -le 14 ]; then
      if [ "$sign" = "+" ]; then
        echo "Etc/GMT-$hours"
      else
        echo "Etc/GMT+$hours"
      fi
      return
    fi
  fi

  echo "$tz"
}

validate_timezone_or_fallback() {
  local tz="$1"
  if timezone_exists "$tz"; then
    echo "$tz"
  else
    echo "UTC"
  fi
}

patch_flow_global_env() {
  local key="$1"
  local value="$2"

  jq \
    --arg k "$key" \
    --arg v "$value" \
    '
    map(
      if .type=="tab"
      then .
      else .
      end
    )
    ' /data/flows.json > "$TMP" && mv "$TMP" /data/flows.json

  # volontairement vide pour le moment :
  # les variables sont surtout passées via env + Node-RED settings.
  return 0
}

# ============================================================
# PREMIUM
# ============================================================
if [ ! -f "$INSTANCE_FILE" ]; then
  cat /proc/sys/kernel/random/uuid > "$INSTANCE_FILE"
  logi "Premium: nouvel install_id généré"
fi

SMART_ENERGY_FINANCE_INSTALL_ID="$(tr -d '\n\r' < "$INSTANCE_FILE")"
SMART_ENERGY_FINANCE_PREMIUM_KEY="$(jq -r '.premium_key // ""' "$OPTS")"

export SMART_ENERGY_FINANCE_INSTALL_ID
export SMART_ENERGY_FINANCE_PREMIUM_KEY

logi "Premium install_id: $SMART_ENERGY_FINANCE_INSTALL_ID"
if [ -n "$SMART_ENERGY_FINANCE_PREMIUM_KEY" ]; then
  logi "Premium key: configured"
else
  logi "Premium key: not configured"
fi

# Compat legacy éventuelle si certains flows réutilisent l'ancien nommage
export SMART_VOLTRONIC_INSTANCE_ID="$SMART_ENERGY_FINANCE_INSTALL_ID"
export SMART_VOLTRONIC_PREMIUM_KEY="$SMART_ENERGY_FINANCE_PREMIUM_KEY"

# ============================================================
# DASHBOARD
# ============================================================
DASHBOARD_CUSTOM_CARDS_INSTALLED="$(bool_or_false '.dashboard_custom_cards_installed')"
DASHBOARD_LANGUAGE="$(jq -r '.dashboard_language // "en"' "$OPTS")"

export DASHBOARD_CUSTOM_CARDS_INSTALLED
export DASHBOARD_LANGUAGE

logi "Dashboard custom cards installed: $DASHBOARD_CUSTOM_CARDS_INSTALLED"
logi "Dashboard language: $DASHBOARD_LANGUAGE"

# ============================================================
# GENERAL / CONTRACT / INPUT MODES
# ============================================================
CURRENCY="$(jq -r '.currency // "EUR"' "$OPTS")"
CONTRACT_TYPE="$(jq -r '.contract_type // "fixed"' "$OPTS")"
MONTHLY_SUBSCRIPTION_PRICE="$(jq_num_or '.monthly_subscription_price' 0)"

FIXED_IMPORT_PRICE="$(jq_num_or '.fixed_import_price' 0)"
FIXED_EXPORT_PRICE="$(jq_num_or '.fixed_export_price' 0)"

SOLAR_ENABLED="$(bool_or_false '.solar_enabled')"
SOLAR_INPUT_MODE="$(jq -r '.solar_input_mode // "energy"' "$OPTS")"
SOLAR_ENERGY_ENTITY="$(jq -r '.solar_energy_entity // ""' "$OPTS")"
SOLAR_POWER_ENTITY="$(jq -r '.solar_power_entity // ""' "$OPTS")"

LOAD_ENABLED="$(bool_or_false '.load_enabled')"
LOAD_INPUT_MODE="$(jq -r '.load_input_mode // "energy"' "$OPTS")"
LOAD_ENERGY_ENTITY="$(jq -r '.load_energy_entity // ""' "$OPTS")"
LOAD_POWER_ENTITY="$(jq -r '.load_power_entity // ""' "$OPTS")"

BATTERY_ENABLED="$(bool_or_false '.battery_enabled')"
BATTERY_INPUT_MODE="$(jq -r '.battery_input_mode // "energy"' "$OPTS")"
BATTERY_CHARGE_ENERGY_ENTITY="$(jq -r '.battery_charge_energy_entity // ""' "$OPTS")"
BATTERY_DISCHARGE_ENERGY_ENTITY="$(jq -r '.battery_discharge_energy_entity // ""' "$OPTS")"
BATTERY_CHARGE_POWER_ENTITY="$(jq -r '.battery_charge_power_entity // ""' "$OPTS")"
BATTERY_DISCHARGE_POWER_ENTITY="$(jq -r '.battery_discharge_power_entity // ""' "$OPTS")"
BATTERY_CAPACITY_AH="$(jq_num_or '.battery_capacity_ah' 0)"
BATTERY_TOTAL_CAPACITY_KWH="$(jq_num_or '.battery_total_capacity_kwh' 0)"
BATTERY_PURCHASE_COST="$(jq_num_or '.battery_purchase_cost' 0)"
BATTERY_CYCLE_LIFE="$(jq_num_or '.battery_cycle_life' 0)"

GRID_ENABLED="$(bool_or_false '.grid_enabled')"
GRID_INPUT_MODE="$(jq -r '.grid_input_mode // "energy"' "$OPTS")"
GRID_IMPORT_ENERGY_ENTITY="$(jq -r '.grid_import_energy_entity // ""' "$OPTS")"
GRID_EXPORT_ENERGY_ENTITY="$(jq -r '.grid_export_energy_entity // ""' "$OPTS")"
GRID_IMPORT_POWER_ENTITY="$(jq -r '.grid_import_power_entity // ""' "$OPTS")"
GRID_EXPORT_POWER_ENTITY="$(jq -r '.grid_export_power_entity // ""' "$OPTS")"

# Tarifs 1..4
TARIFF_1_NAME="$(jq -r '.tariff_1_name // ""' "$OPTS")"
TARIFF_1_PRICE="$(jq_num_or '.tariff_1_price' 0)"
TARIFF_1_START="$(jq -r '.tariff_1_start // ""' "$OPTS")"
TARIFF_1_END="$(jq -r '.tariff_1_end // ""' "$OPTS")"

TARIFF_2_NAME="$(jq -r '.tariff_2_name // ""' "$OPTS")"
TARIFF_2_PRICE="$(jq_num_or '.tariff_2_price' 0)"
TARIFF_2_START="$(jq -r '.tariff_2_start // ""' "$OPTS")"
TARIFF_2_END="$(jq -r '.tariff_2_end // ""' "$OPTS")"

TARIFF_3_NAME="$(jq -r '.tariff_3_name // ""' "$OPTS")"
TARIFF_3_PRICE="$(jq_num_or '.tariff_3_price' 0)"
TARIFF_3_START="$(jq -r '.tariff_3_start // ""' "$OPTS")"
TARIFF_3_END="$(jq -r '.tariff_3_end // ""' "$OPTS")"

TARIFF_4_NAME="$(jq -r '.tariff_4_name // ""' "$OPTS")"
TARIFF_4_PRICE="$(jq_num_or '.tariff_4_price' 0)"
TARIFF_4_START="$(jq -r '.tariff_4_start // ""' "$OPTS")"
TARIFF_4_END="$(jq -r '.tariff_4_end // ""' "$OPTS")"

export CURRENCY
export CONTRACT_TYPE
export MONTHLY_SUBSCRIPTION_PRICE
export FIXED_IMPORT_PRICE
export FIXED_EXPORT_PRICE

export SOLAR_ENABLED SOLAR_INPUT_MODE SOLAR_ENERGY_ENTITY SOLAR_POWER_ENTITY
export LOAD_ENABLED LOAD_INPUT_MODE LOAD_ENERGY_ENTITY LOAD_POWER_ENTITY
export BATTERY_ENABLED BATTERY_INPUT_MODE BATTERY_CHARGE_ENERGY_ENTITY BATTERY_DISCHARGE_ENERGY_ENTITY
export BATTERY_CHARGE_POWER_ENTITY BATTERY_DISCHARGE_POWER_ENTITY
export BATTERY_CAPACITY_AH BATTERY_TOTAL_CAPACITY_KWH BATTERY_PURCHASE_COST BATTERY_CYCLE_LIFE
export GRID_ENABLED GRID_INPUT_MODE GRID_IMPORT_ENERGY_ENTITY GRID_EXPORT_ENERGY_ENTITY
export GRID_IMPORT_POWER_ENTITY GRID_EXPORT_POWER_ENTITY

export TARIFF_1_NAME TARIFF_1_PRICE TARIFF_1_START TARIFF_1_END
export TARIFF_2_NAME TARIFF_2_PRICE TARIFF_2_START TARIFF_2_END
export TARIFF_3_NAME TARIFF_3_PRICE TARIFF_3_START TARIFF_3_END
export TARIFF_4_NAME TARIFF_4_PRICE TARIFF_4_START TARIFF_4_END

logi "Currency: $CURRENCY"
logi "Contract type: $CONTRACT_TYPE"
logi "Monthly subscription price: $MONTHLY_SUBSCRIPTION_PRICE"
logi "Solar enabled: $SOLAR_ENABLED | mode: $SOLAR_INPUT_MODE"
logi "Load enabled: $LOAD_ENABLED | mode: $LOAD_INPUT_MODE"
logi "Battery enabled: $BATTERY_ENABLED | mode: $BATTERY_INPUT_MODE"
logi "Grid enabled: $GRID_ENABLED | mode: $GRID_INPUT_MODE"

# ============================================================
# BASIC VALIDATION
# ============================================================
if [ -z "${CURRENCY}" ]; then
  loge "currency vide."
  exit 1
fi

if [ -z "${MQTT_HOST:-}" ]; then
  :
fi

if [ "$SOLAR_ENABLED" = "true" ]; then
  if [ "$SOLAR_INPUT_MODE" = "energy" ] && [ -z "$SOLAR_ENERGY_ENTITY" ]; then
    loge "solar_enabled=true mais solar_energy_entity est vide."
    exit 1
  fi
  if [ "$SOLAR_INPUT_MODE" = "power" ] && [ -z "$SOLAR_POWER_ENTITY" ]; then
    loge "solar_enabled=true mais solar_power_entity est vide."
    exit 1
  fi
fi

if [ "$LOAD_ENABLED" = "true" ]; then
  if [ "$LOAD_INPUT_MODE" = "energy" ] && [ -z "$LOAD_ENERGY_ENTITY" ]; then
    loge "load_enabled=true mais load_energy_entity est vide."
    exit 1
  fi
  if [ "$LOAD_INPUT_MODE" = "power" ] && [ -z "$LOAD_POWER_ENTITY" ]; then
    loge "load_enabled=true mais load_power_entity est vide."
    exit 1
  fi
fi

if [ "$GRID_ENABLED" = "true" ]; then
  if [ "$GRID_INPUT_MODE" = "energy" ] && [ -z "$GRID_IMPORT_ENERGY_ENTITY" ]; then
    loge "grid_enabled=true mais grid_import_energy_entity est vide."
    exit 1
  fi
  if [ "$GRID_INPUT_MODE" = "power" ] && [ -z "$GRID_IMPORT_POWER_ENTITY" ]; then
    loge "grid_enabled=true mais grid_import_power_entity est vide."
    exit 1
  fi
fi

if [ "$BATTERY_ENABLED" = "true" ]; then
  if [ "$BATTERY_INPUT_MODE" = "energy" ] && \
     [ -z "$BATTERY_CHARGE_ENERGY_ENTITY" ] && [ -z "$BATTERY_DISCHARGE_ENERGY_ENTITY" ]; then
    logw "battery_enabled=true mais aucune entité énergie batterie n'est définie."
  fi
  if [ "$BATTERY_INPUT_MODE" = "power" ] && \
     [ -z "$BATTERY_CHARGE_POWER_ENTITY" ] && [ -z "$BATTERY_DISCHARGE_POWER_ENTITY" ]; then
    logw "battery_enabled=true mais aucune entité puissance batterie n'est définie."
  fi
fi

if [ "$CONTRACT_TYPE" = "time_based" ]; then
  if [ -z "$TARIFF_1_NAME" ] || [ -z "$TARIFF_1_START" ] || [ -z "$TARIFF_1_END" ]; then
    loge "contract_type=time_based mais tariff_1 est incomplet."
    exit 1
  fi
  if [ -z "$TARIFF_2_NAME" ] || [ -z "$TARIFF_2_START" ] || [ -z "$TARIFF_2_END" ]; then
    loge "contract_type=time_based mais tariff_2 est incomplet."
    exit 1
  fi
fi

# ============================================================
# MQTT
# ============================================================
MQTT_HOST="$(jq_str_or '.mqtt_host' '')"
MQTT_PORT="$(jq_num_or '.mqtt_port' 1883)"
MQTT_USER="$(jq -r '.mqtt_user // ""' "$OPTS")"
MQTT_PASS="$(jq -r '.mqtt_pass // ""' "$OPTS")"

export MQTT_HOST MQTT_PORT MQTT_USER MQTT_PASS

logi "MQTT (options.json): ${MQTT_HOST:-<empty>}:${MQTT_PORT} (user: ${MQTT_USER:-<none>})"

if [ -z "$MQTT_HOST" ]; then
  loge "mqtt_host vide. Renseigne-le dans la config add-on."
  exit 1
fi

if [ -z "$MQTT_USER" ] || [ -z "$MQTT_PASS" ]; then
  loge "mqtt_user ou mqtt_pass vide. Renseigne-les dans la config add-on."
  exit 1
fi

# ============================================================
# TIMEZONE
# ============================================================
TZ_MODE_RAW="$(jq -r '.timezone_mode // "UTC"' "$OPTS")"
TZ_CUSTOM_RAW="$(jq -r '.timezone_custom // ""' "$OPTS")"

if [ "$TZ_MODE_RAW" = "CUSTOM" ]; then
  TZ_REQUESTED="$TZ_CUSTOM_RAW"
else
  TZ_REQUESTED="$TZ_MODE_RAW"
fi

TZ_REQUESTED="$(trim "$TZ_REQUESTED")"
TZ_NORMALIZED="$(normalize_timezone "$TZ_REQUESTED")"
ADDON_TIMEZONE="$(validate_timezone_or_fallback "$TZ_NORMALIZED")"

TIMEZONE_VALID="true"
if [ "$ADDON_TIMEZONE" != "$TZ_NORMALIZED" ]; then
  TIMEZONE_VALID="false"
fi

if [ -z "${ADDON_TIMEZONE:-}" ] || [ "$ADDON_TIMEZONE" = "null" ]; then
  ADDON_TIMEZONE="UTC"
  TIMEZONE_VALID="false"
fi

export TZ="$ADDON_TIMEZONE"
export ADDON_TIMEZONE
export ADDON_TIMEZONE_REQUESTED="${TZ_REQUESTED:-UTC}"
export ADDON_TIMEZONE_NORMALIZED="$TZ_NORMALIZED"
export ADDON_TIMEZONE_VALID="$TIMEZONE_VALID"

logi "Timezone requested: ${ADDON_TIMEZONE_REQUESTED}"
logi "Timezone normalized: ${ADDON_TIMEZONE_NORMALIZED}"
if [ "$ADDON_TIMEZONE_VALID" = "true" ]; then
  logi "Timezone active: ${ADDON_TIMEZONE}"
else
  logw "Timezone invalide ou inconnue -> fallback UTC (requested=${ADDON_TIMEZONE_REQUESTED}, normalized=${ADDON_TIMEZONE_NORMALIZED})"
  logi "Timezone active: ${ADDON_TIMEZONE}"
fi

# ============================================================
# STORAGE DIRS
# ============================================================
mkdir -p "$DASHBOARDS_DIR"
mkdir -p "$ADDON_DATA_DIR"
logi "Storage directories prepared: $DASHBOARDS_DIR | $ADDON_DATA_DIR"

# ============================================================
# flows.json update
# ============================================================
ADDON_FLOWS_VERSION="$(cat /addon/flows_version.txt 2>/dev/null || echo '0.0.0')"
INSTALLED_VERSION="$(cat /data/flows_version.txt 2>/dev/null || echo '')"

if [ ! -f /data/flows.json ] || [ "$INSTALLED_VERSION" != "$ADDON_FLOWS_VERSION" ]; then
  logi "Mise à jour flows : (installé: ${INSTALLED_VERSION:-aucun}) -> (addon: $ADDON_FLOWS_VERSION)"
  cp /addon/flows.json /data/flows.json
  echo "$ADDON_FLOWS_VERSION" > /data/flows_version.txt
  logi "flows.json mis à jour vers v$ADDON_FLOWS_VERSION"
else
  logi "flows.json à jour (v$ADDON_FLOWS_VERSION), conservation des flows utilisateur"
fi

# ============================================================
# MQTT broker patch
# ============================================================
if ! jq -e '.[] | select(.type=="mqtt-broker" and .name=="HA MQTT Broker")' /data/flows.json >/dev/null 2>&1; then
  loge 'Aucun mqtt-broker nommé "HA MQTT Broker" trouvé dans flows.json'
  exit 1
fi

logi "Injection MQTT (broker/port/user) dans flows.json"

jq \
  --arg host "$MQTT_HOST" \
  --arg port "$MQTT_PORT" \
  --arg user "$MQTT_USER" \
  '
  map(
    if .type=="mqtt-broker" and .name=="HA MQTT Broker"
    then
      .broker=$host
      | .port=$port
      | .user=$user
    else .
    end
  )
  ' /data/flows.json > "$TMP" && mv "$TMP" /data/flows.json

# ============================================================
# flows_cred.json
# ============================================================
if [ -f /data/flows_cred.json ]; then
  rm -f /data/flows_cred.json
  logw "Ancien flows_cred.json supprimé"
fi

BROKER_ID="$(jq -r '.[] | select(.type=="mqtt-broker" and .name=="HA MQTT Broker") | .id' /data/flows.json)"

if [ -z "$BROKER_ID" ]; then
  loge "Impossible de récupérer l'ID du node mqtt-broker dans flows.json"
  exit 1
fi

logi "Broker node ID: $BROKER_ID — Création flows_cred.json"

jq -n \
  --arg id "$BROKER_ID" \
  --arg user "$MQTT_USER" \
  --arg pass "$MQTT_PASS" \
  '{($id): {"user": $user, "password": $pass}}' \
  > /data/flows_cred.json

logi "flows_cred.json créé avec succès"

# ============================================================
# Dashboard info
# ============================================================
if [ "$DASHBOARD_CUSTOM_CARDS_INSTALLED" = "true" ]; then
  logi "Dashboard: mode custom cards activé"
else
  logw "Dashboard: mode dégradé natif HA actif tant que dashboard_custom_cards_installed=false"
fi

# ============================================================
# Summary
# ============================================================
logi "Résumé configuration:"
logi "- Currency: $CURRENCY"
logi "- Contract type: $CONTRACT_TYPE"
logi "- Timezone: $ADDON_TIMEZONE"
logi "- Solar: $SOLAR_ENABLED ($SOLAR_INPUT_MODE)"
logi "- Load: $LOAD_ENABLED ($LOAD_INPUT_MODE)"
logi "- Battery: $BATTERY_ENABLED ($BATTERY_INPUT_MODE)"
logi "- Grid: $GRID_ENABLED ($GRID_INPUT_MODE)"

# ============================================================
# Start Node-RED
# ============================================================
logi "Starting Node-RED sur le port 1892..."
exec node-red --userDir /data --settings /addon/settings.js
