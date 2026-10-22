#!/bin/sh

ACME_DIR=/acme
ACME_RENEW_DAYS=30
ACME_STAGING_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory
ACME_DNS_RESOLVERS=1.1.1.1:53
SERVING_CERTIFICATE=$ACME_DIR/serving.crt
SERVING_KEY=$ACME_DIR/serving.key

: "${ACME_STAGING:=false}"

acme_enabled() {
    [ -n "${ACME_DOMAIN:-}" ]
}

validate_acme_env() {
    acme_enabled || return 0
    require_matching ACME_DOMAIN '([a-z0-9-]+\.)+[a-z]{2,}' 'ACME_DOMAIN must be a lowercase domain name, e.g. mysql.example.com'
    require_matching ACME_EMAIL '[^@ ]+@[^@ ]+\.[^@ ]+' 'ACME_EMAIL must be an email address'
    require_env CF_DNS_API_TOKEN
    require_boolean ACME_STAGING
}

acme_certificate() {
    printf '%s/lego/certificates/%s.crt' "$ACME_DIR" "$ACME_DOMAIN"
}

acme_key() {
    printf '%s/lego/certificates/%s.key' "$ACME_DIR" "$ACME_DOMAIN"
}

acme_certificate_ready() {
    [ -s "$(acme_certificate)" ] && [ -s "$(acme_key)" ]
}

lego_with_account() {
    set -- --accept-tos --email "$ACME_EMAIL" --dns cloudflare --dns.resolvers "$ACME_DNS_RESOLVERS" \
        --domains "$ACME_DOMAIN" --path "$ACME_DIR/lego" "$@"
    [ "$ACME_STAGING" = "true" ] && set -- --server "$ACME_STAGING_SERVER" "$@"
    lego "$@"
}

renew_acme_certificate() {
    if acme_certificate_ready; then
        lego_with_account renew --days "$ACME_RENEW_DAYS" --no-random-sleep > "$ACME_DIR/lego.log" 2>&1
    else
        log "requesting a Let's Encrypt certificate for $ACME_DOMAIN through Cloudflare DNS"
        lego_with_account run > "$ACME_DIR/lego.log" 2>&1
    fi || { log "ERROR: Let's Encrypt failed for $ACME_DOMAIN: $(tail -n 3 "$ACME_DIR/lego.log" | tr '\n' ' ')"; return 1; }
}

replace_if_changed() {
    cmp -s "$1" "$2" && { rm -f "$1"; return 1; }
    mv "$1" "$2"
}

install_serving_file() {
    (umask 077 && cp "$1" "$2.new")
    replace_if_changed "$2.new" "$2"
}

write_serving_certificate() {
    source_certificate=$1
    source_key=$2
    if acme_certificate_ready; then
        source_certificate=$(acme_certificate)
        source_key=$(acme_key)
    fi
    key_changed=false
    install_serving_file "$source_key" "$SERVING_KEY" && key_changed=true
    install_serving_file "$source_certificate" "$SERVING_CERTIFICATE" || [ "$key_changed" = true ]
}
