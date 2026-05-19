# Build der Angular-Beispiel-App (nutzt den generischen Auth-Baustein src/auth)
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json ./
RUN npm install --no-audit --no-fund
COPY angular.json tsconfig.json tsconfig.app.json ./
COPY src ./src
RUN npx ng build

# Statisch serviert; config.json kommt zur Laufzeit aus dem shared-Volume.
FROM python:3-alpine
COPY --from=build /app/dist/browser /site
COPY serve.py /serve.py
CMD ["sh","-c","cp /shared/config.json /site/config.json 2>/dev/null || true; exec python /serve.py"]
