ARG PYTHON_MAJOR=3.11
ARG NODE_MAJOR=20

# Build the python gbstats package
FROM python:${PYTHON_MAJOR}-slim AS pybuild
WORKDIR /usr/local/src/app
COPY ./packages/stats .
RUN \
  pip3 install poetry==1.8.5  \
  && poetry install --no-root --without dev --no-interaction --no-ansi \
  && poetry build \
  && poetry export -f requirements.txt --output requirements.txt

# Build the nodejs app
FROM python:${PYTHON_MAJOR}-slim AS nodebuild
ARG NODE_MAJOR
WORKDIR /usr/local/src/app
RUN apt-get update && \
  apt-get install -y wget gnupg2 build-essential && \
  echo "deb https://deb.nodesource.com/node_$NODE_MAJOR.x buster main" > /etc/apt/sources.list.d/nodesource.list && \
  wget -qO- https://deb.nodesource.com/gpgkey/nodesource.gpg.key | apt-key add - && \
  echo "deb https://dl.yarnpkg.com/debian/ stable main" > /etc/apt/sources.list.d/yarn.list && \
  wget -qO- https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
  apt-get update && \
  apt-get install -yqq nodejs=$(apt-cache show nodejs|grep Version|grep nodesource|cut -c 10-) yarn && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

# Copy over minimum files to install dependencies
COPY package.json ./package.json
COPY yarn.lock ./yarn.lock
COPY packages/front-end/package.json ./packages/front-end/package.json
COPY packages/back-end/package.json ./packages/back-end/package.json
COPY packages/sdk-js/package.json ./packages/sdk-js/package.json
COPY packages/sdk-react/package.json ./packages/sdk-react/package.json
COPY packages/shared/package.json ./packages/shared/package.json
COPY patches ./patches

# Yarn install with dev dependencies (will be cached as long as dependencies don't change)
RUN yarn install --frozen-lockfile --ignore-optional
# Apply patches this is not ideal since this should run at the end of yarn install but since node 20 it is not
RUN yarn postinstall

# Copy source files
COPY packages ./packages

# Set higher memory limit for Node
ENV NODE_OPTIONS="--max-old-space-size=8192"

# Build dependencies first
RUN yarn build:deps

# Build backend and frontend separately
RUN cd packages/back-end && yarn build
RUN cd packages/front-end && yarn build

# Clean up and install production dependencies
RUN rm -rf node_modules \
    && rm -rf packages/back-end/node_modules \
    && rm -rf packages/front-end/node_modules \
    && rm -rf packages/front-end/.next/cache \
    && rm -rf packages/shared/node_modules \
    && rm -rf packages/sdk-js/node_modules \
    && rm -rf packages/sdk-react/node_modules \
    && yarn install --frozen-lockfile --production=true --ignore-optional

RUN yarn postinstall

# Package the full app together
FROM python:${PYTHON_MAJOR}-slim
ARG NODE_MAJOR
WORKDIR /usr/local/src/app
RUN apt-get update && \
  apt-get install -y wget gnupg2 && \
  echo "deb https://deb.nodesource.com/node_$NODE_MAJOR.x buster main" > /etc/apt/sources.list.d/nodesource.list && \
  wget -qO- https://deb.nodesource.com/gpgkey/nodesource.gpg.key | apt-key add - && \
  echo "deb https://dl.yarnpkg.com/debian/ stable main" > /etc/apt/sources.list.d/yarn.list && \
  wget -qO- https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
  apt-get update && \
  apt-get install -yqq nodejs=$(apt-cache show nodejs|grep Version|grep nodesource|cut -c 10-) yarn && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*
COPY --from=pybuild /usr/local/src/app/requirements.txt /usr/local/src/requirements.txt
RUN pip3 install -r /usr/local/src/requirements.txt && rm -rf /root/.cache/pip
COPY --from=nodebuild /usr/local/src/app/packages ./packages
COPY --from=nodebuild /usr/local/src/app/node_modules ./node_modules
COPY --from=nodebuild /usr/local/src/app/package.json ./package.json

# wildcard used to act as 'copy if exists'
COPY buildinfo* ./buildinfo

COPY --from=pybuild /usr/local/src/app/dist /usr/local/src/gbstats
RUN pip3 install /usr/local/src/gbstats/*.whl
# The front-end app (NextJS)
EXPOSE 3100

# Start both front-end and back-end at once
ENV START_SERVICE=backend

# Modify the CMD to use a script or conditional start
CMD ["sh", "-c", "if [ \"$START_SERVICE\" = \"frontend\" ]; then yarn start:frontend-with-tracing; elif [ \"$START_SERVICE\" = \"backend\" ]; then yarn start:backend-with-tracing; else yarn start; fi"]