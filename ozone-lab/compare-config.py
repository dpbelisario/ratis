#!/usr/bin/env python3
"""Compare your Ozone config (ozone-site.xml, core-site.xml) with the lab and the Ozone 2.0.0 defaults.
Usage: python3 compare-config.py path/to/ozone-site.xml [path/to/core-site.xml ...]
Prints only key names and values for the keys below. For other keys in your files it prints key
names only (values can contain hostnames). Nothing is sent anywhere."""
import sys, xml.etree.ElementTree as ET
ROWS=[('ozone.om.handler.count.key', '100', '5'), ('ozone.scm.block.handler.count.key', '100', '5'), ('ozone.scm.client.handler.count.key', '100', '= default'), ('ozone.scm.datanode.handler.count.key', '100', '= default'), ('ipc.server.handler.queue.size', '100', '100'), ('ipc.server.max.response.size', '1048576', '= default'), ('ipc.9862.backoff.enable', '(not in defaults)', '= default'), ('ipc.9863.backoff.enable', '(not in defaults)', '= default'), ('ipc.backoff.enable', 'false', '= default'), ('ipc.9862.callqueue.impl', '(not in defaults)', '= default'), ('ipc.callqueue.impl', 'java.util.concurrent.LinkedBlockingQueue', '= default'), ('hdds.scmclient.rpc.timeout', '15m', '= default'), ('hdds.scmclient.max.retry.timeout', '10m', '= default'), ('hdds.scmclient.failover.max.retry', '15', '= default'), ('hdds.scmclient.failover.retry.interval', '2s', '= default'), ('ozone.om.client.rpc.timeout', '15m', '= default'), ('ozone.client.failover.max.attempts', '500', '= default'), ('ozone.key.deleting.limit.per.task', '20000', '100'), ('ozone.block.deleting.service.interval', '1m', '= default'), ('hdds.scm.block.deletion.per-interval.max', '100000', '500'), ('hdds.datanode.block.deleting.limit.per.interval', '5000', '25'), ('ozone.directory.deleting.service.interval', '1m', '= default'), ('ozone.om.ratis.server.request.timeout', '3s', '= default'), ('ozone.scm.ha.ratis.request.timeout', '30s', '= default'), ('ozone.om.ratis.minimum.timeout', '5s', '= default'), ('ozone.scm.ha.ratis.leader.election.timeout', '5s', '= default'), ('ozone.om.ratis.segment.size', '4MB', '= default'), ('ozone.scm.ha.ratis.segment.size', '4MB', '= default'), ('ozone.om.ratis.log.purge.gap', '1000000', '= default'), ('ozone.om.ratis.log.appender.queue.num-elements', '1024', '= default'), ('ozone.om.ratis.log.appender.queue.byte-limit', '32MB', '= default'), ('ozone.om.unflushed.transaction.max.count', '10000', '= default'), ('ozone.scm.ha.dbtransactionbuffer.flush.interval', '600s', '= default'), ('hdds.db.profile', 'DISK', '= default'), ('ozone.metastore.rocksdb.statistics', 'OFF', '= default'), ('ozone.om.db.max.open.files', '-1', '= default'), ('hdds.datanode.metadata.rocksdb.cache.size', '1GB', '= default'), ('ozone.scm.container.size', '5GB', '1GB'), ('ozone.replication', '(not in defaults)', '1'), ('ozone.server.default.replication', '3', '1'), ('ozone.datanode.pipeline.limit', '(not in defaults)', '1'), ('ozone.scm.sequence.id.batch.size', '1000', '= default'), ('hdds.heartbeat.interval', '30s', '= default'), ('hdds.container.report.interval', '60m', '60s'), ('hdds.prometheus.endpoint.enabled', 'true', 'true'), ('fs.trash.interval', '0', '0')]
mine = {}
for f in sys.argv[1:]:
    for p in ET.parse(f).getroot().iter('property'):
        n = (p.findtext('name') or '').strip()
        if n:
            mine[n] = (p.findtext('value') or '').strip()
if not mine:
    sys.exit(__doc__)
known = {k for k, _, _ in ROWS}
print(f"{'key':52} {'default':>12} {'lab':>12} {'yours':>14}  note")
for k, dv, lv in ROWS:
    yv = mine.get(k, '= default')
    eff = dv if yv == '= default' else yv
    note = '' if eff == dv else 'CHANGED from default'
    print(f"{k:52} {dv[:12]:>12} {lv[:12]:>12} {yv[:14]:>14}  {note}")
extra = sorted(k for k in mine if k not in known and not k.startswith(('ozone.om.address', 'ozone.scm.address', 'ozone.om.nodes', 'ozone.scm.nodes')))
print(f"\nOther keys set in your files ({len(extra)}), names only:")
for k in extra:
    print("  " + k)
