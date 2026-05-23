# syntax=docker/dockerfile:1.7

FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --no-audit --no-fund
COPY index.html vite.config.js ./
COPY src ./src
RUN npm run build

# nginxinc/nginx-unprivileged runs as uid 101 by default — no root needed
FROM nginxinc/nginx-unprivileged:1.27-alpine
USER nginx
COPY --chown=nginx:nginx nginx.conf /etc/nginx/nginx.conf
COPY --from=build --chown=nginx:nginx /app/dist /usr/share/nginx/html
EXPOSE 8080
