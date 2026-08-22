FROM node:22.13.1-bookworm-slim@sha256:83fdfa2a4de32d7f8d79829ea259bd6a4821f8b2d123204ac467fbe3966450fc AS dependencies
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM dependencies AS validation-build
WORKDIR /app
ARG NEXT_PUBLIC_EDITOR_API_ORIGIN
ENV NEXT_PUBLIC_EDITOR_API_ORIGIN=$NEXT_PUBLIC_EDITOR_API_ORIGIN
COPY . .
RUN test ! -e /app/.env
RUN npm run lint
RUN npm run build
RUN npm test

FROM node:22.13.1-bookworm-slim@sha256:83fdfa2a4de32d7f8d79829ea259bd6a4821f8b2d123204ac467fbe3966450fc AS runtime
WORKDIR /app
COPY --from=validation-build /app /app
RUN mkdir -p /app/tmp \
    && chmod -R a+rX /app \
    && chmod 755 /app /app/tmp
CMD ["npm", "run", "start"]
