# garage-railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/garage-s3-or-just-updated-object-store-t?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

**Deploy on Railway:** [Garage S3 template](https://railway.com/deploy/garage-s3-or-just-updated-object-store-t?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

Wrapper image for deploying [Garage](https://garagehq.deuxfleurs.fr/) — a lightweight
S3-compatible object store — on Railway.

Upstream binary is pinned to `v2.2.0` and verified by SHA-256 at build time.

## What the wrapper adds

- **The credentials on the deploy form are the credentials that work.** Key import runs on
  every boot, not once behind a marker file on the volume, so changing the access key on a
  redeploy actually takes effect instead of being silently ignored.
- **Fails closed on a bad credential.** An empty or out-of-format access key or secret stops
  the boot with a message naming the required format (`GK` + 24 hex, and 64 hex), rather than
  starting a server that answers `AccessDenied: No such key` to every request.
- **Secrets are never written to the deploy log.** The access key id is logged; the secret key,
  the admin token and the RPC secret are not.
- **LMDB metadata engine**, upstream's recommended default for a single node.
- **A real healthcheck.** An in-container nginx gateway listens on `$PORT`, proxies S3 to
  Garage on 3900, and serves `/healthz` from Garage's own cluster-health endpoint.
- Layout capacity is read from the mounted volume instead of a hardcoded value. (Capacity in
  Garage is a distribution weight, not a quota — this only keeps `garage status` honest.)

## Environment

| Variable | Required | Notes |
| --- | --- | --- |
| `GARAGE_ACCESS_KEY` | yes | `GK` + exactly 24 lowercase hex characters |
| `GARAGE_SECRET_KEY` | yes | exactly 64 lowercase hex characters |
| `GARAGE_RPC_SECRET` | no | 64 hex; generated onto the volume when unset |
| `GARAGE_ADMIN_TOKEN` | no | generated onto the volume when unset |
| `GARAGE_BUCKET` | no | default `my-bucket` |
| `GARAGE_REGION` | no | default `garage` |
| `PORT` | injected | nginx listens here |

Mount a volume at `/data`. S3 clients must use **path-style** addressing.

## Rotating credentials

Garage refuses to re-import an access key id it has ever seen, so the secret of an existing
id cannot be changed. To rotate, set a new `GARAGE_ACCESS_KEY` **and** a new
`GARAGE_SECRET_KEY`; buckets and their contents are untouched.
