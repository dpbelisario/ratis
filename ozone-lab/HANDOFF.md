# Ozone incident lab: handoff

This lab reproduces the OM/SCM call-queue incident on Ozone 2.0.0. You can run it
on a laptop (WSL + Docker Engine), or view the run that was recorded in the cloud
on the real 01:00 / 10:00 JST schedule.

Rules:
- The lab is not production. Use placeholder names only (om1..om3, scm1..scm3).
- Do not copy hostnames, keys, logs or numbers from the real cluster into this folder
  or into a chat. Write only the scaled numbers in `lab.env`.

---

## 1. The problem, in simple words

- At about 06:30, the OM call queue (port 9862) started to climb. It stayed full at
  10,000 (100 handlers x 100 queue slots each) until a restart at about 11:00.
- At the same time, the SCM block queue (port 9863, `ScmBlockLocationProtocolService`)
  climbed in a straight line to about 2,400.
- The OM log shows retries and failover from OM to SCM.
- Two jobs run every day: at 01:00 (a large delete, Recon shows a large "pending delete"
  backlog) and at 10:00.
- The question: **why does the queue start to climb at about 06:00, and which OM/SCM
  metrics prove it?**

## 2. What the lab showed (tested on 2026-10-28)

All numbers are lab numbers (scale 1:200, see section 7).

| Test | OM queue (max 50) | OM done/s | SCM 9863 queue | SCM 9863 done/s | Elections | OM failover log lines |
|---|---|---|---|---|---|---|
| Normal traffic (5 keys/s) | 0 | ~10 | 0 | ~5 | 0 | 0 |
| `cpu`: SCM leader at 0.02 CPU | 4 | drops | 3 | drops | +3 (leader moved) | 38, then recovery |
| `cpu-all`: all SCMs at 0.02 CPU | 36 | 0 at times | small | ~0.5 | +6 (leader flaps) | 381 |
| `followers`: both SCM followers frozen | 11 (clients stuck) | 0 | 0 | 0 | 0 | 384 |
| `scm-slow`: each 9863 call takes 2 s | **50 (full)** | ~5 | 0 | 2.5 (= 5 handlers / 2 s) | 0 | 0 |
| `scm-stuck`: 9863 calls never finish | 11 | **0** | **straight line, +5 per timeout** | **0** | 0 | grows steadily |

Main result: **the straight line on SCM 9863 is what retries look like when SCM block
handlers do not finish.** An OM handler waits for SCM until `hdds.scmclient.rpc.timeout`
(default **15m**). Then the OM client fails over and sends the call again. The old call
stays in the SCM queue. So the SCM queue grows by about one call per OM handler per
timeout:

```
slope = OM handlers / hdds.scmclient.rpc.timeout
lab (accel profile, timeout 15s):  5 / 15 s  = +5 per 15 s   (measured: +5 per 15-20 s)
production (defaults):            100 / 15 min = 6.7/min = 400/hour
06:30 -> 11:00 = 4.5 h x 400/h  = about 1,800   (production showed about 2,400)
```

So the straight line does **not** mean "the load increased at 06:00". It means "at
about 06:00 the SCM block handlers stopped finishing their calls". The question then
becomes: **what blocked the SCM 9863 handlers at about 06:00?** Section 8 lists the
production queries that answer it.

### 2.1 One full lab day (accel profile, schedules/incident.conf, 2026-10-28)

1 real minute = 1 lab hour. Values per lab hour: queues and busy = maximum, rates = median.
Writer on all day (about 5 keys/s). Seed: 30,000 keys.

