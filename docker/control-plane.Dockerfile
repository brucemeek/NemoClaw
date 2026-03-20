FROM node:22-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/nemoclaw

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        docker.io \
        git \
        openssh-client \
        python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY . /workspace

RUN find /workspace -type f -name '*.sh' -exec sed -i 's/\r$//' {} +

RUN bash /workspace/scripts/install-openshell.sh \
    && npm install -g /workspace

COPY docker/control-plane-entrypoint.sh /usr/local/bin/nemoclaw-control-entrypoint
RUN sed -i 's/\r$//' /usr/local/bin/nemoclaw-control-entrypoint \
    && chmod +x /usr/local/bin/nemoclaw-control-entrypoint \
    && mkdir -p /home/nemoclaw/.nemoclaw /home/nemoclaw/.openclaw \
    && chmod 700 /home/nemoclaw/.nemoclaw /home/nemoclaw/.openclaw

ENTRYPOINT ["/usr/local/bin/nemoclaw-control-entrypoint"]
CMD []