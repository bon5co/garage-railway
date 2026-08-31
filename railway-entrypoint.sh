#!/bin/sh
# Garage S3 on Railway.
#
# Everything credential-related runs on EVERY boot, deliberately. The templates
# in this category do all of it behind a `.initialized` marker on the volume, so
# the access key a deployer sets is silently ignored from the second boot
# onwards while the deploy still reports success.
set -eu

log() { echo "[garage-railway] $*"; }
die() { echo "[garage-railway] FATAL: $*" >&2; exit 1; }

DATA_DIR="${GARAGE_DATA_DIR:-/data}"
CONF=/etc/garage.toml
PORT="${PORT:-8080}"
S3_PORT="${GARAGE_S3_PORT:-3900}"
ADMIN_PORT="${GARAGE_ADMIN_PORT:-3902}"
BUCKET="${GARAGE_BUCKET:-my-bucket}"
KEY_NAME="${GARAGE_KEY_NAME:-railway-key}"
REGION="${GARAGE_REGION:-garage}"

ACCESS_KEY="${GARAGE_ACCESS_KEY:-}"
SECRET_KEY="${GARAGE_SECRET_KEY:-}"

# --- credential validation ------------------------------------------------
# Garage's key format is fixed: GK + 24 hex for the ID, 64 hex for the secret.
# An out-of-format value is refused here with a readable line instead of being
# accepted and then failing every S3 request with "No such key".
[ -n "$ACCESS_KEY" ] || die "GARAGE_ACCESS_KEY is empty. Set it to GK + 24 hex characters."
[ -n "$SECRET_KEY" ] || die "GARAGE_SECRET_KEY is empty. Set it to 64 hex characters."

case "$ACCESS_KEY" in
  GK*) ;;
  *) die "GARAGE_ACCESS_KEY must start with GK (got ${#ACCESS_KEY} characters)." ;;
esac
if ! echo "$ACCESS_KEY" | grep -Eq '^GK[0-9a-f]{24}$'; then
  die "GARAGE_ACCESS_KEY must be GK followed by exactly 24 lowercase hex characters."
fi
if ! echo "$SECRET_KEY" | grep -Eq '^[0-9a-f]{64}$'; then
  die "GARAGE_SECRET_KEY must be exactly 64 lowercase hex characters."
fi

mkdir -p "$DATA_DIR/meta" "$DATA_DIR/data"

# --- cluster secrets ------------------------------------------------------
# Both are stable across redeploys: taken from the environment when the
# template supplies them, otherwise generated once onto the volume.
RPC_SECRET="${GARAGE_RPC_SECRET:-}"
if [ -z "$RPC_SECRET" ]; then
  if [ ! -f "$DATA_DIR/rpc_secret" ]; then
    openssl rand -hex 32 > "$DATA_DIR/rpc_secret"
    chmod 600 "$DATA_DIR/rpc_secret"
  fi
  RPC_SECRET="$(cat "$DATA_DIR/rpc_secret")"
fi
if ! echo "$RPC_SECRET" | grep -Eq '^[0-9a-f]{64}$'; then
  die "GARAGE_RPC_SECRET must be exactly 64 lowercase hex characters."
fi

ADMIN_TOKEN="${GARAGE_ADMIN_TOKEN:-}"
if [ -z "$ADMIN_TOKEN" ]; then
  if [ ! -f "$DATA_DIR/admin_token" ]; then
    openssl rand -hex 32 > "$DATA_DIR/admin_token"
    chmod 600 "$DATA_DIR/admin_token"
  fi
  ADMIN_TOKEN="$(cat "$DATA_DIR/admin_token")"
fi

# --- config ---------------------------------------------------------------
# db_engine is LMDB, upstream's recommended default for a single node; the
# templates in this category force sqlite.
cat > "$CONF" <<CFG
metadata_dir = "$DATA_DIR/meta"
data_dir = "$DATA_DIR/data"
db_engine = "lmdb"

replication_factor = 1

rpc_bind_addr = "127.0.0.1:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "$RPC_SECRET"

[s3_api]
s3_region = "$REGION"
api_bind_addr = "127.0.0.1:$S3_PORT"

[admin]
api_bind_addr = "127.0.0.1:$ADMIN_PORT"
admin_token = "$ADMIN_TOKEN"
CFG
chmod 600 "$CONF"

garage() { /usr/local/bin/garage -c "$CONF" "$@"; }

log "starting garage $(/usr/local/bin/garage --version | awk '{print $2}') (db_engine=lmdb, region=$REGION)"
/usr/local/bin/garage -c "$CONF" server &
GARAGE_PID=$!

