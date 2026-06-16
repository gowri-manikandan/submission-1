# Redis Cluster Lifecycle Tool

A small command-line tool (`redis-tool`) that builds, operates, and upgrades a
**6-node Redis Cluster** (3 masters + 3 replicas) running inside Docker
containers. Everything is driven by one CLI — you never SSH in or type
`redis-cli` by hand. The CLI calls **Ansible**, and Ansible does the work on the
nodes over SSH.

---

## 1. The big picture (read this first)

```
  YOUR LAPTOP (control node)
  ┌─────────────────────────────────────────────┐
  │  ./redis-tool  ... (bash CLI)               │
  │        │                                    │
  │        ▼                                    │
  │  ansible-playbook  (automation)             │
  └────────┬────────────────────────────────────┘
           │ SSH (ports 2201–2206)
           ▼
  6 Docker containers = 6 "servers"
  redis-node-1 .. redis-node-6   (IPs 10.10.0.11 .. 10.10.0.16)
        → each runs Redis, joined into ONE cluster
```

- **`redis-tool`** = a bash script. It only *orchestrates*; it does not replace Ansible.
- **Ansible** = installs Redis, writes config, starts Redis, forms the cluster.
- **Docker** = 6 Ubuntu containers that pretend to be 6 remote servers with SSH.

---

## 2. What you need (prerequisites)

The tool checks these for you on every run and stops if something is missing:

| Tool | Why | Install |
|------|-----|---------|
| Docker **or** Podman | Runs the 6 containers | <https://docs.docker.com/engine/install/> |
| Ansible **2.14+** | Configures the nodes | `pip install ansible` |
| An SSH key at `~/.ssh/id_rsa` | Lets Ansible log into the containers | `ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""` |

---

## 3. One-time setup (bring the servers up)

The SSH public key is **baked into the container image** at build time, so SSH
works the moment a container starts — no separate key-copy step.

```bash
# 1. Put your public key in the build context (so the image can COPY it)
cp ~/.ssh/id_rsa.pub infra/id_rsa.pub

# 2. Build the image and start the 6 containers
cd infra
docker compose up -d --build
docker compose ps          # should show 6 containers running
cd ..

# 3. Test connectivity (optional)
cd ansible && ansible redis_nodes -m ping   # expect "pong" from all 6
```

> If you change your SSH key later, re-copy it to `infra/id_rsa.pub` and rebuild.
> (`scripts/bootstrap-ssh.sh` still exists as a fallback that injects the key into
> already-running containers, but it is no longer needed.)

---

## 4. The 5 commands (the actual task)

Run all of these from the project root (`task/`).

### Phase 1 — Provision (build the cluster)
```bash
./redis-tool provision --version 7.0.15 --masters 3 --replicas-per-master 1
```
Installs Redis **7.0.15** (built from source for an exact version), configures
cluster mode, starts Redis on all 6 nodes, and forms the cluster.

### Phase 2 — Seed and verify data
```bash
./redis-tool data seed --keys 1000      # writes 1000 keys
./redis-tool data verify --keys 1000    # PASS — 1000/1000 keys verified
```
Each key's value is `SHA256(key name)`. Because the value is *computed*, verify
can re-check every key without storing anything separately.

### Phase 3 — Status
```bash
./redis-tool status
```
Prints cluster state, masters (slots + key counts), replicas (who they follow),
versions, and memory.

### Phase 4 — Rolling upgrade (zero downtime)
```bash
./redis-tool upgrade --target-version 7.2.6 --strategy rolling
```
See the strategy in section 5.

### Phase 5 — Full verification
```bash
./redis-tool verify --full --keys 1000 --target-version 7.2.6
```
Runs 5 checks: data integrity, version consistency, slot coverage (16384),
cluster state, and replication health. Prints PASS/FAIL for each.

---

## 4b. Extra commands (stretch goals)

### Scale out — add a master + replica pair
```bash
./redis-tool scale --add-nodes 2
```
Starts 2 spare containers (node-7/8, off by default), installs Redis on them at
the cluster's current version, joins them with `CLUSTER MEET` (one new master +
its replica), and **rebalances** hash slots so the new master gets its share.
Data is preserved.

### Rollback — undo a partial/aborted upgrade
```bash
./redis-tool rollback --target-version 7.0.15
```
Downgrades any node that is *ahead* of the target version. Each rolled-back node
is **wiped and re-syncs clean from a surviving old-version master**. This works
while old-version masters are still alive (i.e. aborting a partial upgrade) — see
*Known limitations* for why a full downgrade can't preserve data.

