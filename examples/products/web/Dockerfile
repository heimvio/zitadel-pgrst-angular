# Build of the example app. Build context = repo root so the generic core
# building block angular-auth/ can be included WITHOUT changing import paths:
# it is reconstructed as src/auth/ (the app imports './auth').
FROM node:20-alpine AS build
WORKDIR /app
COPY examples/products/web/package.json ./
RUN npm install --no-audit --no-fund
COPY examples/products/web/angular.json examples/products/web/tsconfig.json examples/products/web/tsconfig.app.json ./
COPY examples/products/web/src ./src
COPY angular-auth ./src/auth
RUN npx ng build

# Served statically; config.json comes at runtime from the shared volume.
FROM python:3-alpine
COPY --from=build /app/dist/browser /site
COPY examples/products/web/serve.py /serve.py
CMD ["sh","-c","cp /shared/config.json /site/config.json 2>/dev/null || true; exec python /serve.py"]
