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

import org.apache.ratis.server.protocol.TermIndex;
import org.apache.ratis.util.Daemon;
import org.apache.ratis.util.Preconditions;
import org.rocksdb.RocksDB;
import org.rocksdb.RocksDBException;
import org.rocksdb.WriteBatch;
import org.rocksdb.WriteOptions;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.util.Map;
import java.util.Queue;
import java.util.TreeMap;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Semaphore;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;

/**
 * Port of Ozone's OzoneManagerDoubleBuffer with the Ozone-specific parts removed.
 *
 * <p>{@link RocksDbStateMachine#applyTransaction} calls {@link #add}, which appends to
 * {@code currentBuffer} and returns. A single flush thread swaps {@code currentBuffer} with
 * {@code readyBuffer}, writes everything in {@code readyBuffer} to RocksDB as one
 * {@code WriteBatch} (data plus the {@link TransactionInfo} marker), and then reports the
 * last flushed term-index through {@code updateLastAppliedIndex}. Until that callback runs,
 * Ratis' {@code applyCompletedIndex} stays behind {@code appliedIndex}.
 *
 * <p>{@code maxUnflushed} bounds how far apply may run ahead of the DB: the semaphore
 * is acquired in {@code applyTransaction} and released when the entry is flushed.
 */
public final class RocksDbDoubleBuffer {
  private static final Logger LOG = LoggerFactory.getLogger(RocksDbDoubleBuffer.class);

  /** One queued command and the log position it came from. */
  private static final class Entry {
    private final TermIndex termIndex;
    private final KeyValueCommand command;

    Entry(TermIndex termIndex, KeyValueCommand command) {
      this.termIndex = termIndex;
      this.command = command;
    }
  }

  private Queue<Entry> currentBuffer = new ConcurrentLinkedQueue<>();
  private Queue<Entry> readyBuffer = new ConcurrentLinkedQueue<>();

  private final RocksDB db;
  private final WriteOptions writeOptions;
  private final Consumer<TermIndex> updateLastAppliedIndex;
  private final Semaphore unflushedTransactions;
  private final long flushIntervalMs;
  private final FlushNotifier flushNotifier = new FlushNotifier();
  private final Daemon daemon;
  private final AtomicBoolean isRunning = new AtomicBoolean(false);
  private final AtomicLong flushedTransactionCount = new AtomicLong();
  private final AtomicLong flushIterations = new AtomicLong();
  /** Orders the batch commit against {@link #persistIfNewer}. */
  private final Object transactionInfoLock = new Object();

  /**
   * @param flushIntervalMs 0 flushes as soon as anything is queued (Ozone's behaviour);
   *        a positive value makes the flush thread wait that long before each batch,
   *        which widens the applied/applyCompleted gap so it is visible in a demo.
   */
  public RocksDbDoubleBuffer(String name, RocksDB db, boolean syncWrites, int maxUnflushed,
      long flushIntervalMs, Consumer<TermIndex> updateLastAppliedIndex) {
    Preconditions.assertTrue(maxUnflushed > 0, () -> "maxUnflushed = " + maxUnflushed);
    this.db = db;
    this.writeOptions = new WriteOptions().setSync(syncWrites);
    this.updateLastAppliedIndex = updateLastAppliedIndex;
    this.unflushedTransactions = new Semaphore(maxUnflushed);
    this.flushIntervalMs = flushIntervalMs;
    this.daemon = Daemon.newBuilder().setName(name + "-DoubleBufferFlushThread")
        .setRunnable(this::flushTransactions).build();
  }

  public RocksDbDoubleBuffer start() {
    isRunning.set(true);
    daemon.start();
    return this;
  }

  /** Blocks when more than maxUnflushed entries are applied but not yet in RocksDB. */
  public void acquireUnflushedTransactions(int n) throws InterruptedException {
    unflushedTransactions.acquire(n);
  }

  void releaseUnflushedTransactions(int n) {
    unflushedTransactions.release(n);
  }

  /** Called from the apply path. Returns immediately; the write happens on the flush thread. */
  public synchronized void add(KeyValueCommand command, TermIndex termIndex) {
    currentBuffer.add(new Entry(termIndex, command));
    notify();
  }

  /** Waits until everything queued before the call has been committed to RocksDB. */
  public void awaitFlush() throws InterruptedException {
    try {
      flushNotifier.await().get();
    } catch (ExecutionException e) {
      throw new IllegalStateException("Flush failed", e.getCause());
    }
  }

  public long getFlushedTransactionCount() {
    return flushedTransactionCount.get();
  }

  public long getFlushIterations() {
    return flushIterations.get();
  }

  public int getUnflushedCount() {
    return currentBuffer.size() + readyBuffer.size();
  }

