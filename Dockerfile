# Garage S3 for Railway — pinned upstream binary, LMDB metadata engine,
# credentials applied from the environment on every boot.
FROM alpine:3.22

ARG GARAGE_VERSION=v2.2.0
ARG GARAGE_SHA256=ec761bb996e8453e86fe68ccc1cf222c73bb1ef05ae0b540bd4827e7d1931aab

RUN apk add --no-cache ca-certificates curl nginx openssl

RUN curl -fsSL -o /usr/local/bin/garage \
      "https://garagehq.deuxfleurs.fr/_releases/${GARAGE_VERSION}/x86_64-unknown-linux-musl/garage" \
 && echo "${GARAGE_SHA256}  /usr/local/bin/garage" | sha256sum -c - \
 && chmod +x /usr/local/bin/garage \
 && /usr/local/bin/garage --version

# Defaults that belong to the image, not to the deploy form: a literal-valued
# template variable publishes as a blank required field, so these stay baked.
ENV GARAGE_BUCKET=my-bucket \
    GARAGE_KEY_NAME=railway-key \
    GARAGE_S3_PORT=3900 \
    GARAGE_ADMIN_PORT=3902 \
    GARAGE_REGION=garage \
    GARAGE_DATA_DIR=/data

COPY nginx.conf /etc/nginx/nginx.conf
COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
