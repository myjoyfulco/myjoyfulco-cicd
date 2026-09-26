# fewcoco-web deployment

The production image serves the built SPA with an unprivileged Node process.
It publishes port `8080` only to `127.0.0.1:8180` on the host. TLS, public
access, response-header overrides, and API/OAuth routing belong to the
separately managed reverse proxy and are not configured here.

## Host layout

Only these roots are used:

```text
/srv/data/deployments/fewcoco-web/
  deployment/     server-authoritative copies of the files in this directory
  properties/     operator-maintained deployment input
    config.env    non-secret host settings
    secret.env    empty, mode 0600 (reserved for future credentials)
  pv/buildcache/
  pv/tmp/
/srv/data/app/fewcoco-web/   intentionally empty; the SPA has no persistent data
```

Copy all version-controlled files from this directory to the host's
`deployment/` directory. Then create `properties/config.env` from
`config.env.example`, and create an empty `properties/secret.env` from
`secret.env.example` with mode `0600`. Keep both untracked. `config.env` may
contain only `BIND_IP`, `HOST_PORT`, `IMAGE_ALLOWED_HOSTS`, and optional public
`VITE_*` path overrides already declared in the repository's `.env.example`.
`secret.env` currently accepts no keys. The deployer rejects any other regular
file in `properties/`. `IMAGE_ALLOWED_HOSTS` is a space-separated list of
remote image origins for the static server's `img-src` CSP. Browser bundles
must never receive usernames, passwords, tokens, credentials, or API keys.

The former `deployment/secret.env` is ignored by the new deployer. It can be
deleted after the first successful deployment using this layout.

## Deploy

```sh
/srv/data/deployments/fewcoco-web/deployment/deploy.sh
/srv/data/deployments/fewcoco-web/deployment/deploy.sh --force
/srv/data/deployments/fewcoco-web/deployment/deploy.sh --ref develop --no-push
```

The default ref is `develop`. Before building, the script copies the six
allowlisted, server-authoritative deployment files into its temporary clone.
It detects edits made independently in Git and on the server since the prior
synchronization, commits only allowlisted files, and pushes unless `--no-push`
is given. The build always runs lint, typecheck, unit tests, and the production
build. Failed health or smoke checks restore the previously running image.

The reverse proxy should send application requests from `/` to
`127.0.0.1:8180`, after giving `/etsy-shop-assistant/api/*` and
`/etsy-shop-assistant/oauth/*` higher-priority routes to their appropriate
services. The static server deliberately returns `404` for those backend paths.