| Lab hour | OM queue | OM busy | OM done/s | SCM 9863 queue | SCM busy | SCM done/s | OM deletedTable | KDS sent/s | Writer clients | Fault |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 (job01: 30,000 deletes in 36 s) | 15 | 5 | 347 | 0 | 2 | 5.2 | 26,363 | 36 | 1 | - |
| 02 | 0 | 0 | 217 | 0 | 0 | 6.5 | 24,900 | 105 | 1 | - |
| 03 | 0 | 0 | 11 | 0 | 0 | 6.5 | 18,900 | 109 | 1 | - |
| 04 | 0 | 0 | 12 | 0 | 0 | 6.5 | 12,900 | 109 | 1 | - |
| 05 | 0 | 0 | 12 | 0 | 0 | 5.7 | 6,900 | 109 | 1 | - |
| 06 (fault-on scm-stuck) | 5 | 5 | 6.1 | 13 | 5 | 3.3 | 900 | 64 | 6 | on |
| 07 | 15 | 5 | 0.1 | 31 | 5 | 0.1 | 400 | 0 | 12 | on |
| 08 | 11 | 5 | 0.1 | **50 (full)** | 5 | 0.1 | 400 | 0 | 12 | on |
| 09 | 11 | 5 | 0 | 50 | 5 | 0.1 | 400 | 0 | 12 | on |
| 10 (job10 burst) | 12 | 5 | 0 | 50 | 5 | 0.1 | 400 | 0 | 12 | on |
| 11 (fault-off, restart OM leader) | 31 | 5 | 22 | 50 -> 0 | 5 | 46 | 0 | 7.3 | 11 | off |

SCM 9863 queue every 15 s from lab 06:00: `0, 1, 7, 13, 13, 19, 25, 31, 31, 37, 43, 49, 50, 50, ...`
(a straight line, then flat at the lab limit 5 x 10 = 50). No SCM leader election in the whole day.

What this shows:
1. **The 01:00 delete alone did not make the queues climb** at lab scale. The OM deletedTable
   drained by 6,000 keys per lab hour (100 per KeyDeletingService run), 1 DeleteScmKeyBlocks
   call per run, both queues at 0. The backlog reached about 0 at 06:00. Test it at your own
   scale with `schedules/jobs-only.conf` before you drop the hypothesis.
2. When the SCM 9863 handlers stop finishing, the picture is the production picture: OM handlers
   5/5, OM done/s 0, SCM 9863 queue in a straight line, OM log with failover lines, no election,
   KeyDeletingService stops (deletedTable stays at 400), writer clients pile up.
3. Release + restart clears it in about 20 s.

Screenshot of the dashboard for this day: `docs/accel-run1.png` (in the bundle).

## 3. Two ways to use the lab

**A. View the cloud run, like you view production.** A cloud machine ran the lab on the
real JST clock: normal traffic all day, the delete job at 01:00, the burst job at 10:00,
an SCM fault at 06:00 and a release plus restart at 11:00. Its Prometheus data is in an
export file (`lab-realtime-YYYYMMDD-HHMM.tar.gz`). You open it in a local Prometheus +
Perses with the same dashboard, and you use PromQL on it as on production:

```bash
cd ~/ozone-lab
./scenario.sh replay ~/lab-realtime-YYYYMMDD-HHMM.tar.gz
```

The command prints the Perses link with the correct time range. Replay uses ports 9091
(Prometheus) and 8081 (Perses), so it can run next to the live lab.

The cloud machine cannot accept connections from your laptop, so there is no live link.
The export is the full Prometheus data (every metric, 5 s resolution).

Note on the cloud machine: it is paused when the Claude session is idle, and it comes
back with its disk but with no processes. On 2026-10-28 it was paused from about 18:37 to
20:18 JST, so the evening data has that gap. `./scenario.sh ensure` restarts Docker,
recreates the containers (data stays in the volumes) and re-applies an active fault. The
session now keeps a background task running through the night so the machine stays up.

The first cloud day: the scheduler started at 18:25 JST on 2026-10-28 (writer on). It runs
job01 at 01:00, fault-on at 06:00, job10 at 10:00 and fault-off + restart at 11:00 JST on
2026-10-29. Two daily Routines (01:00 and 10:00 JST) check that the jobs ran and rerun them
if the cloud machine was replaced. The export `lab-realtime-20261029.tar.gz` comes after
11:20 JST. The accel day of section 2.1 is in `lab-accel-20261028-1820.tar.gz`; you can
replay it now.

**B. Run the lab on your laptop.** Two clock profiles:

