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

import org.apache.ratis.conf.RaftProperties;
import org.apache.ratis.examples.common.Constants;
import org.apache.ratis.grpc.GrpcConfigKeys;
import org.apache.ratis.protocol.RaftPeer;
import org.apache.ratis.server.RaftServer;
import org.apache.ratis.server.RaftServerConfigKeys;
import org.apache.ratis.server.storage.RaftStorage;
import org.apache.ratis.util.NetUtils;
import org.apache.ratis.util.TimeDuration;

import java.io.Closeable;
import java.io.File;
import java.io.IOException;
import java.util.Arrays;
import java.util.Collections;
import java.util.Scanner;

import static java.nio.charset.StandardCharsets.UTF_8;

/**
 * Starts one peer of the RocksDB-backed key-value group. Same shape as CounterServer:
 * peers come from conf.properties (RATIS_EXAMPLE_CONF), storage goes to ./kv-{peerId}.
 *
 * <pre>
 *   java -Dkv.flush.interval.ms=500 -cp ... org.apache.ratis.examples.rocksdb.RocksDbServer 0
 * </pre>
 */
public final class RocksDbServer implements Closeable {
  private final RaftServer server;
  private final RocksDbStateMachine stateMachine;

  public RocksDbServer(RaftPeer peer, File storageDir, RocksDbStateMachine.Config config) throws IOException {
    final RaftProperties properties = new RaftProperties();
    RaftServerConfigKeys.setStorageDir(properties, Collections.singletonList(storageDir));
    RaftServerConfigKeys.Read.setOption(properties, RaftServerConfigKeys.Read.Option.LINEARIZABLE);
    RaftServerConfigKeys.Read.setTimeout(properties, TimeDuration.ONE_MINUTE);
    final int port = NetUtils.createSocketAddr(peer.getAddress()).getPort();
    GrpcConfigKeys.Server.setPort(properties, port);

    this.stateMachine = new RocksDbStateMachine(config);
    this.server = RaftServer.newBuilder()
        .setGroup(Constants.RAFT_GROUP)
        .setProperties(properties)
        .setServerId(peer.getId())
        .setStateMachine(stateMachine)
        .setOption(RaftStorage.StartupOption.RECOVER)
        .build();
  }

  public void start() throws IOException {
    server.start();
  }

  public RocksDbStateMachine getStateMachine() {
    return stateMachine;
  }

  @Override
  public void close() throws IOException {
    server.close();
  }

  static RocksDbStateMachine.Config configFromSystemProperties() {
    return new RocksDbStateMachine.Config()
        .setMaxUnflushed(Integer.getInteger("kv.max.unflushed", 10000))
        .setFlushIntervalMs(Long.getLong("kv.flush.interval.ms", 0L))
        .setSyncWrites(Boolean.getBoolean("kv.sync.writes"))
        .setWriteBufferSize(Long.getLong("kv.write.buffer.size", 0L));
  }

  public static void main(String[] args) {
    try {
      if (args.length != 1) {
        throw new IllegalArgumentException("Expected 1 argument but got " + args.length);
      }
      final int peerIndex = Integer.parseInt(args[0]);
      if (peerIndex < 0 || peerIndex >= Constants.PEERS.size()) {
        throw new IllegalArgumentException("peerIndex must be in [0, " + Constants.PEERS.size() + ")");
      }
      final RaftPeer peer = Constants.PEERS.get(peerIndex);
      final File storageDir = new File("./kv-" + peer.getId());
      try (RocksDbServer s = new RocksDbServer(peer, storageDir, configFromSystemProperties())) {
        s.start();
        // exit when any input entered
        new Scanner(System.in, UTF_8.name()).nextLine();
      }
    } catch (Throwable e) {
      e.printStackTrace();
      System.err.println("args = " + Arrays.toString(args));
      System.err.println("Usage: java [-Dkv.max.unflushed=N] [-Dkv.flush.interval.ms=MS] [-Dkv.sync.writes=true]"
          + " [-Dkv.write.buffer.size=BYTES] org.apache.ratis.examples.rocksdb.RocksDbServer peer_index");
      System.exit(1);
    }
  }
}
