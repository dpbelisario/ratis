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

import org.apache.ratis.client.RaftClient;
import org.apache.ratis.conf.RaftProperties;
import org.apache.ratis.examples.common.Constants;
import org.apache.ratis.protocol.RaftClientReply;
import org.apache.ratis.util.JavaUtils;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.CompletableFuture;

/**
 * Command-line client for the RocksDB-backed key-value group.
 *
 * <pre>
 *   RocksDbClient put KEY VALUE
 *   RocksDbClient get KEY [PEER_INDEX]
 *   RocksDbClient delete KEY
 *   RocksDbClient stats [PEER_INDEX]   # that node's RocksDB read statistics since the previous stats call
 *   RocksDbClient load COUNT [BATCH]   # COUNT async puts, BATCH in flight at a time (default 100)
 * </pre>
 */
public final class RocksDbClient {
  private RocksDbClient() {
  }

  static RaftClient newClient() {
    return RaftClient.newBuilder()
        .setProperties(new RaftProperties())
        .setRaftGroup(Constants.RAFT_GROUP)
        .build();
  }

  static String text(RaftClientReply reply) {
    if (!reply.isSuccess()) {
      throw new IllegalStateException("Request failed: " + reply);
    }
    return reply.getMessage().getContent().toStringUtf8();
  }

  static void load(RaftClient client, int count, int batch) throws Exception {
    final long start = System.nanoTime();
    final List<CompletableFuture<RaftClientReply>> inFlight = new ArrayList<>(batch);
    for (int i = 0; i < count; i++) {
      final String k = String.format("key-%08d", i);
      inFlight.add(client.async().send(KeyValueCommand.put(k, "value-" + i + "-" + start).toMessage()));
      if (inFlight.size() == batch) {
        JavaUtils.allOf(inFlight).get();
        inFlight.forEach(f -> text(f.join()));
        inFlight.clear();
        if ((i + 1) % 1000 == 0) {
          System.out.println("  " + (i + 1) + " puts");
        }
      }
    }
    JavaUtils.allOf(inFlight).get();
    inFlight.forEach(f -> text(f.join()));
    final long ms = (System.nanoTime() - start) / 1_000_000;
    System.out.println("load " + count + " puts in " + ms + " ms (" + (ms == 0 ? count : count * 1000L / ms) + "/s)");
  }

  public static void main(String[] args) throws Exception {
    if (args.length < 1 || (args.length < 2 && !"stats".equalsIgnoreCase(args[0]))) {
      usage();
    }
    try (RaftClient client = newClient()) {
      switch (args[0].toLowerCase()) {
        case "put":
          if (args.length != 3) {
            usage();
          }
          System.out.println(text(client.io().send(KeyValueCommand.put(args[1], args[2]).toMessage())));
          break;
        case "get":
          // Optional third argument: index of the peer to read from (linearizable read on that peer).
          System.out.println(text(args.length > 2
              ? client.io().sendReadOnly(KeyValueCommand.get(args[1]).toMessage(),
                  Constants.PEERS.get(Integer.parseInt(args[2])).getId())
              : client.io().sendReadOnly(KeyValueCommand.get(args[1]).toMessage())));
          break;
        case "stats":
          // Optional second argument: index of the node to ask. Resets that node's counters.
          System.out.println(text(args.length > 1
              ? client.io().sendReadOnly(KeyValueCommand.stats().toMessage(),
                  Constants.PEERS.get(Integer.parseInt(args[1])).getId())
              : client.io().sendReadOnly(KeyValueCommand.stats().toMessage())));
          break;
        case "delete":
          System.out.println(text(client.io().send(KeyValueCommand.delete(args[1]).toMessage())));
          break;
        case "load":
          load(client, Integer.parseInt(args[1]), args.length > 2 ? Integer.parseInt(args[2]) : 100);
          break;
        default:
          usage();
      }
    } catch (IOException e) {
      System.err.println("args = " + Arrays.toString(args));
      throw e;
    }
  }

  private static void usage() {
    System.err.println("Usage: RocksDbClient put KEY VALUE | get KEY [PEER_INDEX] | delete KEY"
        + " | stats [PEER_INDEX] | load COUNT [BATCH]");
    System.exit(1);
  }
}
