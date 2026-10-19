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
import org.apache.ratis.server.storage.FileInfo;
import org.apache.ratis.statemachine.SnapshotInfo;
import org.rocksdb.RocksDB;
import org.rocksdb.RocksDBException;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.List;

/**
 * The last term-index whose effects are in RocksDB.
 *
 * <p>It is written in the same {@code WriteBatch} as the data it describes, so after a crash
 * the DB and this marker always agree, and the state machine can restore
 * {@code lastAppliedTermIndex} from it on startup (Ozone calls this the TransactionInfo key).
 */
public final class TransactionInfo implements Comparable<TransactionInfo> {
  /** DB key, prefixed with '#' so it sorts before any user key. */
  public static final byte[] KEY = "#TRANSACTIONINFO".getBytes(StandardCharsets.UTF_8);

  private final TermIndex termIndex;

  private TransactionInfo(TermIndex termIndex) {
    this.termIndex = termIndex;
  }

  public static TransactionInfo valueOf(TermIndex termIndex) {
    return new TransactionInfo(termIndex);
  }

  public TermIndex getTermIndex() {
    return termIndex;
  }

  public byte[] toBytes() {
    return ByteBuffer.allocate(16).putLong(termIndex.getTerm()).putLong(termIndex.getIndex()).array();
  }

  public static TransactionInfo fromBytes(byte[] bytes) {
    final ByteBuffer b = ByteBuffer.wrap(bytes);
    return new TransactionInfo(TermIndex.valueOf(b.getLong(), b.getLong()));
  }

  /** @return the stored value, or null if the DB has never been written. */
  public static TransactionInfo read(RocksDB db) throws IOException {
    try {
      final byte[] bytes = db.get(KEY);
      return bytes == null ? null : fromBytes(bytes);
    } catch (RocksDBException e) {
      throw new IOException("Failed to read " + new String(KEY, StandardCharsets.UTF_8), e);
    }
  }

  /** Ratis asks the state machine for its latest snapshot; the DB itself is the snapshot, so no files. */
  public SnapshotInfo toSnapshotInfo() {
    return new SnapshotInfo() {
      @Override
      public TermIndex getTermIndex() {
        return termIndex;
      }

      @Override
      public List<FileInfo> getFiles() {
        return Collections.emptyList();
      }

      @Override
      public String toString() {
        return "SnapshotInfo" + termIndex;
      }
    };
  }

  @Override
  public int compareTo(TransactionInfo that) {
    return termIndex.compareTo(that.termIndex);
  }

  @Override
  public boolean equals(Object o) {
    return o instanceof TransactionInfo && termIndex.equals(((TransactionInfo) o).termIndex);
  }

  @Override
  public int hashCode() {
    return termIndex.hashCode();
  }

  @Override
  public String toString() {
    return termIndex.toString();
  }
}