| Profile | Clock | Use it for |
|---|---|---|
| `realtime` | JST wall clock. The jobs run at 01:00 and 10:00 JST. | The same day as production, overnight. |
| `accel` | 1 real minute = 1 lab hour. One lab day (00:00 -> 12:00) takes 12 minutes. | Quick tests, PromQL practice. |

## 4. WSL setup (one time)

1. In Windows, create or edit `%UserProfile%\.wslconfig`:
   ```
   [wsl2]
   memory=12GB
   processors=4
   ```
   Then run `wsl --shutdown` in PowerShell and open Ubuntu again.
2. In Ubuntu (WSL), start Docker Engine and check it:
   ```bash
   sudo service docker start
   ```
   ```bash
   docker compose version
   ```
   If you use systemd in WSL, `sudo systemctl start docker` also works.
3. Put `setup.sh` in your Linux home (not `/mnt/c`). From Windows, the path
   `\\wsl$\Ubuntu\home\<you>\` is your Linux home. Then:
   ```bash
   cd ~ && sed -i 's/\r$//' setup.sh && bash setup.sh
   ```
   This extracts the lab to `~/ozone-lab` and checks Docker, Compose, python3 and memory.

   Alternative: `git clone` the branch `claude/eloquent-albattani-yv1h9x` of your
   `ratis` fork; the lab is in the folder `ozone-lab/`. Copy that folder to your home.

## 5. Bring-up and URLs

```bash
cd ~/ozone-lab && ./scenario.sh up
```

First start pulls about 1.5 GB of images and takes 2-4 minutes. The command waits until
all 7 Ozone targets are up in Prometheus.

Open from Windows (WSL forwards localhost):

| What | URL |
|---|---|
| Perses dashboard "Ozone RPC" | http://localhost:8080/projects/ozone/dashboards/ozone-rpc |
| Prometheus | http://localhost:9090 |
| OM web UI om1 / om2 / om3 | http://localhost:19874 / 29874 / 39874 |
| SCM web UI scm1 / scm2 / scm3 | http://localhost:19876 / 29876 / 39876 |
| Datanode | http://localhost:19882 |
| Recon (optional: `docker compose --profile recon up -d recon`) | http://localhost:9888 |

## 6. Run the scenario

### 6.1 Real-time day (jobs at 01:00 and 10:00 JST)

```bash
cd ~/ozone-lab
./scenario.sh seed      # 30,000 keys (about 6 minutes)
./scenario.sh start     # scheduler daemon; keep WSL open overnight
```

The scheduler reads `schedules/incident.conf` and uses the JST clock (`LAB_TZ`):

| JST | Action | What it does |
|---|---|---|
| 00:00 | `writer-on` | Normal traffic: a new client every 10 s writes 50 keys (5 threads). About 5 keys/s = production 1,000 keys/s / 200. If OM does not answer, clients pile up (max 12). |
| 01:00 | `job01` | Bulk delete: the oldest written keys, up to `JOB01_KEYS` (30,000), with 20 threads (`freon ockr`). Feeds OM deletedTable -> KeyDeletingService -> SCM DeleteScmKeyBlocks. |
| 06:00 | `fault-on` | The lab's model of "SCM block handlers stop finishing" (`FAULT_MODE`, default `scm-stuck`). Remove this line to test the delete hypothesis alone (`schedules/jobs-only.conf`). |
| 10:00 | `job10` | Write burst: 10,000 keys with 40 threads. |
| 11:00 | `fault-off`, `restart` | Release the fault, then restart the OM leader (`RESTART_TARGET`). |

Events that are already past when the scheduler starts are skipped (except `writer-on`).
WSL must stay running: do not close the last Ubuntu window, and stop Windows sleep.

Stop everything: `./scenario.sh stop`. See the log: `tail -f logs/events.log`.

### 6.2 Accelerated day (12 minutes)

```bash
cd ~/ozone-lab
LAB_PROFILE=accel ./scenario.sh accel-day
```

This restarts the Ozone containers with `profiles/accel.env` (every background interval
and the OM->SCM RPC timeout divided by 60), seeds if needed, runs lab 00:00 -> 12:00,
prints the status table every lab hour, and writes an export to `exports/`.

To test the delete hypothesis with no injected fault:

```bash
LAB_PROFILE=accel SCHEDULE=schedules/jobs-only.conf ./scenario.sh accel-day
```

### 6.3 One step at a time

```bash
./scenario.sh status          # the table below
./scenario.sh job01           # run the 01:00 delete now
./scenario.sh job10           # run the 10:00 burst now
./scenario.sh fault-on scm-stuck    # or scm-slow, cpu, cpu-all, followers, pause, delay
./scenario.sh fault-off
./scenario.sh restart om-leader     # or scm-leader, om-all, none, or a service name
./scenario.sh leaders
./scenario.sh export          # Prometheus snapshot -> exports/*.tar.gz
./scenario.sh check-panels    # runs every dashboard query, shows empty ones
```

Put your own settings in `~/ozone-lab/lab.env` (shell format, for example
`SEED_KEYS=60000`). All settings and their defaults are at the top of `scenario.sh`.

### 6.4 Expected results per step

| Step | Expected in `status` and on the dashboard |
|---|---|
| seed / writer | OM completed/s about 10 (leader), SCM AllocateScmBlock about 5/s, queues 0. |
| job01 | OM key deletes/s up to about 370 for about 1.5 minutes. OM deletedTable jumps to about 30,000, then drains by 100 keys per minute (6,000 per hour). SCM DeleteScmKeyBlocks: 1 call per minute. SCM deletedBlocks grows (flushed every 10 minutes in realtime). |
| fault-on scm-stuck | SCM 9863 busy handlers 5/5, SCM 9863 done/s 0, OM busy 5/5, OM done/s 0. SCM 9863 queue: straight line, +5 per `hdds.scmclient.rpc.timeout` (15 min realtime, 15 s accel). OM log: failover lines. No SCM elections. |
| fault-on scm-slow | OM queue full (50), OM done/s low but not 0, SCM 9863 done/s = 2.5 (5 handlers / 2 s). |
| job10 during the fault | More clients wait. The OM queue grows toward 50. |
| fault-off / restart | Queues drain to 0 within about 20 s. Completed/s returns. |

The status table:

```
lab clock 2026-10-28 17:54 (realtime)  fault: scm-slow ...  writer: on (12 clients)  jobs: -  pool: 7900 keys
                      om1      om2      om3     scm1     scm2     scm3    (OM port 9862 | SCM port 9863)
