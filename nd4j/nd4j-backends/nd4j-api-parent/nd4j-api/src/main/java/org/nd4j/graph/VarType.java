/*
 *  ******************************************************************************
 *  *
 *  *
 *  * This program and the accompanying materials are made available under the
 *  * terms of the Apache License, Version 2.0 which is available at
 *  * https://www.apache.org/licenses/LICENSE-2.0.
 *  *
 *  *  See the NOTICE file distributed with this work for additional
 *  *  information regarding copyright ownership.
 *  * Unless required by applicable law or agreed to in writing, software
 *  * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 *  * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 *  * License for the specific language governing permissions and limitations
 *  * under the License.
 *  *
 *  * SPDX-License-Identifier: Apache-2.0
 *  *****************************************************************************
 */
package org.nd4j.graph;

public final class VarType {
  private VarType() { }
  public static final byte VARIABLE = 0;
  public static final byte CONSTANT = 1;
  public static final byte ARRAY = 2;
  public static final byte PLACEHOLDER = 3;
  public static final byte SEQUENCE = 4;

  public static final String[] names = { "VARIABLE", "CONSTANT", "ARRAY", "PLACEHOLDER", "SEQUENCE", };

  public static String name(int e) { return names[e]; }
}

