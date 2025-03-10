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

package org.nd4j.linalg.jcublas.ops.executioner;


import lombok.Getter;
import lombok.NonNull;
import lombok.extern.slf4j.Slf4j;
import lombok.val;
import lombok.var;
import org.bytedeco.javacpp.*;
import org.bytedeco.javacpp.indexer.LongIndexer;
import org.nd4j.common.base.Preconditions;
import org.nd4j.jita.allocator.impl.AtomicAllocator;
import org.nd4j.jita.allocator.pointers.CudaPointer;
import org.nd4j.jita.allocator.tad.DeviceTADManager;
import org.nd4j.jita.conf.CudaEnvironment;
import org.nd4j.linalg.api.buffer.DataBuffer;
import org.nd4j.linalg.api.buffer.DataType;
import org.nd4j.linalg.api.concurrency.AffinityManager;
import org.nd4j.linalg.api.environment.Nd4jEnvironment;
import org.nd4j.linalg.api.memory.pointers.PagedPointer;
import org.nd4j.linalg.api.ndarray.INDArray;
import org.nd4j.linalg.api.ndarray.INDArrayStatistics;
import org.nd4j.linalg.api.ops.*;
import org.nd4j.linalg.api.ops.aggregates.Aggregate;
import org.nd4j.linalg.api.ops.aggregates.Batch;
import org.nd4j.linalg.api.ops.executioner.DefaultOpExecutioner;
import org.nd4j.linalg.api.ops.executioner.OpStatus;
import org.nd4j.linalg.api.ops.impl.scatter.ScatterUpdate;
import org.nd4j.linalg.api.ops.impl.summarystats.Variance;
import org.nd4j.linalg.api.ops.performance.PerformanceTracker;
import org.nd4j.linalg.api.ops.random.BaseRandomOp;
import org.nd4j.linalg.api.rng.Random;
import org.nd4j.linalg.api.shape.LongShapeDescriptor;
import org.nd4j.linalg.api.shape.Shape;
import org.nd4j.linalg.api.shape.TadPack;
import org.nd4j.linalg.api.shape.options.ArrayOptionsHelper;
import org.nd4j.linalg.api.shape.options.ArrayType;
import org.nd4j.linalg.cache.TADManager;
import org.nd4j.linalg.exception.ND4JIllegalStateException;
import org.nd4j.linalg.exception.ND4JOpProfilerException;
import org.nd4j.linalg.factory.Nd4j;
import org.nd4j.linalg.jcublas.bindings.Nd4jCuda;
import org.nd4j.linalg.jcublas.buffer.AddressRetriever;
import org.nd4j.linalg.jcublas.buffer.BaseCudaDataBuffer;
import org.nd4j.linalg.jcublas.buffer.CudaLongDataBuffer;
import org.nd4j.linalg.jcublas.buffer.CudaUtf8Buffer;
import org.nd4j.linalg.jcublas.context.CudaContext;
import org.nd4j.common.primitives.AtomicBoolean;
import org.nd4j.common.primitives.Pair;
import org.nd4j.common.util.ArrayUtil;
import org.nd4j.nativeblas.*;

import java.util.*;


/**
 * JCuda executioner.
 * <p/>
 * Runs ops directly on the gpu
 *
 * If requested Op doesn't exist within GPU context, DefaultOpExecutioner will be used, with arrays/buffers updated after that.
 *
 * @author Adam Gibson
 * @author raver119@gmail.com
 */
@Slf4j
public class CudaExecutioner extends DefaultOpExecutioner {

    protected static NativeOps nativeOps = NativeOpsHolder.getInstance().getDeviceNativeOps();

    //    private static final Allocator allocator = AtomicAllocator.getInstance();

    @Getter
    protected static TADManager tadManager = new DeviceTADManager();
    protected ThreadLocal<PointerPointer> extraz = new ThreadLocal<>();
    protected volatile transient Properties properties;

    protected ThreadLocal<String> lastOp = new ThreadLocal<>();

    protected Map<String, CustomOpDescriptor> customOps = null;

    protected AtomicBoolean experimentalMode = new AtomicBoolean(false);

    public CudaExecutioner() {
        experimentalMode.set(nativeOps.isExperimentalEnabled());
    }

    public NativeOps getNativeOps() {
        return nativeOps;
    }

    @Override
    public String getLastOp() {
        return lastOp.get();
    }

