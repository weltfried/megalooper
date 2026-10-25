# The website, built and served as it will be on GitHub Pages
# (under /megalooper/). Build from the repo root: the manual is made from
# README.md and docs/*.md.
#
#   docker build -f site/Dockerfile -t megalooper-site .
#   docker run --rm -p 8080:80 megalooper-site
#   open http://localhost:8080/megalooper/

FROM node:24-alpine AS build
WORKDIR /repo/site
COPY site/package.json site/package-lock.json ./
RUN npm ci
COPY README.md /repo/
COPY docs /repo/docs
COPY site /repo/site
RUN npm run build

FROM nginx:1.27-alpine
COPY site/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /repo/site/dist /usr/share/nginx/html/megalooper