  /** Flush thread body. */
  private void flushTransactions() {
    while (isRunning.get() && canFlush()) {
      if (flushIntervalMs > 0) {
        // Plain sleep, not wait(): add() notifies on every entry and would cut a wait() short.
        try {
          Thread.sleep(flushIntervalMs);
        } catch (InterruptedException e) {
          Thread.currentThread().interrupt();
          return;
        }
      }
      flushCurrentBuffer();
    }
  }

  private synchronized boolean canFlush() {
    try {
      while (currentBuffer.isEmpty()) {
        // Both buffers are empty (readyBuffer was cleared by the previous flush): wake any waiters.
        flushNotifier.notifyFlush();
        flushNotifier.notifyFlush();
        wait(1000L);
      }
      return true;
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      if (isRunning.get()) {
        LOG.error("{} interrupted while running", Thread.currentThread().getName(), e);
      }
      return false;
    }
  }

  private void flushCurrentBuffer() {
    try {
      swapCurrentAndReadyBuffer();
      if (!readyBuffer.isEmpty()) {
        flushBatch(readyBuffer);
      }
      clearReadyBuffer();
      flushNotifier.notifyFlush();
    } catch (Throwable t) {
      // Ozone terminates the process here: continuing would let the state machine drift from the DB.
      LOG.error("Flush to RocksDB failed, stopping {}", Thread.currentThread().getName(), t);
      isRunning.set(false);
      throw new IllegalStateException("Flush to RocksDB failed", t);
    }
  }

  private void flushBatch(Queue<Entry> buffer) throws IOException {
    TermIndex last = null;
    final int size = buffer.size();
    try (WriteBatch batch = new WriteBatch()) {
      for (Entry e : buffer) {
        switch (e.command.getType()) {
          case PUT:
            batch.put(e.command.getKeyBytes(), e.command.getValueBytes());
            break;
          case DELETE:
            batch.delete(e.command.getKeyBytes());
            break;
          default:
            throw new IllegalStateException("Read-only command in the write buffer: " + e.command);
        }
        last = last == null || e.termIndex.compareTo(last) > 0 ? e.termIndex : last;
      }
      // The marker goes in the same batch as the data, so the DB never claims an index it lacks.
      batch.put(TransactionInfo.KEY, TransactionInfo.valueOf(last).toBytes());
      final long start = System.nanoTime();
      synchronized (transactionInfoLock) {
        db.write(writeOptions, batch);
      }
      LOG.debug("flushed {} entries up to {} in {} us", size, last, (System.nanoTime() - start) / 1000);
    } catch (RocksDBException e) {
      throw new IOException("Failed to write batch of " + size + " entries ending at " + last, e);
    }
    flushedTransactionCount.addAndGet(size);
    flushIterations.incrementAndGet();
    releaseUnflushedTransactions(size);
    // This is the only place applyCompletedIndex moves.
    updateLastAppliedIndex.accept(last);
  }

  /**
   * Stores {@code candidate} as the TransactionInfo unless the DB is already at or beyond it.
   * Used by takeSnapshot, where the marker may need to cover Ratis-internal entries that never
   * went through the buffer.
   *
   * @return whatever is stored when the method returns.
   */
  TransactionInfo persistIfNewer(TransactionInfo candidate) throws IOException {
    synchronized (transactionInfoLock) {
      final TransactionInfo stored = TransactionInfo.read(db);
      if (stored != null && stored.compareTo(candidate) >= 0) {
        return stored;
      }
      try {
        db.put(writeOptions, TransactionInfo.KEY, candidate.toBytes());
      } catch (RocksDBException e) {
        throw new IOException("Failed to persist " + candidate, e);
      }
      return candidate;
    }
  }

  private synchronized void swapCurrentAndReadyBuffer() {
    final Queue<Entry> tmp = currentBuffer;
    currentBuffer = readyBuffer;
    readyBuffer = tmp;
  }

  private synchronized void clearReadyBuffer() {
    readyBuffer.clear();
  }

  public void stop() {
    if (isRunning.compareAndSet(true, false)) {
      LOG.info("Stopping {}", daemon.getName());
      daemon.interrupt();
      try {
        daemon.join();
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
      }
    }
    writeOptions.close();
  }

  /** Lets callers wait for "the flush after next", which is the first one guaranteed to include their entry. */
  static final class FlushNotifier {
    private final Map<Integer, CompletableFuture<Integer>> flushFutures = new TreeMap<>();
    private int flushCount;

    synchronized CompletableFuture<Integer> await() {
      // +2: the entry may already be in readyBuffer being flushed (flush N+1), so wait for N+2.
      return flushFutures.computeIfAbsent(flushCount + 2, k -> new CompletableFuture<>());
    }

    synchronized void notifyFlush() {
      final int flush = ++flushCount;
      final CompletableFuture<Integer> f = flushFutures.remove(flush);
      if (f != null) {
        f.complete(flush);
      }
    }
  }
}
