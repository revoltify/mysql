#!/bin/sh

MYSQL_PORT=3306
CLUSTER_ADMIN_USER=clusteradmin
ADMIN_CLIENT_CONFIG=/tmp/mysql-admin.cnf
PEER_TIMEOUT_SECONDS=3
IPV4_PATTERN='([0-9]{1,3}\.){3}[0-9]{1,3}'
METADATA_SCHEMA=mysql_innodb_cluster_metadata
READ_REPLICA_CHANNEL=read_replica_replication

: "${CLUSTER_NAME:=main}"
: "${CLUSTER_SEED:=false}"
: "${CLUSTER_ROLE:=member}"

validate_topology_env() {
    require_env MYSQL_PRIVATE_IP
    require_matching MYSQL_PRIVATE_IP "$IPV4_PATTERN" 'MYSQL_PRIVATE_IP must be an IPv4 address'
    [ -z "${CLUSTER_HOSTS:-}" ] || require_matching CLUSTER_HOSTS "$IPV4_PATTERN(,$IPV4_PATTERN)*" 'CLUSTER_HOSTS must be comma-separated IPv4 addresses without spaces'
    require_matching CLUSTER_NAME '[A-Za-z][A-Za-z0-9_]{0,39}' 'CLUSTER_NAME must start with a letter and use letters, digits and _'
    require_boolean CLUSTER_SEED
    require_matching CLUSTER_ROLE '(member|read_replica)' 'CLUSTER_ROLE must be member or read_replica'
    [ "$CLUSTER_ROLE" = "member" ] || [ "$CLUSTER_SEED" = "false" ] || fail 'a read_replica cannot be the CLUSTER_SEED, seed a member instead'
}

is_read_replica() {
    [ "$CLUSTER_ROLE" = "read_replica" ]
}

instance_type() {
    is_read_replica && { printf 'read-replica'; return; }
    printf 'group-member'
}

replica_channel_state() {
    sql -e "SELECT SERVICE_STATE FROM performance_schema.replication_connection_status WHERE CHANNEL_NAME = '$READ_REPLICA_CHANNEL'"
}

cluster_hosts() {
    printf '%s\n' "${CLUSTER_HOSTS:-$MYSQL_PRIVATE_IP}" | tr ',' '\n'
}

peer_hosts() {
    cluster_hosts | grep -vx "$MYSQL_PRIVATE_IP" || true
}

host_count() {
    cluster_hosts | wc -l | tr -d ' '
}

majority_of() {
    printf '%s' "$(($1 / 2 + 1))"
}

instance_address() {
    printf '%s:%s' "$1" "$MYSQL_PORT"
}

server_id_for() {
    printf '%s' "$1" | awk -F . '{ printf "%d", (($1 * 256 + $2) * 256 + $3) * 256 + $4 }'
}

write_admin_client_config() {
    [ -s "$ADMIN_CLIENT_CONFIG" ] && return 0
    (umask 077 && printf '[client]\nuser=%s\npassword="%s"\n' "$CLUSTER_ADMIN_USER" "$CLUSTER_ADMIN_PASSWORD" > "$ADMIN_CLIENT_CONFIG")
}

peer_sql() {
    host=$1
    shift
    write_admin_client_config
    mysql --defaults-extra-file="$ADMIN_CLIENT_CONFIG" -h "$host" -P "$MYSQL_PORT" --connect-timeout="$PEER_TIMEOUT_SECONDS" -NB -e "$*" </dev/null 2>/dev/null
}

reachable() {
    peer_sql "$1" 'SELECT 1' > /dev/null
}

primary_seen_by() {
    peer_sql "$1" "SELECT MEMBER_HOST FROM performance_schema.replication_group_members
        WHERE MEMBER_ROLE = 'PRIMARY' AND MEMBER_STATE = 'ONLINE'
        AND EXISTS (SELECT 1 FROM performance_schema.replication_group_members WHERE MEMBER_ID = @@server_uuid AND MEMBER_STATE = 'ONLINE')" \
        | grep -Ex "$IPV4_PATTERN"
}

online_primary() {
    for host in $(cluster_hosts); do
        primary_seen_by "$host" && return 0
    done
    return 1
}

membership_recorded_on() {
    [ "$(peer_sql "$1" "SELECT COUNT(*) FROM $METADATA_SCHEMA.instances WHERE mysql_server_uuid = @@server_uuid")" = "1" ]
}

metadata_present_on() {
    [ "$(peer_sql "$1" "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = '$METADATA_SCHEMA'")" = "1" ]
}

reachable_peers_with_metadata() {
    for host in $(peer_hosts); do
        metadata_present_on "$host" && printf '%s\n' "$host"
    done
    return 0
}

no_reachable_peer_has_metadata() {
    [ -z "$(reachable_peers_with_metadata)" ]
}

cluster_shell() {
    host=$1
    shift
    mkdir -p "$MYSQLSH_USER_CONFIG_HOME"
    mysqlsh --no-wizard --js -e "shell.connect({user: '$CLUSTER_ADMIN_USER', host: '$host', port: $MYSQL_PORT, password: os.getenv('CLUSTER_ADMIN_PASSWORD')}); $*"
}
