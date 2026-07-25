# Build the static bundle
FROM node:20-alpine AS build
WORKDIR /app

COPY package*.json ./
RUN npm install

COPY . .

# Vite bakes env vars in at build time — default to a relative path so the
# built bundle works unmodified behind any origin's reverse proxy (see
# nginx.conf.template). Do not pass an absolute host here.
ARG VITE_API_URL=/api
ENV VITE_API_URL=$VITE_API_URL
RUN npm run build

# Serve it with Nginx
FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html

# Templated so the backend upstream (Docker Compose service name vs.
# Kubernetes Service DNS) is resolved from env at container startup, via
# nginx's built-in envsubst-on-templates entrypoint script.
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
ENV BACKEND_UPSTREAM=http://backend:3000

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]