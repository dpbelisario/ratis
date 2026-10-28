#!/usr/bin/env python3
"""Generate the Perses provisioning files for the Ozone incident lab.

Writes perses/provisioning/{01-project,02-datasource,03-dashboard}.json.
Run again after you edit ROWS. Perses re-reads the folder every minute.

Usage: python3 perses/make-dashboard.py [--prom-url http://prometheus:9090]
"""
import argparse
import json
import os

PROJECT = "ozone"
DASHBOARD = "ozone-rpc"

OM_RPC = 'job="ozone-om",port="9862"'
SCM_BLK = 'job="ozone-scm",servername="ScmBlockLocationProtocolService"'

# Each row: (title, [panel, ...]). Each panel: (title, description, [(query, legend), ...]).
ROWS = [
    ("0. Lab markers (when did the scheduled jobs and the fault run?)", [
        ("Lab clock (hour)",
         "realtime profile: JST hour. accel profile: virtual hour (1 real minute = 1 lab hour).",
         [("lab_clock_hour", "{{profile}}")]),
        ("Jobs running (1 = running)",
         "job01 = 01:00 bulk delete, job10 = 10:00 write burst, seed = pre-load.",
         [("lab_job_running", "{{task}}")]),
        ("Fault active, writer on, writer clients alive",
         "Writer clients pile up when OM does not answer (each client = 5 threads).",
         [("lab_fault_active", "fault active"), ("lab_writer_on", "writer on"),
          ("lab_writer_clients", "writer clients")]),
    ]),
    ("1. OM client RPC, port 9862 (is the OM busy or stuck?)", [
        ("OM call queue length",
         "Calls waiting for a handler. Lab limit = 5 handlers x 10 = 50 (production 100 x 100 = 10K).",
         [(f"rpc_call_queue_length{{{OM_RPC}}}", "{{hostname}}")]),
        ("OM busy handlers",
         "Handlers that are working on a call now. All busy + full queue = saturated.",
         [(f"rpc_num_in_process_handler{{{OM_RPC}}}", "{{hostname}}")]),
        ("OM completed calls/s",
         "Busy = high rate. Stuck = rate near 0 while the queue is full.",
         [(f"rate(rpc_rpc_processing_time_num_ops{{{OM_RPC}}}[1m])", "{{hostname}}")]),
        ("OM avg queue time and processing time (ms)",
         "Queue time grows first when handlers are slow. Processing time is the time inside the handler (includes waits on SCM).",
         [(f"rpc_rpc_queue_time_avg_time{{{OM_RPC}}}", "queue {{hostname}}"),
          (f"rpc_rpc_processing_time_avg_time{{{OM_RPC}}}", "proc {{hostname}}")]),
        ("OM open connections",
         "Open TCP connections are not requests. Compare with the queue.",
         [(f"rpc_num_open_connections{{{OM_RPC}}}", "{{hostname}}")]),
        ("OM log: SCM retry / failover / not-leader lines per minute",
         "Counted from the OM logs by the lab scheduler (production: grep the OM log). Retries come after "
         "hdds.scmclient.rpc.timeout (15m) or a 'not leader' answer.",
         [("rate(lab_om_failover_log_lines_total[5m]) * 60", "OM log lines/min")]),
        ("OM client backoff and dropped connections /s",
         "Backoff happens when the call queue is full (backoff must be enabled).",
         [(f"rate(rpc_rpc_client_backoff{{{OM_RPC}}}[1m])", "backoff {{hostname}}"),
          (f"rate(rpc_num_dropped_connections{{{OM_RPC}}}[1m])", "dropped {{hostname}}")]),
    ]),
    ("2. SCM block RPC, port 9863 (ScmBlockLocationProtocolService)", [
        ("SCM 9863 call queue length",
         "Production climbed in a straight line to 2.4K. Straight line = arrivals at a fixed rate, almost nothing completes.",
         [(f"rpc_call_queue_length{{{SCM_BLK}}}", "{{hostname}}")]),
        ("SCM 9863 busy handlers",
         "Lab limit = 5.",
         [(f"rpc_num_in_process_handler{{{SCM_BLK}}}", "{{hostname}}")]),
        ("SCM 9863 completed calls/s",
         "Only the SCM leader does real work. Followers answer 'not leader'.",
         [(f"rate(rpc_rpc_processing_time_num_ops{{{SCM_BLK}}}[1m])", "{{hostname}}")]),
        ("SCM 9863 avg queue time and processing time (ms)", "",
         [(f"rpc_rpc_queue_time_avg_time{{{SCM_BLK}}}", "queue {{hostname}}"),
          (f"rpc_rpc_processing_time_avg_time{{{SCM_BLK}}}", "proc {{hostname}}")]),
        ("SCM 9863 queue growth (calls per minute)",
         "Slope of the queue. If SCM handlers do not finish, the OM times out after hdds.scmclient.rpc.timeout and "
         "sends the call again, so the slope = OM handlers / rpc timeout (production 100 / 15 min = 6.7/min = 400/h).",
         [(f"deriv(rpc_call_queue_length{{{SCM_BLK}}}[5m]) * 60", "{{hostname}}")]),
        ("SCM block protocol calls/s by type",
         "AllocateScmBlock = writes. DeleteScmKeyBlocks = the OM KeyDeletingService sends deleted keys' blocks.",
         [("sum by (hostname, type) (rate(scm_block_location_protocol_counter[1m])) > 0", "{{hostname}} {{type}}")]),
        ("SCM block protocol avg time per call by type (ms)",
         "time / count, per type. A slow DeleteScmKeyBlocks holds a 9863 handler for that long.",
         [("sum by (hostname, type) (rate(scm_block_location_protocol_time[1m]))"
           " / sum by (hostname, type) (rate(scm_block_location_protocol_counter[1m])) > 0",
           "{{hostname}} {{type}}")]),
    ]),
    ("3. Delete path: OM deletedTable -> KeyDeletingService -> SCM deleted block log", [
        ("OM key deletes/s (user deletes)",
         "The 01:00 job shows here.",
         [("rate(om_metrics_num_key_deletes[1m])", "{{hostname}}")]),
        ("OM deletedTable keys (estimate)",
         "Keys deleted by users but whose blocks are not yet handed to SCM. This is the OM-side 'pending delete' backlog.",
         [("rocksdb_om_db_deletedtable_estimate_num_keys", "{{hostname}}")]),
        ("KeyDeletingService keys sent for purge / purged per s",
         "Runs every ozone.key.deleting.service.interval, at most ozone.key.deleting.limit.per.task keys per run.",
         [("rate(deleting_service_metrics_num_keys_sent_for_purge[1m])", "sent {{hostname}}"),
          ("rate(deleting_service_metrics_num_keys_purged[1m])", "purged {{hostname}}")]),
        ("KeyDeletingService run latency (ms)", "",
         [("om_performance_metrics_key_deleting_service_latency_ms", "{{hostname}}")]),
        ("FSO: DirectoryDeletingService (files moved to deletedTable /s, dirs purged /s)",
         "An FSO directory delete is 1 key delete in om_metrics_num_key_deletes. The files move to deletedTable here, "
         "every ozone.directory.deleting.service.interval (60s).",
         [("rate(deleting_service_metrics_num_sub_files_moved_to_deleted_table[1m])", "files {{hostname}}"),
          ("rate(deleting_service_metrics_num_dirs_purged[1m])", "dirs {{hostname}}"),
          ("rocksdb_om_db_deleteddirectorytable_estimate_num_keys", "deletedDirectoryTable {{hostname}}")]),
        ("SCM deletedBlocks table (deleted block log, estimate)",
         "Transactions written by DeleteScmKeyBlocks through SCM Ratis. Drains when datanodes confirm deletes.",
         [("rocksdb_scm_db_deletedblocks_estimate_num_keys", "{{hostname}}")]),
        ("SCM block deleting service transactions/s",
         "created = added to the log, sent = sent to datanodes, completed = datanodes confirmed.",
         [("rate(scm_block_deleting_service_num_block_deletion_transaction_created[1m])", "created {{hostname}}"),
          ("rate(scm_block_deleting_service_num_block_deletion_transaction_sent[1m])", "sent {{hostname}}"),
          ("rate(scm_block_deleting_service_num_block_deletion_transaction_completed[1m])", "completed {{hostname}}")]),
    ]),
    ("4. SCM Ratis (state machine on port 9894)", [
        ("SCM Ratis apply lag (entries)",
         "Highest commit index minus each node's applied index. Growth = the state machine cannot keep up.",
         [('scalar(max(ratis_server_peerCommitIndex{job="ozone-scm"}))'
           ' - ratis_state_machine_applyCompletedIndex{job="ozone-scm"}', "{{instance}}")]),
        ("SCM Ratis write requests/s", "",
         [('rate(ratis_server_clientWriteRequest_count{job="ozone-scm"}[1m])', "{{instance}}")]),
        ("SCM Ratis log sync time p99 (s)",
         "fsync of the Ratis log. Slow disk = slow every SCM write.",
         [('ratis_log_worker_syncTime{job="ozone-scm",quantile="0.99"}', "{{instance}}")]),
        ("SCM Ratis pending requests", "",
         [('ratis_server_numPendingRequestInQueue{job="ozone-scm"}', "{{instance}}")]),
        ("Leader elections (SCM and OM)",
         "A step = a new election. Failover retries in the OM log come with this.",
         [('ratis_leader_election_electionCount{job=~"ozone-scm|ozone-om"}', "{{job}} {{instance}}")]),
        ("Seconds since last leader election", "",
         [('ratis_leader_election_lastLeaderElapsedTime{job=~"ozone-scm|ozone-om"} / 1000', "{{job}} {{instance}}")]),
    ]),
    ("5. OM Ratis, OM write work, JVM", [
        ("OM Ratis apply lag (entries)", "",
         [('scalar(max(ratis_server_peerCommitIndex{job="ozone-om"}))'
           ' - ratis_state_machine_applyCompletedIndex{job="ozone-om"}', "{{instance}}")]),
        ("OM key commits and block allocations /s",
         "Normal write traffic. Each new block = 1 AllocateScmBlock call from OM to SCM 9863.",
         [("rate(om_metrics_num_key_commits[1m])", "commit {{hostname}}"),
          ("rate(om_metrics_num_block_allocations[1m])", "alloc {{hostname}}")]),
        ("OM keys (estimate)", "",
         [("rocksdb_om_db_keytable_estimate_num_keys", "keyTable {{hostname}}"),
          ("rocksdb_om_db_filetable_estimate_num_keys", "fileTable {{hostname}}")]),
        ("JVM GC time ms/s (OM and SCM)", "",
         [('rate(jvm_metrics_gc_time_millis{job=~"ozone-om|ozone-scm"}[1m])', "{{hostname}}")]),
        ("JVM heap used (MB)", "",
         [('jvm_metrics_mem_heap_used_m{job=~"ozone-om|ozone-scm"}', "{{hostname}}")]),
        ("JVM blocked threads", "Many blocked threads = lock contention.",
         [('jvm_metrics_threads_blocked{job=~"ozone-om|ozone-scm"}', "{{hostname}}")]),
    ]),
]

