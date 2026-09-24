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
  properties/
  pv/buildcache/
  pv/tmp/
/srv/data/app/fewcoco-web/   intentionally empty; the SPA has no persistent data
```

Copy all version-controlled files from this directory to the host's
`deployment/` directory. Then create `secret.env` from `secret.env.example`,
set it to mode `0600`, and keep it untracked. It may contain only `BIND_IP`,
`HOST_PORT`, and optional public `VITE_*` path overrides already declared in
the repository's `.env.example`. Browser bundles must never receive usernames,
passwords, tokens, credentials, or API keys.

## Deploy

```sh
/srv/data/deployments/fewcoco-web/deployment/deploy.sh
/srv/data/deployments/fewcoco-web/deployment/deploy.sh --force
/srv/data/deployments/fewcoco-web/deployment/deploy.sh --ref develop --no-push
```

The default ref is `develop`. Before building, the script copies the five
allowlisted, server-authoritative deployment files into its temporary clone.
It detects edits made independently in Git and on the server since the prior
synchronization, commits only allowlisted files, and pushes unless `--no-push`
is given. The build always runs lint, typecheck, unit tests, and the production
build. Failed health or smoke checks restore the previously running image.

The reverse proxy should send application requests from `/` to
`127.0.0.1:8180`, after giving `/etsy-shop-assistant/api/*` and
`/etsy-shop-assistant/oauth/*` higher-priority routes to their appropriate
services. The static server deliberately returns `404` for those backend paths.