    @Override
    public INDArray exec(BroadcastOp op) {
        long st = profilingConfigurableHookIn(op);

        checkForCompression(op);

        val dimension = op.dimensions().toIntVector();

        if (extraz.get() == null)
            extraz.set(new PointerPointer(32));

        val context = AtomicAllocator.getInstance().getDeviceContext();

        if (CudaEnvironment.getInstance().getConfiguration().isDebug())
            lastOp.set(op.opName());

        Pointer hostYShapeInfo =
                op.y() == null ? null : AddressRetriever.retrieveHostPointer(op.y().shapeInfoDataBuffer());
        Pointer hostZShapeInfo =
                op.z() == null ? null : AddressRetriever.retrieveHostPointer(op.z().shapeInfoDataBuffer());

        val x = op.x() == null ? null : ((BaseCudaDataBuffer) op.x().data()).getOpaqueDataBuffer();
        val y = op.y() == null ? null : ((BaseCudaDataBuffer) op.y().data()).getOpaqueDataBuffer();
        val z = op.z() == null ? null : ((BaseCudaDataBuffer) op.z().data()).getOpaqueDataBuffer();

        Pointer xShapeInfo = AtomicAllocator.getInstance().getPointer(op.x().shapeInfoDataBuffer(), context);

        Pair<DataBuffer, DataBuffer> tadBuffers = tadManager.getTADOnlyShapeInfo(op.x(), dimension);

        Pointer hostTadShapeInfo = AddressRetriever.retrieveHostPointer(tadBuffers.getFirst());
        Pointer devTadShapeInfo = AtomicAllocator.getInstance().getPointer(tadBuffers.getFirst(), context);

        DataBuffer offsets = tadBuffers.getSecond();
        Pointer devTadOffsets = AtomicAllocator.getInstance().getPointer(offsets, context);

        Pointer devTadShapeInfoZ = null;
        Pointer devTadOffsetsZ = null;

        // that's the place where we're going to have second TAD in place
        Pair<DataBuffer, DataBuffer> tadBuffersZ = tadManager.getTADOnlyShapeInfo(op.z(), dimension);

        devTadShapeInfoZ = AtomicAllocator.getInstance().getPointer(tadBuffersZ.getFirst(), context);
        devTadOffsetsZ = AtomicAllocator.getInstance().getPointer(tadBuffersZ.getSecond(), context);
        //        }

        // extraz.get().put
        // new PointerPointer
        PointerPointer xShapeInfoHostPointer = extraz.get().put(
                AddressRetriever.retrieveHostPointer(op.x().shapeInfoDataBuffer()), context.getOldStream(),
                AtomicAllocator.getInstance().getDeviceIdPointer(), context.getBufferAllocation(),
                context.getBufferReduction(), context.getBufferScalar(), context.getBufferSpecial(),
                hostYShapeInfo, hostZShapeInfo, hostTadShapeInfo, devTadShapeInfo, devTadOffsets,
                devTadShapeInfoZ, devTadOffsetsZ);

        //Pointer dimensionPointer = AtomicAllocator.getInstance().getPointer(Nd4j.createBuffer(dimension), context);
        Pointer dimensionPointer = AtomicAllocator.getInstance()
                .getPointer(AtomicAllocator.getInstance().getConstantBuffer(dimension), context);

        switch (op.getOpType()) {
            case BROADCAST:
                nativeOps.execBroadcast(xShapeInfoHostPointer, op.opNum(),
                        x, (LongPointer) AtomicAllocator.getInstance().getHostPointer(op.x().shapeInfoDataBuffer()), (LongPointer) xShapeInfo,
                        y, (LongPointer) AtomicAllocator.getInstance().getHostPointer(op.y().shapeInfoDataBuffer()), (LongPointer) AtomicAllocator.getInstance().getPointer(op.y().shapeInfoDataBuffer(),context),
                        z, (LongPointer) AtomicAllocator.getInstance().getHostPointer(op.z().shapeInfoDataBuffer()), (LongPointer) AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer(), context),
                        ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) AtomicAllocator.getInstance().getHostPointer(op.dimensions().shapeInfoDataBuffer()), (LongPointer) AtomicAllocator.getInstance().getPointer(op.dimensions().shapeInfoDataBuffer(), context));
                break;
            case BROADCAST_BOOL:
                nativeOps.execBroadcastBool(xShapeInfoHostPointer, op.opNum(),
                        x, (LongPointer) AtomicAllocator.getInstance().getHostPointer(op.x().shapeInfoDataBuffer()), (LongPointer) xShapeInfo,
                        y, (LongPointer) AtomicAllocator.getInstance().getHostPointer(op.y().shapeInfoDataBuffer()), (LongPointer) AtomicAllocator.getInstance().getPointer(op.y().shapeInfoDataBuffer(),context),
                        z, (LongPointer) AtomicAllocator.getInstance().getHostPointer(op.z().shapeInfoDataBuffer()), (LongPointer) AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer(), context),
                        null,
                        ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) AtomicAllocator.getInstance().getHostPointer(op.dimensions().shapeInfoDataBuffer()), (LongPointer) AtomicAllocator.getInstance().getPointer(op.dimensions().shapeInfoDataBuffer(), context));
                break;
            default:
                throw new UnsupportedOperationException("Unknown op type: " + op.getOpType());
        }

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        profilingConfigurableHookOut(op, null, st);

        return op.z();
    }

    /**
     *
     * @param op
     * @param dimension
     * @return
     */
    protected INDArray naiveExec(ReduceOp op, int... dimension) {
        long st = profilingConfigurableHookIn(op);

        if(op instanceof BaseReduceOp && ((BaseReduceOp)op).isEmptyReduce()){
            //Edge case for TF import compatibility: [x,y].reduce(empty) = [x,y]
            //Note that "empty" axis is NOT the same as length 0, as in INDArray.sum(new int[0]), which means "all dimensions"
            if(op.z() != null){
                Preconditions.checkState(op.x().equalShapes(op.z()), "For empty reductions, result (z) array must have same shape as x shape." +
                        " Got: x=%ndShape, z=%ndShape", op.x(), op.z());
                op.z().assign(op.x());
                return op.z();
            } else {
                op.setZ(op.x().dup());
                return op.z();
            }
        }

        INDArray ret = op.z();

        checkForCompression(op);
        op.validateDataTypes(null);
        //validateDataType(Nd4j.dataType(), op);

        for (int i = 0; i < dimension.length; i++)
            if (dimension[i] >= op.x().rank() && dimension[i] != Integer.MAX_VALUE)
                throw new ND4JIllegalStateException("Op target dimension " + Arrays.toString(dimension)
                        + " contains element that higher then rank of op.X: [" + op.x().rank() + "]");

        val context = AtomicAllocator.getInstance().getDeviceContext();

        if (CudaEnvironment.getInstance().getConfiguration().isDebug())
            lastOp.set(op.opName());

        val hostXShapeInfo = op.x() == null ? null : AddressRetriever.retrieveHostPointer(op.x().shapeInfoDataBuffer());
        val hostYShapeInfo = op.y() == null ? null : AddressRetriever.retrieveHostPointer(op.y().shapeInfoDataBuffer());
        val hostZShapeInfo = op.z() == null ? null : AddressRetriever.retrieveHostPointer(op.z().shapeInfoDataBuffer());

        Pair<DataBuffer, DataBuffer> tadBuffers = tadManager.getTADOnlyShapeInfo(op.x(), dimension);

        Pointer hostTadShapeInfo = AddressRetriever.retrieveHostPointer(tadBuffers.getFirst());
        Pointer devTadShapeInfo = AtomicAllocator.getInstance().getPointer(tadBuffers.getFirst(), context);

        DataBuffer offsets = tadBuffers.getSecond();
        Pointer devTadOffsets = offsets == null ? null : AtomicAllocator.getInstance().getPointer(offsets, context);

        Pointer xShapeInfo = AtomicAllocator.getInstance().getPointer(op.x().shapeInfoDataBuffer(), context);

        if (extraz.get() == null)
            extraz.set(new PointerPointer(32));

        PointerPointer xShapeInfoHostPointer = extraz.get().put(
                AddressRetriever.retrieveHostPointer(op.x().shapeInfoDataBuffer()),
                (Pointer) context.getOldStream(),
                AtomicAllocator.getInstance().getDeviceIdPointer(),
                context.getBufferAllocation(),
                context.getBufferReduction(),
                context.getBufferScalar(),
                context.getBufferSpecial(),
                (Pointer) hostYShapeInfo,
                (Pointer) hostZShapeInfo,
                hostTadShapeInfo,
                devTadShapeInfo,
                devTadOffsets);

        Pointer yDevTadOffsets = null;
        Pointer yDevTadShapeInfo = null;

        if (op.y() != null) {
            if (dimension.length == 0 || (dimension.length == 1 &&  dimension[0] == Integer.MAX_VALUE )|| op.x().tensorAlongDimension(0, dimension).length() != op.y().length()) {
                if (!op.isComplexAccumulation() && op.x().length() != op.y().length())
                    throw new ND4JIllegalStateException("Op.X [" + op.x().length() + "] and Op.Y [" + op.y().length() + "] lengths should match");

                if (!op.z().isScalar()) {
                    Pair<DataBuffer, DataBuffer> yTadBuffers = tadManager.getTADOnlyShapeInfo(op.y(), dimension);

                    yDevTadShapeInfo = AtomicAllocator.getInstance().getPointer(yTadBuffers.getFirst(), context);

                    DataBuffer yOffsets = yTadBuffers.getSecond();
                    yDevTadOffsets = yOffsets == null ? null : AtomicAllocator.getInstance().getPointer(yOffsets, context);

                    xShapeInfoHostPointer.put(12, yDevTadShapeInfo);
                    xShapeInfoHostPointer.put(13, yDevTadOffsets);
                }
            } else {
                // TAD vs full array code branch
                val fakeOffsets = Nd4j.getConstantHandler().getConstantBuffer(new int[] {0, 0}, DataType.LONG);
                yDevTadOffsets = fakeOffsets == null ? null : AtomicAllocator.getInstance().getPointer(fakeOffsets, context);

                yDevTadShapeInfo = AtomicAllocator.getInstance().getPointer(op.y().shapeInfoDataBuffer(), context);

                xShapeInfoHostPointer.put(12, AtomicAllocator.getInstance().getPointer(op.y().shapeInfoDataBuffer(), context));
                xShapeInfoHostPointer.put(13, null);
            }
        }

        DataType argsType;
        switch (op.getOpType()) {
            case REDUCE_LONG:
            case REDUCE_BOOL:
                argsType = op.x().dataType();
                break;
            default:
                argsType = op.z().dataType();
        }

        Pointer extraArgs = op.extraArgs() != null ? AtomicAllocator.getInstance().getPointer(op.extraArgsDataBuff(argsType), context) : null;
        Pointer dimensionPointer = AtomicAllocator.getInstance().getPointer(AtomicAllocator.getInstance().getConstantBuffer(dimension), context); //AtomicAllocator.getInstance().getPointer(Nd4j.createBuffer(dimension), context);

        val x = op.x() == null ? null : ((BaseCudaDataBuffer) op.x().data()).getOpaqueDataBuffer();
        val y = op.y() == null ? null : ((BaseCudaDataBuffer) op.y().data()).getOpaqueDataBuffer();
        val z = op.z() == null ? null : ((BaseCudaDataBuffer) op.z().data()).getOpaqueDataBuffer();

        if (op instanceof Variance) {
            if (ret.isScalar()) {
                nativeOps.execSummaryStatsScalar(xShapeInfoHostPointer, op.opNum(),
                        x, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                        extraArgs,
                        z, (LongPointer) hostZShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer()),
                        ((Variance) op).isBiasCorrected());
            } else {
                nativeOps.execSummaryStatsTad(xShapeInfoHostPointer, op.opNum(),
                        x, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                        extraArgs,
                        z, (LongPointer) hostZShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer(), context),
                        ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null,
                        ((Variance) op).isBiasCorrected(),
                        (LongPointer) devTadShapeInfo, (LongPointer) devTadOffsets);
            }
        } else if (op.y() != null) {
            if (op.isComplexAccumulation()) {

                val dT = new LongPointerWrapper(devTadOffsets);
                val yT = new LongPointerWrapper(yDevTadOffsets);

                nativeOps.execReduce3All(xShapeInfoHostPointer, op.opNum(),
                        x, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                        extraArgs,
                        y, (LongPointer) hostYShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.y().shapeInfoDataBuffer(),context),
                        z, (LongPointer) hostZShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer(), context),
                        ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null,
                        (LongPointer) devTadShapeInfo, dT,
                        (LongPointer) yDevTadShapeInfo, yT);
            } else if (ret.isScalar()) {
                nativeOps.execReduce3Scalar(xShapeInfoHostPointer, op.opNum(),
                        x, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                        extraArgs,
                        y, (LongPointer) hostYShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.y().shapeInfoDataBuffer(), context),
                        z, (LongPointer) hostZShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer(), context));
            } else {
                nativeOps.execReduce3Tad(xShapeInfoHostPointer, op.opNum(),
                        x, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                        extraArgs,
                        y, (LongPointer) hostYShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.y().shapeInfoDataBuffer(), context),
                        z, (LongPointer) hostZShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer(), context),
                        ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null,
                        (LongPointer) devTadShapeInfo, (LongPointer) devTadOffsets, (LongPointer) yDevTadShapeInfo, (LongPointer) yDevTadOffsets);
            }
        } else {
            if (ret.isScalar()) {
                switch (op.getOpType()) {
                    case REDUCE_FLOAT:
                        nativeOps.execReduceFloat(xShapeInfoHostPointer, op.opNum(),
                                x, (LongPointer) hostXShapeInfo,(LongPointer) xShapeInfo,
                                extraArgs,
                                z, (LongPointer) hostZShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer()));
                        break;
                    case REDUCE_BOOL:
                        nativeOps.execReduceBool(xShapeInfoHostPointer, op.opNum(),
                                x, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                                extraArgs,
                                z, (LongPointer) hostZShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer()));
                        break;
                    case REDUCE_LONG:
                        nativeOps.execReduceLong(xShapeInfoHostPointer, op.opNum(),
                                x, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                                extraArgs,
                                z, (LongPointer) hostZShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer()));
                        break;
                    case REDUCE_SAME:
                        nativeOps.execReduceSame(xShapeInfoHostPointer, op.opNum(),
                                x, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                                extraArgs,
                                z, (LongPointer) hostZShapeInfo,(LongPointer) AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer()));
                        break;
                    default:
                        throw new UnsupportedOperationException();
                }
            } else {
                switch (op.getOpType()) {
                    case REDUCE_FLOAT:
                        nativeOps.execReduceFloat2(xShapeInfoHostPointer, op.opNum(),
                                x, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                                extraArgs,
                                z, (LongPointer) hostZShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer(), context),
                                ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null);
                        break;
                    case REDUCE_BOOL:
                        nativeOps.execReduceBool2(xShapeInfoHostPointer, op.opNum(),
                                x, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                                extraArgs,
                                z, (LongPointer) hostZShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer(), context),
                                ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null);
                        break;
                    case REDUCE_SAME:
                        nativeOps.execReduceSame2(xShapeInfoHostPointer, op.opNum(),
                                x, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                                extraArgs,
                                z, (LongPointer) hostZShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer(), context),
                                ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null);
                        break;
                    case REDUCE_LONG:
                        nativeOps.execReduceLong2(xShapeInfoHostPointer, op.opNum(),
                                x, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                                extraArgs,
                                z, (LongPointer) hostZShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer(), context),
                                ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null);
                        break;
                    default:
                        throw new UnsupportedOperationException();
                }
            }
        }

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        profilingConfigurableHookOut(op, null, st);

        return op.z();
    }

    @Override
    public INDArray exec(Variance op) {
        return exec((ReduceOp) op);
    }

    @Override
    public INDArray exec(ReduceOp op) {
        checkForCompression(op);

        if(op instanceof BaseReduceOp && ((BaseReduceOp)op).isEmptyReduce()){
            //Edge case for TF import compatibility: [x,y].reduce(empty) = [x,y]
            //Note that "empty" axis is NOT the same as length 0, as in INDArray.sum(new int[0]), which means "all dimensions"
            if(op.z() != null){
                Preconditions.checkState(op.x().equalShapes(op.z()), "For empty reductions, result (z) array must have same shape as x shape." +
                        " Got: x=%ndShape, z=%ndShape", op.x(), op.z());
                op.z().assign(op.x());
                return op.z();
            } else {
                op.setZ(op.x().dup());
                return op.z();
            }
        }

        val dimension = op.dimensions().toIntVector();

        if (extraz.get() == null)
            extraz.set(new PointerPointer(32));

        val maxShape = Shape.getMaxShape(op.x(),op.y());

        val wholeDims = Shape.wholeArrayDimension(dimension) || op.x().rank() == dimension.length || dimension.length == 0;
        val retShape = Shape.reductionShape(op.y() == null ? op.x() : op.x().length() > op.y().length() ? op.x() : op.y(), dimension, true, op.isKeepDims());

        if (op.x().isVector() && op.x().length() == ArrayUtil.prod(retShape) && ArrayUtil.prodLong(retShape) > 1 && op.y() == null)
            return op.noOp();

        val dtype = op.resultType();
        INDArray ret = null;
        if (op.z() == null || op.z() == op.x()) {
            if (op.isComplexAccumulation()) {
                val xT = op.x().tensorsAlongDimension(dimension);
                val yT = op.y().tensorsAlongDimension(dimension);

                // we intentionally want to set it to 0.0
                ret = Nd4j.createUninitialized(dtype, new long[] {xT, yT});
            } else {
                if (op.y() != null) {
                    //2 options here: either pairwise, equal sizes - OR every X TAD vs. entirety of Y
                    if (op.x().length() == op.y().length()) {
                        //Pairwise
                        if (!wholeDims && op.x().tensorsAlongDimension(dimension) != op.y().tensorsAlongDimension(dimension)) {
                            throw new ND4JIllegalStateException("Number of TADs along dimension don't match: (x shape = " +
                                    Arrays.toString(op.x().shape()) + ", y shape = " + Arrays.toString(op.y().shape()) +
                                    ", dimension = " + Arrays.toString(dimension) + ")");
                        }
                    } else {
                        if (dimension.length == 0)
                            throw new ND4JIllegalStateException("TAD vs TAD comparison requires dimension (or other comparison mode was supposed to be used?)");

                        //Every X TAD vs. entirety of Y
                        val xTADSize = op.x().length() / op.x().tensorsAlongDimension(dimension);

                        if (xTADSize != op.y().length()) {
                            throw new ND4JIllegalStateException("Size of TADs along dimension don't match for pairwise execution:" +
                                    " (x TAD size = " + xTADSize + ", y size = " + op.y().length());
                        }
                    }
                }

                // in case of regular accumulation we don't care about array state before op
                ret = Nd4j.create(dtype, retShape);
            }
            op.setZ(ret);
        } else {
            // compare length

            if (op.z().length() != (retShape.length == 0 ? 1 : ArrayUtil.prodLong(retShape)))
                throw new ND4JIllegalStateException("Shape of target array for reduction [" + Arrays.toString(op.z().shape()) + "] doesn't match expected [" + Arrays.toString(retShape) + "]");
        }

        long st = profilingConfigurableHookIn(op);
        naiveExec(op, dimension);

        profilingConfigurableHookOut(op, null, st);

        return op.z();
    }

    @Override
    public INDArray exec(IndexAccumulation op) {
        val dimension = Shape.normalizeAxis(op.x().rank(), op.dimensions().toIntVector());

        if (op.x().isEmpty()) {
            for (val d:dimension) {
                Preconditions.checkArgument(op.x().shape()[d] != 0, "IndexReduce can't be issued along axis with 0 in shape");
            }
        }

        if (op.z() == null) {
            val retShape = Shape.reductionShape(op.x(), dimension, true, op.isKeepDims());
            op.setZ(Nd4j.createUninitialized(DataType.LONG, retShape));
        }

        long st = profilingConfigurableHookIn(op);

        checkForCompression(op);

        //validateDataType(Nd4j.dataType(), op);

        if (extraz.get() == null)
            extraz.set(new PointerPointer(32));

        if (op.x().isVector() && op.x().length() == op.z().length()) {
            return op.x();
        }

        if (op.z().isEmpty())
            return op.z();

        if (CudaEnvironment.getInstance().getConfiguration().isDebug())
            lastOp.set(op.opName());

        val context = AtomicAllocator.getInstance().getDeviceContext();

        val hostXShapeInfo =
                op.x() == null ? null : AddressRetriever.retrieveHostPointer(op.x().shapeInfoDataBuffer());
        val hostYShapeInfo =
                op.y() == null ? null : AddressRetriever.retrieveHostPointer(op.y().shapeInfoDataBuffer());
        val hostZShapeInfo =
                op.z() == null ? null : AddressRetriever.retrieveHostPointer(op.z().shapeInfoDataBuffer());

        val xShapeInfo = AtomicAllocator.getInstance().getPointer(op.x().shapeInfoDataBuffer(), context);
        val zShapeInfo = AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer(), context);

        Pair<DataBuffer, DataBuffer> tadBuffers = tadManager.getTADOnlyShapeInfo(op.x(), dimension);

        val hostTadShapeInfo = AddressRetriever.retrieveHostPointer(tadBuffers.getFirst());
        val devTadShapeInfo = AtomicAllocator.getInstance().getPointer(tadBuffers.getFirst(), context);

        val offsets = tadBuffers.getSecond();
        val devTadOffsets = offsets == null ? null : AtomicAllocator.getInstance().getPointer(offsets, context);

        PointerPointer xShapeInfoHostPointer = extraz.get().put(
                AddressRetriever.retrieveHostPointer(op.x().shapeInfoDataBuffer()), (Pointer) context.getOldStream(),
                AtomicAllocator.getInstance().getDeviceIdPointer(), context.getBufferAllocation(),
                context.getBufferReduction(), context.getBufferScalar(), context.getBufferSpecial(),
                (Pointer) hostYShapeInfo, (Pointer) hostZShapeInfo, hostTadShapeInfo, devTadShapeInfo, (Pointer) devTadOffsets);
        Pointer extraArgs = op.extraArgs() != null
                ? AtomicAllocator.getInstance().getPointer(op.extraArgsDataBuff(op.x().dataType()), context) : null;
        //Pointer dimensionPointer = AtomicAllocator.getInstance().getPointer(Nd4j.createBuffer(dimension), context);
        Pointer dimensionPointer = AtomicAllocator.getInstance()
                .getPointer(AtomicAllocator.getInstance().getConstantBuffer(dimension), context);

        val x = op.x() == null ? null : ((BaseCudaDataBuffer) op.x().data()).getOpaqueDataBuffer();
        val y = op.y() == null ? null : ((BaseCudaDataBuffer) op.y().data()).getOpaqueDataBuffer();
        val z = op.z() == null ? null : ((BaseCudaDataBuffer) op.z().data()).getOpaqueDataBuffer();

        nativeOps.execIndexReduce(xShapeInfoHostPointer, op.opNum(),
                x, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                extraArgs,
                z, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null);

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        profilingConfigurableHookOut(op, null, st);

        return op.z();
    }


    @Override
    public INDArray exec(Op op) {
        return exec(op, null);
    }

    @Override
    public INDArray exec(Op op, OpContext oc) {
        checkForCompression(op);

        if (op instanceof TransformOp) {
            TransformOp t = (TransformOp) op;
            invoke(t, oc);
        } else if (op instanceof ReduceOp) {
            ReduceOp acc = (ReduceOp) op;
            invoke(acc, oc, acc.dimensions().toIntVector());
        } else if (op instanceof ScalarOp) {
            ScalarOp sc = (ScalarOp) op;
            invoke(sc, oc);
        } else if (op instanceof BroadcastOp) {
            BroadcastOp broadcastOp = (BroadcastOp) op;
            invoke(broadcastOp, oc);
        } else if (op instanceof IndexAccumulation) {
            IndexAccumulation indexAccumulation = (IndexAccumulation) op;
            invoke(indexAccumulation, oc, indexAccumulation.dimensions().toIntVector());
        } else if (op instanceof RandomOp) {
            exec((RandomOp) op, oc, Nd4j.getRandom());
        } else if (op instanceof CustomOp) {
            exec((CustomOp) op, oc);
        }


        return op.z();
    }


    @Override
    public TransformOp execAndReturn(TransformOp op) {
        checkForCompression(op);
        invoke(op, null);
        return op;
    }



    protected CudaContext invoke(BroadcastOp op, OpContext oc) {
        long st = profilingConfigurableHookIn(op);

        INDArray x = getX(op, oc);
        INDArray y = getY(op, oc);
        INDArray z = getZ(op, oc);

        checkForCompression(op);

        //validateDataType(Nd4j.dataType(), op);

        if (extraz.get() == null)
            extraz.set(new PointerPointer(32));

        val context = AtomicAllocator.getInstance().getDeviceContext();

        if (CudaEnvironment.getInstance().getConfiguration().isDebug())
            lastOp.set(op.opName());

        Pointer xShapeInfo = AtomicAllocator.getInstance().getPointer(x.shapeInfoDataBuffer(), context);


        val hostXShapeInfo =
                x == null ? null : AddressRetriever.retrieveHostPointer(x.shapeInfoDataBuffer());
        val hostYShapeInfo =
                y == null ? null : AddressRetriever.retrieveHostPointer(y.shapeInfoDataBuffer());
        val hostZShapeInfo =
                z == null ? null : AddressRetriever.retrieveHostPointer(z.shapeInfoDataBuffer());

        val tadBuffers = tadManager.getTADOnlyShapeInfo(x, op.getDimension());

        val hostTadShapeInfo = AddressRetriever.retrieveHostPointer(tadBuffers.getFirst());
        val devTadShapeInfo = AtomicAllocator.getInstance().getPointer(tadBuffers.getFirst(), context);

        val offsets = tadBuffers.getSecond();
        val devTadOffsets = AtomicAllocator.getInstance().getPointer(offsets, context);

        Pointer devTadShapeInfoZ = null;
        Pointer devTadOffsetsZ = null;

        // that's the place where we're going to have second TAD in place
        val tadBuffersZ = tadManager.getTADOnlyShapeInfo(z, op.getDimension());

        devTadShapeInfoZ = AtomicAllocator.getInstance().getPointer(tadBuffersZ.getFirst(), context);
        devTadOffsetsZ = AtomicAllocator.getInstance().getPointer(tadBuffersZ.getSecond(), context);

        PointerPointer xShapeInfoHostPointer = extraz.get().put(
                AddressRetriever.retrieveHostPointer(x.shapeInfoDataBuffer()), // 0
                (Pointer) context.getOldStream(), // 1
                AtomicAllocator.getInstance().getDeviceIdPointer(), // 2
                context.getBufferAllocation(), // 3
                context.getBufferReduction(),  // 4
                context.getBufferScalar(),  // 5
                context.getBufferSpecial(), // 6
                (Pointer) hostYShapeInfo,  // 7
                (Pointer) hostZShapeInfo,  // 8
                hostTadShapeInfo,  // 9
                devTadShapeInfo,  // 10
                devTadOffsets, // 11
                devTadShapeInfoZ,  // 12
                devTadOffsetsZ); // 13

        Pointer yShapeInfo = AtomicAllocator.getInstance().getPointer(y.shapeInfoDataBuffer(), context);

        Pointer zShapeInfo = AtomicAllocator.getInstance().getPointer(z.shapeInfoDataBuffer(), context);
        Pointer dimensionPointer = AtomicAllocator.getInstance().getPointer(AtomicAllocator.getInstance().getConstantBuffer(op.getDimension()), context);

        val xb = x == null ? null : ((BaseCudaDataBuffer) x.data()).getOpaqueDataBuffer();
        val yb = y == null ? null : ((BaseCudaDataBuffer) y.data()).getOpaqueDataBuffer();
        val zb = z == null ? null : ((BaseCudaDataBuffer) z.data()).getOpaqueDataBuffer();

        //log.info("X: {}; Y: {}; Z: {}; dTS: {}, dTO: {}; dTSz: {}; dTOz: {};", x.address(), y.address(), z.address(), devTadShapeInfo.address(), devTadOffsets.address(), devTadShapeInfoZ.address(), devTadOffsetsZ.address());

        switch (op.getOpType()) {
            case BROADCAST:
                nativeOps.execBroadcast(xShapeInfoHostPointer, op.opNum(),
                        xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                        yb, (LongPointer) hostYShapeInfo, (LongPointer) yShapeInfo,
                        zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                        ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null);
                break;
            case BROADCAST_BOOL:
                nativeOps.execBroadcastBool(xShapeInfoHostPointer, op.opNum(),
                        xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                        yb, (LongPointer) hostYShapeInfo, (LongPointer) yShapeInfo,
                        zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                        null,
                        ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null);
                break;
            default:
                throw new UnsupportedOperationException("Unknown opType: " + op.getOpType());
        }

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        profilingConfigurableHookOut(op, oc, st);

        return null;
    }



    protected CudaContext invoke(IndexAccumulation op, OpContext oc, int[] dimension) {
        INDArray x = getX(op, oc);
        INDArray y = getY(op, oc);
        INDArray z = getZ(op, oc);

        dimension = Shape.normalizeAxis(x.rank(), dimension);
        if (dimension == null || (dimension.length == 1 && dimension[0] == Integer.MAX_VALUE)) {
            if(z == x || z == null) {
                z = Nd4j.createUninitialized(DataType.LONG, new long[0], 'c');
                setZ(z, op, oc);
            }
        }

        boolean keepDims = op.isKeepDims();
        long[] retShape = Shape.reductionShape(x, dimension, true, keepDims);

        if(z == null || x == z) {
            val ret = Nd4j.createUninitialized(DataType.LONG, retShape);

            setZ(ret, op, oc);
            z = ret;
        } else if(!Arrays.equals(retShape, z.shape())){
            throw new IllegalStateException("Z array shape does not match expected return type for op " + op
                    + ": expected shape " + Arrays.toString(retShape) + ", z.shape()=" + Arrays.toString(z.shape()));
        }

        long st = profilingConfigurableHookIn(op);

        checkForCompression(op);

        //validateDataType(Nd4j.dataType(), op);

        if (extraz.get() == null)
            extraz.set(new PointerPointer(32));

        if (CudaEnvironment.getInstance().getConfiguration().isDebug())
            lastOp.set(op.opName());
        CudaEnvironment.getInstance().getConfiguration().enableDebug(true);
        if (dimension != null)
            for (int i = 0; i < dimension.length; i++)
                if (dimension[i] >= x.rank() && dimension[i] != Integer.MAX_VALUE)
                    throw new ND4JIllegalStateException("Op target dimension " + Arrays.toString(dimension) + " contains element that higher then rank of op.X: [" + x.rank() + "]");

        val context = AtomicAllocator.getInstance().getDeviceContext();

        Pointer xShapeInfo = AtomicAllocator.getInstance().getPointer(x.shapeInfoDataBuffer(), context);
        Pointer extraArgs = op.extraArgs() != null ? AtomicAllocator.getInstance().getPointer(op.extraArgsDataBuff(x.dataType()), context) : null;

        val hostXShapeInfo = x == null ? null : AddressRetriever.retrieveHostPointer(x.shapeInfoDataBuffer());
        val hostYShapeInfo = y == null ? null : AddressRetriever.retrieveHostPointer(y.shapeInfoDataBuffer());
        val hostZShapeInfo = z == null ? null : AddressRetriever.retrieveHostPointer(z.shapeInfoDataBuffer());

        int fdimension[] = dimension;
        if (fdimension == null)
            fdimension = new int[] {0};

        Pair<DataBuffer, DataBuffer> tadBuffers = tadManager.getTADOnlyShapeInfo(x, fdimension);

        Pointer hostTadShapeInfo = AddressRetriever.retrieveHostPointer(tadBuffers.getFirst());
        Pointer devTadShapeInfo = AtomicAllocator.getInstance().getPointer(tadBuffers.getFirst(), context);

        DataBuffer offsets = tadBuffers.getSecond();
        Pointer devTadOffsets = offsets == null ? null : AtomicAllocator.getInstance().getPointer(offsets, context);
        val zShapeInfo = AtomicAllocator.getInstance().getPointer(z.shapeInfoDataBuffer(), context);

        val xb = x == null ? null : ((BaseCudaDataBuffer) x.data()).getOpaqueDataBuffer();
        val zb = z == null ? null : ((BaseCudaDataBuffer) z.data()).getOpaqueDataBuffer();

        PointerPointer xShapeInfoHostPointer = extraz.get().put(
                AddressRetriever.retrieveHostPointer(x.shapeInfoDataBuffer()), (Pointer) context.getOldStream(),
                AtomicAllocator.getInstance().getDeviceIdPointer(), context.getBufferAllocation(),
                context.getBufferReduction(), context.getBufferScalar(), context.getBufferSpecial(),
                (Pointer) hostYShapeInfo, (Pointer) hostZShapeInfo, hostTadShapeInfo, devTadShapeInfo, devTadOffsets);

        if (z.isScalar() || dimension == null || dimension[0] == Integer.MAX_VALUE) {
            nativeOps.execIndexReduceScalar(xShapeInfoHostPointer, op.opNum(),
                    xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                    extraArgs,
                    zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo);
        } else {
            if (dimension != null && dimension.length > 1)
                Arrays.sort(dimension);

            //long dimensionPointer = AtomicAllocator.getInstance().getPointer(Nd4j.createBuffer(dimension), context);
            Pointer dimensionPointer = AtomicAllocator.getInstance()
                    .getHostPointer(AtomicAllocator.getInstance().getConstantBuffer(dimension));

            nativeOps.execIndexReduce(xShapeInfoHostPointer, op.opNum(),
                    xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                    extraArgs,
                    zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                    ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null);
        }

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        profilingConfigurableHookOut(op, oc, st);

        return null;

    }


    protected CudaContext invoke(ReduceOp op, OpContext oc, int[] dimension) {
        val context = AtomicAllocator.getInstance().getDeviceContext();

        INDArray x = getX(op, oc);
        INDArray y = getY(op, oc);
        INDArray z = getZ(op, oc);

        if(op instanceof BaseReduceOp && ((BaseReduceOp)op).isEmptyReduce()){
            //Edge case for TF import compatibility: [x,y].reduce(empty) = [x,y]
            //Note that "empty" axis is NOT the same as length 0, as in INDArray.sum(new int[0]), which means "all dimensions"
            if(z != null){
                Preconditions.checkState(x.equalShapes(z), "For empty reductions, result (z) array must have same shape as x shape." +
                        " Got: x=%ndShape, z=%ndShape", x, z);
                z.assign(x);
                return context;
            } else {
                op.setZ(x.dup());
                return context;
            }
        }

        // FIXME: this should be moved down to C++ on per-op basis
        // reduce to scalar case, ReduceBool ops require special treatment
        if (op instanceof BaseReduceBoolOp && x.isEmpty() && (dimension == null || (dimension.length == 1 && dimension[0] == Integer.MAX_VALUE))) {
            if (z == null) {
                op.setZ(Nd4j.scalar(((BaseReduceBoolOp) op).emptyValue()));
            } else {
                z.assign(((BaseReduceBoolOp) op).emptyValue());
            }

            return context;
        }

        long st = profilingConfigurableHookIn(op);

        checkForCompression(op);

        dimension = Shape.normalizeAxis(x.rank(), dimension);

        //validateDataType(Nd4j.dataType(), op);

        if (extraz.get() == null)
            extraz.set(new PointerPointer(32));

        // dimension is ALWAYS null here.
        if (dimension == null )
            dimension = new int[] {Integer.MAX_VALUE};

        if (dimension != null && dimension.length > 1)
            Arrays.sort(dimension);

        for (int i = 0; i < dimension.length; i++)
            if (dimension[i] >= x.rank() && dimension[i] != Integer.MAX_VALUE)
                throw new ND4JIllegalStateException("Op target dimension " + Arrays.toString(dimension)
                        + " contains element that higher then rank of op.X: [" + x.rank() + "]");

        if (CudaEnvironment.getInstance().getConfiguration().isDebug())
            lastOp.set(op.opName());

        val tadBuffers = x.isEmpty() ? Pair.<DataBuffer, DataBuffer>makePair(x.data(), null) : tadManager.getTADOnlyShapeInfo(x, dimension);

        val hostTadShapeInfo = AddressRetriever.retrieveHostPointer(tadBuffers.getFirst());
        val devTadShapeInfo = AtomicAllocator.getInstance().getPointer(tadBuffers.getFirst(), context);

        val offsets = x.isEmpty() ? null : tadBuffers.getSecond();
        val devTadOffsets = offsets == null ? null : AtomicAllocator.getInstance().getPointer((DataBuffer) offsets, context);

        Pointer xShapeInfo = AtomicAllocator.getInstance().getPointer(x.shapeInfoDataBuffer(), context);

        long[] retShape = Shape.reductionShape(x, dimension, true, op.isKeepDims());

        if (y != null) {
            //2 options here: either pairwise, equal sizes - OR every X TAD vs. entirety of Y
            if (x.length() == y.length()) {
                //Pairwise
                if (x.tensorsAlongDimension(dimension) != y.tensorsAlongDimension(dimension)) {
                    throw new ND4JIllegalStateException("Number of TADs along dimension don't match: (x shape = " +
                            Arrays.toString(x.shape()) + ", y shape = " + Arrays.toString(y.shape()) +
                            ", dimension = " + Arrays.toString(dimension) + ")");
                }
            } else {
                //Every X TAD vs. entirety of Y
                val xTADSize = x.length() / x.tensorsAlongDimension(dimension);

                if (xTADSize != y.length()) {
                    throw new ND4JIllegalStateException("Size of TADs along dimension don't match for pairwise execution:" +
                            " (x TAD size = " + xTADSize + ", y size = " + y.length());
                }
            }
        }

        //if (x.isVector() && x.length() == ArrayUtil.prod(retShape)) {
        //    return null;
        //}

        val dataType = oc != null ? op.resultType(oc) : op.resultType();

        if( z == null ){
            val ret = Nd4j.createUninitialized(dataType, retShape);
            setZ(ret, op, oc);
            z = ret;
        } else if(z.dataType() != dataType || !Arrays.equals(retShape, z.shape())){
            throw new ND4JIllegalStateException("Output array for op " + op.getClass().getSimpleName() + " should have type " + dataType + " and shape " + Arrays.toString(retShape)
                    + " but has datatype " + z.dataType() + " and shape " + Arrays.toString(z.shape()));
        }

        val eb = op.extraArgsDataBuff(z.dataType() == DataType.BOOL || op.getOpType() == Op.Type.REDUCE_LONG ? x.dataType() : z.dataType());
        Pointer extraArgs = op.extraArgs() != null ? AtomicAllocator.getInstance().getPointer(eb, context) : null;

        val hostXShapeInfo = x == null ? null : AddressRetriever.retrieveHostPointer(x.shapeInfoDataBuffer());
        val hostYShapeInfo = y == null ? null : AddressRetriever.retrieveHostPointer(y.shapeInfoDataBuffer());
        val hostZShapeInfo = z == null ? null : AddressRetriever.retrieveHostPointer(z.shapeInfoDataBuffer());

        val xShapeInfoHostPointer = extraz.get().put(
                AddressRetriever.retrieveHostPointer(x.shapeInfoDataBuffer()), (Pointer) context.getOldStream(),
                AtomicAllocator.getInstance().getDeviceIdPointer(), context.getBufferAllocation(),
                context.getBufferReduction(), context.getBufferScalar(), context.getBufferSpecial(),
                (Pointer) hostYShapeInfo, (Pointer) hostZShapeInfo, hostTadShapeInfo, devTadShapeInfo, (Pointer) devTadOffsets);

        val yTadBuffers = y == null ? null : tadManager.getTADOnlyShapeInfo(y, dimension);

        val yDevTadShapeInfo = y == null ? null : AtomicAllocator.getInstance().getPointer(yTadBuffers.getFirst(), context);
        val yOffsets = y == null ? null : yTadBuffers.getSecond();
        val yDevTadOffsets = yOffsets == null ? null : (Pointer) AtomicAllocator.getInstance().getPointer(yOffsets, context);

        if (y != null) {
            xShapeInfoHostPointer.put(12L, (Pointer) yDevTadShapeInfo);
            xShapeInfoHostPointer.put(13L, (Pointer) yDevTadOffsets);
        }

        val zShapeInfo = AtomicAllocator.getInstance().getPointer(z.shapeInfoDataBuffer(), context);

        val xb = x == null ? null : ((BaseCudaDataBuffer) x.data()).getOpaqueDataBuffer();
        val yb = y == null ? null : ((BaseCudaDataBuffer) y.data()).getOpaqueDataBuffer();
        val zb = z == null ? null : ((BaseCudaDataBuffer) z.data()).getOpaqueDataBuffer();

        op.validateDataTypes(null);

        if (z.isScalar()) {
            if (op instanceof Variance) {
                nativeOps.execSummaryStatsScalar(xShapeInfoHostPointer, op.opNum(),
                        xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                        extraArgs,
                        zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                        ((Variance) op).isBiasCorrected());
            } else if (y != null) {
                Pointer yShapeInfo = AtomicAllocator.getInstance().getPointer(y.shapeInfoDataBuffer(), context);
                nativeOps.execReduce3Scalar(xShapeInfoHostPointer, op.opNum(),
                        xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                        extraArgs,
                        yb, (LongPointer) hostYShapeInfo, (LongPointer) yShapeInfo,
                        zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo);
            } else {
                switch (op.getOpType()) {
                    case REDUCE_FLOAT:
                        nativeOps.execReduceFloat(xShapeInfoHostPointer, op.opNum(),
                                xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                                extraArgs,
                                zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo);
                        break;
                    case REDUCE_BOOL:
                        nativeOps.execReduceBool(xShapeInfoHostPointer, op.opNum(),
                                xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                                extraArgs,
                                zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo);
                        break;
                    case REDUCE_SAME:
                        nativeOps.execReduceSame(xShapeInfoHostPointer, op.opNum(),
                                xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                                extraArgs,
                                zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo);
                        break;
                    case REDUCE_LONG:
                        nativeOps.execReduceLong(xShapeInfoHostPointer, op.opNum(),
                                xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                                extraArgs,
                                zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo);
                        break;
                    default:
                        throw new UnsupportedOperationException();
                }
            }
        } else {
            val dimensionPointer = AtomicAllocator.getInstance().getPointer(AtomicAllocator.getInstance().getConstantBuffer(dimension), context); //AtomicAllocator.getInstance().getPointer(Nd4j.createBuffer(dimension), context);

            if (y != null) {
                val yShapeInfo = AtomicAllocator.getInstance().getPointer(y.shapeInfoDataBuffer(), context);
                nativeOps.execReduce3Tad(xShapeInfoHostPointer, op.opNum(),
                        xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                        extraArgs,
                        yb, (LongPointer) hostYShapeInfo, (LongPointer) yShapeInfo,
                        zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                        ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null,
                        (LongPointer) devTadShapeInfo, (LongPointer) devTadOffsets, (LongPointer) yDevTadShapeInfo, (LongPointer) yDevTadOffsets);
            } else {
                if (op instanceof Variance) {
                    nativeOps.execSummaryStatsTad(xShapeInfoHostPointer, op.opNum(),
                            xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                            extraArgs,
                            zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                            ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null,
                            ((Variance) op).isBiasCorrected(),
                            (LongPointer) devTadShapeInfo, (LongPointer) devTadOffsets);
                } else {
                    switch (op.getOpType()) {
                        case REDUCE_FLOAT:
                            nativeOps.execReduceFloat2(xShapeInfoHostPointer, op.opNum(),
                                    xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                                    extraArgs,
                                    zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                                    ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null);
                            break;
                        case REDUCE_SAME:
                            nativeOps.execReduceSame2(xShapeInfoHostPointer, op.opNum(),
                                    xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                                    extraArgs,
                                    zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                                    ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null);
                            break;
                        case REDUCE_BOOL:
                            nativeOps.execReduceBool2(xShapeInfoHostPointer, op.opNum(),
                                    xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                                    extraArgs,
                                    zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                                    ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null);
                            break;
                        case REDUCE_LONG:
                            nativeOps.execReduceLong2(xShapeInfoHostPointer, op.opNum(),
                                    xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                                    extraArgs,
                                    zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                                    ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null);
                            break;
                        default:
                            throw new UnsupportedOperationException();
                    }
                }
            }
        }

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        profilingConfigurableHookOut(op, oc, st);

        Nd4j.getExecutioner().commit();

        return context;
    }


    protected CudaContext intercept(ScalarOp op, int[] dimension) {
        long st = profilingConfigurableHookIn(op);

        if (dimension != null && dimension.length > 1)
            Arrays.sort(dimension);

        val context = AtomicAllocator.getInstance().getDeviceContext();

        if (CudaEnvironment.getInstance().getConfiguration().isDebug())
            lastOp.set(op.opName());

        val hostXShapeInfo = op.x() == null ? null : AddressRetriever.retrieveHostPointer(op.x().shapeInfoDataBuffer());
        val hostYShapeInfo = op.y() == null ? null : AddressRetriever.retrieveHostPointer(op.y().shapeInfoDataBuffer());
        val hostZShapeInfo = op.z() == null ? null : AddressRetriever.retrieveHostPointer(op.z().shapeInfoDataBuffer());

        val xShapeInfo = AtomicAllocator.getInstance().getPointer(op.x().shapeInfoDataBuffer(), context);
        val yShapeInfo = AtomicAllocator.getInstance().getPointer(op.y().shapeInfoDataBuffer(), context);
        val zShapeInfo = AtomicAllocator.getInstance().getPointer(op.z().shapeInfoDataBuffer(), context);

        val tadBuffers = tadManager.getTADOnlyShapeInfo(op.x(), dimension);

        val hostTadShapeInfo = AddressRetriever.retrieveHostPointer(tadBuffers.getFirst());
        val devTadShapeInfo = AtomicAllocator.getInstance().getPointer(tadBuffers.getFirst(), context);

        val offsets = tadBuffers.getSecond();
        val devTadOffsets = AtomicAllocator.getInstance().getPointer(offsets, context);

        Pointer devTadShapeInfoZ = null;
        Pointer devTadOffsetsZ = null;

        val tadBuffersZ = tadManager.getTADOnlyShapeInfo(op.z(), dimension);

        devTadShapeInfoZ = AtomicAllocator.getInstance().getPointer(tadBuffersZ.getFirst(), context);
        devTadOffsetsZ = AtomicAllocator.getInstance().getPointer(tadBuffersZ.getSecond(), context);


        PointerPointer extraPointers = extraz.get().put(
                AddressRetriever.retrieveHostPointer(op.x().shapeInfoDataBuffer()), (Pointer) context.getOldStream(),
                AtomicAllocator.getInstance().getDeviceIdPointer(), context.getBufferAllocation(),
                context.getBufferReduction(), context.getBufferScalar(), context.getBufferSpecial(),
                (Pointer) hostYShapeInfo, (Pointer) hostZShapeInfo, hostTadShapeInfo, devTadShapeInfo, devTadOffsets,
                devTadShapeInfoZ, devTadOffsetsZ);

        val extraArgs = op.extraArgs() != null ? AtomicAllocator.getInstance().getPointer(op.extraArgsDataBuff(op.z().dataType()), context) : null;

        val dimensionPointer = AtomicAllocator.getInstance().getPointer(AtomicAllocator.getInstance().getConstantBuffer(dimension), context);

        val x = op.x() == null ? null : ((BaseCudaDataBuffer) op.x().data()).getOpaqueDataBuffer();
        val y = op.y() == null ? null : ((BaseCudaDataBuffer) op.y().data()).getOpaqueDataBuffer();
        val z = op.z() == null ? null : ((BaseCudaDataBuffer) op.z().data()).getOpaqueDataBuffer();

        switch (op.getOpType()) {
            case SCALAR:
                nativeOps.execScalarTad(extraPointers, op.opNum(),
                        x, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                        z, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                        y, (LongPointer) hostYShapeInfo, (LongPointer) yShapeInfo,
                        extraArgs,
                        ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null,
                        (LongPointer) devTadShapeInfo, (LongPointer) devTadOffsets,
                        (LongPointer) devTadShapeInfoZ, (LongPointer) devTadOffsetsZ);
                break;
            case SCALAR_BOOL:
                nativeOps.execScalarBoolTad(extraPointers, op.opNum(),
                        x, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                        z, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                        y, (LongPointer) hostYShapeInfo, (LongPointer) yShapeInfo,
                        extraArgs,
                        ((BaseCudaDataBuffer) op.dimensions().data()).getOpaqueDataBuffer(), (LongPointer) op.dimensions().shapeInfoDataBuffer().addressPointer(), null,
                        (LongPointer) devTadShapeInfo, (LongPointer) devTadOffsets,
                        (LongPointer) devTadShapeInfoZ, (LongPointer) devTadOffsetsZ);
                break;
            default:
                throw new UnsupportedOperationException();
        }

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        profilingConfigurableHookOut(op, null, st);

        return null;
    }

    @Override
    public INDArray exec(ScalarOp op) {
        invoke(op, null);
        return op.z();
    }

    protected CudaContext invoke(ScalarOp op, OpContext oc) {
        long st = profilingConfigurableHookIn(op);

        checkForCompression(op);

        INDArray x = getX(op, oc);
        INDArray y = getY(op, oc);
        INDArray z = getZ(op, oc);

//        validateDataType(Nd4j.dataType(), op);

        if(z == null){
            switch (op.getOpType()) {
                case SCALAR:
                    z = x.ulike();
                    setZ(x.ulike(), op, oc);
                    break;
                case SCALAR_BOOL:
                    z = Nd4j.createUninitialized(DataType.BOOL, x.shape());
                    setZ(z, op, oc);
                    break;
                default:
                    throw new ND4JIllegalStateException("Unknown op type: [" + op.getOpType() +"]");
            }
        }

        if (x.length() != z.length())
            throw new ND4JIllegalStateException("op.X length should be equal to op.Y length: ["
                    + Arrays.toString(x.shapeInfoDataBuffer().asInt()) + "] != ["
                    + Arrays.toString(z.shapeInfoDataBuffer().asInt()) + "]");

        if (extraz.get() == null)
            extraz.set(new PointerPointer(32));

        if (CudaEnvironment.getInstance().getConfiguration().isDebug())
            lastOp.set(op.opName());

        if (op.dimensions() != null) {
            intercept(op, op.dimensions().toIntVector());
            return null;
        }

        val context = AtomicAllocator.getInstance().getDeviceContext();

        val hostXShapeInfo = x == null ? null : AddressRetriever.retrieveHostPointer(x.shapeInfoDataBuffer());
        val hostYShapeInfo = op.scalar() == null ? null : AddressRetriever.retrieveHostPointer(op.scalar().shapeInfoDataBuffer());
        val hostZShapeInfo = z == null ? null : AddressRetriever.retrieveHostPointer(z.shapeInfoDataBuffer());

        Pointer xShapeInfo = AtomicAllocator.getInstance().getPointer(x.shapeInfoDataBuffer(), context);
        Pointer extraArgs = op.extraArgs() != null ? AtomicAllocator.getInstance().getPointer(op.extraArgsDataBuff(op.getOpType() == Op.Type.SCALAR_BOOL ? x.dataType() : z.dataType()), context) : null;

        Pointer zShapeInfo = AtomicAllocator.getInstance().getPointer(z.shapeInfoDataBuffer(), context);

        PointerPointer xShapeInfoHostPointer = extraz.get().put(
                AddressRetriever.retrieveHostPointer(x.shapeInfoDataBuffer()), (Pointer) context.getOldStream(),
                AtomicAllocator.getInstance().getDeviceIdPointer(), context.getBufferAllocation(),
                context.getBufferReduction(), context.getBufferScalar(), context.getBufferSpecial(),
                (Pointer) hostYShapeInfo, (Pointer) hostZShapeInfo, null, null);

        val xb = x == null ? null : ((BaseCudaDataBuffer) x.data()).getOpaqueDataBuffer();
        val yb = op.scalar() == null ? null : ((BaseCudaDataBuffer) op.scalar().data()).getOpaqueDataBuffer();
        val zb = z == null ? null : ((BaseCudaDataBuffer) z.data()).getOpaqueDataBuffer();

        switch (op.getOpType()) {
            case SCALAR_BOOL:
                nativeOps.execScalarBool(xShapeInfoHostPointer, op.opNum(),
                        xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                        zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                        yb, (LongPointer) hostYShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.scalar().shapeInfoDataBuffer(), context),
                        extraArgs);
                break;
            case SCALAR:
                nativeOps.execScalar(xShapeInfoHostPointer, op.opNum(),
                        xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                        zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                        yb, (LongPointer) hostYShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(op.scalar().shapeInfoDataBuffer(), context),
                        extraArgs);
                break;
            default:
                throw new UnsupportedOperationException("Unknown op type: " + op.getOpType());
        }

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        profilingConfigurableHookOut(op, oc, st);

        return null;
    }

    protected CudaContext invoke(TransformOp op, OpContext oc) {
        long st = profilingConfigurableHookIn(op);

        INDArray x = getX(op, oc);
        INDArray y = getY(op, oc);
        INDArray z = getZ(op, oc);

        checkForCompression(op);

        //validateDataType(Nd4j.dataType(), op);

        AtomicAllocator allocator = AtomicAllocator.getInstance();

        if (extraz.get() == null)
            extraz.set(new PointerPointer(32));

        val context = allocator.getDeviceContext();

        if (CudaEnvironment.getInstance().getConfiguration().isDebug())
            lastOp.set(op.opName());

        // special temp array for IsMax along dimension
        INDArray ret = null;

        Pointer xShapeInfo = allocator.getPointer(x.shapeInfoDataBuffer(), context);


        Pointer dimensionDevPointer = null;
        Pointer dimensionHostPointer = null;
        Pointer retPointer = null;
        Pointer retHostShape = null;
        int dimension[] = null;

        val hostXShapeInfo = x == null ? null : AddressRetriever.retrieveHostPointer(x.shapeInfoDataBuffer());
        var hostYShapeInfo = y == null ? null : AddressRetriever.retrieveHostPointer(y.shapeInfoDataBuffer());


        if (z == null) {
            ret = Nd4j.createUninitialized(op.resultType(), x.shape(), x.ordering());
            setZ(ret, op, oc);
            z = ret;
        }

        var extraArgs = op.extraArgs() != null ? allocator.getPointer(op.extraArgsDataBuff(op.getOpType() == Op.Type.TRANSFORM_BOOL || op.getOpType() == Op.Type.PAIRWISE_BOOL ? x.dataType() : z.dataType()), context) : null;
        val hostZShapeInfo = z == null ? null : AddressRetriever.retrieveHostPointer(z.shapeInfoDataBuffer());

        Pointer hostTadShapeInfo = null;
        Pointer devTadShapeInfo = null;

        Pointer hostMaxTadShapeInfo = null;
        Pointer devMaxTadShapeInfo = null;

        Pair<DataBuffer, DataBuffer> tadBuffers;
        Pair<DataBuffer, DataBuffer> tadMaxBuffers;

        Pointer devTadOffsets = null;
        Pointer devMaxTadOffsets = null;

        op.validateDataTypes(oc, experimentalMode.get());

        Pointer zShapeInfo = allocator.getPointer(z.shapeInfoDataBuffer(), context);


        PointerPointer xShapeInfoHostPointer =
                extraz.get().put(AddressRetriever.retrieveHostPointer(x.shapeInfoDataBuffer()), // 0
                        (Pointer) context.getOldStream(), // 1
                        allocator.getDeviceIdPointer(), // 2
                        context.getBufferAllocation(), // 3
                        context.getBufferReduction(), // 4
                        context.getBufferScalar(), // 5
                        context.getBufferSpecial(), // 6
                        (Pointer) hostYShapeInfo, // 7
                        (Pointer) hostZShapeInfo, // 8
                        hostTadShapeInfo, // 9
                        devTadShapeInfo, // 10
                        devTadOffsets, // 11
                        hostMaxTadShapeInfo, // 12
                        devMaxTadShapeInfo, // 13
                        devMaxTadOffsets, // 14
                        dimensionDevPointer, // special pointer for IsMax  // 15
                        dimensionHostPointer, // special pointer for IsMax  // 16
                        retPointer, // special pointer for IsMax // 17
                        (Pointer) new CudaPointer(dimension == null ? 0 : dimension.length),
                        retHostShape);


        val xb = x == null ? null : ((BaseCudaDataBuffer) x.data()).getOpaqueDataBuffer();
        val yb = y == null ? null : ((BaseCudaDataBuffer) y.data()).getOpaqueDataBuffer();
        val zb = z == null ? null : ((BaseCudaDataBuffer) z.data()).getOpaqueDataBuffer();

        if (y != null) {
            Pointer yShapeInfo = allocator.getPointer(y.shapeInfoDataBuffer(), context);

            switch (op.getOpType()) {
                case TRANSFORM_BOOL:
                case PAIRWISE_BOOL:
                    nativeOps.execPairwiseTransformBool(xShapeInfoHostPointer, op.opNum(),
                            xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                            yb, (LongPointer) hostYShapeInfo, (LongPointer) yShapeInfo,
                            zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                            extraArgs);
                    break;
                default:
                    nativeOps.execPairwiseTransform(xShapeInfoHostPointer, op.opNum(),
                            xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                            yb, (LongPointer) hostYShapeInfo, (LongPointer) yShapeInfo,
                            zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                            extraArgs);
                    break;
            }
        } else {
            switch (op.getOpType()) {
                case TRANSFORM_ANY:
                    nativeOps.execTransformAny(xShapeInfoHostPointer, op.opNum(),
                            xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                            zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                            extraArgs);
                    break;
                case TRANSFORM_FLOAT:
                    nativeOps.execTransformFloat(xShapeInfoHostPointer, op.opNum(),
                            xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                            zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                            extraArgs);
                    break;
                case TRANSFORM_BOOL:
                    nativeOps.execTransformBool(xShapeInfoHostPointer, op.opNum(),
                            xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                            zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                            extraArgs);
                    break;
                case TRANSFORM_SAME:
                    nativeOps.execTransformSame(xShapeInfoHostPointer, op.opNum(),
                            xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                            zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                            extraArgs);
                    break;
                case TRANSFORM_STRICT:
                    nativeOps.execTransformStrict(xShapeInfoHostPointer, op.opNum(),
                            xb, (LongPointer) hostXShapeInfo, (LongPointer) xShapeInfo,
                            zb, (LongPointer) hostZShapeInfo, (LongPointer) zShapeInfo,
                            extraArgs);
                    break;
                default:
                    throw new UnsupportedOperationException();
            }
        }

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        if (extraArgs != null)
            extraArgs.address();

        if (ret != null)
            ret.elementWiseStride();

        profilingConfigurableHookOut(op, oc, st);

        return null;
    }

    protected <T extends Aggregate> DataBuffer getBuffer(Batch<T> batch) {
        DataBuffer buffer = Nd4j.getDataBufferFactory().createInt(batch.getSample().getRequiredBatchMemorySize() * 4,
                false);
        batch.setParamsSurface(buffer);
        return buffer;
    }

    @Override
    public <T extends Aggregate> void exec(Batch<T> batch) {
        throw new UnsupportedOperationException("Pew-pew");
    }

    @Override
    public void exec(List<Aggregate> batch) {
        if (batch.size() == 0)
            return;

        List<Batch<Aggregate>> batches = Batch.getBatches(batch, 8192);
        for (Batch<Aggregate> single : batches) {
            this.exec(single);
        }

        val context = AtomicAllocator.getInstance().getDeviceContext();
        context.syncOldStream();
    }

    @Override
    public void exec(Aggregate op) {
        throw new UnsupportedOperationException("Pew-pew");
    }

    /**
     * This method executes specified RandomOp using default RNG available via Nd4j.getRandom()
     *
     * @param op
     */
    @Override
    public INDArray exec(RandomOp op) {
        return exec(op, Nd4j.getRandom());
    }


    @Override
    public INDArray exec(RandomOp op, Random rng) {
        return exec(op, null, rng);
    }

    public INDArray exec(RandomOp op, OpContext oc, Random rng) {
        INDArray x = getX(op, oc);
        INDArray y = getY(op, oc);
        INDArray z = getZ(op, oc);

        if(op instanceof BaseRandomOp && ((BaseRandomOp)op).isTripleArgRngOp() && z != null && x == null && y == null){
            //Ugly hack to ensure the triple arg call occurs
            //See GaussianDistribution.setZ etc
            x = z;
            y = z;
        }

        long st = profilingConfigurableHookIn(op);

        checkForCompression(op);

        //validateDataType(Nd4j.dataType(), op);

        if (rng.getStatePointer() == null)
            throw new IllegalStateException(
                    "You should use one of NativeRandom classes for NativeOperations execution");

        if (extraz.get() == null)
            extraz.set(new PointerPointer(32));

        if (CudaEnvironment.getInstance().getConfiguration().isDebug())
            lastOp.set(op.opName());

        val context = AtomicAllocator.getInstance().getDeviceContext();

        PointerPointer extraZZ = extraz.get().put(AddressRetriever.retrieveHostPointer(z.shapeInfoDataBuffer()),
                context.getOldStream(), AtomicAllocator.getInstance().getDeviceIdPointer());

        val hostXShapeInfo = x == null ? null : AddressRetriever.retrieveHostPointer(x.shapeInfoDataBuffer());
        val hostYShapeInfo = y == null ? null : AddressRetriever.retrieveHostPointer(y.shapeInfoDataBuffer());
        val hostZShapeInfo = z == null ? null : AddressRetriever.retrieveHostPointer(z.shapeInfoDataBuffer());

        val xb = x == null ? null : ((BaseCudaDataBuffer) x.data()).getOpaqueDataBuffer();
        val yb = y == null ? null : ((BaseCudaDataBuffer) y.data()).getOpaqueDataBuffer();
        val zb = z == null ? null : ((BaseCudaDataBuffer) z.data()).getOpaqueDataBuffer();

        if (x != null && y != null && z != null) {
            // triple arg call
            nativeOps.execRandom3(extraZZ, op.opNum(), rng.getStatePointer(), // rng state ptr
                    xb, (LongPointer) hostXShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(x.shapeInfoDataBuffer(), context),
                    yb, (LongPointer) hostYShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(y.shapeInfoDataBuffer(), context),
                    zb, (LongPointer) hostZShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(z.shapeInfoDataBuffer(), context),
                    AtomicAllocator.getInstance().getPointer(op.extraArgsDataBuff(z.dataType()), context));

        } else if (x != null && z != null) {
            //double arg call
            nativeOps.execRandom2(extraZZ, op.opNum(), rng.getStatePointer(), // rng state ptr
                    xb, (LongPointer) hostXShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(x.shapeInfoDataBuffer(), context),
                    zb, (LongPointer) hostZShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(z.shapeInfoDataBuffer(), context),
                    AtomicAllocator.getInstance().getPointer(op.extraArgsDataBuff(z.dataType()),context));


        } else {
            // single arg call
            nativeOps.execRandom(extraZZ, op.opNum(), rng.getStatePointer(), // rng state ptr
                    zb, (LongPointer) hostZShapeInfo, (LongPointer) AtomicAllocator.getInstance().getPointer(z.shapeInfoDataBuffer(), context),
                    AtomicAllocator.getInstance().getPointer(op.extraArgsDataBuff(z.dataType()), context));
        }

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        profilingConfigurableHookOut(op, oc, st);

        return z;
    }

    /**
     * This method return set of key/value
     * and key/key/value objects,
     * describing current environment
     *
     * @return
     */
    @Override
    public synchronized Properties getEnvironmentInformation() {
        if (properties == null) {
            Properties props = super.getEnvironmentInformation();

            List<Map<String, Object>> devicesList = new ArrayList<>();

            // fill with per-device information: name, memory, versions
            for (int i = 0; i < nativeOps.getAvailableDevices(); i++) {
                Map<String, Object> deviceProps = new HashMap<>();

                deviceProps.put(Nd4jEnvironment.CUDA_DEVICE_NAME_KEY, nativeOps.getDeviceName(i));
                deviceProps.put(Nd4jEnvironment.CUDA_FREE_MEMORY_KEY, nativeOps.getDeviceFreeMemory(i));
                deviceProps.put(Nd4jEnvironment.CUDA_TOTAL_MEMORY_KEY, nativeOps.getDeviceTotalMemory(i));
                deviceProps.put(Nd4jEnvironment.CUDA_DEVICE_MAJOR_VERSION_KEY, (long) nativeOps.getDeviceMajor(i));
                deviceProps.put(Nd4jEnvironment.CUDA_DEVICE_MINOR_VERSION_KEY, (long) nativeOps.getDeviceMinor(i));

                devicesList.add(i, deviceProps);
            }

            // fill with basic general info
            props.put(Nd4jEnvironment.BACKEND_KEY, "CUDA");
            props.put(Nd4jEnvironment.CUDA_NUM_GPUS_KEY, nativeOps.getAvailableDevices());
            props.put(Nd4jEnvironment.CUDA_DEVICE_INFORMATION_KEY, devicesList);
            props.put(Nd4jEnvironment.BLAS_VENDOR_KEY, (Nd4j.factory().blas()).getBlasVendor().toString());
            props.put(Nd4jEnvironment.HOST_FREE_MEMORY_KEY, Pointer.maxBytes() - Pointer.totalBytes());

            // fill bandwidth information
            props.put(Nd4jEnvironment.MEMORY_BANDWIDTH_KEY, PerformanceTracker.getInstance().getCurrentBandwidth());

            properties = props;
        } else {

            List<Map<String, Object>> devicesList = (List<Map<String, Object>>) properties.get(Nd4jEnvironment.CUDA_DEVICE_INFORMATION_KEY);

            // just update information that might change over time
            for (int i = 0; i < nativeOps.getAvailableDevices(); i++) {
                Map<String, Object> dev = devicesList.get(i);

                dev.put(Nd4jEnvironment.CUDA_FREE_MEMORY_KEY, nativeOps.getDeviceFreeMemory(i));
                dev.put(Nd4jEnvironment.CUDA_TOTAL_MEMORY_KEY, nativeOps.getDeviceTotalMemory(i));
            }

            properties.put(Nd4jEnvironment.CUDA_DEVICE_INFORMATION_KEY, devicesList);
            properties.put(Nd4jEnvironment.HOST_FREE_MEMORY_KEY, Pointer.maxBytes() - Pointer.totalBytes());

            // fill bandwidth information
            properties.put(Nd4jEnvironment.MEMORY_BANDWIDTH_KEY, PerformanceTracker.getInstance().getCurrentBandwidth());
        }
        return properties;
    }

    @Override
    public TADManager getTADManager() {
        return tadManager;
    }

    @Override
    @SuppressWarnings("unchecked")
    public void printEnvironmentInformation() {
        super.printEnvironmentInformation();
    }

    @Override
    public void commit() {
        val ctx = AtomicAllocator.getInstance().getDeviceContext();
        ctx.syncOldStream();
        ctx.syncSpecialStream();
    }

    @Override
    public synchronized Map<String, CustomOpDescriptor> getCustomOperations() {
        if(customOps == null) {
            String list = nativeOps.getAllCustomOps();

            if (list == null || list.isEmpty()) {
                log.warn("No customs ops available!");
                customOps = Collections.emptyMap();
                return customOps;
            }

            val map = new HashMap<String, CustomOpDescriptor>();

            String[] split = list.split(";");
            for (String op : split) {
                if (op == null || op.isEmpty())
                    continue;

                String[] another = op.split(":");

                CustomOpDescriptor descriptor = CustomOpDescriptor.builder()
                        .hash(Long.valueOf(another[1]))
                        .numInputs(Integer.valueOf(another[2]))
                        .numOutputs(Integer.valueOf(another[3]))
                        .allowsInplace(Integer.valueOf(another[4]) == 1)
                        .numTArgs(Integer.valueOf(another[5]))
                        .numIArgs(Integer.valueOf(another[6]))
                        .build();

                map.put(another[0], descriptor);
            }

            customOps = Collections.unmodifiableMap(map);
        }

        return customOps;
    }



    protected LongShapeDescriptor getShapeFromPointer(LongPointer ptr) {
        val rank = (int) ptr.get(0);

        val shape = new long[rank * 2 + 4];
        for (int i = 0; i < shape.length; i++) {
            shape[i] = ptr.get(i);
        }

        //val extras = ptr.get(Shape.shapeInfoLength(rank) - 3);
        val t = ArrayOptionsHelper.arrayType(shape);
        return LongShapeDescriptor.fromShape(Shape.shape(shape), Shape.stride(shape), Shape.elementWiseStride(shape), Shape.order(shape), ArrayOptionsHelper.dataType(shape), t == ArrayType.EMPTY);
    }

    @Override
    public List<LongShapeDescriptor> calculateOutputShape(@NonNull CustomOp op) {
        return calculateOutputShape(op, null);
    }

    @Override
    public List<LongShapeDescriptor> calculateOutputShape(@NonNull CustomOp op, OpContext opContext) {

        Nd4j.getExecutioner().commit();

        val lc = op.opName().toLowerCase();
        val hash = op.opHash();

        val result = new ArrayList<LongShapeDescriptor>();
        int nIn = opContext != null ? opContext.numInputArguments() : op.numInputArguments();
        if(nIn == 0 && op.getDescriptor().getNumInputs() >= 1) {
            if(log.isTraceEnabled()){
                log.trace("Could not calculate output shape for op {}: number of input args was 0",
                        op.getClass().getName());
            }
            return Collections.emptyList();
        }

        val inputBuffers = new PointerPointer<>(nIn * 2);
        val inputShapes = new PointerPointer<>(nIn);

        val inputArgs = opContext != null ? opContext.getInputArrays() : op.inputArguments();
        int cnt = 0;
        for (val in: inputArgs) {
            // TODO: once we implement Context-based shape function call this method should be removed
            val loc = Nd4j.getAffinityManager().getActiveLocation(in);
            if (loc != AffinityManager.Location.DEVICE && loc != AffinityManager.Location.EVERYWHERE) {
                Nd4j.getAffinityManager().ensureLocation(in, AffinityManager.Location.DEVICE);
                AtomicAllocator.getInstance().tickDeviceWrite(in);
            }

            // NOT A TYPO: shape functions work on host side only
            if (!in.isEmpty()) {
                inputBuffers.put(cnt, in.data().addressPointer());
                inputBuffers.put(cnt + nIn, AtomicAllocator.getInstance().getPointer(in.data()));
            }

            inputShapes.put(cnt++, in.shapeInfoDataBuffer().addressPointer());
        }


        int nIArgs = opContext != null ? opContext.numIArguments() : op.numIArguments();
        val iArgs = nIArgs > 0 ? new LongPointer(nIArgs) : null;
        cnt = 0;
        if(opContext != null) {
            for (val i: opContext.getIArguments())
                iArgs.put(cnt++, i);
        } else {
            for (val i: op.iArgs())
                iArgs.put(cnt++, i);
        }


        int nTArgs = opContext != null ? opContext.numTArguments() : op.numTArguments();
        val tArgs = nTArgs > 0 ? new DoublePointer(nTArgs) : null;

        int nBArgs = opContext != null ? opContext.numBArguments() : op.numBArguments();
        val bArgs = nBArgs > 0 ? new BooleanPointer(nBArgs) : null;

        int nDArgs = opContext != null ? opContext.numDArguments() : op.numDArguments();
        val dArgs = nDArgs > 0 ? new IntPointer(nDArgs) : null;

        cnt = 0;
        if(opContext != null){
            for (val b: opContext.getBArguments())
                bArgs.put(cnt++, b);
        } else {
            for (val b: op.bArgs())
                bArgs.put(cnt++, b);
        }


        cnt = 0;
        if(opContext != null){
            for (val b: opContext.getTArguments())
                tArgs.put(cnt++, b);
        } else {
            for (val b: op.tArgs())
                tArgs.put(cnt++, b);
        }

        cnt = 0;
        if(opContext != null){
            for (val b: opContext.getDArguments())
                dArgs.put(cnt++, b.toInt());
        } else {
            for (val b: op.dArgs())
                dArgs.put(cnt++, b.toInt());
        }

        OpaqueShapeList ptrptr = nativeOps.calculateOutputShapes2(null,
                hash, inputBuffers, inputShapes, nIn, tArgs, nTArgs,
                iArgs, nIArgs, bArgs, nBArgs, dArgs, nDArgs);
//        OpaqueShapeList ptrptr = nativeOps.calculateOutputShapes2(null, hash, inputBuffers, inputShapes, op.inputArguments().size(), tArgs, op.tArgs().length, iArgs, op.iArgs().length, bArgs, op.numBArguments(), dArgs, op.numDArguments());

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        if (ptrptr == null)
            throw new RuntimeException();

        for (int e = 0; e < nativeOps.getShapeListSize(ptrptr); e++ )
            result.add(getShapeFromPointer(new PagedPointer(nativeOps.getShape(ptrptr, e)).asLongPointer()));

        nativeOps.deleteShapeList(ptrptr);


        return result;
    }

    /**
     * This method executes given CustomOp
     *
     * PLEASE NOTE: You're responsible for input/output validation
     * PLEASE NOTE: right now this operations are executing on CPU
     * @param op
     */
    @Override
    public INDArray[] exec(CustomOp op) {

        Nd4j.getExecutioner().commit();

        boolean shapeOverride = false;
        if (op.numOutputArguments() == 0 && !op.isInplaceCall()) {
            try {
                val list = this.calculateOutputShape(op);
                if (list.isEmpty())
                    throw new ND4JIllegalStateException("Op name " + op.opName() + " failed to execute. You can't execute non-inplace CustomOp without outputs being specified");

                for (val shape: list)
                    op.addOutputArgument(Nd4j.create(shape, false));

                shapeOverride = true;
            } catch (Exception e) {
                throw new ND4JIllegalStateException("Op name " + op.opName() + " - no output arrays were provided and calculateOutputShape failed to execute", e);
            }
        }



        val name = op.opName();
        try (val context = (CudaOpContext) buildContext()) {
            // optionally skip shape validation on op execution
            if (shapeOverride)
                context.shapeFunctionOverride(true);

            context.markInplace(op.isInplaceCall());

            // transferring rng state
            context.setRngStates(Nd4j.getRandom().rootState(), Nd4j.getRandom().nodeState());

            //transferring input/output arrays
            context.setInputArrays(op.inputArguments());
            context.setOutputArrays(op.outputArguments());

            // transferring static args
            context.setBArguments(op.bArgs());
            context.setIArguments(op.iArgs());
            context.setTArguments(op.tArgs());
            context.setDArguments(op.dArgs());

            val result = exec(op, context);
            val states = context.getRngStates();


            // pulling states back
            Nd4j.getRandom().setStates(states.getFirst(), states.getSecond());

            return result;
        } catch (ND4JOpProfilerException e) {
            throw e;
        } catch (Exception e) {
            throw new RuntimeException("Op [" + name + "] execution failed", e);
        }
    }

    @Override
    public void enableDebugMode(boolean reallyEnable) {
        debug.set(reallyEnable);
        nativeOps.enableDebugMode(reallyEnable);
    }

    @Override
    public void enableVerboseMode(boolean reallyEnable) {
        verbose.set(reallyEnable);
        nativeOps.enableVerboseMode(reallyEnable);
    }

    @Override
    public void registerGraph(long id, Pointer graph) {
        nativeOps.registerGraph(null, id, graph);

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());
    }

    @Override
    public Map<String, INDArray> executeGraph(long id, @NonNull Map<String, INDArray> map, @NonNull Map<String, Integer> reverseMap) {

        Nd4j.getExecutioner().commit();

        val ptrBuffers = new PointerPointer(map.size() * 2);
        val ptrShapes = new PointerPointer(map.size() * 2);
        val ptrIndices = new IntPointer(map.size());

        int cnt = 0;
        val keySet = new ArrayList<>(map.keySet());
        for (val key: keySet) {
            val array = map.get(key);

            ptrBuffers.put(cnt, AtomicAllocator.getInstance().getHostPointer(array));
            ptrShapes.put(cnt, AtomicAllocator.getInstance().getHostPointer(array.shapeInfoDataBuffer()));
            ptrIndices.put(cnt, reverseMap.get(key));

            cnt++;
        }

        val newMap = new LinkedHashMap<String, INDArray>();

        OpaqueVariablesSet result = nativeOps.executeStoredGraph(null, id, ptrBuffers, ptrShapes, ptrIndices, map.size());

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        OpStatus status = OpStatus.byNumber(nativeOps.getVariablesSetStatus(result));

        if (status != OpStatus.ND4J_STATUS_OK)
            throw new ND4JIllegalStateException("Op execution failed: " + status);

        for (int e = 0; e < nativeOps.getVariablesSetSize(result); e++) {
            OpaqueVariable var = nativeOps.getVariable(result, e);
            int nodeId = nativeOps.getVariableId(var);
            int index = nativeOps.getVariableIndex(var);
            LongPointer shapeInfo = nativeOps.getVariableShape(var);
            Pointer buffer = nativeOps.getVariableBuffer(var);

            val rank = (int) shapeInfo.get(0);
            val jshape = new long[rank * 2 + 4];
            for (int i = 0; i < jshape.length; i++) {
                jshape[i] = shapeInfo.get(i);
            }

            val shapeOf = Shape.shapeOf(jshape);
            val stridesOf = Shape.stridesOf(jshape);
            val order = Shape.order(jshape);
            val array = Nd4j.create(shapeOf, stridesOf, 0, order);

            Pointer.memcpy(AtomicAllocator.getInstance().getHostPointer(array), buffer, ArrayUtil.prod(shapeOf) * array.dataType().width());
            //AtomicAllocator.getInstance().getAllocationPoint(array).tickHostWrite();
            if (1 > 0)
                throw new UnsupportedOperationException("Pew-pew");

            String nodeName = nativeOps.getVariableName(var);
            newMap.put(nodeName, array);
        }

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        nativeOps.deleteVariablesSet(result);

        return newMap;
    }

    @Override
    public void forgetGraph(long id) {
        nativeOps.unregisterGraph(null, id);

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());
    }

    /**
     * This method allows to set desired number of elements per thread, for performance optimization purposes.
     * I.e. if array contains 2048 elements, and threshold is set to 1024, 2 threads will be used for given op execution.
     * <p>
     * Default value: 1024
     *
     * @param threshold
     */
    @Override
    public void setElementsThreshold(int threshold) {
        nativeOps.setElementThreshold(threshold);
    }

    /**
     * This method allows to set desired number of sub-arrays per thread, for performance optimization purposes.
     * I.e. if matrix has shape of 64 x 128, and threshold is set to 8, each thread will be processing 8 sub-arrays (sure, if you have 8 core cpu).
     * If your cpu has, say, 4, cores, only 4 threads will be spawned, and each will process 16 sub-arrays
     * <p>
     * Default value: 8
     *
     * @param threshold
     */
    @Override
    public void setTadThreshold(int threshold) {
        nativeOps.setTADThreshold(threshold);
    }


    @Override
    public ExecutionerType type() {
        return ExecutionerType.CUDA;
    }

    @Override
    public String getString(DataBuffer buffer, long index) {
        Preconditions.checkArgument(buffer instanceof CudaUtf8Buffer, "Expected Utf8Buffer");

        val addr = ((LongIndexer) buffer.indexer()).get(index);
        val ptr = new PagedPointer(addr);
        val str = new Nd4jCuda.utf8string(ptr);
        return str._buffer().capacity(str._length()).getString();
    }

    @Override
    public boolean isExperimentalMode() {
        return experimentalMode.get();
    }

    @Override
    public void scatterUpdate(ScatterUpdate.UpdateOp op, @NonNull INDArray array, @NonNull INDArray indices, @NonNull INDArray updates, @NonNull int[] axis) {
        val context = AtomicAllocator.getInstance().getDeviceContext();

        val tadX = tadManager.getTADOnlyShapeInfo(array, axis);
        val tadY = tadManager.getTADOnlyShapeInfo(updates, axis);

        if (tadY.getSecond().length() != indices.length())
            throw new IllegalStateException("Number of updates doesn't match number of indices. Bad dimensions used?");

        if (extraz.get() == null)
            extraz.set(new PointerPointer(32));

        val stuff = extraz.get().put(null, context.getOldStream());

        nativeOps.scatterUpdate(stuff, op.ordinal(), (int) indices.length(),
                null, (LongPointer) AtomicAllocator.getInstance().getHostPointer(tadX.getFirst()), null, AtomicAllocator.getInstance().getPointer(array, context), (LongPointer) AtomicAllocator.getInstance().getPointer(tadX.getFirst()), (LongPointer) AtomicAllocator.getInstance().getPointer(tadX.getSecond()),
                null, (LongPointer) AtomicAllocator.getInstance().getHostPointer(tadY.getFirst()), null, AtomicAllocator.getInstance().getPointer(updates, context), (LongPointer) AtomicAllocator.getInstance().getPointer(tadY.getFirst()), (LongPointer) AtomicAllocator.getInstance().getPointer(tadY.getSecond()),
                AtomicAllocator.getInstance().getHostPointer(indices), (LongPointer) AtomicAllocator.getInstance().getHostPointer(indices.shapeInfoDataBuffer()), AtomicAllocator.getInstance().getPointer(indices, context), (LongPointer) AtomicAllocator.getInstance().getPointer(indices.shapeInfoDataBuffer(), context));

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());
    }

    @Override
    public OpContext buildContext() {
        return new CudaOpContext();
    }

    @Override
    public INDArray[] exec(CustomOp op, OpContext context) {
        Nd4j.getExecutioner().commit();
        long st = profilingConfigurableHookIn(op, context);
        val ctx = AtomicAllocator.getInstance().getDeviceContext();


        val status = nativeOps.execCustomOp2(null, op.opHash(), context.contextPointer());
        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        if (status != 0)
            throw new RuntimeException("Op [" + op.opName() + "] execution failed");

        // check if input && output needs update
        for (val in:op.inputArguments()) {
            if (!in.isEmpty())
                ((BaseCudaDataBuffer) in.data()).actualizePointerAndIndexer();
        }

        for (val out:op.outputArguments()) {
            if (!out.isEmpty()) {
                ((BaseCudaDataBuffer) out.data()).actualizePointerAndIndexer();
            }

            AtomicAllocator.getInstance().tickDeviceWrite(out);
        }


        profilingConfigurableHookOut(op, context, st);

        if (context.getOutputArrays().isEmpty())
            return new INDArray[0];
        else
            return context.getOutputArrays().toArray(new INDArray[context.getOutputArrays().size()]);
    }

    @Override
    public INDArrayStatistics inspectArray(@NonNull INDArray array) {
        val debugInfo = new Nd4jCuda.DebugInfo();
        val ctx = AtomicAllocator.getInstance().getDeviceContext();
        AtomicAllocator.getInstance().synchronizeHostData(array);

        if (extraz.get() == null)
            extraz.set(new PointerPointer(32));

        val extras = extraz.get().put(
                null,
                ctx.getOldStream(),
                AtomicAllocator.getInstance().getDeviceIdPointer(),
                ctx.getBufferAllocation(),
                ctx.getBufferReduction(),
                ctx.getBufferScalar(),
                ctx.getBufferSpecial());


        nativeOps.inspectArray(extras, AtomicAllocator.getInstance().getHostPointer(array), (LongPointer) AtomicAllocator.getInstance().getHostPointer(array.shapeInfoDataBuffer()), AtomicAllocator.getInstance().getPointer(array, ctx), (LongPointer) AtomicAllocator.getInstance().getPointer(array.shapeInfoDataBuffer()), debugInfo);

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        return INDArrayStatistics.builder()
                .minValue(debugInfo._minValue())
                .maxValue(debugInfo._maxValue())
                .meanValue(debugInfo._meanValue())
                .stdDevValue(debugInfo._stdDevValue())
                .countInf(debugInfo._infCount())
                .countNaN(debugInfo._nanCount())
                .countNegative(debugInfo._negativeCount())
                .countPositive(debugInfo._positiveCount())
                .countZero(debugInfo._zeroCount())
                .build();
    }


    @Override
    public DataBuffer createShapeInfo(long[] shape, long[] stride, long elementWiseStride, char order, DataType dtype, boolean empty) {
        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        val dbf = nativeOps.shapeBuffer(shape.length, new LongPointer(shape), new LongPointer(stride), dtype.toInt(), order, elementWiseStride, empty);

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        val result = new CudaLongDataBuffer(nativeOps.getConstantShapeBufferPrimary(dbf), nativeOps.getConstantShapeBufferSpecial(dbf), Shape.shapeInfoLength(shape.length));

        nativeOps.deleteConstantShapeBuffer(dbf);

        return result;
    }

    @Override
    public DataBuffer createShapeInfo(long[] shape, long[] stride, long elementWiseStride, char order, DataType dtype, long extras) {
        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        val dbf = nativeOps.shapeBufferEx(shape.length, new LongPointer(shape), new LongPointer(stride), dtype.toInt(), order, elementWiseStride, extras);

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        val result = new CudaLongDataBuffer(nativeOps.getConstantShapeBufferPrimary(dbf), nativeOps.getConstantShapeBufferSpecial(dbf), Shape.shapeInfoLength(shape.length));

        nativeOps.deleteConstantShapeBuffer(dbf);

        return result;
    }

    @Override
    public TadPack tadShapeInfoAndOffsets(INDArray array, int[] dimension) {
        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        OpaqueTadPack pack = nativeOps.tadOnlyShapeInfo((LongPointer) array.shapeInfoDataBuffer().addressPointer(), new IntPointer(dimension), dimension.length);

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        val tadShape = new CudaLongDataBuffer(nativeOps.getPrimaryShapeInfo(pack), nativeOps.getSpecialShapeInfo(pack), nativeOps.getShapeInfoLength(pack));
        val tadOffsets = new CudaLongDataBuffer(nativeOps.getPrimaryOffsets(pack), nativeOps.getSpecialOffsets(pack), nativeOps.getNumberOfTads(pack));

        nativeOps.deleteTadPack(pack);

        return new TadPack(tadShape, tadOffsets);
    }

    @Override
    public DataBuffer createConstantBuffer(long[] values, DataType desiredType) {
        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        val dbf = nativeOps.constantBufferLong(desiredType.toInt(), new LongPointer(values), values.length);

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        val buffer = Nd4j.createBuffer(nativeOps.getConstantDataBufferPrimary(dbf), nativeOps.getConstantDataBufferSpecial(dbf), values.length, desiredType);
        buffer.setConstant(true);

        return buffer;
    }

    @Override
    public DataBuffer createConstantBuffer(double[] values, DataType desiredType)  {
        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        val dbf = nativeOps.constantBufferDouble(desiredType.toInt(), new DoublePointer(values), values.length);

        if (nativeOps.lastErrorCode() != 0)
            throw new RuntimeException(nativeOps.lastErrorMessage());

        val buffer = Nd4j.createBuffer(nativeOps.getConstantDataBufferPrimary(dbf), nativeOps.getConstantDataBufferSpecial(dbf), values.length, desiredType);
        buffer.setConstant(true);

        return buffer;
    }

    @Override
    public int useCount(DataBuffer buffer){
        return nativeOps.dbUseCount(((BaseCudaDataBuffer) buffer).getOpaqueDataBuffer());
    }


}