INTRO = """**Ozone incident lab** (Ozone 2.0.0, 3 OM + 3 SCM, lab RPC capacity 1:200).

How to read: a full OM queue alone does not mean failure. Check **completed calls/s**:
high = busy, near 0 = stuck. Then check SCM 9863 (row 2): if SCM is slow, OM handlers wait on SCM.
Row 3 follows a delete from OM to SCM. Row 4 shows if the SCM state machine keeps up.
"""


def panel(title, desc, queries):
    return {
        "kind": "Panel",
        "spec": {
            "display": {"name": title, "description": desc},
            "plugin": {"kind": "TimeSeriesChart",
                       "spec": {"legend": {"position": "bottom", "mode": "list"}}},
            "queries": [
                {"kind": "TimeSeriesQuery",
                 "spec": {"plugin": {"kind": "PrometheusTimeSeriesQuery",
                                     "spec": {"query": q, "seriesNameFormat": legend}}}}
                for q, legend in queries
            ],
        },
    }


def build(prom_url):
    panels = {"intro": {"kind": "Panel", "spec": {
        "display": {"name": "Read me"},
        "plugin": {"kind": "Markdown", "spec": {"text": INTRO}}}}}
    layouts = [{"kind": "Grid", "spec": {"display": {"title": "Read me", "collapse": {"open": True}},
                                         "items": [{"x": 0, "y": 0, "width": 24, "height": 4,
                                                    "content": {"$ref": "#/spec/panels/intro"}}]}}]
    n = 0
    for row_title, row_panels in ROWS:
        items = []
        for i, (title, desc, queries) in enumerate(row_panels):
            n += 1
            key = f"p{n}"
            panels[key] = panel(title, desc, queries)
            items.append({"x": (i % 3) * 8, "y": (i // 3) * 8, "width": 8, "height": 8,
                          "content": {"$ref": f"#/spec/panels/{key}"}})
        layouts.append({"kind": "Grid", "spec": {"display": {"title": row_title, "collapse": {"open": True}},
                                                 "items": items}})
    project = {"kind": "Project", "metadata": {"name": PROJECT}, "spec": {"display": {"name": PROJECT}}}
    datasource = {"kind": "Datasource", "metadata": {"name": "prometheus", "project": PROJECT},
                  "spec": {"default": True, "plugin": {"kind": "PrometheusDatasource", "spec": {
                      "proxy": {"kind": "HTTPProxy", "spec": {"url": prom_url}}}}}}
    dashboard = {"kind": "Dashboard", "metadata": {"name": DASHBOARD, "project": PROJECT},
                 "spec": {"display": {"name": "Ozone RPC"}, "duration": "30m", "refreshInterval": "10s",
                          "variables": [], "panels": panels, "layouts": layouts}}
    return project, datasource, dashboard, n


def all_queries():
    """Every PromQL query in the dashboard (used by scenario.sh check-panels)."""
    return [(title, q) for _, row in ROWS for title, _, qs in row for q, _ in qs]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prom-url", default="http://prometheus:9090")
    ap.add_argument("--list-queries", action="store_true", help="print title<TAB>query and exit")
    args = ap.parse_args()
    if args.list_queries:
        for title, q in all_queries():
            print(f"{title}\t{q}")
        return
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "provisioning")
    os.makedirs(out, exist_ok=True)
    project, datasource, dashboard, n = build(args.prom_url)
    for name, obj in (("01-project", project), ("02-datasource", datasource), ("03-dashboard", dashboard)):
        with open(os.path.join(out, name + ".json"), "w") as f:
            json.dump(obj, f, indent=2)
    print(f"wrote {out}: {n} panels in {len(ROWS)} rows")


if __name__ == "__main__":
    main()
