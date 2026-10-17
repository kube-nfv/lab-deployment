FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        iproute2 qemu-efi-aarch64 qemu-system-arm qemu-utils \
    && rm -rf /var/lib/apt/lists/*
COPY vm-entrypoint.sh /usr/local/bin/vm-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/vm-entrypoint.sh"]
