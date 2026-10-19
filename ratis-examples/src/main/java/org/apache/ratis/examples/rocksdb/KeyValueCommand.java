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

import org.apache.ratis.protocol.Message;
import org.apache.ratis.thirdparty.com.google.protobuf.ByteString;

import java.nio.charset.StandardCharsets;

/**
 * Wire format of a client request: one type byte, then {@code key\0value}.
 * Kept as plain bytes so the example has no protobuf schema of its own.
 */
public final class KeyValueCommand {
  /** Command types. GET is read-only and goes through query(), the others are log entries. */
  public enum Type {
    PUT, DELETE, GET;

    static Type valueOf(byte b) {
      final Type[] values = values();
      if (b < 0 || b >= values.length) {
        throw new IllegalArgumentException("Unknown command type byte " + b);
      }
      return values[b];
    }
  }

  private final Type type;
  private final String key;
  private final String value;

  private KeyValueCommand(Type type, String key, String value) {
    this.type = type;
    this.key = key;
    this.value = value;
  }

  public static KeyValueCommand put(String key, String value) {
    return new KeyValueCommand(Type.PUT, key, value);
  }

  public static KeyValueCommand delete(String key) {
    return new KeyValueCommand(Type.DELETE, key, "");
  }

  public static KeyValueCommand get(String key) {
    return new KeyValueCommand(Type.GET, key, "");
  }

  public Type getType() {
    return type;
  }

  public String getKey() {
    return key;
  }

  public String getValue() {
    return value;
  }

  public byte[] getKeyBytes() {
    return key.getBytes(StandardCharsets.UTF_8);
  }

  public byte[] getValueBytes() {
    return value.getBytes(StandardCharsets.UTF_8);
  }

  public boolean isReadOnly() {
    return type == Type.GET;
  }

  public Message toMessage() {
    return Message.valueOf(encode());
  }

  public ByteString encode() {
    final byte[] k = getKeyBytes();
    final byte[] v = getValueBytes();
    final byte[] buf = new byte[1 + k.length + 1 + v.length];
    buf[0] = (byte) type.ordinal();
    System.arraycopy(k, 0, buf, 1, k.length);
    buf[1 + k.length] = 0;
    System.arraycopy(v, 0, buf, 2 + k.length, v.length);
    return ByteString.copyFrom(buf);
  }

  public static KeyValueCommand decode(ByteString bytes) {
    if (bytes.isEmpty()) {
      throw new IllegalArgumentException("Empty command");
    }
    final byte[] buf = bytes.toByteArray();
    final Type t = Type.valueOf(buf[0]);
    int sep = 1;
    while (sep < buf.length && buf[sep] != 0) {
      sep++;
    }
    if (sep >= buf.length) {
      throw new IllegalArgumentException("Missing key/value separator");
    }
    final String k = new String(buf, 1, sep - 1, StandardCharsets.UTF_8);
    final String v = new String(buf, sep + 1, buf.length - sep - 1, StandardCharsets.UTF_8);
    if (k.isEmpty()) {
      throw new IllegalArgumentException("Empty key");
    }
    return new KeyValueCommand(t, k, v);
  }

  @Override
  public String toString() {
    return type + "(" + key + (type == Type.PUT ? "=" + value : "") + ")";
  }
}
