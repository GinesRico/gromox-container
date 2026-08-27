FROM alpine:3.20

RUN apk add --no-cache postfix cyrus-sasl ca-certificates bash

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 25

ENTRYPOINT ["/entrypoint.sh"]
