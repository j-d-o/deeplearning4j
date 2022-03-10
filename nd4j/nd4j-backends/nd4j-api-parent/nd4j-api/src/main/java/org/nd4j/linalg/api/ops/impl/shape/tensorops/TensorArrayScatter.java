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

package org.nd4j.linalg.api.ops.impl.shape.tensorops;

import onnx.Onnx;
import org.nd4j.autodiff.samediff.SDVariable;
import org.nd4j.autodiff.samediff.SameDiff;
import org.nd4j.linalg.api.buffer.DataType;
import org.nd4j.linalg.api.ndarray.INDArray;

import java.util.Collections;
import java.util.List;
import java.util.Map;

public class TensorArrayScatter extends BaseTensorOp {
    public TensorArrayScatter(String name, SameDiff sameDiff, SDVariable[] args){
        super(name, sameDiff, args);
    }
    public TensorArrayScatter(SameDiff sameDiff, SDVariable[] args){
        super(null, sameDiff, args);
    }

    public TensorArrayScatter(){}

    public TensorArrayScatter(SameDiff sd, SDVariable input, SDVariable indices, SDVariable scatter) {
        this(sd,new SDVariable[]{input,indices,scatter});
    }

    public TensorArrayScatter(INDArray input, INDArray indices, INDArray scatter) {
    }

    @Override
    public String[] tensorflowNames() {
        return new String[]{"TensorArrayScatter", "TensorArrayScatterV2", "TensorArrayScatterV3"};
    }

    @Override
    public String toString() {
        return opName();
    }

    @Override
    public String opName() {
        return "scatter_list";
    }


    @Override
    public void initFromOnnx(Onnx.NodeProto node, SameDiff initWith, Map<String, Onnx.AttributeProto> attributesForNode, Onnx.GraphProto graph) {
    }

    @Override
    public List<DataType> calculateOutputDataTypes(List<DataType> inputDataType){
        //Dummy float variable
        return Collections.singletonList(DataType.FLOAT);
    }
}
