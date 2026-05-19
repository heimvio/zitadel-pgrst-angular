# Build der Beispiel-App. Build-Context = Repo-Root, damit der generische
# Kern-Baustein angular-auth/ eingebunden werden kann, OHNE Importpfade zu
# ändern: er wird als src/auth/ rekonstruiert (App importiert './auth').
FROM node:20-alpine AS build
WORKDIR /app
COPY examples/products/web/package.json ./
RUN npm install --no-audit --no-fund
COPY examples/products/web/angular.json examples/products/web/tsconfig.json examples/products/web/tsconfig.app.json ./
COPY examples/products/web/src ./src
COPY angular-auth ./src/auth
RUN npx ng build

# Statisch serviert; config.json kommt zur Laufzeit aus dem shared-Volume.
FROM python:3-alpine
COPY --from=build /app/dist/browser /site
COPY examples/products/web/serve.py /serve.py
CMD ["sh","-c","cp /shared/config.json /site/config.json 2>/dev/null || true; exec python /serve.py"]
