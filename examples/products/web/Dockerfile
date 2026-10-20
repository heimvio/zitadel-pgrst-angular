# Build of the example app.
#
# Build context = repo root. We first build the library (ng-packagr) from
# projects/zitadel-pgrst-angular, then npm-install it into the example
# app via the file:../../../dist/... path defined in examples/products/web/package.json.
FROM node:20-alpine AS lib
WORKDIR /repo
COPY package.json tsconfig.json angular.json ./
COPY projects ./projects
RUN npm install --no-audit --no-fund \
 && npx ng build zitadel-pgrst-angular

FROM node:20-alpine AS app
WORKDIR /app
COPY --from=lib /repo/dist /repo-dist
COPY examples/products/web/package.json ./
# Rewrite the file: path so npm install resolves against the copied dist.
RUN sed -i 's|file:../../../dist/|file:/repo-dist/|' package.json \
 && npm install --no-audit --no-fund
COPY examples/products/web/angular.json examples/products/web/tsconfig.json examples/products/web/tsconfig.app.json ./
COPY examples/products/web/src ./src
RUN npx ng build

# Served statically; config.json comes at runtime from the shared volume.
FROM python:3-alpine
COPY --from=app /app/dist/browser /site
COPY examples/products/web/serve.py /serve.py
CMD ["sh","-c","cp /shared/config.json /site/config.json 2>/dev/null || true; exec python /serve.py"]
