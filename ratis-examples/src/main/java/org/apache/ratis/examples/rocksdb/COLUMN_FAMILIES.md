<!--
  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License. See accompanying LICENSE file.
-->

# Column families: design note for a storage-as-a-service state machine

## What a column family is

A column family is the kind of record, not the key. Keys stay keys; a column family only says
which group a key belongs to. RocksDB knows no types: the application decides that "everything
about images goes in `objects`", and every column family is still just `key -> bytes`.

All column families of one database share one WAL, so a single `WriteBatch` can write to several
of them atomically. Each column family has its own memtable, its own SST files and its own
options.

## What this example has today

One column family, `default`. It holds the load keys (`key-00000000` ... `key-00049999`),
any hand-written keys, and the `#TRANSACTIONINFO` marker. Only the `#` prefix separates the
marker from user data.

## Scenario: image upload

A user uploads `cat.jpg` (12 MB) into bucket `photos`. The service splits it into 3 chunks of
4 MB and stores those in S3. RocksDB holds only the metadata, never the image bytes.

| column family | key | value | why it is separate |
|---|---|---|---|
| `buckets` | `photos` | `{owner: david, region: tokyo, created: 2026-10-01}` | tiny, read constantly |
| `objects` | `photos/cat.jpg` | `{size: 12MB, type: image/jpeg, sha256: ab12.., chunks: 3, created: 2026-10-21T15:10, owner: david}` | one row per image: the main lookup |
| `chunks` | `obj-7781/000`, `obj-7781/001`, `obj-7781/002` | `{s3: s3://store-a/7781-000, size: 4MB, crc: 9f3e}` | many rows per image, most writes, tuned separately |
| `by_date` | `2026-10-21/photos/cat.jpg` | empty | index for "images uploaded today": a range scan on the date prefix |
| `deleted` | `obj-6650` | `{deleted_at: 2026-10-20, chunks: 2}` | queue for a cleanup job that deletes old chunks from S3 |
| `txn_info` | `last_applied` | `term 3, index 4210474` | the Raft marker, kept out of the user data |

### One upload is one WriteBatch across four column families

```
objects:  photos/cat.jpg            = {size 12MB, chunks 3, ...}
chunks:   obj-7781/000              = {s3://store-a/7781-000}
chunks:   obj-7781/001              = {s3://store-a/7781-001}
chunks:   obj-7781/002              = {s3://store-a/7781-002}
by_date:  2026-10-21/photos/cat.jpg = (empty)
txn_info: last_applied              = term 3, index 4210474
```

All six rows commit together or not at all, because all column families share one WAL. The
crash-safety argument of the current design (data and marker in one atomic batch) is unchanged.

### What appears on disk

```
sm/rocksdb/
  000012.log   one WAL, all column families mixed, each entry tagged with its column family ID
  000020.sst   objects only
  000021.sst   chunks only
  000022.sst   chunks only (chunks flush more often: more writes)
  000023.sst   by_date only
  000024.sst   txn_info only
  OPTIONS-*    one [CFOptions "..."] section per column family
  LOG          "[chunks] Flushing memtable", "[objects] Flushing memtable", ...
```

An SST file never mixes column families. The file name does not say which one it belongs to;
the MANIFEST and the SST's table properties (`column family name`) do.

## Why split it this way

- **Different reads.** "Get one image's info" hits `objects`. "List today's uploads" scans
  `by_date`. Neither has to walk past millions of chunk rows.
- **Different settings.** `chunks` is write-heavy, so it gets a bigger memtable. `buckets` is
  tiny and hot, so it stays fully cached.
- **Cheap cleanup.** The cleanup job scans only `deleted`. A whole index can be dropped in one
  call.
- **The same key can live in two places.** An ID in `objects` and the same ID in `deleted` are
  two separate rows.

## Relation to Apache Ozone

Ozone's Ozone Manager uses the same layout: `volumeTable`, `bucketTable` and `keyTable` hold
object metadata, a block mapping points at datanodes, `deletedTable` feeds cleanup, and
`transactionInfoTable` holds the marker. It is one RocksDB with one column family per table;
the data itself lives on the datanodes.

## Implementation hooks in this example

- `RocksDbStateMachine.initialize`: open the database with a list of column family
  descriptors and keep one handle per family.
- `RocksDbDoubleBuffer.flushBatch`: route each command to `batch.put(handle, key, value)` for
  its family. Write the marker to `txn_info`. Keep it one `WriteBatch`.
- `TransactionInfo.read`: read the marker from the `txn_info` handle instead of the
  `#TRANSACTIONINFO` key in `default`.
- `KeyValueCommand`: carry a column family name or ID so each put says which family it goes to.
