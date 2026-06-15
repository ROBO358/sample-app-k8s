FROM nginxinc/nginx-unprivileged:1.29-alpine

ARG BUILT_AT
ENV BUILT_AT=${BUILT_AT:-unknown}

COPY nginx.conf /etc/nginx/nginx.conf
COPY default.conf /etc/nginx/conf.d/default.conf
COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY index.html.tmpl /usr/share/nginx/html.tmpl/index.html.tmpl

USER root
RUN chmod +x /docker-entrypoint.sh
USER nginx

EXPOSE 8080

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
