/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.apache.ratis.examples.rocksdb;

import org.apache.ratis.proto.RaftProtos.RaftPeerRole;
import org.apache.ratis.proto.RaftProtos.StateMachineLogEntryProto;
import org.apache.ratis.protocol.Message;
import org.apache.ratis.protocol.RaftClientRequest;
import org.apache.ratis.protocol.RaftGroupId;
import org.apache.ratis.server.RaftServer;
import org.apache.ratis.server.protocol.TermIndex;
import org.apache.ratis.server.raftlog.RaftLog;
import org.apache.ratis.server.storage.RaftStorage;
import org.apache.ratis.statemachine.SnapshotInfo;
import org.apache.ratis.statemachine.TransactionContext;
import org.apache.ratis.statemachine.impl.BaseStateMachine;
import org.apache.ratis.thirdparty.com.google.protobuf.ByteString;
import org.apache.ratis.util.LifeCycle;
import org.apache.ratis.util.Preconditions;
import org.rocksdb.FlushOptions;
import org.rocksdb.Options;
import org.rocksdb.RocksDB;
import org.rocksdb.RocksDBException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * Port of Ozone's OzoneManagerStateMachine to a plain key-value store on RocksDB.
 *
 * <p>Index flow, in Ratis' terms:
 * <ol>
 *   <li>{@code commitIndex}: Ratis has replicated the entry to a majority. Nothing here is involved.</li>
 *   <li>{@code appliedIndex}: Ratis called {@link #applyTransaction}. This method only queues the
 *       command into {@link RocksDbDoubleBuffer} and returns a future, exactly like Ozone's
 *       {@code runCommand} handing an {@code OMClientResponse} to its double buffer.</li>
 *   <li>{@code applyCompletedIndex} ({@code applied} in {@code ratis sh group info}): the flush
 *       thread committed the batch to RocksDB and called {@link #updateLastAppliedTermIndex}.</li>
 * </ol>
 *
 * <p>Tunables (system properties, read by {@link RocksDbServer}):
 * {@code kv.max.unflushed} (default 10000, Ozone's default), {@code kv.flush.interval.ms} (default 0),
 * {@code kv.sync.writes} (default false), {@code kv.write.buffer.size} (RocksDB memtable bytes).
 *
 * <p>Not ported: Ozone's leader-to-follower snapshot install (checkpoint tarball over HTTP) and its
 * table cache for reads of unflushed data. Keep log purging off (the default) so lagging followers
 * catch up by log replay, and expect {@link #query} to lag the apply by one flush.
 */
public class RocksDbStateMachine extends BaseStateMachine {
  private static final Logger LOG = LoggerFactory.getLogger(RocksDbStateMachine.class);

  /** Everything the state machine needs to build its double buffer. */
  public static final class Config {
    private int maxUnflushed = 10000;
    private long flushIntervalMs = 0;
    private boolean syncWrites = false;
    private long writeBufferSize = 0;

    public Config setMaxUnflushed(int n) {
      this.maxUnflushed = n;
      return this;
    }

    public Config setFlushIntervalMs(long ms) {
      this.flushIntervalMs = ms;
      return this;
    }

    public Config setSyncWrites(boolean sync) {
      this.syncWrites = sync;
      return this;
    }

    public Config setWriteBufferSize(long bytes) {
      this.writeBufferSize = bytes;
      return this;
    }

    @Override
    public String toString() {
      return "maxUnflushed=" + maxUnflushed + ", flushIntervalMs=" + flushIntervalMs
          + ", syncWrites=" + syncWrites + ", writeBufferSize=" + writeBufferSize;
    }
  }

  private final Config config;
  private Options options;
  private RocksDB db;
  private volatile RocksDbDoubleBuffer doubleBuffer;
  private volatile TransactionInfo latestSnapshot;
  /** Single thread so every replica applies in log order (Ozone keeps the same restriction). */
  private final ExecutorService executor = Executors.newSingleThreadExecutor(r -> {
    final Thread t = new Thread(r, "RocksDbStateMachine-ApplyTransactionThread");
    t.setDaemon(true);
    return t;
  });

  /** Guards lastNotified/lastSkipped/lastApplied updates; take the state machine monitor first if both. */
  private final Object termIndexLock = new Object();
  private volatile TermIndex lastNotifiedTermIndex = TermIndex.valueOf(0, RaftLog.INVALID_LOG_INDEX);
  private volatile long lastSkippedIndex = RaftLog.INVALID_LOG_INDEX;

  public RocksDbStateMachine(Config config) {
    this.config = config;
  }

  public RocksDbStateMachine() {
    this(new Config());
  }

  // ---------------------------------------------------------------- lifecycle

  @Override
  public void initialize(RaftServer server, RaftGroupId groupId, RaftStorage raftStorage) throws IOException {
    getLifeCycle().startAndTransition(() -> {
      super.initialize(server, groupId, raftStorage);
      final File dir = new File(raftStorage.getStorageDir().getStateMachineDir(), "rocksdb");
      if (!dir.mkdirs() && !dir.isDirectory()) {
        throw new IOException("Failed to create " + dir);
      }
      openDb(dir);
      loadSnapshotInfoFromDB();
      this.doubleBuffer = newDoubleBuffer();
      LOG.info("{}: initialized {} at {} with lastApplied={}, {}", getId(), groupId, dir,
          getLastAppliedTermIndex(), config);
    });
  }

  private void openDb(File dir) throws IOException {
    RocksDB.loadLibrary();
    options = new Options().setCreateIfMissing(true);
    if (config.writeBufferSize > 0) {
      // Small memtable => frequent RocksDB flushes to SST, the "F2" scenario.
      options.setWriteBufferSize(config.writeBufferSize);
    }
    try {
      db = RocksDB.open(options, dir.getAbsolutePath());
    } catch (RocksDBException e) {
      throw new IOException("Failed to open RocksDB at " + dir, e);
    }
  }

  private RocksDbDoubleBuffer newDoubleBuffer() {
    return new RocksDbDoubleBuffer(String.valueOf(getId()), db, config.syncWrites, config.maxUnflushed,
        config.flushIntervalMs, this::updateLastAppliedTermIndex).start();
  }

  /** Ozone: loadSnapshotInfoFromDB. The DB marker is the truth about what has been applied. */
  private void loadSnapshotInfoFromDB() throws IOException {
    final TransactionInfo info = TransactionInfo.read(db);
    if (info != null) {
      synchronized (termIndexLock) {
        setLastAppliedTermIndex(info.getTermIndex());
      }
      latestSnapshot = info;
      LOG.info("{}: lastAppliedTermIndex restored from DB as {}", getId(), info);
    } else {
      LOG.info("{}: no TransactionInfo in DB, starting empty", getId());
    }
  }

  @Override
  public synchronized void reinitialize() throws IOException {
    loadSnapshotInfoFromDB();
    if (getLifeCycleState() == LifeCycle.State.PAUSED) {
      getLifeCycle().startAndTransition(() -> {
        doubleBuffer = newDoubleBuffer();
        LOG.info("{}: reinitialized with lastApplied={}", getId(), getLastAppliedTermIndex());
      });
    }
  }

  @Override
  public void pause() {
    synchronized (this) {
      final LifeCycle.State state = getLifeCycleState();
      if (state == LifeCycle.State.PAUSED) {
        return;
      }
      if (state != LifeCycle.State.NEW) {
        getLifeCycle().transition(LifeCycle.State.PAUSING);
        getLifeCycle().transition(LifeCycle.State.PAUSED);
      }
    }
    try {
      doubleBuffer.awaitFlush();
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
    }
    doubleBuffer.stop();
  }

  @Override
  public void close() throws IOException {
    getLifeCycle().checkStateAndClose(() -> {
      final RocksDbDoubleBuffer buffer = doubleBuffer;
      if (buffer != null) {
        buffer.stop();
      }
      executor.shutdown();
      try {
        executor.awaitTermination(5, TimeUnit.SECONDS);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
      }
      if (db != null) {
        db.close();
      }
      if (options != null) {
        options.close();
      }
      LOG.info("{}: closed", getId());
    });
  }

  // ---------------------------------------------------------------- index bookkeeping (verbatim from Ozone)

  /** Ratis calls this for entries that are not state machine data (config changes, leader no-op). */
  @Override
  public void notifyTermIndexUpdated(long currentTerm, long newIndex) {
    synchronized (termIndexLock) {
      final long oldIndex = lastNotifiedTermIndex.getIndex();
      if (newIndex - oldIndex > 1) {
        lastSkippedIndex = newIndex - 1;
      }
      final TermIndex newTermIndex = TermIndex.valueOf(currentTerm, newIndex);
      lastNotifiedTermIndex = assertUpdateIncreasingly("lastNotified", lastNotifiedTermIndex, newTermIndex);
      if (lastNotifiedTermIndex.getIndex() - getLastAppliedTermIndex().getIndex() == 1) {
        updateLastAppliedTermIndex(lastNotifiedTermIndex);
      }
    }
  }

  @Override
  protected boolean updateLastAppliedTermIndex(TermIndex newTermIndex) {
    synchronized (termIndexLock) {
      assertUpdateIncreasingly("lastApplied", getLastAppliedTermIndex(), newTermIndex);
      // If the flushed index sits inside a run of Ratis-internal entries we were already notified
      // about, jump straight to the end of that run.
      if (newTermIndex.getIndex() < lastNotifiedTermIndex.getIndex()
          && newTermIndex.getIndex() >= lastSkippedIndex) {
        newTermIndex = lastNotifiedTermIndex;
      }
      return super.updateLastAppliedTermIndex(newTermIndex);
    }
  }

  private static TermIndex assertUpdateIncreasingly(String name, TermIndex oldTi, TermIndex newTi) {
    Preconditions.assertTrue(newTi.compareTo(oldTi) >= 0,
        () -> name + ": newTermIndex = " + newTi + " < oldTermIndex = " + oldTi);
    return newTi;
  }

  @Override
  public SnapshotInfo getLatestSnapshot() {
    final TransactionInfo info = latestSnapshot;
    return info == null ? null : info.toSnapshotInfo();
  }

  // ---------------------------------------------------------------- write path

  /** Leader-side validation before the entry is written to the Raft log. */
  @Override
  public TransactionContext startTransaction(RaftClientRequest request) throws IOException {
    final ByteString content = request.getMessage().getContent();
    final TransactionContext.Builder builder = TransactionContext.newBuilder()
        .setClientRequest(request)
        .setStateMachine(this)
        .setServerRole(RaftPeerRole.LEADER);
    try {
      final KeyValueCommand cmd = KeyValueCommand.decode(content);
      if (cmd.isReadOnly()) {
        throw new IOException("GET must be sent as a read-only request: " + cmd);
      }
      return builder.setLogData(content).setStateMachineContext(cmd).build();
    } catch (IllegalArgumentException | IOException e) {
      final TransactionContext ctx = builder.build();
      ctx.setException(e instanceof IOException ? (IOException) e : new IOException(e));
      return ctx;
    }
  }

  /**
   * Apply a committed entry. Mirrors Ozone: parse (leader has it in the context, followers decode
   * the log data), throttle on the unflushed semaphore, run on the single apply thread. The command
   * is only queued; RocksDB is written later by the double buffer.
   */
  @Override
  public CompletableFuture<Message> applyTransaction(TransactionContext trx) {
    try {
      final Object context = trx.getStateMachineContext();
      final KeyValueCommand cmd = context != null ? (KeyValueCommand) context
          : KeyValueCommand.decode(trx.getStateMachineLogEntry().getLogData());
      final TermIndex termIndex = TermIndex.valueOf(trx.getLogEntry());
      LOG.debug("{}: applyTransaction {} {}", getId(), termIndex, cmd);

      final RocksDbDoubleBuffer buffer = doubleBuffer;
      buffer.acquireUnflushedTransactions(1);
      return CompletableFuture.supplyAsync(() -> runCommand(buffer, cmd, termIndex), executor);
    } catch (Exception e) {
      if (e instanceof InterruptedException) {
        Thread.currentThread().interrupt();
      }
      return completeExceptionally(e);
    }
  }

  private Message runCommand(RocksDbDoubleBuffer buffer, KeyValueCommand cmd, TermIndex termIndex) {
    buffer.add(cmd, termIndex);
    return Message.valueOf("OK " + termIndex.getIndex());
  }

  // ---------------------------------------------------------------- read path

  /** Reads straight from RocksDB, so a value is visible once its batch is flushed, not once applied. */
  @Override
  public CompletableFuture<Message> query(Message request) {
    try {
      final KeyValueCommand cmd = KeyValueCommand.decode(request.getContent());
      if (!cmd.isReadOnly()) {
        throw new IOException("Not a read-only command: " + cmd);
      }
      final byte[] value = db.get(cmd.getKeyBytes());
      return CompletableFuture.completedFuture(Message.valueOf(
          value == null ? "" : new String(value, StandardCharsets.UTF_8)));
    } catch (IllegalArgumentException | IOException | RocksDBException e) {
      return completeExceptionally(e);
    }
  }

  // ---------------------------------------------------------------- snapshot

  /**
   * Ozone: "a dummy operation", because every flush already persists the applied index with the
   * data. Wait for the buffer to drain, make the marker cover any trailing Ratis-internal entries,
   * flush the memtable, and report the index.
   */
  @Override
  public long takeSnapshot() throws IOException {
    while (getLastAppliedTermIndex().getIndex() < lastSkippedIndex) {
      try {
        doubleBuffer.awaitFlush();
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new IOException("Interrupted waiting for flush", e);
      }
    }
    return takeSnapshotImpl();
  }

  private synchronized long takeSnapshotImpl() throws IOException {
    synchronized (termIndexLock) {
      final TermIndex applied = getLastAppliedTermIndex();
      final TermIndex notified = lastNotifiedTermIndex;
      final TermIndex snapshot = applied.compareTo(notified) > 0 ? applied : notified;
      final TransactionInfo info = doubleBuffer.persistIfNewer(TransactionInfo.valueOf(snapshot));
      try (FlushOptions flushOptions = new FlushOptions().setWaitForFlush(true)) {
        db.flush(flushOptions);
      } catch (RocksDBException e) {
        throw new IOException("RocksDB flush failed", e);
      }
      latestSnapshot = info;
      LOG.info("{}: snapshot at {} (applied={}, notified={}, skipped={})", getId(), info, applied, notified,
          lastSkippedIndex);
      return info.getTermIndex().getIndex();
    }
  }

  // ---------------------------------------------------------------- misc

  @Override
  public String toStateMachineLogEntryString(StateMachineLogEntryProto proto) {
    try {
      return KeyValueCommand.decode(proto.getLogData()).toString();
    } catch (IllegalArgumentException e) {
      return super.toStateMachineLogEntryString(proto);
    }
  }

  RocksDbDoubleBuffer getDoubleBuffer() {
    return doubleBuffer;
  }

  private static <T> CompletableFuture<T> completeExceptionally(Exception e) {
    final CompletableFuture<T> f = new CompletableFuture<>();
    f.completeExceptionally(e);
    return f;
  }
}