call queue            0.0     50.0      0.0      0.0      0.0      0.0
busy handlers         0.0      5.0      0.0      0.0      5.0      0.0
completed/s           0.0      4.7      0.0      0.0      2.7      0.0
avg proc ms           0.0    719.3      0.0      0.0   2000.7      0.0
```

How to read it: only the leaders do work (here om2 and scm2). A full queue alone does
not mean failure. **Completed/s** tells "busy" (high) from "stuck" (near 0). Open
connections are not requests.

## 7. Scale model and settings

| Item | Production | Lab | Where |
|---|---|---|---|
| OM handlers x queue per handler | 100 x 100 = 10,000 | 5 x 10 = 50 | `docker-config` |
| SCM 9863 handlers | 100 (default) | 5 | `docker-config` |
| Normal write rate | about 1,000 keys/s (to confirm) | about 5 keys/s | `WRITER_*` |
| 01:00 delete size | unknown | 30,000 keys (= 6,000,000 / 200) | `JOB01_KEYS`, `SEED_KEYS` |
| KeyDeletingService keys per run | 20,000 / 1 min | 100 / 1 min | `profiles/*.env` |
| SCM deletes sent to datanodes per interval | 100,000 / 60 s | 500 / 60 s | `profiles/*.env` |
| OM -> SCM RPC timeout | 15m (default) | 15m realtime, 15s accel | `profiles/accel.env` |
| Bucket layout | unknown | OBJECT_STORE (`obs`); `fso` also exists | `BUCKET` |

Defaults read from Ozone 2.0.0 with `ozone getconf -confKey`:

| Key | Default |
|---|---|
| `hdds.scmclient.rpc.timeout` | 15m |
| `hdds.scmclient.max.retry.timeout` | 10m |
| `hdds.scmclient.failover.max.retry` | 15 |
| `hdds.scmclient.failover.retry.interval` | 2s |
| `ozone.block.deleting.service.interval` (OM KeyDeletingService) | 1m |
| `ozone.key.deleting.limit.per.task` | 20000 |
| `ozone.directory.deleting.service.interval` | 1m |
| `hdds.scm.block.deleting.service.interval` | 60s |
| `hdds.scm.block.deletion.per-interval.max` | 100000 |
| `hdds.datanode.block.deleting.limit.per.interval` | 5000 |
| `ozone.scm.block.deletion.max.retry` | 4096 |
| `ozone.scm.ha.dbtransactionbuffer.flush.interval` | 600s |
| `ozone.scm.ha.ratis.request.timeout` | 30s |
| `ipc.client.rpc-timeout.ms` | 120000 |
| `ipc.backoff.enable` | false (a full queue does not push back on clients) |
| `ipc.callqueue.impl` | LinkedBlockingQueue (FIFO) |

Measured lab throughput (cloud VM, 4 CPUs, 5 OM handlers, 1 KB keys, 20 threads):
`freon ockg` 270-290 keys/s on a 30,000-key run (85 keys/s on a 2,000-key run, JVM warm-up);
`freon ockr` 370-830 deletes/s. With the default 100 handlers the rate is limited by the
laptop CPU, not by the handlers. 1,000 keys/s is not a target for the lab: the scale model
divides key counts and rates by 200 (production 1,000 keys/s -> lab 5 keys/s).

## 8. Queries to run on production (06:00 - 11:00 window)

Change `job=` labels to the names that production uses. Look at the leaders.

| Question | PromQL | What proves what |
|---|---|---|
| Was OM busy or stuck? | `rate(rpc_rpc_processing_time_num_ops{port="9862"}[5m])` | Near 0 with a full queue = stuck. |
| Were all OM handlers busy? | `rpc_num_in_process_handler{port="9862"}` | 100 = all handlers wait (on SCM, a lock, or Ratis). |
| How long did OM calls take? | `rpc_rpc_processing_time_avg_time{port="9862"}` | Minutes = the handlers wait on SCM (the 15m timeout). |
| Did SCM block handlers finish anything? | `rate(rpc_rpc_processing_time_num_ops{servername="ScmBlockLocationProtocolService"}[5m])` | Near 0 = SCM 9863 handlers stuck (the lab's `scm-stuck`). Low but not 0 = slow (`scm-slow`). |
| Were all SCM block handlers busy? | `rpc_num_in_process_handler{servername="ScmBlockLocationProtocolService"}` | 100 = all blocked. |
| Is the straight line the retry slope? | `deriv(rpc_call_queue_length{servername="ScmBlockLocationProtocolService"}[30m]) * 3600` | About 400/hour = 100 OM handlers / 15 min timeout -> retries, not new load. |
| Which call type stopped at 06:00? | `sum by (type) (rate(scm_block_location_protocol_counter[5m]))` | The type whose rate goes to 0 first (AllocateScmBlock or DeleteScmKeyBlocks). |
| How long did each type take? | `sum by (type) (rate(scm_block_location_protocol_time[5m])) / sum by (type) (rate(scm_block_location_protocol_counter[5m]))` | A long DeleteScmKeyBlocks after 01:00 = the delete path holds 9863 handlers. |
| Did the SCM leader change? | `changes(ratis_leader_election_electionCount{job="<scm job>"}[1h])` | 0 = no real failover: the OM "failover" lines are retries. |
| Did the SCM state machine keep up? | `scalar(max(ratis_server_peerCommitIndex{job="<scm job>"})) - ratis_state_machine_applyCompletedIndex{job="<scm job>"}` | Growing lag = SCM Ratis apply is slow (every SCM write waits). |
| Was the Ratis log disk slow? | `ratis_log_worker_syncTime{job="<scm job>",quantile="0.99"}` | Seconds = slow disk / fsync. |
| Delete backlog (OM side) | `rocksdb_om_db_deletedtable_estimate_num_keys` | Big after 01:00, drains at 20,000 per minute. When does it reach 0? |
| Delete backlog (SCM side) | `rocksdb_scm_db_deletedblocks_estimate_num_keys` | Grows when OM hands blocks to SCM faster than datanodes delete them. |
| KeyDeletingService rate | `rate(deleting_service_metrics_num_keys_sent_for_purge[5m])` | When did it change near 06:00? |
| FSO delete backlog (if the buckets are FSO) | `rate(deleting_service_metrics_num_sub_files_moved_to_deleted_table[5m])`, `rocksdb_om_db_deleteddirectorytable_estimate_num_keys` | An FSO `rm -r` of a directory is **1** in `om_metrics_num_key_deletes`. Its files move to deletedTable later, in DirectoryDeletingService runs (every 60s, 10 threads). A delete at 01:00 can still be working at 06:00. |
| SCM JVM at 06:00 | `rate(jvm_metrics_gc_time_millis{processname="StorageContainerManager"}[5m])`, `jvm_metrics_mem_heap_used_m`, `jvm_metrics_threads_blocked` | GC near 1000 ms/s or many blocked threads = SCM cannot run its handlers. |

Production logs to check (no copy into the lab): the OM log near 06:00 for the first
`failover` / `NotLeaderException` / `timeout` line, and the SCM leader log near 06:00 for
long GC, Ratis, DeletedBlockLog or lock warnings. A thread dump (`jstack`) of the SCM
leader during the next event would show where the 9863 handlers wait.

## 9. How the parts connect

**Two state machines.**
- OM Ratis (port 9872): every OM write (create key, commit key, delete key, purge) is
  a Ratis log entry. The OM leader applies it to its RocksDB (`om.db`).
- SCM Ratis (port 9894): SCM writes (new containers, block-ID batches, deleted block
  log transactions) are Ratis log entries on the SCM leader.

**Write path.** Client -> OM 9862 (createKey) -> OM handler calls SCM 9863
`AllocateScmBlock` -> client writes data to the datanode -> OM commitKey. If SCM 9863
does not answer, the OM handler waits up to `hdds.scmclient.rpc.timeout` (15m).

**Delete loop.**
1. 01:00 job deletes keys -> OM moves them to `deletedTable` (OM Ratis).
2. OM KeyDeletingService (every 1m, up to 20,000 keys) sends their blocks to SCM 9863
   `DeleteScmKeyBlocks`.
3. SCM writes them to the deleted block log through SCM Ratis (`deletedBlocks` table,
   flushed every 10 minutes).
4. SCM SCMBlockDeletingService sends delete commands to datanodes (heartbeat responses).
5. When SCM accepts the blocks, OM purges the keys from `deletedTable` (OM Ratis).

**The colleague's theory (slow SCM, failover, "not leader").** If SCM is slow, OM
handlers wait. After the timeout, the OM client tries the next SCM. A follower answers
"not leader" quickly, and the client goes back to the leader. These lines are in the OM
log. The lab shows: retries and "not leader" lines do not need a real leader change
(`scm-stuck`: 0 elections). A real leader change (`cpu` fault) shows elections and then
recovers. A failover that does not recover needs a cause that stays: for example all SCMs
slow (`cpu-all`) or SCM handlers that never finish (`scm-stuck`).

**FSO delete (tested on 2.0.0).** `ozone fs -rm -r -skipTrash ofs://omservice/vol1/fso/<dir>`
removed a 300-key directory in one RPC (1.5 s). `om_metrics_num_key_deletes` went up by 1.
Within 60 s, DirectoryDeletingService moved the 300 files to deletedTable
(`deleting_service_metrics_num_sub_files_moved_to_deleted_table` = 300, `num_dirs_purged` = 1).
Then KeyDeletingService sent them to SCM as for OBS keys. Settings:
`ozone.directory.deleting.service.interval` = 60s, `ozone.thread.number.dir.deletion` = 10;
2.0.0 has no per-run file limit for this service.

**Faults in the lab** (`FAULT_MODE`):

| Mode | How | Models |
|---|---|---|
| `scm-stuck` (default) | Byteman rule: 9863 AllocateScmBlock / DeleteScmKeyBlocks block until `fault-off` | SCM block handlers never finish (lock, Ratis wait, ...) |
| `scm-slow` | Byteman rule: each 9863 call sleeps `FAULT_BLOCK_DELAY_MS` (2000) | SCM block handlers are slow |
| `cpu` | `docker update --cpus 0.02` on the SCM leader | One slow SCM machine |
| `cpu-all` | same on all 3 SCMs | SCM slow everywhere |
| `followers` | `docker pause` both SCM followers | SCM Ratis cannot commit |
| `pause` | `docker pause` the SCM leader | SCM process frozen |
| `delay` | `tc netem delay 500ms` on the SCM leader | Slow network. Not tested: the cloud kernel has no `sch_netem`. Test it in WSL. |

The scheduler also counts OM log lines with SCM retry / failover / not-leader messages
(`FAILOVER_RE` in `scenario.sh`) into the metric `lab_om_failover_log_lines_total`; the
dashboard shows it per minute in row 1. Production has no such metric: grep the OM log.

The Byteman rules are in `byteman/scm-fault.btm`. They are loaded at SCM start and do
nothing until `fault-on` writes a flag file in `/tmp/lab-fault/` inside the SCM containers.

## 10. To lock down

- [ ] Production numbers: keys/s (normal and at 10:00), total key count, size of the
      01:00 delete (keys), OM and SCM handler counts, `ipc.server.handler.queue.size`.
- [ ] Scale factor (default 1:200). Set it in `docker-config` and `profiles/*.env`.
- [ ] Bucket layout (OBJECT_STORE or FSO). Set `BUCKET=fso` in `lab.env` to model FSO:
      seed and writer then write into `/vol1/fso`, and job01 deletes each batch as a
      directory (`ozone fs -rm -r -skipTrash ofs://omservice/vol1/fso/<prefix>`). Tested.
- [ ] Delete command the 01:00 job uses (S3 DeleteObjects, `ozone sh key delete`, `fs -rm -r`).
- [ ] Network-delay fault (`delay`) in WSL: check `sudo modprobe sch_netem`.
- [ ] Time-compression factor for `accel` (`SEC_PER_LAB_HOUR`, default 60).
- [ ] What restarted at 11:00 (OM leader, all OMs, SCM leader). Set `RESTART_TARGET`.
- [ ] Production values of `hdds.scmclient.rpc.timeout` and the failover settings.

## 11. Files

| File | Content |
|---|---|
| `docker-compose.yaml` | 3 SCM, 3 OM, datanode, client, labmeta, Prometheus v3.15.1, Perses v0.55.0 (Recon optional) |
| `docker-config` | Ozone settings (HA, small RPC capacity) |
| `profiles/realtime.env`, `profiles/accel.env` | Clock profile settings (delete pacing, intervals, timeouts) |
| `schedules/incident.conf`, `schedules/jobs-only.conf` | Lab-clock schedules |
| `scenario.sh` | All commands (section 6) |
| `byteman/` | SCM fault rules |
| `prometheus.yml` | Scrapes `/prom` every 5 s: om1-3:9874, scm1-3:9876, datanode:9882, labmeta |
| `perses/make-dashboard.py` | Generates the "Ozone RPC" dashboard (36 panels in 6 rows + a read-me panel) |
| `docs/accel-run1.png` | Dashboard screenshot of the accel day in section 2.1 |
| `docker-compose.replay.yaml`, `replay/` | Replay stack for exports |
| `make-bundle.sh` | Builds `dist/setup.sh` |

Memory: 7 Ozone JVMs at 1 GB heap + Prometheus + Perses + clients: about 9-10 GB.
Set `OZONE_HEAP=768m` in `lab.env` on a smaller machine.
