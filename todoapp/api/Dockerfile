# syntax=docker/dockerfile:1.7

FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --omit=dev --no-audit --no-fund && npm cache clean --force

FROM gcr.io/distroless/nodejs20-debian12:nonroot
WORKDIR /app
ENV NODE_ENV=production \
    PORT=8080
COPY --from=deps --chown=nonroot:nonroot /app/node_modules /app/node_modules
COPY --chown=nonroot:nonroot src /app/src
COPY --chown=nonroot:nonroot package.json /app/package.json
USER nonroot
EXPOSE 8080
CMD ["src/index.js"]
