# --- етап 1: збірка статичних файлів ---
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts
COPY . .
RUN npm run build

# --- етап 2: Nginx віддає статику і проксує /api на backend ---
FROM nginx:1.30-alpine

# оновлюємо системні пакети базового образу: закриває вразливості, які знаходить Trivy
RUN apk upgrade --no-cache

# адресу backend можна змінити змінною оточення (docker compose / Kubernetes)
ENV BACKEND_URL=http://backend:5000

COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80
