# syntax=docker/dockerfile:1.7
FROM node:22.12.0-slim AS build

WORKDIR /srv/fewcoco-web
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --no-audit --no-fund

COPY . ./
RUN npm run lint && npm run typecheck && npm run test
ARG PUBLIC_CONFIG_HASH=local
RUN --mount=type=secret,id=app_env,target=/srv/fewcoco-web/.env,required=true test -n "$PUBLIC_CONFIG_HASH" && npm run build

FROM node:22.12.0-alpine AS runtime

ENV HOST=0.0.0.0 \
    NODE_ENV=production \
    PORT=8080
WORKDIR /srv/fewcoco-web

COPY --chown=node:node --from=build /srv/fewcoco-web/dist ./dist
COPY --chown=node:node scripts/static-server.mjs ./scripts/static-server.mjs

USER node
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8080/healthz').then(r=>{if(!r.ok)throw Error(r.status)})" || exit 1
CMD ["node", "scripts/static-server.mjs"]
