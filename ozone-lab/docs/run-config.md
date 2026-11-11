# Lab run details (daily realtime run, Ozone 2.0.0)

Lab only. Placeholder hostnames. Not production data.

## Topology and versions

| Item | Lab |
|---|---|
| Ozone image | apache/ozone:2.0.0 |
| OM | 3 (HA, Ratis), heap 1 GB each |
| SCM | 3 (HA, Ratis), heap 1 GB each, Byteman fault rules loaded |
| Datanode | 1 (so replication ONE) |
| Recon | 1 |
| Client (freon) | 1 container, heap 2 GB; each freon JVM 384 MB |
| Prometheus | v3.15.1, scrape every 5 s, /prom on OM 9874, SCM 9876 |
| Perses | v0.55.0 |

## Daily schedule (JST, schedules/incident.conf)

| Time | Action | Detail |
|---|---|---|
| 00:00 | writer-on | Normal traffic: a new freon client every 10 s, 50 keys x 1 KB, 5 threads, max 16 clients alive |
| 01:00 | job01 | Bulk delete of the oldest batches, up to 60,000 keys (8 batches in parallel, 10 threads each) |
| 06:00 | fault-on | scm-stuck: every SCM 9863 allocateBlock / deleteKeyBlocks call blocks until fault-off |
| 10:00 | job10 | Write burst: 10,000 keys x 1 KB, 40 threads |
| 11:00 | restart om-all | om1, om2, om3 stopped one by one, 60 s grace, then killed |
| 11:10 | restart scm-leader | 60 s grace |
| 11:20 | fault-off | SCM block calls finish again |
| 11:30 | export | exports/lab-realtime-YYYYMMDD.tar.gz (Prometheus data + logs) |

## Scaling to production

| | Production default | Lab | Ratio |
|---|---|---|---|
| OM 9862 handlers x queue per handler | 100 x 100 = 10,000 slots | 5 x 100 = 500 | 1:20 |
| SCM 9863 handlers x queue | 100 x 100 = 10,000 | 5 x 100 = 500 | 1:20 |
| Delete pacing (3 limits below) | 20000 / 100000 / 5000 | 100 / 500 / 25 | 1:200 |
| Bulk delete size | ~6,000,000 keys | 30,000-60,000 keys | 1:100-1:200 |

Known limit: RPC capacity is scaled 1:20 but delete pacing 1:200. Compare shapes (staircase vs
straight line, time of climb), not absolute numbers.

## Config: Ozone 2.0.0 default vs lab

Bold = set in the lab (docker-config, profiles/realtime.env). Defaults come from the
ozone-default XML files inside the 2.0.0 jars.

| Key | Ozone 2.0.0 default | Lab | Your prod (fill in) |
|---|---|---|---|
| `ozone.om.handler.count.key` | 100 | **5** | |
| `ozone.scm.block.handler.count.key` | 100 | **5** | |
| `ozone.scm.client.handler.count.key` | 100 | = default | |
| `ozone.scm.datanode.handler.count.key` | 100 | = default | |
| `ipc.server.handler.queue.size` | 100 | **100** | |
| `ipc.server.max.response.size` | 1048576 | = default | |
| `ipc.9862.backoff.enable` | (not in defaults) | = default | |
| `ipc.9863.backoff.enable` | (not in defaults) | = default | |
| `ipc.backoff.enable` | false | = default | |
| `ipc.9862.callqueue.impl` | (not in defaults) | = default | |
| `ipc.callqueue.impl` | java.util.concurrent.LinkedBlockingQueue | = default | |
| `hdds.scmclient.rpc.timeout` | 15m | = default | |
| `hdds.scmclient.max.retry.timeout` | 10m | = default | |
| `hdds.scmclient.failover.max.retry` | 15 | = default | |
| `hdds.scmclient.failover.retry.interval` | 2s | = default | |
| `ozone.om.client.rpc.timeout` | 15m | = default | |
| `ozone.client.failover.max.attempts` | 500 | = default | |
| `ozone.key.deleting.limit.per.task` | 20000 | **100** | |
| `ozone.block.deleting.service.interval` | 1m | = default | |
| `hdds.scm.block.deletion.per-interval.max` | 100000 | **500** | |
| `hdds.datanode.block.deleting.limit.per.interval` | 5000 | **25** | |
| `ozone.directory.deleting.service.interval` | 1m | = default | |
| `ozone.om.ratis.server.request.timeout` | 3s | = default | |
| `ozone.scm.ha.ratis.request.timeout` | 30s | = default | |
| `ozone.om.ratis.minimum.timeout` | 5s | = default | |
| `ozone.scm.ha.ratis.leader.election.timeout` | 5s | = default | |
| `ozone.om.ratis.segment.size` | 4MB | = default | |
| `ozone.scm.ha.ratis.segment.size` | 4MB | = default | |
| `ozone.om.ratis.log.purge.gap` | 1000000 | = default | |
| `ozone.om.ratis.log.appender.queue.num-elements` | 1024 | = default | |
| `ozone.om.ratis.log.appender.queue.byte-limit` | 32MB | = default | |
| `ozone.om.unflushed.transaction.max.count` | 10000 | = default | |
| `ozone.scm.ha.dbtransactionbuffer.flush.interval` | 600s | = default | |
| `hdds.db.profile` | DISK | = default | |
| `ozone.metastore.rocksdb.statistics` | OFF | = default | |
| `ozone.om.db.max.open.files` | -1 | = default | |
| `hdds.datanode.metadata.rocksdb.cache.size` | 1GB | = default | |
| `ozone.scm.container.size` | 5GB | **1GB** | |
| `ozone.replication` | (not in defaults) | **1** | |
| `ozone.server.default.replication` | 3 | **1** | |
| `ozone.datanode.pipeline.limit` | (not in defaults) | **1** | |
| `ozone.scm.sequence.id.batch.size` | 1000 | = default | |
| `hdds.heartbeat.interval` | 30s | = default | |
| `hdds.container.report.interval` | 60m | **60s** | |
| `hdds.prometheus.endpoint.enabled` | true | **true** | |
| `fs.trash.interval` | 0 | **0** | |

## Compare with your config

```bash
python3 ~/ozone-lab/compare-config.py /path/to/ozone-site.xml /path/to/core-site.xml
```

It prints default / lab / yours for each key above and marks keys you changed. For other keys in
your files it prints names only, no values, so hostnames do not appear in the output.
