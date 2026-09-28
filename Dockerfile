FROM mcr.microsoft.com/powershell:7.4-debian-12 AS powershell

FROM node:22-bookworm-slim AS sync
RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates libicu72 libgssapi-krb5-2 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=powershell /opt/microsoft/powershell/7 /opt/microsoft/powershell/7
RUN ln -s /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY src ./src
COPY scripts ./scripts
COPY tests ./tests
COPY projects ./projects
ARG FLOW_HUB_REVISION=local-docker
ENV FLOW_HUB_REVISION=$FLOW_HUB_REVISION
RUN npm test && npm run build \
    && mkdir /site && chown -R node:node /app /site
USER node
ENTRYPOINT ["node", "scripts/local-sync.mjs"]

FROM nginx:1.28-alpine AS portal
COPY deploy/nginx.conf /etc/nginx/nginx.conf
USER nginx
EXPOSE 8080
ENTRYPOINT ["nginx", "-g", "daemon off;"]
