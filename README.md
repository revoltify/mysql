# mysqlctl

- [Introduction](#introduction)
- [Installation](#installation)
    - [Requirements](#requirements)
    - [Updating](#updating)
    - [Uninstalling](#uninstalling)
- [Preparing Your Servers](#preparing-your-servers)
- [Creating a Cluster](#creating-a-cluster)
    - [Single Server or High Availability](#single-server-or-high-availability)
- [Connecting Laravel](#connecting-laravel)
    - [Using Your Own Domain](#using-your-own-domain)
    - [Without a Domain](#without-a-domain)
    - [Read Replicas](#read-replicas)
    - [Read-Only Nodes](#read-only-nodes)
    - [Primary Keys](#primary-keys)
- [Managing Servers](#managing-servers)
    - [Adding Servers](#adding-servers)
    - [Removing Servers](#removing-servers)
    - [Replacing Servers](#replacing-servers)
- [Operations](#operations)
    - [Checking Status](#checking-status)
    - [Failing Over](#failing-over)
    - [Upgrading](#upgrading)
    - [Rotating Certificates](#rotating-certificates)
    - [Backups](#backups)
    - [Running SQL](#running-sql)
- [Command Reference](#command-reference)

<a name="introduction"></a>
## Introduction

`mysqlctl` sets up and runs a [MySQL 8.4 LTS](https://dev.mysql.com/doc/refman/8.4/en/) InnoDB Cluster on your own servers, entirely over SSH from your machine. One server or many, it handles installation, Group Replication, automatic failover, TLS certificates and backups, so your Laravel application and Horizon workers always reach a single, encrypted endpoint.

Every server runs the same Docker image. Clients connect on port `6446` with TLS; MySQL Router on each server forwards them to whichever server is currently the primary, so failovers are invisible to your application. A write is only acknowledged once a majority of servers has it, so a failover never loses a committed transaction.

<a name="installation"></a>
## Installation

Install `mysqlctl` with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/revoltify/mysql/main/install.sh | sh
```

The command is installed to `/usr/local/bin` (or `~/.local/bin` when that isn't writable) and pinned to the version you installed. Everything `mysqlctl` knows about your clusters lives in `~/.mysqlctl`.

> [!WARNING]
> `~/.mysqlctl` holds each cluster's passwords and its certificate authority key. Back it up somewhere safe.

<a name="requirements"></a>
### Requirements

Your machine needs `bash`, `ssh`, `curl`, `openssl` and `awk`, which macOS and most Linux distributions already include. You also need SSH access as `root` (or a sudo user) to each server using your SSH key.

<a name="updating"></a>
### Updating

```bash
mysqlctl self-update
```

<a name="uninstalling"></a>
### Uninstalling

```bash
mysqlctl uninstall
```

Your cluster data in `~/.mysqlctl` is kept. To delete it as well, pass `--purge`. Your servers keep running either way.

```bash
mysqlctl uninstall --purge
```

<a name="preparing-your-servers"></a>
## Preparing Your Servers

Create your servers with your provider before running `mysqlctl`:

- Ubuntu 24.04+ or Debian 12+, with at least 2 GB of RAM.
- All servers in the **same region and private network** (VPC).
- Your SSH key installed for `root`.

In your provider's firewall, allow SSH from your own IP, all traffic inside the private network, and port `6446` from your application or load balancer. Nothing else needs to be open.

> [!NOTE]
> Placing a TCP load balancer in front of port `6446` on every server gives your application one stable address that never changes as you add or replace servers.

<a name="creating-a-cluster"></a>
## Creating a Cluster

Choose a name for your cluster and run `init`:

```bash
mysqlctl init main
```

The first time, `mysqlctl` asks a few questions: single server or high availability, each server's name, public IP and private IP, the SSH user, the addresses your application uses to connect (your load balancer IP or hostname), the database and user for your application, and optional S3 backups. Press **Enter** to accept a default.

After showing you the plan, it installs Docker on every server, generates the passwords and TLS certificate, creates the cluster, and creates your application's database and user.

<a name="single-server-or-high-availability"></a>
### Single Server or High Availability

A **single server** is the simplest start, but it has no failover: restarting it briefly interrupts your application.

**High availability** needs at least three servers. When the primary fails, the others elect a new one within about ten seconds, with no action from you. When the failed server comes back, it catches up and rejoins on its own. You can start with one server and [add more](#adding-servers) at any time.

| Servers | Survives |
|---|---|
| 1 | no failures |
| 3 | 1 failure |
| 5 | 2 failures |

If every server goes down at once, the cluster restarts itself as soon as a majority is back, led by the server with the most recent data.

<a name="connecting-laravel"></a>
## Connecting Laravel

The `env` command prints the settings for your application's `.env`:

```bash
mysqlctl env main
```

The connection is always encrypted. Laravel's default `config/database.php` already passes `MYSQL_ATTR_SSL_CA` to PDO, so no code changes are needed.

> [!WARNING]
> Keep the `MYSQL_ATTR_SSL_CA` line. Laravel only turns on TLS when it is set, and without it every connection fails with `SSL connection error: SSL is required from client`.

<a name="using-your-own-domain"></a>
### Using Your Own Domain

The simplest setup gives your servers a free, publicly trusted certificate from Let's Encrypt, so Laravel verifies the connection with the certificate bundle every server already has.

You need a domain whose DNS is on Cloudflare and a Cloudflare API token with **Zone → DNS → Edit** for that zone only. Answer **y** to the domain question during `init`, or switch an existing cluster at any time:

```bash
mysqlctl domain main
```

Then point the domain at your load balancer, or at your servers' public IPs, with a DNS-only (grey cloud) record. `env` now prints:

```env
DB_CONNECTION=mysql
DB_HOST=mysql.example.com
DB_PORT=6446
DB_DATABASE=laravel
DB_USERNAME=laravel
DB_PASSWORD=...
MYSQL_ATTR_SSL_CA=/etc/ssl/certs/ca-certificates.crt
```

`MYSQL_ATTR_SSL_CA` points at the system certificate bundle, whose location depends on where your application runs:

| Where Laravel runs | `MYSQL_ATTR_SSL_CA` |
|---|---|
| Debian, Ubuntu or Alpine based containers (Bunny Magic Containers, Docker) | `/etc/ssl/certs/ca-certificates.crt` |
| macOS (local development) | `/etc/ssl/cert.pem` |

Certificates renew automatically. Until the first one is issued, the servers keep using their private certificate.

> [!NOTE]
> Let's Encrypt proves you own the domain by creating a temporary DNS record, which is why the token is needed. No ports have to be opened for it.

<a name="without-a-domain"></a>
### Without a Domain

Without a domain, the servers use a certificate from the cluster's own certificate authority, and `env` adds it to the settings:

```env
DB_CONNECTION=mysql
DB_HOST=203.0.113.10
DB_PORT=6446
DB_DATABASE=laravel
DB_USERNAME=laravel
DB_PASSWORD=...
MYSQL_ATTR_SSL_CA=/tmp/mysql/ca.crt
DB_SSL_CA_B64=...
```

Save the certificate as a file when your application starts. On Bunny Magic Containers, add this to your container's start command:

```bash
mkdir -p /tmp/mysql && echo "$DB_SSL_CA_B64" | base64 -d > /tmp/mysql/ca.crt
```

Anywhere else, such as on your own machine, write the file once and point `MYSQL_ATTR_SSL_CA` at it. The certificate is also stored at `~/.mysqlctl/clusters/<cluster>-tls/ca.crt`.

> [!NOTE]
> `DB_HOST` must be one of the names you gave for TLS during `init`, because the certificate is only valid for those names.

<a name="read-replicas"></a>
### Read Replicas

Port `6447` on every server spreads read-only connections over the secondaries and any [read-only nodes](#read-only-nodes). To use it, open the port in your firewall and give your `mysql` connection in `config/database.php` separate read and write ports:

```php
'mysql' => [
    'read' => [
        'port' => 6447,
    ],
    'write' => [
        'port' => 6446,
    ],
    'sticky' => true,
    // ...
],
```

Secondaries apply writes a moment after the primary, so keep `sticky` enabled.

<a name="read-only-nodes"></a>
### Read-Only Nodes

A read-only node copies the data from the primary and then follows it with asynchronous replication. It serves reads on `6447` but never votes, never becomes the primary and is not counted when the members decide whether they still have a majority. Start it like any other server, with these lines in its `.env`:

```ini
MYSQL_PRIVATE_IP=10.104.0.9
CLUSTER_HOSTS=10.104.0.1,10.104.0.2,10.104.0.3,10.104.0.9
CLUSTER_ROLE=read_replica
CLUSTER_SEED=false
```

`CLUSTER_HOSTS` lists every server, members and read-only nodes alike. `CLUSTER_ROLE` defaults to `member`, and a read-only node can never be the seed. A server keeps the role it joined with: to change it, start the server again with an empty data directory. When the primary changes, the read-only node switches to the new one by itself. If it was cut off for a while, it can take up to a minute or two. Its `node-status` reports `role=read_replica` and `state=ONLINE` while its replication channel is running.

<a name="primary-keys"></a>
### Primary Keys

Group Replication only accepts writes to tables that have a primary key. Laravel's default migrations all have one; give your own tables one too, for example `$table->id()`, or `$table->primary(['user_id', 'role_id'])` on pivot tables.

<a name="managing-servers"></a>
## Managing Servers

<a name="adding-servers"></a>
### Adding Servers

Create the server in the same private network, then pass its name and `public-ip/private-ip`:

```bash
mysqlctl add-node main mysql-04 203.0.113.14/10.104.0.7
```

The server is installed, copies the data from the primary and joins the cluster. The rest of the cluster is updated automatically.

<a name="removing-servers"></a>
### Removing Servers

```bash
mysqlctl remove-node main mysql-04
```

`mysqlctl` refuses to remove the current primary or to leave fewer than three members. Read-only nodes do not count towards that and can always be removed. The removed server's data stays on disk until you delete the server. If the server can no longer be reached, `mysqlctl` stops instead of leaving a node that could rejoin when it boots; destroy the server first, then rerun with `--force`.

<a name="replacing-servers"></a>
### Replacing Servers

Swap a server for a new one without dropping below your current size:

```bash
mysqlctl replace-node main mysql-02 mysql-05 203.0.113.15/10.104.0.8
```

<a name="operations"></a>
## Operations

<a name="checking-status"></a>
### Checking Status

```bash
mysqlctl status main
```

Shows each server's state, role, replication queue, memory and containers, and checks that an encrypted connection through each server's port `6446` reaches the primary, ending with `healthy` or the problems found.

<a name="failing-over"></a>
### Failing Over

Move the primary role to another server, for example before maintenance:

```bash
mysqlctl failover main
```

A planned switch lets running transactions finish first. Pass a server name to choose the new primary: `mysqlctl failover main mysql-03`.

To see how your application behaves during a real failure, `test-failover` kills the primary under write load and reports the error window and any lost writes:

```bash
mysqlctl test-failover main
```

<a name="upgrading"></a>
### Upgrading

```bash
mysqlctl upgrade main
```

Secondaries are upgraded one at a time, then the primary role moves away and the old primary is upgraded last. Pass a tag to pin a specific image version: `mysqlctl upgrade main 1.2.0`.

<a name="rotating-certificates"></a>
### Rotating Certificates

```bash
mysqlctl rotate-certs main
```

Issues a new server certificate from the cluster's certificate authority. Your application keeps working, since the authority itself does not change.

<a name="backups"></a>
### Backups

When backups are enabled during `init`, one of the secondaries uploads a compressed physical backup (Percona XtraBackup) to your S3-compatible storage (Bunny Storage, Cloudflare R2, AWS S3, Backblaze B2) on a schedule. To take one immediately:

```bash
mysqlctl backup-now main
```

If the cluster is created again on empty servers, the first server restores the newest valid backup before the others join.

To see which backups exist, run `list-backups` on any server. It reads `BACKUP_PATH` by default, or the path you give it:

```bash
docker exec mysql-mysql-1 list-backups
docker exec mysql-mysql-1 list-backups mysql/old-cluster
```

To start a new cluster from another cluster's backups, or from an older backup, add these lines to the first server's `.env` before its first start:

```ini
RESTORE_PATH=mysql/old-cluster
RESTORE_BACKUP=backup-20260101T030000Z.xbstream.zst
```

`RESTORE_PATH` is only read for the restore. New backups still go to `BACKUP_PATH`, so give the new cluster its own path. `RESTORE_BACKUP` picks one backup by its `list-backups` name instead of the newest. Both apply only on the first server (`CLUSTER_SEED=true`) when it starts with an empty data directory. If the path has no backups or the named backup cannot be restored, the server refuses to start instead of starting empty.

<a name="running-sql"></a>
### Running SQL

Run SQL on the current primary:

```bash
mysqlctl cli main "SHOW DATABASES"
```

Without SQL, `cli` opens an interactive `mysql` prompt. You can also pipe a file into it, for example to import a dump:

```bash
mysqlctl cli main < dump.sql
```

Or open a shell on a server:

```bash
mysqlctl ssh main mysql-01
```

<a name="command-reference"></a>
## Command Reference

| Command | Description |
|---|---|
| `init <cluster>` | Create a cluster, asking for its settings the first time |
| `status <cluster>` | Health of every server and its router |
| `add-node <cluster> <name> <public>/<private>` | Add a server |
| `remove-node <cluster> <name>` | Remove a server |
| `replace-node <cluster> <old> <new> <public>/<private>` | Replace a server |
| `failover <cluster> [node]` | Move the primary role to another server |
| `test-failover <cluster>` | Measure a failover under write load |
| `upgrade <cluster> [tag]` | Rolling upgrade to a new image |
| `rotate-certs <cluster>` | Issue a new server certificate |
| `domain <cluster>` | Use a Let's Encrypt certificate for your domain |
| `backup-now <cluster>` | Upload a backup now |
| `env <cluster>` | Print Laravel environment variables |
| `cli <cluster> [sql]` | Run SQL on the primary |
| `ssh <cluster> [node]` | Open a shell on a server |
| `list` | List your clusters |
| `version` | Show the installed version |
| `self-update` | Install the latest version |
| `uninstall [--purge]` | Remove `mysqlctl` |

Every command that changes your servers shows its plan and asks for confirmation first. Pass `--yes` to skip the prompt, for example in scripts.