---

## 5. The rolling upgrade strategy (and why)

The cluster must stay healthy (`cluster_state:ok`) the whole time. The order is
what makes it safe:

1. **Pre-flight checks** — cluster healthy? all nodes reachable? version actually
   different? data baseline OK? If any fail, stop before touching anything.
2. **Upgrade replicas first, one at a time** — a replica doesn't serve hash
   slots, so taking one down doesn't lose data or availability. Wait for
   `cluster:ok` after each.
3. **Upgrade masters with failover** — for each master, first run
   `CLUSTER FAILOVER` on its *already-upgraded* replica so the replica becomes
   the master. Traffic moves to the new version, then the old master (now a
   replica) is upgraded safely.
4. **Post-upgrade verification** — `data verify` + `status` prove zero data loss.

> One-line reason: **never take down a serving master before a newer replica has
> taken its place.**

---

## 6. Stretch goals implemented

- **S1 — Scale out:** `./redis-tool scale --add-nodes 2` adds a new master +
  replica pair (from 2 pre-declared spare containers) and rebalances slots, live.
- **S3 — Rollback:** `./redis-tool rollback --target-version <old>` undoes a
  partial/aborted upgrade by downgrading the upgraded nodes (wipe + re-sync from a
  surviving old-version master). Full-downgrade limitation documented below.
- **S4 — Idempotency:** running `provision` again is a no-op (it detects a healthy
  cluster and skips creation); running `upgrade` when every node is already on the
  target version prints "nothing to do" and exits cleanly without any failover.
- **S5 — Structured logging:** every command writes a JSON-lines log to `logs/`
  (`logs/<command>_<timestamp>.jsonl`) with timestamp, node, action, and outcome.

(S2 — scale-in — is the natural next step: `reshard` slots off a master, then
`del-node` it and its replica. Not implemented.)

---

## 7. Assumptions & trade-offs

- **Build from source, not apt.** Ubuntu's `apt install redis-server` gives 6.0.16,
  not the exact version the task asks for, so the tool compiles the requested
  version into `/usr/local/bin`. Trade-off: provision/upgrade take longer.
- **SSH key baked into the image.** The image `COPY`s `infra/id_rsa.pub` into
  `authorized_keys`, so new containers (including scaled-out spares) are reachable
  the instant they start — no runtime key injection.
- **Pre-declared spares for scale-out.** The infra defines 8 containers; 6 run by
  default and 2 (node-7/8, behind a compose `profile`) stay off until `scale`
  starts them. Static IPs `10.10.0.11`–`10.10.0.18`.
- **Commands run from node-1.** All `redis-cli` cluster commands are issued on
  `redis-node-1` over SSH, so the tool needs only that node reachable for status/verify.

---

## 8. Known limitations

- **Downgrade after a completed major upgrade is not data-safe.** Redis 7.2 writes
  RDB format v11, which Redis 7.0 cannot read. A true rolling *rollback* therefore
  only works while the old-version masters are still alive (i.e. aborting a
  *partial* upgrade). A full downgrade would need a data flush + re-seed.
- **Containers have no systemd.** Redis is started directly with
  `redis-server /etc/redis/redis.conf`, not via `systemctl`.

---

## 9. Project layout

```
task/
├── redis-tool                 # the CLI (bash) — provision/data/status/upgrade/rollback/verify/scale
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/hosts.ini     # 6 active nodes + 2 spares (separate group) + IPs
│   ├── playbooks/              # provision.yml, provision_node.yml, upgrade_node.yml
│   └── roles/redis/            # install, configure, start, create_cluster, upgrade tasks + redis.conf template
├── infra/
│   ├── Containerfile           # Ubuntu + SSH image (bakes in id_rsa.pub)
│   ├── id_rsa.pub              # your SSH public key (copied into the build context)
│   └── compose.yml             # 8 nodes on 10.10.0.0/24 (node-7/8 behind "scale" profile)
├── scripts/                    # seed, verify, status, failover, preflight, scale_out, wait_cluster_ok, bootstrap-ssh
├── logs/                       # JSON operation logs (S5)
└── output/                     # saved terminal output of each command
```

> Note: a few internals still assume the original 6 nodes (the upgrade replica
> loop). After `scale`, a later `upgrade` would need those parts made dynamic to
> include node-7/8 — a known follow-up.