# --- wait for the node to answer -----------------------------------------
i=0
until garage status >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 120 ] || die "garage did not become reachable within 120s"
  kill -0 "$GARAGE_PID" 2>/dev/null || die "garage exited during startup"
  sleep 1
done

NODE_ID="$(garage status | awk '/^==== HEALTHY NODES ====/{h=1;next} h && $1 ~ /^[0-9a-f]{8}/{print $1; exit}')"
[ -n "$NODE_ID" ] || NODE_ID="$(garage node id -q 2>/dev/null | cut -d@ -f1)"
[ -n "$NODE_ID" ] || die "could not determine this node's id"

# --- layout ---------------------------------------------------------------
# Capacity is a distribution weight in Garage, not a quota, but reporting the
# volume's real size keeps `garage status` and any admin UI honest.
if ! garage layout show 2>/dev/null | grep -q "$NODE_ID"; then
  CAP_BYTES="$(df -B1 "$DATA_DIR" | awk 'NR==2 {print int($2 * 0.95)}')"
  [ -n "$CAP_BYTES" ] && [ "$CAP_BYTES" -gt 0 ] || CAP_BYTES=10000000000
  log "assigning layout role to node ${NODE_ID} (capacity $((CAP_BYTES / 1000000000))GB)"
  garage layout assign -z railway -c "${CAP_BYTES}B" "$NODE_ID" >/dev/null
  NEXT_VERSION="$(garage layout show | grep -oE 'apply --version [0-9]+' | grep -oE '[0-9]+$' | tail -1)"
  [ -n "$NEXT_VERSION" ] || NEXT_VERSION=1
  garage layout apply --version "$NEXT_VERSION" >/dev/null
  # The layout has to be live before any bucket or key call is accepted.
  j=0
  until garage status 2>/dev/null | grep -q "$NODE_ID"; do
    j=$((j + 1))
    [ "$j" -lt 60 ] || die "layout did not converge within 60s"
    sleep 1
  done
fi

# --- credentials, applied every boot -------------------------------------
# This is the whole point of the wrapper. The templates in this category do all
# of it once, behind a marker file on the volume, so a key set or changed after
# the first boot is accepted by the deploy form, printed in the deploy log, and
# then rejected by every S3 request with "No such key".
if garage key info "$ACCESS_KEY" >/dev/null 2>&1; then
  CURRENT_SECRET="$(garage key info --show-secret "$ACCESS_KEY" 2>/dev/null | awk '/Secret key:/{print $3}')"
  if [ "$CURRENT_SECRET" = "$SECRET_KEY" ]; then
    log "access key $ACCESS_KEY is current"
  else
    # Garage refuses to re-import a key id it has ever seen ("Even if it is
    # deleted, we can't let you create a new key with the same ID"), so the
    # secret of an existing id cannot be changed. Refuse to boot rather than
    # serve credentials that contradict the ones on the deploy form.
    die "GARAGE_SECRET_KEY does not match the secret stored for $ACCESS_KEY. Garage cannot change the secret of an existing access key id. To rotate, set GARAGE_ACCESS_KEY to a NEW id (GK + 24 hex) as well as a new secret; the buckets and their contents are untouched."
  fi
else
  log "importing access key $ACCESS_KEY"
  garage key import --yes -n "$KEY_NAME" "$ACCESS_KEY" "$SECRET_KEY" >/dev/null
fi

if ! garage bucket info "$BUCKET" >/dev/null 2>&1; then
  log "creating bucket $BUCKET"
  garage bucket create "$BUCKET" >/dev/null
fi
garage bucket allow --read --write --owner "$BUCKET" --key "$ACCESS_KEY" >/dev/null

# Secrets are never echoed: the deployer set them, and a deploy log is not a
# place to publish an S3 secret key or an admin token.
log "ready: bucket=$BUCKET region=$REGION access_key=$ACCESS_KEY (secret not logged)"

# --- gateway --------------------------------------------------------------
sed "s/__PORT__/$PORT/g" /etc/nginx/nginx.conf > /run/nginx.conf
log "serving S3 on \$PORT=$PORT (path-style addressing)"
nginx -c /run/nginx.conf -g 'daemon off;' &
NGINX_PID=$!

# If either process dies the container dies with it, so Railway restarts
# instead of serving a half-running stack.
while true; do
  kill -0 "$GARAGE_PID" 2>/dev/null || die "garage exited"
  kill -0 "$NGINX_PID" 2>/dev/null || die "nginx exited"
  sleep 5
done
