#!/bin/sh

MIB=1048576
CGROUP_ROOT=/sys/fs/cgroup

host_memory_bytes() {
    kilobytes=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    printf '%s' "$((kilobytes * 1024))"
}

own_cgroup_dirs() {
    path=$(sed -n 's/^0:://p' /proc/self/cgroup)
    while true; do
        [ -d "$CGROUP_ROOT$path" ] && printf '%s\n' "$CGROUP_ROOT$path"
        [ -z "$path" ] || [ "$path" = "/" ] && return 0
        path=${path%/*}
    done
}

smallest_cgroup_memory_limit() {
    for dir in $(own_cgroup_dirs) "$CGROUP_ROOT/memory"; do
        cat "$dir/memory.max" "$dir/memory.limit_in_bytes" 2>/dev/null
    done | grep -E '^[0-9]+$' | sort -n | head -n 1
}

container_memory_bytes() {
    host=$(host_memory_bytes)
    limit=$(smallest_cgroup_memory_limit)
    if [ -z "$limit" ] || [ "$limit" -ge "$host" ]; then
        log "no cgroup memory limit below MemTotal found, sizing from MemTotal ($host bytes)"
        printf '%s' "$host"
        return
    fi
    printf '%s' "$limit"
}

cgroup_cpu_quotas() {
    for dir in $(own_cgroup_dirs); do
        cat "$dir/cpu.max" 2>/dev/null
    done
    if [ -r "$CGROUP_ROOT/cpu/cpu.cfs_quota_us" ]; then
        printf '%s %s\n' "$(cat "$CGROUP_ROOT/cpu/cpu.cfs_quota_us")" "$(cat "$CGROUP_ROOT/cpu/cpu.cfs_period_us")"
    fi
}

container_cpus() {
    online=$(nproc)
    limited=$(cgroup_cpu_quotas | awk '$1 ~ /^[0-9]+$/ && $1 > 0 { cpus = int(($1 + $2 - 1) / $2); print cpus }' | sort -n | head -n 1)
    [ -n "$limited" ] && [ "$limited" -lt "$online" ] && printf '%s' "$limited" || printf '%s' "$online"
}

clamp() {
    value=$1
    [ "$value" -lt "$2" ] && value=$2
    [ "$value" -gt "$3" ] && value=$3
    printf '%s' "$value"
}

buffer_pool_size_for() {
    printf '%s' "${MYSQL_BUFFER_POOL_SIZE:-$(($1 * MYSQL_BUFFER_POOL_PERCENT / 100))}"
}

redo_log_capacity_for() {
    clamp "$(($1 / 4))" "$((256 * MIB))" "$((8192 * MIB))"
}

message_cache_size_for() {
    clamp "$(($1 / 16))" "$((128 * MIB))" "$((1024 * MIB))"
}

max_connections_for() {
    clamp "$(($1 / 8 / MIB))" 200 4000
}

tuned_directives() {
    memory=$(container_memory_bytes)
    buffer_pool=$(buffer_pool_size_for "$memory")
    printf 'innodb_buffer_pool_size=%s\n' "$buffer_pool"
    printf 'innodb_redo_log_capacity=%s\n' "$(redo_log_capacity_for "$buffer_pool")"
    printf 'loose-group_replication_message_cache_size=%s\n' "$(message_cache_size_for "$memory")"
    printf 'max_connections=%s\n' "$(max_connections_for "$memory")"
    printf 'innodb_read_io_threads=%s\n' "$(clamp "$(container_cpus)" 4 16)"
    printf 'innodb_write_io_threads=%s\n' "$(clamp "$(container_cpus)" 4 16)"
}

env_directives() {
    env | awk -F '=' '/^MYSQL_CONFIG_[A-Z0-9_]+=/ {
        print tolower(substr($1, 14)) "=" substr($0, length($1) + 2)
    }'
}

reserved_env_directives() {
    env_directives | cut -d = -f 1 \
        | grep -xE 'port|bind_address|datadir|socket|pid_file|server_id|report_host|report_port|gtid_mode|enforce_gtid_consistency|log_bin|user|plugin_load_add|init_file|skip_networking|mysqlx|secure_file_priv'
}
