FROM alpine:3.22
RUN apk add --no-cache dnsmasq
ENTRYPOINT ["dnsmasq", "-k", "--log-facility=-"]
