FROM nginx:alpine

COPY deploy/always-on/portal-nginx.conf /etc/nginx/conf.d/default.conf
COPY portal /usr/share/nginx/html
