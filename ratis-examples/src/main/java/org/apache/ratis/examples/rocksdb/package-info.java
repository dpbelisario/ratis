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

/**
 * A key-value store on Apache Ratis whose state lives in RocksDB.
 *
 * <p>This is a stripped-down port of the Apache Ozone Manager pattern
 * (OzoneManagerStateMachine + OzoneManagerDoubleBuffer) using nothing but
 * Ratis and rocksdbjni:
 * <ul>
 *   <li>{@link org.apache.ratis.examples.rocksdb.RocksDbStateMachine#applyTransaction}
 *       does not touch RocksDB. It hands the command to the double buffer and
 *       returns, so Ratis' {@code appliedIndex} advances immediately.</li>
 *   <li>{@link org.apache.ratis.examples.rocksdb.RocksDbDoubleBuffer} batches the
 *       queued commands, commits them to RocksDB in one {@code WriteBatch}
 *       together with the last term-index, and only then calls
 *       {@code updateLastAppliedTermIndex}. That is what moves
 *       {@code applyCompletedIndex} (the {@code applied} line in
 *       {@code ratis sh group info}).</li>
 *   <li>{@code commitIndex} is Ratis' own; it never waits for the state machine.</li>
 * </ul>
 */
package org.apache.ratis.examples.rocksdb;
