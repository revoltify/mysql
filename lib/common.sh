#!/bin/sh

NODE_ENV_FILE=/etc/node.env

load_node_env() {
    [ -r "$NODE_ENV_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in *=*) ;; *) continue ;; esac
        key=${line%%=*}
        case "$key" in '' | [0-9]* | *[!A-Za-z0-9_]*) continue ;; esac
        export "$key=${line#*=}"
    done < "$NODE_ENV_FILE"
}

load_node_env

LIB_DIR=/usr/local/lib/mysql-cluster
DATA_DIR=/var/lib/mysql
RUN_USER=mysql
ROOT_CLIENT_CONFIG=/tmp/mysql-root.cnf
MYSQL_SOCKET=/var/run/mysqld/mysqld.sock
BACKUP_PATH="${BACKUP_PATH:-mysql}"
BACKUP_PATH_PATTERN='[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*'
BACKUP_NAME_PATTERN='^backup-[0-9]{8}T[0-9]{6}Z\.xbstream\.zst$'
BACKUP_TMP_DIR="${BACKUP_TMP_DIR:-/var/lib/mysql-backup}"
PASSWORD_PATTERN='[A-Za-z0-9_-]{32,}'

: "${BACKUP_ENABLED:=true}"
: "${RESTORE_ON_EMPTY:=true}"
: "${BACKUP_INTERVAL_SECONDS:=3600}"
: "${BACKUP_RETRY_SECONDS:=300}"
: "${BACKUP_RETENTION:=168}"
: "${MYSQLSH_USER_CONFIG_HOME:=/tmp/mysqlsh}"
export MYSQLSH_USER_CONFIG_HOME

log() {
    printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$0")" "$*" >&2
}

fail() {
    log "ERROR: $*"
    exit 1
}

value_of() {
    eval "printf '%s' \"\${$1:-}\""
}

require_env() {
    for variable in "$@"; do
        [ -n "$(value_of "$variable")" ] || fail "$variable is required"
    done
}

require_boolean() {
    case "$(value_of "$1")" in
        true | false) ;;
        *) fail "$1 must be true or false" ;;
    esac
}

require_integer_at_least() {
    value=$(value_of "$1")
    case "$value" in
        '' | *[!0-9]*) fail "$1 must be a whole number" ;;
    esac
    [ "$value" -ge "$2" ] || fail "$1 must be at least $2"
}

require_matching() {
    printf '%s' "$(value_of "$1")" | grep -Eq "^$2\$" || fail "${3:-$1 contains unsupported characters}"
}

distinct_characters_in() {
    printf '%s' "$1" | fold -w 1 | sort -u | wc -l | tr -d ' '
}

validate_password() {
    require_env "$1"
    require_matching "$1" "$PASSWORD_PATTERN" "$1 must be at least 32 characters of A-Z a-z 0-9 _ -"
    [ "$(distinct_characters_in "$(value_of "$1")")" -ge 10 ] || fail "$1 is too predictable, generate one with: openssl rand -hex 32"
}

validate_passwords() {
    for variable in MYSQL_ROOT_PASSWORD CLUSTER_ADMIN_PASSWORD "$@"; do
        validate_password "$variable"
    done
}

owned_by_run_user() {
    [ "$(stat -c %U "$1")" = "$RUN_USER" ]
}

drop_privileges() {
    [ "$(id -u)" = "0" ] || return 0
    exec gosu "$RUN_USER" "$@"
}

own_directories() {
    for directory in "$@"; do
        mkdir -p "$directory"
        owned_by_run_user "$directory" || chown -R "$RUN_USER:$RUN_USER" "$directory"
        chmod 700 "$directory"
    done
}

write_root_client_config() {
    [ -s "$ROOT_CLIENT_CONFIG" ] && return 0
    (umask 077 && printf '[client]\nuser=root\npassword="%s"\nsocket=%s\n' "$MYSQL_ROOT_PASSWORD" "$MYSQL_SOCKET" > "$ROOT_CLIENT_CONFIG")
}

sql() {
    write_root_client_config
    mysql --defaults-extra-file="$ROOT_CLIENT_CONFIG" -NB "$@" </dev/null
}

data_dir_empty() {
    [ -z "$(ls -A "$DATA_DIR")" ]
}

mysql_alive() {
    sql -e 'SELECT 1' > /dev/null 2>&1
}

sha256_of() {
    sha256sum "$1" | cut -d ' ' -f 1
}

size_of() {
    wc -c < "$1" | tr -d ' '
}

backup_names() {
    objects=$(s3_list) || return 1
    printf '%s\n' "$objects" | grep -E "$BACKUP_NAME_PATTERN" | sort
}

use_restore_path() {
    require_matching RESTORE_PATH "$BACKUP_PATH_PATTERN" 'RESTORE_PATH must be an S3 path such as mysql/old, without . or .. segments'
    BACKUP_PATH=$RESTORE_PATH
}

restore_source() {
    [ -z "${RESTORE_PATH:-}" ] || use_restore_path
    [ -z "${RESTORE_BACKUP:-}" ] || printf '%s' "$RESTORE_BACKUP" | grep -Eq "$BACKUP_NAME_PATTERN" \
        || fail "RESTORE_BACKUP must be a backup name as printed by list-backups"
}

restore_candidates() {
    [ -n "${RESTORE_BACKUP:-}" ] || { backup_names; return; }
    printf '%s\n' "$RESTORE_BACKUP"
}

backup_epoch() {
    stamp=$(printf '%s' "$1" | sed -E 's/^backup-([0-9]{8})T([0-9]{2})([0-9]{2})([0-9]{2})Z.*/\1 \2:\3:\4/')
    date -u -d "$stamp" +%s
}

validate_backup_env() {
    s3_require_env
    require_integer_at_least BACKUP_INTERVAL_SECONDS 60
    require_integer_at_least BACKUP_RETRY_SECONDS 1
    require_integer_at_least BACKUP_RETENTION 1
}

. "$LIB_DIR/s3.sh"
