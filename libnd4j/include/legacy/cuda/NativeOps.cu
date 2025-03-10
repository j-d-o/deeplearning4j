/* ******************************************************************************
 *
 *
 * This program and the accompanying materials are made available under the
 * terms of the Apache License, Version 2.0 which is available at
 * https://www.apache.org/licenses/LICENSE-2.0.
 *
 *  See the NOTICE file distributed with this work for additional
 *  information regarding copyright ownership.
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 ******************************************************************************/

#include <cuda.h>
#include <exceptions/cuda_exception.h>
#include <exceptions/datatype_exception.h>
#include <execution/AffinityManager.h>
#include <graph/GraphExecutioner.h>
#include <graph/GraphHolder.h>
#include <helpers/BlasHelper.h>
#include <helpers/CudaLaunchHelper.h>
#include <helpers/DebugHelper.h>
#include <helpers/PointersManager.h>
#include <helpers/threshold.h>
#include <legacy/NativeOpExecutioner.h>
#include <legacy/NativeOps.h>
#include <loops/reduce_bool.h>
#include <loops/reduce_long.h>
#include <loops/scalar.h>
#include <loops/transform_any.h>
#include <ops/declarable/CustomOperations.h>
#include <ops/specials_cuda.h>
#include <system/buffer.h>

//#include <sys/time.h>
#include <curand.h>
#include <helpers/DebugHelper.h>

using namespace sd;
#include <loops/special_kernels.h>

cudaDeviceProp *deviceProperties;
cudaFuncAttributes *funcAttributes = new cudaFuncAttributes[64];
int blockLimit = 128;
int maxThreads = 512;
bool allowedP2P = false;
bool supportedP2P = false;
#ifdef SD_EXPERIMENTAL_ENABLED
bool experimentalSupport = true;
#else
bool experimentalSupport = false;
#endif

int minThreads = 32;

__constant__ char deviceConstantMemory[49152];

// this method just does type conversion in fancy way
int getDeviceId(sd::Pointer ptrToDeviceId) { return (int)(sd::LongType)ptrToDeviceId; }

/*
 * Basic CUDA constants here: number of blocks per MP
 */
int getDeviceBlockThreshold(int deviceId) {
  int ccMinor = deviceProperties[deviceId].minor;
  int ccMajor = deviceProperties[deviceId].major;

  int blockThreshold = 8;

  if (ccMajor >= 5)
    blockThreshold = 32;
  else if (ccMajor == 3)
    blockThreshold = 16;
  else if (ccMajor < 3)
    blockThreshold = 8;

  return blockThreshold;
}

/*
 * This message returns shared memory threshold value. default overflow ratio is 0.3
 */
int getDeviceSharedThreshold(int deviceId) {
  int ccMinor = deviceProperties[deviceId].minor;
  int ccMajor = deviceProperties[deviceId].major;

  // please note threshold isn't multiple of 32, and that's NOT a mistake

  int shmemThreshold;
  if (ccMajor == 6 && ccMinor == 0)
    shmemThreshold = 65536;
  else if (ccMajor == 6 && ccMinor == 1)
    shmemThreshold = 49152;
  else if (ccMajor == 5 && ccMinor == 2)
    shmemThreshold = 98304;
  else if (ccMajor == 5)
    shmemThreshold = 65536;
  else if (ccMajor == 3 && ccMinor == 7)
    shmemThreshold = 114688;
  else
    shmemThreshold = 49152;

  return shmemThreshold / 0.3;
}

sd::buffer::Buffer<sd::LongType> *createScalarBuffer(cudaStream_t stream) {
  auto scalarShapeInfo = shape::createScalarShapeInfo();
  auto buff = sd::buffer::createBuffer(scalarShapeInfo, shape::shapeInfoLength(2), stream);
  sd::buffer::copyDataToGpu(&buff, stream);
  return buff;
}

class ScalarShapeInformation {
 private:
  sd::buffer::Buffer<sd::LongType> *scalarDimension;
  sd::buffer::Buffer<sd::LongType> *scalarShapeInfo;
  //    std::thread::id threadId;

 public:
  ScalarShapeInformation(cudaStream_t stream) {
    auto scalarDimensionBuff = reinterpret_cast<sd::LongType *>(malloc(sizeof(sd::LongType)));

    CHECK_ALLOC(scalarDimensionBuff, "Failed to allocate ShapeInfoBuffer", sizeof(sd::LongType));

    scalarDimensionBuff[0] = SD_MAX_DIMENSION;
    scalarDimension = sd::buffer::createBuffer(scalarDimensionBuff, 1, stream);
    scalarShapeInfo = createScalarBuffer(stream);
    //        threadId = std::this_thread::get_id();
  }
  ~ScalarShapeInformation() {
    sd::buffer::freeBuffer(&scalarShapeInfo);
    sd::buffer::freeBuffer(&scalarDimension);
  }

  sd::LongType *getShapeInfoHostPointer() { return scalarShapeInfo->data; }

  sd::LongType *getShapeInfoGpuPointer() { return scalarShapeInfo->gData; }

  sd::LongType *getDimensionHostPointer() { return scalarDimension->data; }

  sd::LongType *getDimensionGpuPointer() { return scalarDimension->gData; }
};

template <typename T>
class ScalarInfo {
  sd::buffer::Buffer<T> *scalarData;
  ScalarShapeInformation *shapeInfo;
  T finalResult;
  cudaStream_t streamRef;

 public:
  ScalarInfo(cudaStream_t stream) {
    T *scalarResult = reinterpret_cast<T *>(malloc(sizeof(T)));

    CHECK_ALLOC(scalarResult, "Failed to allocate new scalar buffer", sizeof(T));

    shapeInfo = new ScalarShapeInformation(stream);
    scalarData = sd::buffer::createBuffer(scalarResult, 1, stream);
    streamRef = stream;
    sd::buffer::copyDataToGpu(&scalarData, stream);
  }

  T getFinalResultFromDevice() {
    sd::buffer::copyDataFromGpu(&scalarData, streamRef);
    return scalarData->data[0];
  }

  /**
   * Get the device shape information
   * representing a scalar
   */
  sd::LongType *getDeviceShapeInfo() { return shapeInfo->getShapeInfoGpuPointer(); }

  /**
   * Get the dZ pointers
   */
  T *getDevicePointer() { return scalarData->gData; }

  /**
   * Get the infinite dimension device pointer
   */
  sd::LongType *getDimensionDevicePointer() { return shapeInfo->getDimensionGpuPointer(); }

  ~ScalarInfo() {
    sd::buffer::freeBuffer(&scalarData);
    delete shapeInfo;
  }
};

void execPairwiseTransform(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX,
                           sd::LongType const *hXShapeInfo, sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbY,
                           sd::LongType const *hYShapeInfo, sd::LongType const *dYShapeInfo, OpaqueDataBuffer *dbZ,
                           sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo, void *extraParams) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX, dbY});

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execPairwiseTransform(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), dbY->primary(), hYShapeInfo,
        dbY->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hYShapeInfo).special(), dbZ->primary(),
        hZShapeInfo, dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
        extraParams);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX, dbY});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execPairwiseTransformBool(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX,
                               sd::LongType const *hXShapeInfo, sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbY,
                               sd::LongType const *hYShapeInfo, sd::LongType const *dYShapeInfo, OpaqueDataBuffer *dbZ,
                               sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo, void *extraParams) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX, dbY});

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execPairwiseBoolTransform(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), dbY->primary(), hYShapeInfo,
        dbY->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hYShapeInfo).special(), dbZ->primary(),
        hZShapeInfo, dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
        extraParams);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX, dbY});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execSummaryStatsScalar(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX,
                            sd::LongType const *hXShapeInfo, sd::LongType const *dXShapeInfo, void *extraParams,
                            OpaqueDataBuffer *dbZ, sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo,
                            bool biasCorrected) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execSummaryStatsScalar(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), extraParams, dbZ->primary(),
        hZShapeInfo, dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
        biasCorrected);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execBroadcastBool(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                       sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbY, sd::LongType const *hYShapeInfo,
                       sd::LongType const *dYShapeInfo, OpaqueDataBuffer *dbZ, sd::LongType const *hZShapeInfo,
                       sd::LongType const *dZShapeInfo, void *extraParams, OpaqueDataBuffer *dbDimension,
                       sd::LongType const *hDimensionShape, sd::LongType const *dDimensionShape) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX, dbY});
    InteropDataBuffer::preparePrimaryUse({}, {dbDimension});

    auto dimension = reinterpret_cast<int *>(dbDimension->primary());
    int dimensionLength = static_cast<int>(shape::length(hDimensionShape));

    auto hTADShapeInfo = reinterpret_cast<sd::LongType *>(extraPointers[9]);
    auto tadOnlyShapeInfo = reinterpret_cast<sd::LongType *>(extraPointers[10]);
    auto tadOffsets = reinterpret_cast<sd::LongType *>(extraPointers[11]);
    auto tadOnlyShapeInfoZ = reinterpret_cast<sd::LongType *>(extraPointers[12]);
    auto tadOffsetsZ = reinterpret_cast<sd::LongType *>(extraPointers[13]);

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execBroadcastBool(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), dbY->primary(), hYShapeInfo,
        dbY->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hYShapeInfo).special(), dbZ->primary(),
        hZShapeInfo, dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
        extraParams, dimension, dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX, dbY});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

/**
 *
 * @param opNum
 * @param dX
 * @param dXShapeInfo
 * @param dY
 * @param dYShapeInfo
 * @param dZ
 * @param dZShapeInfo
 * @param dimension
 * @param dimensionLength
 */
void execBroadcast(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                   sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbY, sd::LongType const *hYShapeInfo,
                   sd::LongType const *dYShapeInfo, OpaqueDataBuffer *dbZ, sd::LongType const *hZShapeInfo,
                   sd::LongType const *dZShapeInfo, OpaqueDataBuffer *dbDimension, sd::LongType const *hDimensionShape,
                   sd::LongType const *dDimensionShape) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX, dbY});
    InteropDataBuffer::preparePrimaryUse({}, {dbDimension});

    auto dimension = reinterpret_cast<int *>(dbDimension->primary());
    int dimensionLength = static_cast<int>(shape::length(hDimensionShape));

    cudaStream_t *stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);

    auto hTADShapeInfo = reinterpret_cast<sd::LongType *>(extraPointers[9]);
    auto tadOnlyShapeInfo = reinterpret_cast<sd::LongType *>(extraPointers[10]);
    auto tadOffsets = reinterpret_cast<sd::LongType *>(extraPointers[11]);
    auto tadOnlyShapeInfoZ = reinterpret_cast<sd::LongType *>(extraPointers[12]);
    auto tadOffsetsZ = reinterpret_cast<sd::LongType *>(extraPointers[13]);

    auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
    auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
    auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execBroadcast(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), dbY->primary(), hYShapeInfo,
        dbY->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hYShapeInfo).special(), dbZ->primary(),
        hZShapeInfo, dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
        dimension, dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX, dbY});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

/**
 *
 * @param opNum
 * @param dX
 * @param dXShapeInfo
 * @param extraParams
 * @param dZ
 * @param dZShapeInfo
 */
////////////////////////////////////////////////////////////////////////
void execReduceFloat(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                     sd::LongType const *dXShapeInfo, void *extraParams, OpaqueDataBuffer *dbZ,
                     sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execReduceFloatScalar(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), extraParams, dbZ->primary(),
        hZShapeInfo, dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special());

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execReduceSame(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                    sd::LongType const *dXShapeInfo, void *extraParams, OpaqueDataBuffer *dbZ,
                    sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execReduceSameScalar(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), extraParams, dbZ->primary(),
        hZShapeInfo, dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special());

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execReduceSame2(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                     sd::LongType const *dXShapeInfo, void *extraParams, OpaqueDataBuffer *dbZ,
                     sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo, OpaqueDataBuffer *dbDimension,
                     sd::LongType const *hDimensionShape, sd::LongType const *dDimensionShape) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});
    InteropDataBuffer::preparePrimaryUse({}, {dbDimension});

    auto dimension = reinterpret_cast<int *>(dbDimension->primary());
    int dimensionLength = static_cast<int>(shape::length(hDimensionShape));

    const auto zLen = shape::length(hZShapeInfo);

    std::vector<int> dimensions(dimension, dimension + dimensionLength);

    const sd::LongType *zShapeInfoH = hZShapeInfo;

    if (shape::rank(hXShapeInfo) - dimensionLength != shape::rank(hZShapeInfo) && zLen != 1) {
      auto zPack = ConstantShapeHelper::getInstance().createShapeInfoWithNoUnitiesForReduce(hZShapeInfo, dimensions);
      zShapeInfoH = reinterpret_cast<sd::LongType const *>(zPack.primary());
    }

    std::vector<int> dims =
        (zLen != 1) ? ShapeUtils::evalDimsForReduceOp(shape::rank(hXShapeInfo), dimensions) : std::vector<int>();
    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execReduceSame(&lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
                                        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(),
                                        extraParams, dbZ->primary(), zShapeInfoH, dbZ->special(),
                                        ConstantShapeHelper::getInstance().bufferForShapeInfo(zShapeInfoH).special(),
                                        dims.data(), dims.size());

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execReduceLong2(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                     sd::LongType const *dXShapeInfo, void *extraParams, OpaqueDataBuffer *dbZ,
                     sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo, OpaqueDataBuffer *dbDimension,
                     sd::LongType const *hDimensionShape, sd::LongType const *dDimensionShape) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});
    InteropDataBuffer::preparePrimaryUse({}, {dbDimension});

    auto dimension = reinterpret_cast<int *>(dbDimension->primary());
    int dimensionLength = static_cast<int>(shape::length(hDimensionShape));

    const auto zLen = shape::length(hZShapeInfo);

    std::vector<int> dimensions(dimension, dimension + dimensionLength);

    const sd::LongType *zShapeInfoH = hZShapeInfo;

    if (shape::rank(hXShapeInfo) - dimensionLength != shape::rank(hZShapeInfo) && zLen != 1) {
      auto zPack = ConstantShapeHelper::getInstance().createShapeInfoWithNoUnitiesForReduce(hZShapeInfo, dimensions);
      zShapeInfoH = reinterpret_cast<sd::LongType const *>(zPack.primary());
    }

    std::vector<int> dims =
        (zLen != 1) ? ShapeUtils::evalDimsForReduceOp(shape::rank(hXShapeInfo), dimensions) : std::vector<int>();

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execReduceLong(&lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
                                        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(),
                                        extraParams, dbZ->primary(), zShapeInfoH, dbZ->special(),
                                        ConstantShapeHelper::getInstance().bufferForShapeInfo(zShapeInfoH).special(),
                                        dims.data(), dims.size());

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execReduceLong(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                    sd::LongType const *dXShapeInfo, void *extraParams, OpaqueDataBuffer *dbZ,
                    sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});

    auto stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);
    auto hTADShapeInfo = reinterpret_cast<sd::LongType *>(extraPointers[9]);
    auto dTADShapeInfo = reinterpret_cast<sd::LongType *>(extraPointers[10]);

    auto reductionPointer = reinterpret_cast<void *>(extraPointers[4]);

    auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
    auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

    if (zType != sd::DataType::INT64)
      throw datatype_exception::build("execReduceLong wrong Z data type", sd::DataType::INT64, zType);

    auto xLength = shape::length(hXShapeInfo);
    auto blockWidth = 256;
    auto numBlocks = CudaLaunchHelper::getReductionBlocks(xLength, blockWidth);
    dim3 launchDims(numBlocks, blockWidth, 32768);

    BUILD_DOUBLE_SELECTOR(
        xType, zType, functions::reduce::ReduceLongFunction,
        ::execReduceScalar(launchDims, stream, opNum, dbX->special(),
                           ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), hXShapeInfo,
                           extraParams, dbZ->special(),
                           ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(), hXShapeInfo,
                           nullptr, 0, reductionPointer, dTADShapeInfo),
        SD_COMMON_TYPES, SD_LONG_TYPES);

    sd::DebugHelper::checkErrorCode(stream, "execReduceLong(...) failed");

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execReduceBool2(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                     sd::LongType const *dXShapeInfo, void *extraParams, OpaqueDataBuffer *dbZ,
                     sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo, OpaqueDataBuffer *dbDimension,
                     sd::LongType const *hDimensionShape, sd::LongType const *dDimensionShape) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});
    InteropDataBuffer::preparePrimaryUse({}, {dbDimension});

    auto dimension = reinterpret_cast<int *>(dbDimension->primary());
    int dimensionLength = static_cast<int>(shape::length(hDimensionShape));

    const auto zLen = shape::length(hZShapeInfo);

    std::vector<int> dimensions(dimension, dimension + dimensionLength);

    const sd::LongType *zShapeInfoH = hZShapeInfo;

    if (shape::rank(hXShapeInfo) - dimensionLength != shape::rank(hZShapeInfo) && zLen != 1) {
      auto zPack = ConstantShapeHelper::getInstance().createShapeInfoWithNoUnitiesForReduce(hZShapeInfo, dimensions);
      zShapeInfoH = reinterpret_cast<sd::LongType const *>(zPack.primary());
    }

    std::vector<int> dims =
        (zLen != 1) ? ShapeUtils::evalDimsForReduceOp(shape::rank(hXShapeInfo), dimensions) : std::vector<int>();

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execReduceBool(&lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
                                        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(),
                                        extraParams, dbZ->primary(), zShapeInfoH, dbZ->special(),
                                        ConstantShapeHelper::getInstance().bufferForShapeInfo(zShapeInfoH).special(),
                                        dims.data(), dims.size());

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execReduceBool(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                    sd::LongType const *dXShapeInfo, void *extraParams, OpaqueDataBuffer *dbZ,
                    sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});

    auto stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);
    auto hTADShapeInfo = reinterpret_cast<sd::LongType *>(extraPointers[9]);
    auto dTADShapeInfo = reinterpret_cast<sd::LongType *>(extraPointers[10]);

    auto reductionPointer = reinterpret_cast<void *>(extraPointers[4]);

    auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
    auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

    if (zType != sd::DataType::BOOL) throw std::runtime_error("execReduceBool requires Z operand to have BOOL type");

    auto xLength = shape::length(hXShapeInfo);
    auto blockWidth = 256;
    auto numBlocks = CudaLaunchHelper::getReductionBlocks(xLength, blockWidth);
    dim3 launchDims(numBlocks, blockWidth, 32768);

    BUILD_DOUBLE_SELECTOR(
        xType, zType, functions::reduce::ReduceBoolFunction,
        ::execReduceScalar(launchDims, stream, opNum, dbX->special(),
                           ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), hXShapeInfo,
                           extraParams, dbZ->special(),
                           ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(), hZShapeInfo,
                           nullptr, 0, reductionPointer, dTADShapeInfo),
        SD_COMMON_TYPES, SD_BOOL_TYPES);

    sd::DebugHelper::checkErrorCode(stream, "execReduceBool(...) failed");

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

/**
 *
 * @param opNum
 * @param dX
 * @param dXShapeInfo
 * @param extraParams
 * @param dZ
 * @param dZShapeInfo
 * @param dimension
 * @param dimensionLength
 */
////////////////////////////////////////////////////////////////////////
void execIndexReduce(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                     sd::LongType const *dXShapeInfo, void *extraParams, OpaqueDataBuffer *dbZ,
                     sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo, OpaqueDataBuffer *dbDimension,
                     sd::LongType const *hDimensionShape, sd::LongType const *dDimensionShape) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});
    InteropDataBuffer::preparePrimaryUse({}, {dbDimension});

    auto dimension = reinterpret_cast<int *>(dbDimension->primary());
    int dimensionLength = static_cast<int>(shape::length(hDimensionShape));

    auto tadPack =
        sd::ConstantTadHelper::getInstance().tadForDimensions(hXShapeInfo, dimension, shape::length(hDimensionShape));

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execIndexReduce(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), extraParams, dbZ->primary(),
        hZShapeInfo, dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
        (int *)dbDimension->special(), dimensionLength, tadPack.specialShapeInfo(), tadPack.specialOffsets());

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

/**
 *
 * @param opNum
 * @param dX
 * @param dXShapeInfo
 * @param extraParams
 * @param dZ
 * @param dZShapeInfo
 */
////////////////////////////////////////////////////////////////////////
void execReduceFloat2(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                      sd::LongType const *dXShapeInfo, void *extraParams, OpaqueDataBuffer *dbZ,
                      sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo, OpaqueDataBuffer *dbDimension,
                      sd::LongType const *hDimensionShape, sd::LongType const *dDimensionShape) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});
    InteropDataBuffer::preparePrimaryUse({}, {dbDimension});

    auto dimension = reinterpret_cast<int *>(dbDimension->primary());
    int dimensionLength = static_cast<int>(shape::length(hDimensionShape));

    const auto zLen = shape::length(hZShapeInfo);

    std::vector<int> dimensions(dimension, dimension + dimensionLength);

    const sd::LongType *zShapeInfoH = hZShapeInfo;

    if (shape::rank(hXShapeInfo) - dimensionLength != shape::rank(hZShapeInfo) && zLen != 1) {
      auto zPack = ConstantShapeHelper::getInstance().createShapeInfoWithNoUnitiesForReduce(hZShapeInfo, dimensions);
      zShapeInfoH = reinterpret_cast<sd::LongType const *>(zPack.primary());
    }

    std::vector<int> dims =
        (zLen != 1) ? ShapeUtils::evalDimsForReduceOp(shape::rank(hXShapeInfo), dimensions) : std::vector<int>();

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execReduceFloat(&lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
                                         ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(),
                                         extraParams, dbZ->primary(), zShapeInfoH, dbZ->special(),
                                         ConstantShapeHelper::getInstance().bufferForShapeInfo(zShapeInfoH).special(),
                                         dims.data(), dims.size());

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

/**
 *
 * @param opNum
 * @param dX
 * @param dXShapeInfo
 * @param extraParams
 */
////////////////////////////////////////////////////////////////////////
void execIndexReduceScalar(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX,
                           sd::LongType const *hXShapeInfo, sd::LongType const *dXShapeInfo, void *extraParams,
                           OpaqueDataBuffer *dbZ, sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execIndexReduceScalar(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), extraParams, dbZ->primary(),
        hZShapeInfo, dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special());

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execTransformSame(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                       sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbZ, sd::LongType const *hZShapeInfo,
                       sd::LongType const *dZShapeInfo, void *extraParams) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});

    auto tadShapeInfo = reinterpret_cast<sd::LongType *>(extraPointers != nullptr ? extraPointers[0] : nullptr);
    auto tadOffsets = reinterpret_cast<sd::LongType *>(extraPointers != nullptr ? extraPointers[1] : nullptr);

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execTransformSame(&lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
                                           ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(),
                                           dbZ->primary(), hZShapeInfo, dbZ->special(),
                                           ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
                                           extraParams, tadShapeInfo, tadOffsets);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execTransformBool(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                       sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbZ, sd::LongType const *hZShapeInfo,
                       sd::LongType const *dZShapeInfo, void *extraParams) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});

    auto tadShapeInfo = reinterpret_cast<sd::LongType *>(extraPointers != nullptr ? extraPointers[0] : nullptr);
    auto tadOffsets = reinterpret_cast<sd::LongType *>(extraPointers != nullptr ? extraPointers[1] : nullptr);

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execTransformBool(&lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
                                           ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(),
                                           dbZ->primary(), hZShapeInfo, dbZ->special(),
                                           ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
                                           extraParams, tadShapeInfo, tadOffsets);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execTransformAny(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                      sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbZ, sd::LongType const *hZShapeInfo,
                      sd::LongType const *dZShapeInfo, void *extraParams) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});

    auto stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);
    auto streamSpecial = reinterpret_cast<cudaStream_t &>(extraPointers[4]);
    LaunchContext lc(stream, streamSpecial, extraPointers[5], extraPointers[3],
                     reinterpret_cast<int *>(extraPointers[6]));

    NativeOpExecutioner::execTransformAny(&lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
                                          ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(),
                                          dbZ->primary(), hZShapeInfo, dbZ->special(),
                                          ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
                                          extraParams, nullptr, nullptr);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execTransformStrict(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                         sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbZ, sd::LongType const *hZShapeInfo,
                         sd::LongType const *dZShapeInfo, void *extraParams) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});

    auto tadShapeInfo = reinterpret_cast<sd::LongType *>(extraPointers != nullptr ? extraPointers[10] : nullptr);
    auto tadOffsets = reinterpret_cast<sd::LongType *>(extraPointers != nullptr ? extraPointers[11] : nullptr);

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execTransformStrict(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), dbZ->primary(), hZShapeInfo,
        dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(), extraParams,
        tadShapeInfo, tadOffsets);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execTransformFloat(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                        sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbZ, sd::LongType const *hZShapeInfo,
                        sd::LongType const *dZShapeInfo, void *extraParams) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});

    auto tadShapeInfo = reinterpret_cast<sd::LongType *>(extraPointers != nullptr ? extraPointers[10] : nullptr);
    auto tadOffsets = reinterpret_cast<sd::LongType *>(extraPointers != nullptr ? extraPointers[11] : nullptr);

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execTransformFloat(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), dbZ->primary(), hZShapeInfo,
        dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(), extraParams,
        tadShapeInfo, tadOffsets);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void checkP2P() {
  int curDevice = 0;

  cudaGetDevice(&curDevice);

  int devCnt = 0;
  cudaGetDeviceCount(&devCnt);

  if (curDevice < 0 && curDevice > devCnt) curDevice = 0;

  bool tempSupport = true;

  if (devCnt > 1) {
    for (int dX = 0; dX < devCnt; dX++) {
      for (int dY = 0; dY < devCnt; dY++) {
        if (dX == dY) continue;

        int canAccess = 0;
        cudaSetDevice(dX);

        cudaDeviceCanAccessPeer(&canAccess, dX, dY);

        if (!canAccess) {
          tempSupport = false;
          break;
        }
      }
    }

    supportedP2P = tempSupport;

    cudaSetDevice(curDevice);
  } else {
    // if we have only 1 device - we say that we support P2P, since all data will be on 1 device
    supportedP2P = true;
  }
}

void enableP2P(bool enable) {
  if (enable == allowedP2P) return;

  int curDevice = 0;

  cudaGetDevice(&curDevice);

  int devCnt = 0;
  cudaGetDeviceCount(&devCnt);

  if (curDevice < 0 && curDevice > devCnt) curDevice = 0;

  if (devCnt > 1) {
    for (int dX = 0; dX < devCnt; dX++) {
      for (int dY = 0; dY < devCnt; dY++) {
        if (dX == dY) continue;

        int canAccess = 0;
        cudaSetDevice(dX);

        cudaDeviceCanAccessPeer(&canAccess, dX, dY);

        if (canAccess) {
          if (enable) {
            cudaDeviceEnablePeerAccess(dY, 0);
          } else {
            cudaDeviceDisablePeerAccess(dY);
          }
        } else {
          if (sd::Environment::getInstance().isVerbose()) printf("Peer access [%i] -> [%i] isn't possible\n", dX, dY);
        }
      }
    }

    cudaSetDevice(curDevice);
  }

  allowedP2P = enable;

  cudaSetDevice(curDevice);
}

bool isP2PAvailable() { return supportedP2P; }

void initializeDevicesAndFunctions() {
  try {
    int devCnt = 0;
    cudaGetDeviceCount(&devCnt);
    deviceProperties = new cudaDeviceProp[devCnt];
    for (int i = 0; i < devCnt; i++) {
      cudaSetDevice(i);
      cudaGetDeviceProperties(&deviceProperties[i], i);

      cudaDeviceSetLimit(cudaLimitStackSize, 4096);
    }

    cudaSetDevice(0);

    checkP2P();

    // enabling p2p gpu access if it's supported
    if (supportedP2P && devCnt > 1) enableP2P(allowedP2P);
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void initializeFunctions(sd::Pointer *functions) {
  sd::BlasHelper::getInstance().initializeDeviceFunctions(functions);
  /*
  cublasSgemv = (CublasSgemv)functions[0];
  cublasDgemv = (CublasDgemv)functions[1];
  cublasHgemm = (CublasHgemm)functions[2];
  cublasSgemm = (CublasSgemm)functions[3];
  cublasDgemm = (CublasDgemm)functions[4];
  cublasSgemmEx = (CublasSgemmEx)functions[5];
  cublasHgemmBatched = (CublasHgemmBatched)functions[6];
  cublasSgemmBatched = (CublasSgemmBatched)functions[7];
  cublasDgemmBatched = (CublasDgemmBatched)functions[8];
  */
}

/**
 * This method acquires memory chunk of requested size on host side
 *
 * @param pointer pointer that'll be used for allocation
 * @param memorySize memory size, in bytes
 * @param flags optional parameter
 */
sd::Pointer mallocHost(sd::LongType memorySize, int flags) {
  sd::Pointer pointer;
  // cudaHostAllocMapped |cudaHostAllocPortable
  auto res = cudaHostAlloc(reinterpret_cast<void **>(&pointer), memorySize + 8, cudaHostAllocDefault);
  if (res != 0) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(res);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaHostAlloc failed");
  }

  return reinterpret_cast<int8_t *>(pointer);
}

/**
 * This method acquires memory chunk of requested size on specified device
 *
 * @param pointer pointer that'll be used for allocation
 * @param memorySize memory size, in bytes
 * @param ptrToDeviceId pointer to deviceId. For cuda that's just and int, for OpenCL that's pointer to device_id, etc
 * @param flags optional parameter
 */
sd::Pointer mallocDevice(sd::LongType memorySize, int deviceId, int flags) {
  sd::Pointer pointer;
  auto res = cudaMalloc(reinterpret_cast<void **>(&pointer), memorySize + 8);
  if (res != 0) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(res);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaMalloc failed");
  }

  return reinterpret_cast<int8_t *>(pointer);
}

/**
 * This method releases previously allocated host memory space
 *
 * @param pointer pointer that'll be freed
 */
int freeHost(sd::Pointer pointer) {
  auto res = cudaFreeHost(reinterpret_cast<void *>(pointer));
  if (res != 0) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(res);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaFreeHost failed");
  }

  return 1L;
}

/**
 * This method releases previously allocated memory space on device
 *
 * @param pointer pointer that'll be freed
 * @param ptrToDeviceId pointer to deviceId.
 */
int freeDevice(sd::Pointer pointer, int deviceId) {
  auto res = cudaFree(reinterpret_cast<void *>(pointer));

  // we're intentionally skipping
  if (res != 0 && res != 1) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(res);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaFree failed");
  }

  return res == 0 ? 1L : 0L;
}

sd::Pointer createContext() { return 0L; }

sd::Pointer createStream() {
  auto stream = new cudaStream_t();
  auto dZ = cudaStreamCreate(stream);
  if (dZ != 0) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(dZ);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaStreamCreate failed");
  }

  return stream;
}

sd::Pointer createEvent() {
  sd::Pointer nativeEvent = (sd::Pointer)malloc(sizeof(cudaEvent_t));

  CHECK_ALLOC(nativeEvent, "Failed to allocate new CUDA event buffer", sizeof(cudaEvent_t));

  auto dZ = cudaEventCreateWithFlags(reinterpret_cast<cudaEvent_t *>(&nativeEvent), cudaEventDisableTiming);
  if (dZ != 0) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(dZ);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaEventCreateWithFlags failed");
  }

  return nativeEvent;
}

int registerEvent(sd::Pointer event, sd::Pointer stream) {
  auto pEvent = reinterpret_cast<cudaEvent_t *>(&event);
  auto pStream = reinterpret_cast<cudaStream_t *>(stream);

  auto dZ = cudaEventRecord(*pEvent, *pStream);
  if (dZ != 0) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(dZ);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaEventRecord failed");
  }

  return 1;
}

int setDevice(int deviceId) {
  AffinityManager::setCurrentDevice(deviceId);
  return 1;
}

sd::LongType getDeviceFreeMemoryDefault() {
  size_t memFree = 0;
  size_t memTotal = 0;

  cudaMemGetInfo(&memFree, &memTotal);

  return (sd::LongType)memFree;
}

sd::LongType getDeviceFreeMemory(int device) {
  int orig = -1;

  cudaGetDevice(&orig);

  if (device >= 0 && device != orig) {
    cudaSetDevice(device);
  }

  size_t memFree = 0;
  size_t memTotal = 0;

  cudaMemGetInfo(&memFree, &memTotal);

  if (device >= 0 && device != orig) {
    cudaSetDevice(orig);
  }

  return (sd::LongType)memFree;
}

sd::LongType getDeviceTotalMemory(int device) {
  int orig = -1;

  cudaGetDevice(&orig);

  if (device >= 0 && device != orig) {
    cudaSetDevice(device);
  }
  size_t memFree = 0;
  size_t memTotal = 0;

  cudaMemGetInfo(&memFree, &memTotal);

  if (device >= 0 && device != orig) {
    cudaSetDevice(orig);
  }

  return (sd::LongType)memTotal;
}

int memcpySync(sd::Pointer dst, sd::Pointer src, sd::LongType size, int flags, sd::Pointer reserved) {
  cudaMemcpyKind kind;

  switch (flags) {
    case 0: {
      kind = cudaMemcpyHostToHost;
    } break;
    case 1: {
      kind = cudaMemcpyHostToDevice;
    } break;
    case 2: {
      kind = cudaMemcpyDeviceToHost;
    } break;
    case 3: {
      kind = cudaMemcpyDeviceToDevice;
    } break;
    default: {
      sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
      sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("UNDEFNED MEMCPY");
      return 0;
    }
  }

  auto dZ = cudaMemcpy(reinterpret_cast<void *>(dst), const_cast<const void *>(reinterpret_cast<void *>(src)),
                       static_cast<size_t>(size), kind);
  if (dZ != 0) {
    printf("Failed on [%p] -> [%p], size: [%i], direction: [%i], dZ: [%i]\n", src, dst, size, flags,
           static_cast<int>(dZ));
    fflush(stdout);
    fflush(stderr);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(dZ);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaMemcpy failed");
    return 0;
  }

  return 1;
}

int memcpyAsync(sd::Pointer dst, sd::Pointer src, sd::LongType size, int flags, sd::Pointer reserved) {
  auto pStream = reinterpret_cast<cudaStream_t *>(reserved);

  cudaMemcpyKind kind;

  // sd::DebugHelper::checkErrorCode(pStream, "Preliminary sync failed");

  switch (flags) {
    case 0: {
      kind = cudaMemcpyHostToHost;
    } break;
    case 1: {
      kind = cudaMemcpyHostToDevice;
    } break;
    case 2: {
      kind = cudaMemcpyDeviceToHost;
    } break;
    case 3: {
      kind = cudaMemcpyDeviceToDevice;
    } break;
    default: {
      sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
      sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("UNDEFNED MEMCPY");
      return 0;
    }
  }

  auto dZ = cudaMemcpyAsync(reinterpret_cast<void *>(dst), const_cast<const void *>(reinterpret_cast<void *>(src)),
                            static_cast<size_t>(size), kind, *pStream);
  // auto dZ = cudaMemcpy(reinterpret_cast<void *>(dst), const_cast<const void *>(reinterpret_cast<void *>(src)),
  // static_cast<size_t>(size), kind);
  if (dZ != 0) {
    printf("Failed on [%p] -> [%p], size: [%i], direction: [%i], dZ: [%i]\n", src, dst, size, flags,
           static_cast<int>(dZ));
    fflush(stdout);
    fflush(stderr);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(dZ);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaMemcpyAsync failed");
    return 0;
  }

  return 1;
}

int memsetSync(sd::Pointer dst, int value, sd::LongType size, int flags, sd::Pointer reserved) {
  auto dZ = cudaMemset(reinterpret_cast<void *>(dst), value, static_cast<size_t>(size));
  if (dZ != 0) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(dZ);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaMemset failed");
  }

  return 1;
}

int memsetAsync(sd::Pointer dst, int value, sd::LongType size, int flags, sd::Pointer reserved) {
  auto pStream = reinterpret_cast<cudaStream_t *>(reserved);

  auto dZ = cudaMemsetAsync(reinterpret_cast<void *>(dst), value, static_cast<size_t>(size), *pStream);
  if (dZ != 0) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(dZ);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaMemsetAsync failed");
  }

  return 1;
}

int destroyEvent(sd::Pointer event) {
  auto pEvent = reinterpret_cast<cudaEvent_t *>(&event);
  auto dZ = cudaEventDestroy(*pEvent);
  if (dZ != 0) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(dZ);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaEventDestroy failed");
  }

  return 1;
}

int streamSynchronize(sd::Pointer stream) {
  auto pStream = reinterpret_cast<cudaStream_t *>(stream);

  auto dZ = cudaStreamSynchronize(*pStream);
  if (dZ != 0) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(dZ);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaStreamSynchronize failed");
  }

  return 1L;
}

int eventSynchronize(sd::Pointer event) {
  auto pEvent = reinterpret_cast<cudaEvent_t *>(&event);

  auto dZ = cudaEventSynchronize(*pEvent);
  if (dZ != 0) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(dZ);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaEventSynchronize failed");
  }

  return 1L;
}

int getAvailableDevices() {
  int devCnt = 0;
  cudaGetDeviceCount(&devCnt);
  return devCnt;
}

void enableDebugMode(bool reallyEnable) { sd::Environment::getInstance().setDebug(reallyEnable); }

void setGridLimit(int gridSize) {
  if (gridSize > 8192) gridSize = 8192;
  if (gridSize < 1) gridSize = 1;
  blockLimit = gridSize;
}

int ompGetMaxThreads() { return maxThreads; }

int ompGetNumThreads() { return maxThreads; }

void setOmpNumThreads(int threads) {
  if (threads > 1024) threads = 1024;
  if (threads < 32) threads = 32;
  maxThreads = threads;
}

void enableVerboseMode(bool reallyEnable) { sd::Environment::getInstance().setVerbose(reallyEnable); }

int getDeviceMajor(int device) { return deviceProperties[device].major; }

int getDeviceMinor(int device) { return deviceProperties[device].minor; }

const char *getDeviceName(int device) { return deviceProperties[device].name; }

void specialConcat(sd::Pointer *extraPointers, int dimension, int numArrays, sd::Pointer *data,
                   sd::Pointer *inputShapeInfo, void *dZ, sd::LongType const *dZShapeInfo, sd::Pointer *tadPointers,
                   sd::Pointer *offsetPointers) {
  try {
    BUILD_SINGLE_SELECTOR(ArrayOptions::dataType(dZShapeInfo), sd::SpecialMethods,
                          ::concatCpuGeneric(dimension, numArrays, data, inputShapeInfo, dZ, dZShapeInfo),
                          SD_COMMON_TYPES);
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

/**
 * This method saves
 */
sd::TadPack *tadOnlyShapeInfo(sd::LongType const *dXShapeInfo, int *dimension, int dimensionLength) {
  try {
    auto pack = new TadPack();
    *pack = sd::ConstantTadHelper::getInstance().tadForDimensions(dXShapeInfo, dimension, dimensionLength);
    return pack;
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
    return nullptr;
  }
}

sd::LongType const *getPrimaryShapeInfo(sd::TadPack *pack) { return pack->primaryShapeInfo(); }
sd::LongType const *getPrimaryOffsets(sd::TadPack *pack) { return pack->primaryOffsets(); }
sd::LongType const *getSpecialShapeInfo(sd::TadPack *pack) { return pack->specialShapeInfo(); }
sd::LongType const *getSpecialOffsets(sd::TadPack *pack) { return pack->specialOffsets(); }
sd::LongType getNumberOfTads(sd::TadPack *pack) { return pack->numberOfTads(); }
int getShapeInfoLength(sd::TadPack *pack) { return pack->shapeInfoLength(); }

int memcpyConstantAsync(sd::LongType dst, sd::Pointer src, sd::LongType size, int flags, sd::Pointer reserved) {
  cudaStream_t *pStream = reinterpret_cast<cudaStream_t *>(reserved);

  cudaMemcpyKind kind;

  DEBUG_KERNEL(pStream, -1);

  switch (flags) {
    case 0: {
      kind = cudaMemcpyHostToHost;
    } break;
    case 1: {
      kind = cudaMemcpyHostToDevice;
    } break;
    case 2: {
      kind = cudaMemcpyDeviceToHost;
    }
    case 3: {
      kind = cudaMemcpyDeviceToDevice;
    } break;
  }
  auto dZ = cudaMemcpyToSymbolAsync(deviceConstantMemory, const_cast<const void *>(src), size, dst, kind, *pStream);
  if (dZ != 0) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(dZ);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaMemcpyToSymbolAsync failed");
  }

  return 1;
}

sd::Pointer getConstantSpace() {
  sd::Pointer dConstAddr;
  cudaError_t dZ = cudaGetSymbolAddress(reinterpret_cast<void **>(&dConstAddr), deviceConstantMemory);

  if (dZ != 0) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(dZ);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("cudaGetSymbolAddress failed");
  }

  return dConstAddr;
}

void pullRows(sd::Pointer *extraPointers, OpaqueDataBuffer *dbX, sd::LongType const *xShapeInfo,
              sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbZ, sd::LongType const *zShapeInfo,
              sd::LongType const *dZShapeInfo, sd::LongType n, sd::LongType *indexes, sd::LongType const *tadShapeInfo,
              sd::LongType const *tadOffsets, sd::LongType const *zTadShapeInfo, sd::LongType const *zTadOffsets) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});

    cudaStream_t *stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);
    dim3 launchDims(64, 256, 1024);
    auto xType = sd::ArrayOptions::dataType(xShapeInfo);
    BUILD_SINGLE_SELECTOR(xType, pullRowsKernelGeneric,
                          (launchDims, stream, dbX->special(), dbZ->special(), n, indexes, tadShapeInfo, tadOffsets,
                           zTadShapeInfo, zTadOffsets),
                          SD_COMMON_TYPES);

    DEBUG_KERNEL(stream, -1);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void average(sd::Pointer *extras, sd::Pointer *x, sd::LongType const *xShapeInfo, sd::Pointer *dx,
             sd::LongType const *dXShapeInfo, void *z, sd::LongType const *zShapeInfo, void *dz,
             sd::LongType const *dzShapeInfo, int n, sd::LongType length, bool propagate) {
  try {
    cudaStream_t *stream = reinterpret_cast<cudaStream_t *>(extras[1]);
    int mode = getDeviceId(extras[3]);

    auto dX = reinterpret_cast<void **>(dx);

    if (sd::Environment::getInstance().isDebugAndVerbose()) printf("averageFloat called\n");

    auto xType = sd::ArrayOptions::dataType(xShapeInfo);
    // launching on gpu
    if (mode == 0) {
      dim3 launchDims(256, 256, 4096);
      BUILD_SINGLE_SELECTOR(xType, averagingKernelGeneric, (launchDims, stream, dX, dz, n, length, propagate),
                            SD_COMMON_TYPES);
      sd::DebugHelper::checkErrorCode(stream, "AverageFloat(...) failed");
    } else {
      // launching on host memory
      BUILD_SINGLE_SELECTOR(xType, sd::SpecialMethods, ::averageGeneric(x, z, zShapeInfo, n, length, propagate),
                            SD_COMMON_TYPES);
    }
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void accumulate(sd::Pointer *extras, sd::Pointer *x, sd::LongType const *xShapeInfo, sd::Pointer *dx,
                sd::LongType const *dXShapeInfo, void *z, sd::LongType const *zShapeInfo, void *dz,
                sd::LongType const *dzShapeInfo, int n, sd::LongType length) {
  try {
    auto stream = reinterpret_cast<cudaStream_t *>(extras[1]);
    int mode = getDeviceId(extras[3]);

    auto dX = reinterpret_cast<void **>(dx);

    if (sd::Environment::getInstance().isDebugAndVerbose()) printf("accumulateFloat called\n");
    auto xType = sd::ArrayOptions::dataType(xShapeInfo);

    // launching on gpu
    if (mode == 0) {
      dim3 launchDims(n, 256, 16384);
      BUILD_SINGLE_SELECTOR(xType, accumulateKernelGeneric, (launchDims, stream, dX, dz, n, length), SD_COMMON_TYPES);
      sd::DebugHelper::checkErrorCode(stream, "AccumulateFloat(...) failed");
    } else {
      // launching on host memory
      BUILD_SINGLE_SELECTOR(xType, sd::SpecialMethods, ::accumulateGeneric(x, z, zShapeInfo, n, length),
                            SD_COMMON_TYPES);
    }
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void shuffle(sd::Pointer *extras, sd::Pointer *x, sd::Pointer *xShapeInfo, sd::Pointer *dx, sd::Pointer *dXShapeInfo,
             sd::Pointer *z, sd::Pointer *zShapeInfo, sd::Pointer *dz, sd::Pointer *dZShapeInfo, int N, int *shuffleMap,
             sd::Pointer *tadShapeInfo, sd::Pointer *tadOffsets) {
  try {
    cudaStream_t *stream = reinterpret_cast<cudaStream_t *>(extras[1]);

    auto dX = reinterpret_cast<void **>(dx);
    auto dZ = reinterpret_cast<void **>(dz);
    auto xShape = reinterpret_cast<sd::LongType **>(xShapeInfo);
    auto dxShape = reinterpret_cast<sd::LongType **>(dXShapeInfo);
    auto tadOnlyShapeInfo = reinterpret_cast<sd::LongType **>(tadShapeInfo);
    auto tadOffset = reinterpret_cast<sd::LongType **>(tadOffsets);

    auto xType = sd::ArrayOptions::dataType(xShape[0]);
    dim3 launchDims(256, 512, 8192);
    BUILD_SINGLE_SELECTOR(xType, shuffleKernelGeneric,
                          (launchDims, stream, dX, dxShape, dZ, N, shuffleMap, tadOnlyShapeInfo, tadOffset),
                          SD_COMMON_TYPES);

    sd::DebugHelper::checkErrorCode(stream, "shuffle(...) failed");
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

bool isExperimentalEnabled() { return sd::Environment::getInstance().isExperimentalBuild(); }

void setOmpMinThreads(int threads) {
  minThreads = sd::math::sd_max<int>(32, threads);
  minThreads = sd::math::sd_min<int>(maxThreads, minThreads);
}

int getDevice() { return sd::AffinityManager::currentDeviceId(); }

void setElementThreshold(int num) {
  // this is no-op for CUDA
}

void setTADThreshold(int num) {
  // this is no-op for CUDA
}

////////////////////////////////////////////////////////////////////////
void execSummaryStats(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                      sd::LongType const *dXShapeInfo, void *extraParams, OpaqueDataBuffer *dbZ,
                      sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo, bool biasCorrected) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execSummaryStats(&lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
                                          ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(),
                                          extraParams, dbZ->primary(), hZShapeInfo, dbZ->special(),
                                          ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
                                          biasCorrected);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execSummaryStatsTad(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                         sd::LongType const *dXShapeInfo, void *extraParams, OpaqueDataBuffer *dbZ,
                         sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo,
                         OpaqueDataBuffer *dbDimension, sd::LongType const *hDimensionShape,
                         sd::LongType const *dDimensionShape, bool biasCorrected, sd::LongType const *tadShapeInfo,
                         sd::LongType const *tadOffsets) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX, dbDimension});
    InteropDataBuffer::preparePrimaryUse({}, {dbDimension});

    auto dimension = reinterpret_cast<int *>(dbDimension->primary());
    int dimensionLength = static_cast<int>(shape::length(hDimensionShape));

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execSummaryStats(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), extraParams, dbZ->primary(),
        hZShapeInfo, dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
        reinterpret_cast<int *>(dbDimension->special()), dimensionLength, tadShapeInfo, tadOffsets, biasCorrected);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX, dbDimension});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execReduce3(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                 sd::LongType const *dXShapeInfo, void *extraParams, OpaqueDataBuffer *dbY,
                 sd::LongType const *hYShapeInfo, sd::LongType const *dYShapeInfo, OpaqueDataBuffer *dbZ,
                 sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX, dbY});

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execReduce3(&lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
                                     ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(),
                                     extraParams, dbY->primary(), hYShapeInfo, dbY->special(),
                                     ConstantShapeHelper::getInstance().bufferForShapeInfo(hYShapeInfo).special(),
                                     dbZ->primary(), hZShapeInfo, dbZ->special(),
                                     ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special());

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX, dbY});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execReduce3Tad(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                    sd::LongType const *dXShapeInfo, void *extraParams, OpaqueDataBuffer *dbY,
                    sd::LongType const *hYShapeInfo, sd::LongType const *dYShapeInfo, OpaqueDataBuffer *dbZ,
                    sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo, OpaqueDataBuffer *dbDimension,
                    sd::LongType const *hDimensionShape, sd::LongType const *dDimensionShape,
                    sd::LongType const *tadOnlyShapeInfo, sd::LongType const *tadOffsets,
                    sd::LongType const *yTadOnlyShapeInfo, sd::LongType const *yTadOffsets) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX, dbY});
    InteropDataBuffer::preparePrimaryUse({}, {dbDimension});

    auto dimension = reinterpret_cast<int *>(dbDimension->primary());
    int dimensionLength = static_cast<int>(shape::length(hDimensionShape));

    auto tadPack =
        sd::ConstantTadHelper::getInstance().tadForDimensions(hXShapeInfo, dimension, shape::length(hDimensionShape));
    auto tadLength = shape::length(tadPack.primaryShapeInfo());
    auto yLength = shape::length(hYShapeInfo);
    auto xLength = shape::length(hXShapeInfo);

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);

    if (tadLength == yLength || tadLength == xLength) {
      // sd_printf("== way\n","");
      NativeOpExecutioner::execReduce3(
          &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
          ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), extraParams, dbY->primary(),
          hYShapeInfo, dbY->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hYShapeInfo).special(),
          dbZ->primary(), hZShapeInfo, dbZ->special(),
          ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(), dimension, dimensionLength,
          tadOnlyShapeInfo, tadOffsets, yTadOnlyShapeInfo, yTadOffsets);
    } else
      NativeOpExecutioner::execReduce3TAD(
          &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
          ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), extraParams, dbY->primary(),
          hYShapeInfo, dbY->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hYShapeInfo).special(),
          dbZ->primary(), hZShapeInfo, dbZ->special(),
          ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(), dimension, dimensionLength,
          tadOnlyShapeInfo, yTadOffsets, yTadOnlyShapeInfo, yTadOffsets);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX, dbY});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execReduce3Scalar(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                       sd::LongType const *dXShapeInfo, void *extraParams, OpaqueDataBuffer *dbY,
                       sd::LongType const *hYShapeInfo, sd::LongType const *dYShapeInfo, OpaqueDataBuffer *dbZ,
                       sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX, dbY});

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execReduce3Scalar(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), extraParams, dbY->primary(),
        hYShapeInfo, dbY->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hYShapeInfo).special(),
        dbZ->primary(), hZShapeInfo, dbZ->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special());

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX, dbY});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execScalarBool(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                    sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbZ, sd::LongType const *hZShapeInfo,
                    sd::LongType const *dZShapeInfo, OpaqueDataBuffer *dbScalar, sd::LongType const *hScalarShapeInfo,
                    sd::LongType const *dScalarShapeInfo, void *extraParams) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX, dbScalar});

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execScalarBool(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), dbZ->primary(), hZShapeInfo,
        dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
        dbScalar->primary(), hScalarShapeInfo, dbScalar->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hScalarShapeInfo).special(), extraParams);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX, dbScalar});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execScalarBoolTad(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                       sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbZ, sd::LongType const *hZShapeInfo,
                       sd::LongType const *dZShapeInfo, OpaqueDataBuffer *dbScalars,
                       sd::LongType const *hScalarShapeInfo, sd::LongType const *dScalarShapeInfo, void *extraParams,
                       OpaqueDataBuffer *dbDimension, sd::LongType const *hDimensionShape,
                       sd::LongType const *dDimensionShape, sd::LongType const *tadShapeInfo,
                       sd::LongType const *tadOffsets, sd::LongType const *tadShapeInfoZ,
                       sd::LongType const *tadOffsetsZ) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX, dbScalars});
    InteropDataBuffer::preparePrimaryUse({}, {dbDimension});

    auto dimension = reinterpret_cast<int *>(dbDimension->primary());
    int dimensionLength = static_cast<int>(shape::length(hDimensionShape));

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execScalarBool(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), extraParams, dbZ->primary(),
        hZShapeInfo, dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
        dbScalars->primary(), hScalarShapeInfo, dbScalars->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hScalarShapeInfo).special(), dimension, dimensionLength,
        tadShapeInfo, tadOffsets, tadShapeInfoZ, tadOffsetsZ);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX, dbScalars});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execScalar(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbZ, sd::LongType const *hZShapeInfo,
                sd::LongType const *dZShapeInfo, OpaqueDataBuffer *dbScalar, sd::LongType const *hScalarShapeInfo,
                sd::LongType const *dScalarShapeInfo, void *extraParams) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX, dbScalar});

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execScalar(
        &lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), dbZ->primary(), hZShapeInfo,
        dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
        dbScalar->primary(), hScalarShapeInfo, dbScalar->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hScalarShapeInfo).special(), extraParams);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX, dbScalar});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execScalarTad(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                   sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbZ, sd::LongType const *hZShapeInfo,
                   sd::LongType const *dZShapeInfo, OpaqueDataBuffer *dbScalars, sd::LongType const *hScalarShapeInfo,
                   sd::LongType const *dScalarShapeInfo, void *extraParams, OpaqueDataBuffer *dbDimension,
                   sd::LongType const *hDimensionShape, sd::LongType const *dDimensionShape,
                   sd::LongType const *tadShapeInfo, sd::LongType const *tadOffsets, sd::LongType const *tadShapeInfoZ,
                   sd::LongType const *tadOffsetsZ) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX, dbScalars});
    InteropDataBuffer::preparePrimaryUse({}, {dbDimension});

    auto dimension = reinterpret_cast<int *>(dbDimension->primary());
    int dimensionLength = static_cast<int>(shape::length(hDimensionShape));

    cudaStream_t *stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);

    auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
    auto yType = sd::ArrayOptions::dataType(hScalarShapeInfo);
    auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

    if (yType != xType && yType != sd::DataType::BOOL && !isExperimentalEnabled())
      throw sd::datatype_exception::build("execScalar both operands must have same data type", xType, yType);

    dim3 launchDims(256, 256, 16384);

#ifdef SD_EXPERIMENTAL_ENABLED
    BUILD_PAIRWISE_SELECTOR(
        xType, yType, zType, functions::scalar::ScalarTransform,
        ::executeCudaAlongDimension(launchDims, stream, opNum, dX, dXShapeInfo, dZ, dZShapeInfo, dScalars, extraParams,
                                    dimension, dimensionLength, tadShapeInfo, tadOffsets, tadShapeInfoZ, tadOffsetsZ),
        SD_COMMON_TYPES, SD_COMMON_TYPES);
#else
    BUILD_SINGLE_SELECTOR_THRICE(
        xType, functions::scalar::ScalarTransform,
        ::executeCudaAlongDimension(
            launchDims, stream, opNum, dbX->special(),
            ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), dbZ->special(),
            ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(), dbScalars->special(),
            extraParams, dimension, dimensionLength, tadShapeInfo, tadOffsets, tadShapeInfoZ, tadOffsetsZ),
        SD_COMMON_TYPES);
#endif

    DEBUG_KERNEL(stream, opNum);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX, dbScalars});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void execAggregate(sd::Pointer *extraPointers, int opNum, void **arguments, int numArguments, sd::LongType **shapes,
                   int numShapes, int *indexArguments, int numIndexArguments, int **intArrays, int numIntArrays,
                   void *realArguments, int numRealArguments, sd::DataType dtype) {}

void batchExecutor(sd::Pointer *extraPointers, int numAggregates, int opNum, int maxArgs, int maxShapes,
                   int maxIntArrays, int maxIntArraySize, int maxIdx, int maxReals, void *ptrToArguments,
                   sd::DataType dtype) {}

void execAggregateBatch(sd::Pointer *extraPointers, int numAggregates, int opNum, int maxArgs, int maxShapes,
                        int maxIntArrays, int maxIntArraySize, int maxIdx, int maxReals, void *ptrToArguments,
                        sd::DataType dtype) {}

////////////////////////////////////////////////////////////////////////
void execRandom(sd::Pointer *extraPointers, int opNum, sd::Pointer stateHost, OpaqueDataBuffer *dbZ,
                sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo, void *extraArguments) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {});

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execRandom(&lc, opNum, stateHost, dbZ->primary(), hZShapeInfo, dbZ->special(),
                                    ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
                                    extraArguments);

    InteropDataBuffer::registerSpecialUse({dbZ}, {});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execRandom2(sd::Pointer *extraPointers, int opNum, sd::Pointer stateHost, OpaqueDataBuffer *dbX,
                 sd::LongType const *hXShapeInfo, sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbZ,
                 sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo, void *extraArguments) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX});

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execRandom(
        &lc, opNum, stateHost, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), dbZ->primary(), hZShapeInfo,
        dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(), extraArguments);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

////////////////////////////////////////////////////////////////////////
void execRandom3(sd::Pointer *extraPointers, int opNum, sd::Pointer stateHost, OpaqueDataBuffer *dbX,
                 sd::LongType const *hXShapeInfo, sd::LongType const *dXShapeInfo, OpaqueDataBuffer *dbY,
                 sd::LongType const *hYShapeInfo, sd::LongType const *dYShapeInfo, OpaqueDataBuffer *dbZ,
                 sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo, void *extraArguments) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX, dbY});

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execRandom(
        &lc, opNum, stateHost, dbX->primary(), hXShapeInfo, dbX->special(),
        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(), dbY->primary(), hYShapeInfo,
        dbY->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hYShapeInfo).special(), dbZ->primary(),
        hZShapeInfo, dbZ->special(), ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
        extraArguments);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX, dbY});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

sd::Pointer initRandom(sd::Pointer *extraPointers, long seed, long bufferSize, sd::Pointer ptrToBuffer) {
  unsigned long long *ptrHost = reinterpret_cast<unsigned long long *>(extraPointers[0]);
  cudaStream_t *stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);

  // we don't synchronize at random initialization, it's safe to go unsync here
  // cudaStreamSynchronize(*stream);

  auto ptrDev = reinterpret_cast<unsigned long long *>(ptrToBuffer);
  auto buffer = new sd::random::RandomBuffer(seed, bufferSize, reinterpret_cast<uint64_t *>(ptrHost),
                                             reinterpret_cast<uint64_t *>(ptrDev));
  buffer->propagateToDevice(buffer, *stream);

  sd::DebugHelper::checkErrorCode(stream, "initRandom(...) failed A");

  // we generate sequence in the host memory
  sd::random::Xoroshiro128 generator(buffer);
  generator.refreshBuffer();

  // and copy it to gpu
  cudaMemcpyAsync(ptrDev, ptrHost, bufferSize * 8, cudaMemcpyHostToDevice, *stream);
  sd::DebugHelper::checkErrorCode(stream, "initRandom(...) failed B");

  return buffer;
}

void destroyRandom(sd::Pointer ptrBuffer) {
  sd::random::RandomBuffer *buffer = reinterpret_cast<sd::random::RandomBuffer *>(ptrBuffer);

  // FIXME: it's bad thing, but we can't know in advance, which stream(s) where using this generator in practice
  cudaDeviceSynchronize();

  delete buffer;
}

void refreshBuffer(sd::Pointer *extraPointers, long seed, sd::Pointer ptrRandom) {
  sd::random::RandomBuffer *buffer = reinterpret_cast<sd::random::RandomBuffer *>(ptrRandom);

  unsigned long long *ptrHost = reinterpret_cast<unsigned long long *>(extraPointers[0]);
  cudaStream_t *stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);
  cudaStreamSynchronize(*stream);

  uint64_t *ptrDev = buffer->getDeviceBuffer();

  // update rng state
  buffer->setSeed(seed);
  buffer->setOffset(0);
  buffer->propagateToDevice(buffer, *stream);

  // refresh buffer on host size
  sd::random::Xoroshiro128 generator(buffer);
  generator.refreshBuffer();

  // copy back to gpu
  cudaMemcpyAsync(ptrDev, ptrHost, buffer->getSize() * 8, cudaMemcpyHostToDevice, *stream);
}

void reSeedBuffer(sd::Pointer *extraPointers, long seed, sd::Pointer ptrRandom) {
  sd::random::RandomBuffer *buffer = reinterpret_cast<sd::random::RandomBuffer *>(ptrRandom);

  cudaStream_t *stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);
  cudaStreamSynchronize(*stream);

  // update rng state
  buffer->reSeed(seed);
  buffer->setOffset(0);
  buffer->propagateToDevice(buffer, *stream);
}

/**
 * Return the length of a shape buffer
 * based on the pointer
 * @param buffer  the buffer pointer to check
 * @return
 */
int lengthForShapeBufferPointer(sd::Pointer buffer) {
  auto shapeBuffer = reinterpret_cast<sd::LongType *>(buffer);
  return shape::shapeInfoLength(shape::rank(shapeBuffer));
}

/**
 * The pointer to get the address for
 *
 * @param address the address to get the pointer
 * @return the pointer for the given address
 */

sd::Pointer pointerForAddress(sd::LongType address) { return reinterpret_cast<sd::Pointer>(address); }

void tear(sd::Pointer *extras, OpaqueDataBuffer *dbX, sd::LongType const *xShapeInfo, sd::LongType const *dXShapeInfo,
          sd::Pointer *targets, sd::LongType const *zShapeInfo, sd::LongType const *tadShapeInfo,
          sd::LongType const *tadOffsets) {
  try {
    InteropDataBuffer::prepareSpecialUse({}, {dbX});

    cudaStream_t *stream = reinterpret_cast<cudaStream_t *>(extras[1]);
    dim3 launchDims(512, 512, 512);
    auto xType = sd::ArrayOptions::dataType(xShapeInfo);
    BUILD_SINGLE_SELECTOR(
        xType, tearKernelGeneric,
        (launchDims, stream, dbX->special(), dXShapeInfo, targets, zShapeInfo, tadShapeInfo, tadOffsets),
        SD_COMMON_TYPES);

    sd::DebugHelper::checkErrorCode(stream, "tearFloat(...) failed");

    InteropDataBuffer::registerSpecialUse({}, {dbX});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void prescanArrayRecursive(sd::Pointer *extras, int *dZ, int *dX, int numElements, int level) {
  auto stream = reinterpret_cast<cudaStream_t *>(extras[1]);
  auto g_scanBlockSums = reinterpret_cast<int **>(extras[2]);

  int blockSize = 512;  // max size of the thread blocks
  int numBlocks = sd::math::sd_max<int>(1, static_cast<int>(ceil(static_cast<float>(numElements) / (2.f * blockSize))));
  int numThreads;

  if (numBlocks > 1)
    numThreads = blockSize;
  else if (sd::isPowerOfTwo(numElements))
    numThreads = numElements / 2;
  else
    numThreads = sd::floorPow2(numElements);

  int numEltsPerBlock = numThreads * 2;

  // if this is a non-power-of-2 array, the last block will be non-full
  // compute the smallest power of 2 able to compute its scan.
  int numEltsLastBlock = numElements - (numBlocks - 1) * numEltsPerBlock;
  int numThreadsLastBlock = sd::math::sd_max<int>(1, numEltsLastBlock / 2);
  int np2LastBlock = 0;
  int sharedMemLastBlock = 0;

  if (numEltsLastBlock != numEltsPerBlock) {
    np2LastBlock = 1;

    if (!isPowerOfTwo(numEltsLastBlock)) numThreadsLastBlock = floorPow2(numEltsLastBlock);

    unsigned int extraSpace = (2 * numThreadsLastBlock) / NUM_BANKS;
    sharedMemLastBlock = sizeof(int) * (2 * numThreadsLastBlock + extraSpace);
  }

  // padding space is used to avoid shared memory bank conflicts
  int extraSpace = numEltsPerBlock / NUM_BANKS;
  int sharedMemSize = sizeof(int) * (numEltsPerBlock + extraSpace);

  // setup execution parameters
  // if NP2, we process the last block separately
  dim3 grid(max(1, numBlocks - np2LastBlock), 1, 1);
  dim3 threads(numThreads, 1, 1);
  dim3 gridOnes(1, 1, 1);
  dim3 threadsOnes(numThreadsLastBlock, 1, 1);

  if (sharedMemSize < 2048) sharedMemSize = 2048;

  if (sharedMemLastBlock < 2048) sharedMemLastBlock = 2048;

  // execute the scan
  if (numBlocks > 1) {
    sd::prescanLauncher<true, false>(grid, threads, sharedMemSize, stream, dZ, dX, g_scanBlockSums[level],
                                     numThreads * 2, 0, 0);
    if (np2LastBlock) {
      sd::prescanLauncher<true, true>(gridOnes, threadsOnes, sharedMemLastBlock, stream, dZ, dX, g_scanBlockSums[level],
                                      numEltsLastBlock, numBlocks - 1, numElements - numEltsLastBlock);
    }

    // After scanning all the sub-blocks, we are mostly done.  But now we
    // need to take all of the last values of the sub-blocks and scan those.
    // This will give us a new value that must be sdded to each block to
    // get the final results.
    // recursive (CPU) call
    prescanArrayRecursive(extras, g_scanBlockSums[level], g_scanBlockSums[level], numBlocks, level + 1);

    sd::uniformAdd<<<grid, threads, 1024, *stream>>>(dZ, g_scanBlockSums[level], numElements - numEltsLastBlock, 0, 0);

    if (np2LastBlock) {
      sd::uniformAdd<<<1, numThreadsLastBlock, 1024, *stream>>>(dZ, g_scanBlockSums[level], numEltsLastBlock,
                                                                numBlocks - 1, numElements - numEltsLastBlock);
    }
  } else if (isPowerOfTwo(numElements)) {
    sd::prescanLauncher<false, false>(grid, threads, sharedMemSize, stream, dZ, dX, 0, numThreads * 2, 0, 0);
  } else {
    sd::prescanLauncher<false, true>(grid, threads, sharedMemSize, stream, dZ, dX, 0, numElements, 0, 0);
  }

  sd::DebugHelper::checkErrorCode(stream, "prescanArray(...) failed");
}

////////////////////////////////////////////////////////////////////////
void execReduce3All(sd::Pointer *extraPointers, int opNum, OpaqueDataBuffer *dbX, sd::LongType const *hXShapeInfo,
                    sd::LongType const *dXShapeInfo, void *extraParamsVals, OpaqueDataBuffer *dbY,
                    sd::LongType const *hYShapeInfo, sd::LongType const *dYShapeInfo, OpaqueDataBuffer *dbZ,
                    sd::LongType const *hZShapeInfo, sd::LongType const *dZShapeInfo, OpaqueDataBuffer *dbDimension,
                    sd::LongType const *hDimensionShape, sd::LongType const *dDimensionShape,
                    sd::LongType const *xTadShapeInfo, sd::LongType const *xOffsets, sd::LongType const *yTadShapeInfo,
                    sd::LongType const *yOffsets) {
  try {
    InteropDataBuffer::prepareSpecialUse({dbZ}, {dbX, dbY, dbDimension});
    InteropDataBuffer::preparePrimaryUse({}, {dbDimension});

    auto dimension = reinterpret_cast<int *>(dbDimension->primary());
    int dimensionLength = static_cast<int>(shape::length(hDimensionShape));

    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    NativeOpExecutioner::execReduce3All(&lc, opNum, dbX->primary(), hXShapeInfo, dbX->special(),
                                        ConstantShapeHelper::getInstance().bufferForShapeInfo(hXShapeInfo).special(),
                                        extraParamsVals, dbY->primary(), hYShapeInfo, dbY->special(),
                                        ConstantShapeHelper::getInstance().bufferForShapeInfo(hYShapeInfo).special(),
                                        dbZ->primary(), hZShapeInfo, dbZ->special(),
                                        ConstantShapeHelper::getInstance().bufferForShapeInfo(hZShapeInfo).special(),
                                        reinterpret_cast<int *>(dbDimension->special()), dimensionLength, xTadShapeInfo,
                                        xOffsets, yTadShapeInfo, yOffsets);

    InteropDataBuffer::registerSpecialUse({dbZ}, {dbX, dbY});
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void sort(sd::Pointer *extraPointers, void *x, sd::LongType const *xShapeInfo, void *dX,
          sd::LongType const *dXShapeInfo, bool descending) {
  try {
    cudaStream_t *stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);

    auto xLength = shape::length(xShapeInfo);
    auto xEWS = shape::elementWiseStride(xShapeInfo);
    auto xType = sd::ArrayOptions::dataType(xShapeInfo);

    // check if xLength is a power of 2, and use bitonic sort, if that's the case
    if ((xLength != 0) && ((xLength & (xLength - 1)) == 0) && (xLength <= 1024 * 1024 * 10)) {
      int numThreads = sd::math::sd_min<int>(512, xLength);
      int numBlocks = xLength / numThreads;
      if (xLength % numThreads > 0 || numBlocks == 0) numBlocks++;

      dim3 launchDims(numBlocks, numThreads, 32768);

      for (int k = 2; k <= xLength; k = 2 * k) {
        for (int j = k >> 1; j > 0; j = j >> 1) {
          BUILD_SINGLE_SELECTOR(xType, bitonicSortStepGeneric,
                                (launchDims, stream, dX, dXShapeInfo, j, k, xLength, descending), SD_COMMON_TYPES);
        }
      }
    } else {
      int numThreads = sd::math::sd_min<int>(512, xLength);
      int numBlocks = xLength / numThreads;
      if (xLength % numThreads > 0 || numBlocks == 0) numBlocks++;

      numBlocks = sd::math::sd_min<int>(512, numBlocks);
      dim3 launchDims(numBlocks, numThreads, 32768);

      int max = 2, dg = 0;
      while (max < xLength) {
        max <<= 1;
        dg++;
      }
      max <<= 1;

      for (int window = 2; window < max; window <<= 1) {
        int n = window;
        int rev = 0;
        do {
          int half = n >> 1;
          BUILD_SINGLE_SELECTOR(xType, bitonicArbitraryStepGeneric,
                                (launchDims, stream, dX, dXShapeInfo, n, xLength, rev, descending), SD_COMMON_TYPES);
          n >>= 1;
          rev = 1;
        } while (n > 1);
      }
    }

    sd::DebugHelper::checkErrorCode(stream, "sort(...) failed");
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void sortByKey(sd::Pointer *extraPointers, void *x, sd::LongType const *xShapeInfo, void *dX,
               sd::LongType const *dXShapeInfo, void *y, sd::LongType const *yShapeInfo, void *dy,
               sd::LongType const *dyShapeInfo, bool descending) {
  try {
    auto stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);

    auto xLength = shape::length(xShapeInfo);
    auto yLength = shape::length(yShapeInfo);
    auto xEWS = shape::elementWiseStride(xShapeInfo);
    auto xType = sd::ArrayOptions::dataType(xShapeInfo);
    auto yType = sd::ArrayOptions::dataType(yShapeInfo);

    if (shape::isEmpty(xShapeInfo) || shape::isEmpty(yShapeInfo)) return;

    if (xLength != yLength) throw std::runtime_error("sortByKey: keys and values must have the same size");

    // check if xLength is a power of 2, and use bitonic sort, if that's the case
    if ((xLength != 0) && ((xLength & (xLength - 1)) == 0) && (xLength <= 1024 * 1024 * 10)) {
      int numThreads = sd::math::sd_min<int>(512, xLength);
      int numBlocks = xLength / numThreads;
      if (xLength % numThreads > 0 || numBlocks == 0) numBlocks++;

      dim3 launchDims(numBlocks, numThreads, 32768);

      for (int k = 2; k <= xLength; k = 2 * k) {
        for (int j = k >> 1; j > 0; j = j >> 1) {
          BUILD_DOUBLE_SELECTOR(xType, yType, bitonicSortStepGenericKey,
                                (launchDims, stream, dX, dXShapeInfo, dy, dyShapeInfo, j, k, xLength, descending),
                                SD_COMMON_TYPES, SD_COMMON_TYPES);
        }
      }
    } else {
      int numThreads = sd::math::sd_min<int>(512, xLength);
      int numBlocks = xLength / numThreads;
      if (xLength % numThreads > 0 || numBlocks == 0) numBlocks++;

      numBlocks = sd::math::sd_min<int>(512, numBlocks);
      dim3 launchDims(numBlocks, numThreads, 32768);

      int max = 2, dg = 0;
      while (max < xLength) {
        max <<= 1;
        dg++;
      }
      max <<= 1;

      for (int window = 2; window < max; window <<= 1) {
        int n = window;
        int rev = 0;
        do {
          int half = n >> 1;
          BUILD_DOUBLE_SELECTOR(xType, yType, bitonicArbitraryStepGenericKey,
                                (launchDims, stream, dX, dXShapeInfo, dy, dyShapeInfo, n, xLength, rev, descending),
                                SD_COMMON_TYPES, SD_COMMON_TYPES);
          n >>= 1;
          rev = 1;
        } while (n > 1);
      }
    }

  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void sortByValue(sd::Pointer *extraPointers, void *x, sd::LongType const *xShapeInfo, void *dX,
                 sd::LongType const *dXShapeInfo, void *y, sd::LongType const *yShapeInfo, void *dy,
                 sd::LongType const *dyShapeInfo, bool descending) {
  try {
    auto stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);

    auto xLength = shape::length(xShapeInfo);
    auto yLength = shape::length(yShapeInfo);
    auto xEWS = shape::elementWiseStride(xShapeInfo);
    auto xType = sd::ArrayOptions::dataType(yShapeInfo);
    auto yType = sd::ArrayOptions::dataType(xShapeInfo);

    if (shape::isEmpty(xShapeInfo) || shape::isEmpty(yShapeInfo)) return;

    if (xLength != yLength) throw std::runtime_error("sortByValue: keys and values must have the same size");

    // check if xLength is a power of 2, and use bitonic sort, if that's the case
    if ((xLength != 0) && ((xLength & (xLength - 1)) == 0) && (xLength <= 1024 * 1024 * 10)) {
      int numThreads = sd::math::sd_min<int>(512, xLength);
      int numBlocks = xLength / numThreads;
      if (xLength % numThreads > 0 || numBlocks == 0) numBlocks++;

      dim3 launchDims(numBlocks, numThreads, 32768);

      for (int k = 2; k <= xLength; k = 2 * k) {
        for (int j = k >> 1; j > 0; j = j >> 1) {
          BUILD_DOUBLE_SELECTOR(xType, yType, bitonicSortStepGenericKey,
                                (launchDims, stream, dy, dyShapeInfo, dX, dXShapeInfo, j, k, xLength, descending),
                                SD_COMMON_TYPES, SD_COMMON_TYPES);
        }
      }
    } else {
      int numThreads = sd::math::sd_min<int>(512, xLength);
      int numBlocks = xLength / numThreads;
      if (xLength % numThreads > 0 || numBlocks == 0) numBlocks++;

      numBlocks = sd::math::sd_min<int>(512, numBlocks);
      dim3 launchDims(numBlocks, numThreads, 32768);

      int max = 2, dg = 0;
      while (max < xLength) {
        max <<= 1;
        dg++;
      }
      max <<= 1;

      for (int window = 2; window < max; window <<= 1) {
        int n = window;
        int rev = 0;
        do {
          int half = n >> 1;
          BUILD_DOUBLE_SELECTOR(xType, yType, bitonicArbitraryStepGenericKey,
                                (launchDims, stream, dy, dyShapeInfo, dX, dXShapeInfo, n, xLength, rev, descending),
                                SD_COMMON_TYPES, SD_COMMON_TYPES);
          n >>= 1;
          rev = 1;
        } while (n > 1);
      }
    }
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void sortTadByKey(sd::Pointer *extraPointers, void *x, sd::LongType const *xShapeInfo, void *dX,
                  sd::LongType const *dXShapeInfo, void *y, sd::LongType const *yShapeInfo, void *dy,
                  sd::LongType const *dyShapeInfo, int *dimension, int dimensionLength, bool descending) {
  try {
    auto stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);
    auto context =
        extraPointers[0] == 0 ? LaunchContext::defaultContext() : reinterpret_cast<LaunchContext *>(extraPointers[0]);
    auto tadPack = sd::ConstantTadHelper::getInstance().tadForDimensions(xShapeInfo, dimension, dimensionLength);
    dim3 launchDims((int)tadPack.numberOfTads(), 256, 2048);
    auto xType = sd::ArrayOptions::dataType(xShapeInfo);
    auto yType = sd::ArrayOptions::dataType(yShapeInfo);
    BUILD_DOUBLE_SELECTOR(xType, yType, oesTadGenericKey,
                          (launchDims, stream, dX, dXShapeInfo, dy, dyShapeInfo, nullptr, dimensionLength,
                           tadPack.platformShapeInfo(), tadPack.platformOffsets(), descending),
                          SD_COMMON_TYPES, SD_COMMON_TYPES);

    sd::DebugHelper::checkErrorCode(stream, "sortTadKey(...) failed");
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void sortTadByValue(sd::Pointer *extraPointers, void *x, sd::LongType const *xShapeInfo, void *dX,
                    sd::LongType const *dXShapeInfo, void *y, sd::LongType const *yShapeInfo, void *dy,
                    sd::LongType const *dyShapeInfo, int *dimension, int dimensionLength, bool descending) {
  try {
    auto stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);
    auto context =
        extraPointers[0] == 0 ? LaunchContext::defaultContext() : reinterpret_cast<LaunchContext *>(extraPointers[0]);
    auto tadPack = sd::ConstantTadHelper::getInstance().tadForDimensions(xShapeInfo, dimension, dimensionLength);
    dim3 launchDims((int)tadPack.numberOfTads(), 256, 2048);
    auto xType = sd::ArrayOptions::dataType(yShapeInfo);
    auto yType = sd::ArrayOptions::dataType(xShapeInfo);

    BUILD_DOUBLE_SELECTOR(xType, yType, oesTadGenericKey,
                          (launchDims, stream, dy, dyShapeInfo, dX, dXShapeInfo, nullptr, dimensionLength,
                           tadPack.platformShapeInfo(), tadPack.platformOffsets(), descending),
                          SD_COMMON_TYPES, SD_COMMON_TYPES);

    sd::DebugHelper::checkErrorCode(stream, "sortTadValue(...) failed");
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void sortTad(sd::Pointer *extraPointers, void *x, sd::LongType const *xShapeInfo, void *dX,
             sd::LongType const *dXShapeInfo, int *dimension, int dimensionLength, sd::LongType const *tadShapeInfo,
             sd::LongType const *tadOffsets, bool descending) {
  try {
    // to be implemented
    auto stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);
    auto context =
        extraPointers[0] == 0 ? LaunchContext::defaultContext() : reinterpret_cast<LaunchContext *>(extraPointers[0]);
    auto tadPack = sd::ConstantTadHelper::getInstance().tadForDimensions(xShapeInfo, dimension, dimensionLength);
    dim3 launchDims((int)tadPack.numberOfTads(), 512, 33768);
    auto xType = sd::ArrayOptions::dataType(xShapeInfo);
    BUILD_SINGLE_SELECTOR(
        xType, oesTadGeneric,
        (launchDims, stream, dX, dXShapeInfo, nullptr, dimensionLength, tadShapeInfo, tadOffsets, descending),
        SD_COMMON_TYPES);

    sd::DebugHelper::checkErrorCode(stream, "sortTad(...) failed");
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void sortCooIndices(sd::Pointer *extraPointers, sd::LongType *indices, void *values, sd::LongType length,
                    const sd::LongType *xShapeInfo) {
  throw std::runtime_error("sortCooIndices:: Not implemented yet");
}

void ravelMultiIndex(sd::Pointer *extraPointers, sd::LongType *indices, sd::LongType *flatIndices, sd::LongType length,
                     sd::LongType *shapeInfo, int mode) {
  throw std::runtime_error("ravelMultiIndex:: Not implemented yet");
}

void unravelIndex(sd::Pointer *extraPointers, sd::LongType *indices, sd::LongType *flatIndices, sd::LongType length,
                  sd::LongType *shapeInfo) {
  throw std::runtime_error("unravelIndex:: Not implemented yet");
}

sd::LongType *mmapFile(sd::Pointer *extraPointers, const char *fileName, sd::LongType length) { return nullptr; }

void munmapFile(sd::Pointer *extraPointers, sd::LongType *ptrMap, sd::LongType length) {}

sd::graph::ResultWrapper *executeFlatGraph(sd::Pointer *extraPointers, sd::Pointer flatBufferPointer) {
  try {
    return sd::graph::GraphExecutioner::executeFlatBuffer(flatBufferPointer);
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
    return nullptr;
  }
}

sd::LongType getResultWrapperSize(sd::graph::ResultWrapper *ptr) { return ptr->size(); }
sd::Pointer getResultWrapperPointer(sd::graph::ResultWrapper *ptr) { return ptr->pointer(); }

const char *getAllCustomOps() { return sd::ops::OpRegistrator::getInstance().getAllCustomOperations(); }

sd::ShapeList *_calculateOutputShapes(sd::Pointer *extraPointers, sd::ops::DeclarableOp *op, sd::Pointer *inputBuffers,
                                      sd::Pointer *inputShapes, int numInputShapes, double *tArgs, int numTArgs,
                                      sd::LongType *iArgs, int numIArgs, bool *bArgs, int numBArgs, int *dArgs,
                                      int numDArgs) {
  sd::graph::VariableSpace varSpace;
  Context block(2, &varSpace);
  sd::ShapeList inShapes;

  for (int e = 0; e < numIArgs; e++) block.getIArguments()->push_back(iArgs[e]);

  for (int e = 0; e < numTArgs; e++) block.getTArguments()->push_back(tArgs[e]);

  for (int e = 0; e < numBArgs; e++) block.getBArguments()->push_back(bArgs[e]);

  for (int e = 0; e < numDArgs; e++) block.getDArguments()->push_back((sd::DataType)dArgs[e]);

  for (int e = 0; e < numInputShapes; e++) {
    auto shape_ = reinterpret_cast<sd::LongType *>(inputShapes[e]);

    // we shouldn't copy buffer if that's empty array
    void *buffer_ = sd::ArrayOptions::arrayType(shape_) == ArrayType::EMPTY ? nullptr : inputBuffers[e];
    void *bufferD_ =
        sd::ArrayOptions::arrayType(shape_) == ArrayType::EMPTY ? nullptr : inputBuffers[e + numInputShapes];

    auto array = new sd::NDArray(buffer_, bufferD_, shape_);

    // block should contain references to proper variable
    varSpace.putVariable(1, e, array);
    block.pickInput(1, e);

    inShapes.push_back(shape_);
  }

  auto shapeList = op->calculateOutputShape(&inShapes, block);

  if (varSpace.launchContext()->getWorkspace() != nullptr) shapeList->detach();

  return shapeList;
}

sd::ShapeList *calculateOutputShapes2(sd::Pointer *extraPointers, sd::LongType hash, sd::Pointer *inputBuffers,
                                      sd::Pointer *inputShapes, int numInputShapes, double *tArgs, int numTArgs,
                                      sd::LongType *iArgs, int numIArgs, bool *bArgs, int numBArgs, int *dArgs,
                                      int numDArgs) {
  try {
    auto op = sd::ops::OpRegistrator::getInstance().getOperation(hash);

    return _calculateOutputShapes(extraPointers, op, inputBuffers, inputShapes, numInputShapes, tArgs, numTArgs, iArgs,
                                  numIArgs, bArgs, numBArgs, dArgs, numDArgs);
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
    return nullptr;
  }
}

sd::ShapeList *_calculateOutputShapes(sd::Pointer *extraPointers, sd::ops::DeclarableOp *op, sd::Pointer *inputShapes,
                                      int numInputShapes, double *tArgs, int numTArgs, sd::LongType *iArgs,
                                      int numIArgs) {
  Context block(1);
  sd::ShapeList inShapes;

  for (int e = 0; e < numIArgs; e++) block.getIArguments()->push_back(iArgs[e]);

  for (int e = 0; e < numTArgs; e++) block.getTArguments()->push_back(tArgs[e]);

  for (int e = 0; e < numInputShapes; e++) inShapes.push_back(reinterpret_cast<sd::LongType *>(inputShapes[e]));

  auto shapeList = op->calculateOutputShape(&inShapes, block);

  return shapeList;
}

sd::ShapeList *calculateOutputShapes(sd::Pointer *extraPointers, sd::LongType hash, sd::Pointer *inputShapes,
                                     int numInputShapes, double *tArgs, int numTArgs, sd::LongType *iArgs,
                                     int numIArgs) {
  try {
    auto op = sd::ops::OpRegistrator::getInstance().getOperation(hash);

    return _calculateOutputShapes(extraPointers, op, inputShapes, numInputShapes, tArgs, numTArgs, iArgs, numIArgs);
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
    return nullptr;
  }
}

sd::LongType getShapeListSize(sd::ShapeList *list) { return list->size(); }

sd::LongType const *getShape(sd::ShapeList *list, sd::LongType i) { return list->at(i); }

static SD_INLINE sd::Status realExec(sd::ops::DeclarableOp *op, sd::Pointer *extraPointers, sd::LongType hash,
                                     sd::Pointer *inputBuffers, sd::Pointer *inputShapes, int numInputs,
                                     sd::Pointer *outputBuffers, sd::Pointer *outputShapes, int numOutputs,
                                     double *tArgs, int numTArgs, sd::LongType *iArgs, int numIArgs, bool *bArgs,
                                     int numBArgs, bool isInplace) {
  if (op == nullptr) sd_printf("Can't find requested operation: [%lld]\n", hash);

  // we're using the same fake nodeId everywhere here

  std::vector<sd::NDArray *> inputs(numInputs);
  std::vector<sd::NDArray *> outputs(numOutputs);
  std::vector<double> ttArgs(numTArgs);
  std::vector<bool> bbArgs(numBArgs);
  std::vector<sd::LongType> iiArgs(numIArgs);

  // filling block now with inputs
  for (int e = 0; e < numInputs; e++) {
    auto shape = reinterpret_cast<sd::LongType *>(inputShapes[e]);
    void *buffer = sd::ArrayOptions::arrayType(shape) == ArrayType::EMPTY ? nullptr : inputBuffers[e];
    void *bufferD = sd::ArrayOptions::arrayType(shape) == ArrayType::EMPTY ? nullptr : inputBuffers[e + numInputs];

    inputs[e] = new sd::NDArray(buffer, bufferD, shape);
  }

  // if not inplace - transferring output arrays

  if (!isInplace)
    for (int e = 0; e < numOutputs; e++) {
      // we want to keep original output shape intact
      auto shape = shape::copyShape(reinterpret_cast<sd::LongType *>(outputShapes[e]));
      void *buffer = sd::ArrayOptions::arrayType(shape) == ArrayType::EMPTY ? nullptr : outputBuffers[e];
      void *bufferD = sd::ArrayOptions::arrayType(shape) == ArrayType::EMPTY ? nullptr : outputBuffers[e + numOutputs];

      // FIXME: revisit this.
      bool canNullify = true;
      for (int i = 0; i < numInputs; i++) {
        void *ibuffer = sd::ArrayOptions::arrayType(shape) == ArrayType::EMPTY ? nullptr : inputBuffers[i];
        if (ibuffer == buffer) {
          canNullify = false;
          break;
        }
      }

      if (canNullify && buffer != nullptr)
        memset((uint8_t *)buffer, '\0',
               shape::length(shape) * DataTypeUtils::sizeOfElement(ArrayOptions::dataType(shape)));

      auto array = new sd::NDArray(buffer, bufferD, shape);
      outputs[e] = array;
    }

  for (int e = 0; e < numIArgs; e++) iiArgs[e] = iArgs[e];

  for (int e = 0; e < numTArgs; e++) ttArgs[e] = tArgs[e];

  for (int e = 0; e < numBArgs; e++) bbArgs[e] = bArgs[e];

  // hypothetically at this point we have everything filled
  auto dZ = op->execute(inputs, outputs, ttArgs, iiArgs, bbArgs, std::vector<sd::DataType>(), isInplace);
  // auto dZ = op->execute(inputs, ttArgs, iiArgs, isInplace);

  if (!isInplace)
    for (int e = 0; e < numOutputs; e++) {
      if (outputs[e]->ordering() != shape::order(reinterpret_cast<sd::LongType *>(outputShapes[e])))
        outputs[e]->streamline(shape::order(reinterpret_cast<sd::LongType *>(outputShapes[e])));
    }

  for (auto v : inputs) delete v;

  for (auto v : outputs) delete v;

  return Status::OK;
}

Status execCustomOp(sd::Pointer *extraPointers, sd::LongType hash, sd::Pointer *inputBuffers, sd::Pointer *inputShapes,
                    int numInputs, sd::Pointer *outputBuffers, sd::Pointer *outputShapes, int numOutputs, double *tArgs,
                    int numTArgs, sd::LongType *iArgs, int numIArgs, bool *bArgs, int numBArgs, bool isInplace) {
  try {
    auto op = sd::ops::OpRegistrator::getInstance().getOperation(hash);

    return realExec(op, extraPointers, hash, inputBuffers, inputShapes, numInputs, outputBuffers, outputShapes,
                    numOutputs, tArgs, numTArgs, iArgs, numIArgs, bArgs, numBArgs, isInplace);
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
    return Status::BAD_INPUT;
  }
}

Status execCustomOp2(sd::Pointer *extraPointers, sd::LongType hash, sd::Pointer opContext) {
  try {
    auto op = sd::ops::OpRegistrator::getInstance().getOperation(hash);
    auto context = reinterpret_cast<Context *>(opContext);

    auto result = op->execute(context);

    auto res = cudaStreamSynchronize(*context->launchContext()->getCudaStream());
    if (res != 0) throw sd::cuda_exception::build("customOp execution failed", res);

    for (auto v : context->fastpath_in()) {
      if (!v->isEmpty()) v->syncToDevice();
    }

    for (auto v : context->fastpath_out()) {
      if (!v->isEmpty()) v->syncToDevice();
    }

    return result;
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
    return Status::BAD_INPUT;
  }
}

Status registerGraph(sd::Pointer *extraPointers, sd::LongType graphId, sd::Pointer flatBufferPointer) {
  try {
    auto graph = sd::graph::GraphExecutioner::importFromFlatPointer(flatBufferPointer);

    sd::graph::GraphHolder::getInstance().registerGraph(graphId, graph);

    return Status::OK;
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
    return Status::BAD_INPUT;
  }
}

static VariablesSet *executeStoredGraphT(sd::Pointer *extraPointers, sd::LongType graphId, sd::Pointer *inputBuffers,
                                         sd::Pointer *inputShapes, int *inputIndices, int numInputs) {
  auto graph = sd::graph::GraphHolder::getInstance().pullGraph(graphId);
  auto varSpace = graph->getVariableSpace()->clone();

  std::vector<sd::NDArray *> handles;

  for (int e = 0; e < numInputs; e++) {
    auto idx = inputIndices[e];

    // we'll delete this array later, together with cloned VariableSpace
    auto array = new sd::NDArray(inputBuffers[e], reinterpret_cast<sd::LongType *>(inputShapes[e]));
    handles.emplace_back(array);

    if (varSpace->hasVariable(idx)) {
      auto var = varSpace->getVariable(idx);
      if (var->hasNDArray()) delete var->getNDArray();

      var->setNDArray(array);
    } else
      varSpace->putVariable(idx, array);
  }

  auto dZ = sd::graph::GraphExecutioner::execute(graph, varSpace);
  auto varSet = new sd::graph::VariablesSet(dZ);

  if (dZ == Status::OK) {
    // pull back results, and provide them
    auto outputs = graph->fetchOutputs();
    for (int e = 0; e < outputs->size(); e++) {
      // we're only getting variable ID/Index from original grap. values will be taken from cloned workspace
      std::pair<int, int> varId(outputs->at(e)->id(), outputs->at(e)->index());

      auto var = varSpace->getVariable(varId);

      varSet->push_back(var->clone());
    }

    delete outputs;
  }

  delete varSpace;

  return varSet;
}

VariablesSet *executeStoredGraph(sd::Pointer *extraPointers, sd::LongType graphId, sd::Pointer *inputBuffers,
                                 sd::Pointer *inputShapes, int *inputIndices, int numInputs) {
  try {
    return executeStoredGraphT(extraPointers, graphId, inputBuffers, inputShapes, inputIndices, numInputs);
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
    return nullptr;
  }
}

sd::LongType getVariablesSetSize(sd::graph::VariablesSet *set) { return set->size(); }

sd::Status getVariablesSetStatus(sd::graph::VariablesSet *set) { return set->status(); }

sd::graph::Variable *getVariable(sd::graph::VariablesSet *set, sd::LongType i) { return set->at(i); }

int getVariableId(sd::graph::Variable *variable) { return variable->id(); }

int getVariableIndex(sd::graph::Variable *variable) { return variable->index(); }

const char *getVariableName(sd::graph::Variable *variable) { return variable->getName()->c_str(); }

sd::LongType const *getVariableShape(sd::graph::Variable *variable) { return variable->getNDArray()->shapeInfo(); }

void *getVariableBuffer(sd::graph::Variable *variable) { return variable->getNDArray()->buffer(); }

sd::Status unregisterGraph(sd::Pointer *extraPointers, sd::LongType graphId) {
  try {
    sd::graph::GraphHolder::getInstance().dropGraphAny(graphId);

    return Status::OK;
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
    return Status::BAD_INPUT;
  }
}

void deletePointerArray(sd::Pointer pointer) {
  sd::Pointer *ptr = reinterpret_cast<sd::Pointer *>(pointer);
  delete[] ptr;
}

void deleteCharArray(sd::Pointer pointer) {
  auto ptr = reinterpret_cast<char *>(pointer);
  delete[] ptr;
}

void deleteIntArray(sd::Pointer pointer) {
  auto ptr = reinterpret_cast<int *>(pointer);
  delete[] ptr;
}

void deleteLongArray(sd::Pointer pointer) {
  auto ptr = reinterpret_cast<sd::LongType *>(pointer);
  delete[] ptr;
}

void deleteVariablesSet(sd::graph::VariablesSet *pointer) { delete pointer; }

void deleteShapeList(sd::Pointer shapeList) {
  sd::ShapeList *list = reinterpret_cast<sd::ShapeList *>(shapeList);

  // list->destroy();
  delete list;
}

const char *getAllOperations() { return sd::OpTracker::getInstance().exportOperations(); }

sd::Pointer getGraphState(sd::LongType id) { return (sd::Pointer) new sd::graph::GraphState(id); }

void deleteGraphState(sd::Pointer state) {
  auto stateP = reinterpret_cast<sd::graph::GraphState *>(state);
  delete stateP;
}

sd::Status execCustomOpWithScope(sd::Pointer *extraPointers, sd::graph::GraphState *state, sd::LongType opHash,
                                 sd::LongType *scopes, int numScopes, sd::Pointer *inputBuffers,
                                 sd::Pointer *inputShapes, int numInputs, sd::Pointer *outputBuffers,
                                 sd::Pointer *outputShapes, int numOutputs) {
  /**
   * That's basically exec, with VariableSpace provided in GraphState:
   * depending on operation (i.e. while of if), different logic executors could be used
   */

  auto graph = state->graph();
  auto varSpace = state->variableSpace();

  // Node is dynamically created, and has nothing beyond it: only inputs and outputs
  // this node has id of 0, and inputs are
  Node node(OpType_LOGIC, opHash, 0);

  // mapping inputs
  for (int e = 0; e < numInputs; e++) {
    auto buffer = inputBuffers[e];
    auto shapeInfo = reinterpret_cast<sd::LongType *>(inputShapes[e]);

    auto array = new sd::NDArray(buffer, shapeInfo, varSpace->launchContext());

    // now we just put array to VarSpace
    varSpace->putVariable(0, e, array);
    node.pickInput(0, e);
  }

  // mapping scopes
  for (int e = 0; e < numScopes; e++) {
    // we should check scope existence in GraphState/Graph
    int scopeId = (int)scopes[e];
    if (!state->hasScope(scopeId)) {
      // sd_printf("execCustomOpWithScope: referenced scope [%i] doesn't exist\n", scopeId);
      return Logger::logKernelFailureMsg();
    }
    node.pickInput(scopeId, 0);
  }

  auto dZ = LogicExecutor::processNode(graph, &node);
  if (dZ != Status::OK) return dZ;

  // mapping outputs

  for (int e = 0; e < numOutputs; e++) {
    auto buffer = outputBuffers[e];
    auto shapeInfo = reinterpret_cast<sd::LongType *>(outputShapes[e]);

    NDArray array(buffer, shapeInfo, varSpace->launchContext());

    // now we just put array to VarSpace to the same ID
    // varSpace->putVariable(0, e, array);

    auto t = varSpace->getVariable(0, e)->getNDArray();
    array.assign(t);
  }

  // removing input variables
  for (int e = 0; e < numInputs; e++) {
    varSpace->dropVariable(0, e);
  }

  // after some bla-bla-bla we should have Graph and Node for current op
  return Status::OK;
}

sd::Status execCustomOpWithScope(sd::Pointer *extraPointers, sd::Pointer state, sd::LongType opHash,
                                 sd::LongType *scopes, int numScopes, sd::Pointer *inputBuffers,
                                 sd::Pointer *inputShapes, int numInputs, sd::Pointer *outputBuffers,
                                 sd::Pointer *outputShapes, int numOutputs) {
  try {
    return execCustomOpWithScope(extraPointers, reinterpret_cast<sd::graph::GraphState *>(state), opHash, scopes,
                                 numScopes, inputBuffers, inputShapes, numInputs, outputBuffers, outputShapes,
                                 numOutputs);
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
    return sd::Status::BAD_INPUT;
  }
}

void deleteResultWrapper(sd::Pointer ptr) {
  // just 0 room for compiler s@!t
  auto p = reinterpret_cast<sd::graph::ResultWrapper *>(ptr);
  delete p;
}

int estimateThreshold(sd::Pointer *extraPointers, sd::Pointer dX, sd::LongType const *dXShapeInfo, int N,
                      float threshold) {
  throw std::runtime_error("estimateThreshold: Not implemented yet");
}

/*
 * TypeDef:
 *     void convertTypes(sd::Pointer *extras, int srcType, sd::Pointer dX, long N, int dstType, sd::Pointer dZ);
 */
void convertTypes(sd::Pointer *extras, int srcType, sd::Pointer dX, sd::LongType N, int dstType, sd::Pointer dZ) {
  try {
    auto dx = reinterpret_cast<void *>(dX);
    auto dz = reinterpret_cast<void *>(dZ);

    if (srcType == ND4J_FLOAT8) {
      if (dstType == ND4J_FLOAT8) {
        // convertKernel<double, sd::float8>(extras, dx, N, dz);
      } else if (dstType == ND4J_INT8) {
        // sd::TypeCast::convertGenericCuda<sd::float8, sd::int8>(extras, dx, N, dz);
      } else if (dstType == ND4J_UINT8) {
        // sd::TypeCast::convertGenericCuda<sd::float8, sd::uint8>(extras, dx, N, dz);
      } else if (dstType == ND4J_FLOAT16) {
        // sd::TypeCast::convertGenericCuda<sd::float8, float16>(extras, dx, N, dz);
      } else if (dstType == ND4J_INT16) {
        // sd::TypeCast::convertGenericCuda<sd::float8, sd::int16>(extras, dx, N, dz);
      } else if (dstType == ND4J_UINT16) {
        // sd::TypeCast::convertGenericCuda<sd::float8, sd::uint16>(extras, dx, N, dz);
      } else if (dstType == ND4J_FLOAT24) {
      } else if (dstType == ND4J_FLOAT32) {
        // sd::TypeCast::convertGenericCuda<sd::float8, float>(extras, dx, N, dz);
      } else if (dstType == ND4J_DOUBLE) {
        // sd::TypeCast::convertGenericCuda<sd::float8, double>(extras, dx, N, dz);
      } else {
        sd_printf("Unsupported types conversion: [%i] -> [%i]\n", srcType, dstType);
      }
    } else if (srcType == ND4J_INT8) {
      if (dstType == ND4J_FLOAT8) {
        // sd::TypeCast::convertGenericCuda<sd::int8, sd::float8>(extras, dx, N, dz);
      } else if (dstType == ND4J_INT8) {
        // convertKernel<sd::int8, sd::int8>(extras, dx, N, dz);
      } else if (dstType == ND4J_UINT8) {
        sd::TypeCast::convertGenericCuda<int8_t, uint8_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_FLOAT16) {
        sd::TypeCast::convertGenericCuda<int8_t, float16>(extras, dx, N, dz);
      } else if (dstType == ND4J_INT16) {
        sd::TypeCast::convertGenericCuda<int8_t, int16_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_UINT16) {
        sd::TypeCast::convertGenericCuda<int8_t, uint16_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_FLOAT24) {
        // TODO: eventually we might want to add it
      } else if (dstType == ND4J_FLOAT32) {
        sd::TypeCast::convertGenericCuda<int8_t, float>(extras, dx, N, dz);
      } else if (dstType == ND4J_DOUBLE) {
        sd::TypeCast::convertGenericCuda<int8_t, double>(extras, dx, N, dz);
      } else {
        sd_printf("Unsupported types conversion: [%i] -> [%i]\n", srcType, dstType);
      }
    } else if (srcType == ND4J_UINT8) {
      if (dstType == ND4J_FLOAT8) {
        // sd::TypeCast::convertGenericCuda<uint8_t, sd::float8>(extras, dx, N, dz);
      } else if (dstType == ND4J_INT8) {
        sd::TypeCast::convertGenericCuda<uint8_t, int8_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_UINT8) {
        sd::TypeCast::convertGenericCuda<uint8_t, uint8_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_FLOAT16) {
        sd::TypeCast::convertGenericCuda<uint8_t, float16>(extras, dx, N, dz);
      } else if (dstType == ND4J_INT16) {
        sd::TypeCast::convertGenericCuda<uint8_t, int16_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_UINT16) {
        sd::TypeCast::convertGenericCuda<uint8_t, uint16_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_FLOAT24) {
        // TODO: still might want to add
      } else if (dstType == ND4J_FLOAT32) {
        sd::TypeCast::convertGenericCuda<uint8_t, float>(extras, dx, N, dz);
      } else if (dstType == ND4J_DOUBLE) {
        sd::TypeCast::convertGenericCuda<uint8_t, double>(extras, dx, N, dz);
      } else {
        sd_printf("Unsupported types conversion: [%i] -> [%i]\n", srcType, dstType);
      }
    } else if (srcType == ND4J_FLOAT16) {
      if (dstType == ND4J_FLOAT8) {
        // sd::TypeCast::convertGenericCuda<float16, sd::float8>(extras, dx, N, dz);
      } else if (dstType == ND4J_INT8) {
        sd::TypeCast::convertGenericCuda<float16, int8_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_UINT8) {
        sd::TypeCast::convertGenericCuda<float16, uint8_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_FLOAT16) {
        sd::TypeCast::convertGenericCuda<float16, float16>(extras, dx, N, dz);
      } else if (dstType == ND4J_INT16) {
        sd::TypeCast::convertGenericCuda<float16, int16_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_UINT16) {
        sd::TypeCast::convertGenericCuda<float16, uint16_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_FLOAT24) {
        // TODO: .... ^^^
      } else if (dstType == ND4J_FLOAT32) {
        sd::TypeCast::convertGenericCuda<float16, float>(extras, dx, N, dz);
      } else if (dstType == ND4J_DOUBLE) {
        sd::TypeCast::convertGenericCuda<float16, double>(extras, dx, N, dz);
      } else if (dstType == ND4J_THRESHOLD) {
        // sd::convertToThreshold<float16>(nullptr, dx, N, dz);
      } else {
        sd_printf("Unsupported types conversion: [%i] -> [%i]\n", srcType, dstType);
      }
    } else if (srcType == ND4J_INT16) {
      if (dstType == ND4J_FLOAT8) {
        // sd::TypeCast::convertGenericCuda<int16_t, sd::float8>(extras, dx, N, dz);
      } else if (dstType == ND4J_INT8) {
        sd::TypeCast::convertGenericCuda<int16_t, int8_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_UINT8) {
        sd::TypeCast::convertGenericCuda<int16_t, uint8_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_FLOAT16) {
        sd::TypeCast::convertGenericCuda<int16_t, float16>(extras, dx, N, dz);
      } else if (dstType == ND4J_INT16) {
        sd::TypeCast::convertGenericCuda<int16_t, int16_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_UINT16) {
        sd::TypeCast::convertGenericCuda<int16_t, uint16_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_FLOAT24) {
        // TODO...
      } else if (dstType == ND4J_FLOAT32) {
        sd::TypeCast::convertGenericCuda<int16_t, float>(extras, dx, N, dz);
      } else if (dstType == ND4J_DOUBLE) {
        sd::TypeCast::convertGenericCuda<int16_t, double>(extras, dx, N, dz);
      } else {
        printf("Unsupported types conversion: [%i] -> [%i]\n", srcType, dstType);
      }
    } else if (srcType == ND4J_FLOAT24) {
    } else if (srcType == ND4J_FLOAT32) {
      if (dstType == ND4J_FLOAT8) {
        // sd::TypeCast::convertGenericCuda<float, sd::float8>(extras, dx, N, dz);
      } else if (dstType == ND4J_INT8) {
        sd::TypeCast::convertGenericCuda<float, int8_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_UINT8) {
        sd::TypeCast::convertGenericCuda<float, uint8_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_FLOAT16) {
        sd::TypeCast::convertGenericCuda<float, float16>(extras, dx, N, dz);
      } else if (dstType == ND4J_INT16) {
        sd::TypeCast::convertGenericCuda<float, int16_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_UINT16) {
        sd::TypeCast::convertGenericCuda<float, uint16_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_FLOAT24) {
      } else if (dstType == ND4J_DOUBLE) {
        sd::TypeCast::convertGenericCuda<float, double>(extras, dx, N, dz);
      } else if (dstType == ND4J_THRESHOLD) {
        // sd::convertToThreshold<float>(nullptr, dx, N, dz);
      } else {
        sd_printf("Unsupported types conversion: [%i] -> [%i]\n", srcType, dstType);
      }
    } else if (srcType == ND4J_DOUBLE) {
      if (dstType == ND4J_FLOAT8) {
        // sd::TypeCast::convertGenericCuda<double, sd::float8>(extras, dx, N, dz);
      } else if (dstType == ND4J_INT8) {
        sd::TypeCast::convertGenericCuda<double, int8_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_UINT8) {
        sd::TypeCast::convertGenericCuda<double, uint8_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_FLOAT16) {
        sd::TypeCast::convertGenericCuda<double, float16>(extras, dx, N, dz);
      } else if (dstType == ND4J_INT16) {
        sd::TypeCast::convertGenericCuda<double, int16_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_UINT16) {
        sd::TypeCast::convertGenericCuda<double, uint16_t>(extras, dx, N, dz);
      } else if (dstType == ND4J_FLOAT24) {
      } else if (dstType == ND4J_FLOAT32) {
        sd::TypeCast::convertGenericCuda<double, float>(extras, dx, N, dz);
      } else if (dstType == ND4J_DOUBLE) {
        //
      } else if (dstType == ND4J_THRESHOLD) {
        // sd::convertToThreshold<double>(nullptr, dx, N, dz);
      } else {
        sd_printf("Unsupported types conversion: [%i] -> [%i]\n", srcType, dstType);
      }
    } else if (srcType == ND4J_THRESHOLD) {
      if (dstType == ND4J_FLOAT16) {
        // sd::convertFromThreshold<float16>(nullptr, dx, N, dz);
      } else if (dstType == ND4J_FLOAT32) {
        // sd::convertFromThreshold<float>(nullptr, dx, N, dz);
      } else if (dstType == ND4J_DOUBLE) {
        // sd::convertFromThreshold<double>(nullptr, dx, N, dz);
      } else {
        sd_printf("Unsupported types conversion: [%i] -> [%i]\n", srcType, dstType);
      }
    } else {
      sd_printf("Unsupported types conversion: [%i] -> [%i]\n", srcType, dstType);
    }
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

sd::Pointer createUtf8String(sd::Pointer *extraPointers, const char *string, int length) {
  auto u = new sd::utf8string(string, length);
  return reinterpret_cast<sd::Pointer>(u);
}

sd::LongType getUtf8StringLength(sd::Pointer *extraPointers, sd::Pointer ptr) {
  return reinterpret_cast<sd::utf8string *>(ptr)->_length;
}
char *getUtf8StringBuffer(sd::Pointer *extraPointers, sd::Pointer ptr) {
  return reinterpret_cast<sd::utf8string *>(ptr)->_buffer;
}

void deleteUtf8String(sd::Pointer *extraPointers, sd::Pointer ptr) { delete (reinterpret_cast<sd::utf8string *>(ptr)); }

///////////////////////////////////////////////////////////////////
template <typename T, typename I>
SD_KERNEL static void scatterUpdateCuda(const int opCode, const int numOfSubArrs, void *vx,
                                        const sd::LongType *xShapeInfo, const sd::LongType *xOffsets, void *vy,
                                        const sd::LongType *yShapeInfo, const sd::LongType *yOffsets,
                                        const void *vindexes) {
  __shared__ T *x, *y;
  __shared__ sd::LongType arrLenX, arrLenY;
  auto indexes = reinterpret_cast<const I *>(vindexes);

  for (int e = 0; e < numOfSubArrs; e++) {
    const auto xIndex = indexes[e];
    const bool isOwner = xIndex < gridDim.x ? blockIdx.x == xIndex : blockIdx.x == xIndex % gridDim.x;

    if (!isOwner) continue;

    if (threadIdx.x == 0) {
      x = reinterpret_cast<T *>(vx) + xOffsets[xIndex];
      y = reinterpret_cast<T *>(vy) + yOffsets[e];
      arrLenX = shape::length(xShapeInfo);
      arrLenY = shape::length(yShapeInfo);
    }
    __syncthreads();

    if (arrLenX != arrLenY) return;

    for (sd::LongType i = threadIdx.x; i < arrLenX; i += blockDim.x) {
      const auto xOffset = shape::getIndexOffset(i, xShapeInfo);
      const auto yOffset = shape::getIndexOffset(i, yShapeInfo);

      switch (opCode) {
        case 0:
          x[xOffset] += y[yOffset];
          break;
        case 1:
          x[xOffset] -= y[yOffset];
          break;
        case 2:
          x[xOffset] *= y[yOffset];
          break;
        case 3:
          x[xOffset] /= y[yOffset];
          break;
        case 4:
          x[xOffset] = y[yOffset] - x[xOffset];
          break;
        case 5:
          x[xOffset] = y[yOffset] / x[xOffset];
          break;
        case 6:
          x[xOffset] = y[yOffset];
          break;
        default:
          continue;
      }
    }
    __syncthreads();
  }
}

template <typename T, typename I>
SD_HOST static void scatterUpdateCudaLauncher(const cudaStream_t *stream, const int opCode, const int numOfSubArrs,
                                              void *vx, const sd::LongType const *xShapeInfo,
                                              const sd::LongType *xOffsets, void *vy, const sd::LongType *yShapeInfo,
                                              const sd::LongType *yOffsets, const void *indexes) {
  scatterUpdateCuda<T, I><<<512, 256, SD_MAX_NUM_THREADS, *stream>>>(opCode, numOfSubArrs, vx, xShapeInfo, xOffsets, vy,
                                                                     yShapeInfo, yOffsets, indexes);
}

//////////////////////////////////////////////////////////////////////////
void scatterUpdate(sd::Pointer *extraPointers, int opCode, int numOfSubArrs, void *hX, sd::LongType const *hXShapeInfo,
                   sd::LongType const *hXOffsets, void *dX, sd::LongType const *dXShapeInfo,
                   sd::LongType const *dXOffsets, void *hY, sd::LongType const *hYShapeInfo,
                   sd::LongType const *hYOffsets, void *dY, sd::LongType const *dYShapeInfo,
                   sd::LongType const *dYOffsets, void *hIindexes, sd::LongType const *hIndicesShapeInfo,
                   void *dIindexes, sd::LongType const *dIndicesShapeInfo) {
  try {
    auto stream = reinterpret_cast<cudaStream_t *>(extraPointers[1]);

    auto type = ArrayOptions::dataType(hXShapeInfo);
    auto iType = ArrayOptions::dataType(hIndicesShapeInfo);

    BUILD_DOUBLE_SELECTOR(
        type, iType, scatterUpdateCudaLauncher,
        (stream, opCode, numOfSubArrs, dX, dXShapeInfo, dXOffsets, dY, dYShapeInfo, dYOffsets, dIindexes),
        SD_COMMON_TYPES, SD_INDEXING_TYPES);

    sd::DebugHelper::checkErrorCode(stream, "scatterUpdate(...) failed");
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void inspectArray(sd::Pointer *extraPointers, sd::Pointer buffer, sd::LongType *shapeInfo, sd::Pointer specialBuffer,
                  sd::LongType *specialShapeInfo, sd::Pointer debugInfo) {
  try {
    LaunchContext lc(extraPointers[1], extraPointers[4], extraPointers[5], extraPointers[3]);
    auto p = reinterpret_cast<sd::DebugInfo *>(debugInfo);
    NDArray array(buffer, specialBuffer, shapeInfo, &lc);
    sd::DebugHelper::retrieveDebugStatistics(p, &array);
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

void SD_KERNEL tryPointerKernel(void *p, int len) {
  auto buf = reinterpret_cast<int8_t *>(p);
  auto tid = threadIdx.x + blockIdx.x * blockDim.x;
  __shared__ int b;
  if (tid < len) atomicAdd(&b, buf[tid]);

  __syncthreads();

  if (threadIdx.x == 0 && blockIdx.x == 0) printf("Pointer check complete: %i\n", b);
}

void tryPointer(sd::Pointer extra, sd::Pointer p, int len) {
  try {
    cudaStream_t stream;
    cudaStreamCreate(&stream);

    tryPointerKernel<<<256, 512, len + 64, stream>>>(p, len);
    auto e = cudaStreamSynchronize(stream);

    if (e != 0) throw sd::cuda_exception::build("tryPointer failed", e);

    cudaStreamDestroy(stream);
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

int dataTypeFromNpyHeader(void *header) { return (int)cnpy::dataTypeFromHeader(reinterpret_cast<char *>(header)); }

OpaqueConstantShapeBuffer *shapeBuffer(int rank, sd::LongType *shape, sd::LongType *strides, sd::DataType dtype,
                                       char order, sd::LongType ews, bool empty) {
  return shapeBufferEx(rank, shape, strides, dtype, order, ews, empty ? ARRAY_EMPTY : 0);
}

OpaqueConstantShapeBuffer *shapeBufferEx(int rank, sd::LongType *shape, sd::LongType *strides, sd::DataType dtype,
                                         char order, sd::LongType ews, sd::LongType extras) {
  try {
    auto buffer = new ConstantShapeBuffer();
    *buffer = sd::ConstantShapeHelper::getInstance().bufferForShapeInfo(
        ShapeDescriptor(dtype, order, shape, strides, rank, ews, extras));
    return buffer;
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
    return nullptr;
  }
}

void deleteConstantShapeBuffer(OpaqueConstantShapeBuffer *ptr) { delete ptr; }

void deleteConstantDataBuffer(OpaqueConstantDataBuffer *ptr) { delete ptr; }

void deleteTadPack(sd::TadPack *ptr) { delete ptr; }

bool isBlasVersionMatches(int major, int minor, int build) {
  auto result = major == Environment::getInstance()._blasMajorVersion &&
                minor == Environment::getInstance()._blasMinorVersion &&
                build == Environment::getInstance()._blasPatchVersion;

  if (!result) {
    sd_printf("CUDA/cuBLAS version mismatch. Expected: %i.%i.%i but got %i.%i.%i instead\n",
              Environment::getInstance()._blasMajorVersion, Environment::getInstance()._blasMinorVersion,
              Environment::getInstance()._blasPatchVersion, major, minor, build);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(152);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage("CUDA/cuBLAS version mismatch");
  }

  return result;
}

sd::ConstantDataBuffer *constantBufferLong(sd::DataType dtype, sd::LongType const *data, int length) {
  return sd::ConstantHelper::getInstance().constantBuffer(ConstantDescriptor(data, length), dtype);
}

sd::ConstantDataBuffer *constantBufferDouble(sd::DataType dtype, double *data, int length) {
  return sd::ConstantHelper::getInstance().constantBuffer(ConstantDescriptor(data, length), dtype);
}

sd::ConstantDataBuffer *constantBuffer(sd::DataType dtype, sd::ConstantDescriptor *descriptor) {
  return sd::ConstantHelper::getInstance().constantBuffer(*descriptor, dtype);
}

sd::Pointer getConstantDataBufferPrimary(sd::ConstantDataBuffer *dbf) { return dbf->primary(); }
sd::Pointer getConstantDataBufferSpecial(sd::ConstantDataBuffer *dbf) { return dbf->special(); }
sd::LongType getConstantDataBufferLength(sd::ConstantDataBuffer *dbf) { return dbf->length(); }
sd::LongType getConstantDataBufferSizeOf(sd::ConstantDataBuffer *dbf) { return dbf->sizeOf(); }

sd::Pointer getConstantShapeBufferPrimary(OpaqueConstantShapeBuffer *dbf) {
  return const_cast<sd::LongType *>(dbf->primary());
}

sd::Pointer getConstantShapeBufferSpecial(OpaqueConstantShapeBuffer *dbf) {
  return const_cast<sd::LongType *>(dbf->special());
}

sd::graph::Context *createGraphContext(int nodeId) { return new sd::graph::Context(nodeId); }

sd::graph::RandomGenerator *getGraphContextRandomGenerator(sd::graph::Context *ptr) { return &ptr->randomGenerator(); }

void markGraphContextInplace(sd::graph::Context *ptr, bool reallyInplace) { ptr->markInplace(reallyInplace); }

void setGraphContextCudaContext(sd::graph::Context *ptr, void *stream, void *reductionPointer,
                                void *allocationPointer) {
  ptr->setCudaContext(stream, reductionPointer, allocationPointer);
}

void setGraphContextInputArray(sd::graph::Context *ptr, int index, void *buffer, void *shapeInfo, void *specialBuffer,
                               void *specialShapeInfo) {
  ptr->setInputArray(index, buffer, shapeInfo, specialBuffer, specialShapeInfo);
}

void setGraphContextOutputArray(sd::graph::Context *ptr, int index, void *buffer, void *shapeInfo, void *specialBuffer,
                                void *specialShapeInfo) {
  ptr->setOutputArray(index, buffer, shapeInfo, specialBuffer, specialShapeInfo);
}

void setGraphContextInputBuffer(OpaqueContext *ptr, int index, OpaqueDataBuffer *buffer, void *shapeInfo,
                                void *specialShapeInfo) {
  ptr->setInputArray(index, buffer, shapeInfo, specialShapeInfo);
}

void setGraphContextOutputBuffer(OpaqueContext *ptr, int index, OpaqueDataBuffer *buffer, void *shapeInfo,
                                 void *specialShapeInfo) {
  ptr->setOutputArray(index, buffer, shapeInfo, specialShapeInfo);
}

void setGraphContextTArguments(sd::graph::Context *ptr, double *arguments, int numberOfArguments) {
  ptr->setTArguments(arguments, numberOfArguments);
}

void setGraphContextIArguments(sd::graph::Context *ptr, sd::LongType *arguments, int numberOfArguments) {
  ptr->setIArguments(arguments, numberOfArguments);
}

void setGraphContextBArguments(sd::graph::Context *ptr, bool *arguments, int numberOfArguments) {
  ptr->setBArguments(arguments, numberOfArguments);
}

void setGraphContextDArguments(OpaqueContext *ptr, int *arguments, int numberOfArguments) {
  std::vector<sd::DataType> dtypes(numberOfArguments);
  for (int e = 0; e < numberOfArguments; e++) dtypes[e] = (sd::DataType)arguments[e];

  ptr->setDArguments(dtypes);
}

void deleteGraphContext(sd::graph::Context *ptr) { delete ptr; }

sd::graph::RandomGenerator *createRandomGenerator(sd::LongType rootSeed, sd::LongType nodeSeed) {
  try {
    return new sd::graph::RandomGenerator(rootSeed, nodeSeed);
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
    return nullptr;
  }
}

sd::LongType getRandomGeneratorRootState(sd::graph::RandomGenerator *ptr) { return ptr->rootState(); }

sd::LongType getRandomGeneratorNodeState(sd::graph::RandomGenerator *ptr) { return ptr->nodeState(); }

void setRandomGeneratorStates(sd::graph::RandomGenerator *ptr, sd::LongType rootSeed, sd::LongType nodeSeed) {
  ptr->setStates(rootSeed, nodeSeed);
}

float getRandomGeneratorRelativeFloat(sd::graph::RandomGenerator *ptr, sd::LongType index) {
  return ptr->relativeT<float>(index);
}

double getRandomGeneratorRelativeDouble(sd::graph::RandomGenerator *ptr, sd::LongType index) {
  return ptr->relativeT<double>(index);
}

int getRandomGeneratorRelativeInt(sd::graph::RandomGenerator *ptr, sd::LongType index) {
  return ptr->relativeInt(index);
}

sd::LongType getRandomGeneratorRelativeLong(sd::graph::RandomGenerator *ptr, sd::LongType index) {
  return ptr->relativeLong(index);
}

int getRandomGeneratorNextInt(sd::graph::RandomGenerator *ptr) {
  // to nullify  _nodeState._long ^= (steps ^ 0xdeadbeef);
  // we will use step = 0xdeadbeef
  auto result = ptr->relativeInt(1);
  ptr->rewindH(0xdeadbeef);
  return result;
}

sd::LongType getRandomGeneratorNextLong(sd::graph::RandomGenerator *ptr) {
  auto result = ptr->relativeLong(1);
  ptr->rewindH(0xdeadbeef);
  return result;
}

float getRandomGeneratorNextFloat(sd::graph::RandomGenerator *ptr) {
  auto result = ptr->relativeT<float>(1);
  ptr->rewindH(0xdeadbeef);
  return result;
}

double getRandomGeneratorNextDouble(sd::graph::RandomGenerator *ptr) {
  auto result = ptr->relativeT<double>(1);
  ptr->rewindH(0xdeadbeef);
  return result;
}

void deleteRandomGenerator(sd::graph::RandomGenerator *ptr) { delete ptr; }

sd::Pointer shapeBufferForNumpy(sd::Pointer npyArray) {
  try {
    cnpy::NpyArray arr = cnpy::loadNpyFromPointer(reinterpret_cast<char *>(npyArray));
    unsigned int shapeSize = arr.shape.size();
    std::vector<sd::LongType> shape(shapeSize);
    bool _empty = false;
    for (unsigned int i = 0; i < shapeSize; i++) {
      shape[i] = arr.shape[i];

      if (arr.shape[i] == 0) _empty = true;
    }

    auto dtype = cnpy::dataTypeFromHeader(reinterpret_cast<char *>(npyArray));

    sd::LongType *shapeBuffer;
    if (shape.size() == 1 && shape[0] == 0) {
      // scalar case
      shapeBuffer = sd::ShapeBuilders::createScalarShapeInfo(dtype);
    } else if (_empty) {
      if (shapeSize > 0)
        shapeBuffer = sd::ShapeBuilders::emptyShapeInfo(dtype, arr.fortranOrder ? 'f' : 'c', shape);
      else
        shapeBuffer = sd::ShapeBuilders::emptyShapeInfo(dtype);
    } else {
      shapeBuffer = sd::ShapeBuilders::createShapeInfo(dtype, arr.fortranOrder ? 'f' : 'c', shape);
    }
    return (sd::Pointer)(sd::ConstantShapeHelper::getInstance().createFromExisting(
        shapeBuffer, true));  // TO DO: this can lead to unpleasant crash sometimes
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
    return nullptr;
  }
}

sd::LongType getCachedMemory(int deviceId) { return sd::ConstantHelper::getInstance().getCachedAmount(deviceId); }

sd::LaunchContext *defaultLaunchContext() { return LaunchContext::defaultContext(); }

sd::Pointer lcScalarPointer(OpaqueLaunchContext *lc) { return lc->getScalarPointer(); }

sd::Pointer lcReductionPointer(OpaqueLaunchContext *lc) { return lc->getReductionPointer(); }

sd::Pointer lcAllocationPointer(OpaqueLaunchContext *lc) { return lc->getAllocationPointer(); }

sd::Pointer lcExecutionStream(OpaqueLaunchContext *lc) { return lc->getCudaStream(); }

sd::Pointer lcCopyStream(OpaqueLaunchContext *lc) { return lc->getCudaSpecialStream(); }

sd::Pointer lcBlasHandle(OpaqueLaunchContext *lc) { return lc->getCublasHandle(); }

sd::Pointer lcSolverHandle(OpaqueLaunchContext *lc) { return lc->getCusolverHandle(); }

int lastErrorCode() { return sd::LaunchContext::defaultContext()->errorReference()->errorCode(); }

const char *lastErrorMessage() { return sd::LaunchContext::defaultContext()->errorReference()->errorMessage(); }

void ctxShapeFunctionOverride(OpaqueContext *ptr, bool reallyOverride) {
  ptr->setShapeFunctionOverride(reallyOverride);
}

void ctxPurge(OpaqueContext *ptr) { ptr->clearFastPath(); }

int binaryLevel() { return 0; }

int optimalLevel() { return 0; }

bool isMinimalRequirementsMet() { return true; }

bool isOptimalRequirementsMet() { return true; }

void ctxAllowHelpers(OpaqueContext *ptr, bool reallyAllow) { ptr->allowHelpers(reallyAllow); }

void ctxSetExecutionMode(OpaqueContext *ptr, int execMode) {
  if (execMode < 0 || execMode > 2) execMode = 0;

  ptr->setExecutionMode((samediff::ExecutionMode)execMode);
}

OpaqueDataBuffer *dbCreateExternalDataBuffer(sd::LongType elements, int dataType, sd::Pointer primary,
                                             sd::Pointer special) {
  auto buffer = dbAllocateDataBuffer(0, dataType, false);

  if (primary != nullptr) buffer->setPrimary(primary, elements);

  if (special != nullptr) buffer->setSpecial(special, elements);

  return buffer;
}

OpaqueDataBuffer *dbAllocateDataBuffer(sd::LongType elements, int dataType, bool allocateBoth) {
  return allocateDataBuffer(elements, dataType, allocateBoth);
}

OpaqueDataBuffer *allocateDataBuffer(sd::LongType elements, int dataType, bool allocateBoth) {
  try {
    auto dtype = DataTypeUtils::fromInt(dataType);
    return new sd::InteropDataBuffer(elements * DataTypeUtils::sizeOf(dtype), dtype, allocateBoth);
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
    return nullptr;
  }
}

sd::Pointer dbPrimaryBuffer(OpaqueDataBuffer *dataBuffer) { return dataBuffer->primary(); }

sd::Pointer dbSpecialBuffer(OpaqueDataBuffer *dataBuffer) { return dataBuffer->special(); }

void deleteDataBuffer(OpaqueDataBuffer *dataBuffer) { delete dataBuffer; }

void dbSetPrimaryBuffer(OpaqueDataBuffer *dataBuffer, sd::Pointer primaryBuffer, sd::LongType numBytes) {
  dataBuffer->setPrimary(primaryBuffer, numBytes);
}

void dbSetSpecialBuffer(OpaqueDataBuffer *dataBuffer, sd::Pointer specialBuffer, sd::LongType numBytes) {
  dataBuffer->setSpecial(specialBuffer, numBytes);
}

void dbAllocatePrimaryBuffer(OpaqueDataBuffer *dataBuffer) { dataBuffer->dataBuffer()->allocatePrimary(); }

void dbAllocateSpecialBuffer(OpaqueDataBuffer *dataBuffer) { dataBuffer->dataBuffer()->allocateSpecial(); }

void dbExpandBuffer(OpaqueDataBuffer *dataBuffer, sd::LongType elements) {
  try {
    dataBuffer->dataBuffer()->expand(elements * DataTypeUtils::sizeOf(dataBuffer->dataBuffer()->getDataType()));
  } catch (std::exception &e) {
    sd::LaunchContext::defaultContext()->errorReference()->setErrorCode(1);
    sd::LaunchContext::defaultContext()->errorReference()->setErrorMessage(e.what());
  }
}

OpaqueDataBuffer *dbCreateView(OpaqueDataBuffer *dataBuffer, sd::LongType length, sd::LongType offset) {
  return new InteropDataBuffer(*dataBuffer, length, offset);
}

int dbUseCount(OpaqueDataBuffer* dataBuffer){
 if(dataBuffer) return dataBuffer->useCount();
 return 0;
}

void dbSyncToSpecial(OpaqueDataBuffer *dataBuffer) { dataBuffer->dataBuffer()->syncToSpecial(); }

void dbSyncToPrimary(OpaqueDataBuffer *dataBuffer) { dataBuffer->dataBuffer()->syncToPrimary(nullptr); }

void dbTickHostRead(OpaqueDataBuffer *dataBuffer) { dataBuffer->dataBuffer()->readPrimary(); }

void dbTickHostWrite(OpaqueDataBuffer *dataBuffer) { dataBuffer->dataBuffer()->writePrimary(); }

void dbTickDeviceRead(OpaqueDataBuffer *dataBuffer) { dataBuffer->dataBuffer()->readSpecial(); }

void dbTickDeviceWrite(OpaqueDataBuffer *dataBuffer) { dataBuffer->dataBuffer()->writeSpecial(); }

void dbExpand(OpaqueDataBuffer *dataBuffer, sd::LongType elements) { dataBuffer->expand(elements); }

void dbClose(OpaqueDataBuffer *dataBuffer) { dataBuffer->getDataBuffer()->close(); }

int dbDeviceId(OpaqueDataBuffer *dataBuffer) { return dataBuffer->deviceId(); }

void dbSetDeviceId(OpaqueDataBuffer *dataBuffer, int deviceId) { dataBuffer->setDeviceId(deviceId); }

int dbLocality(OpaqueDataBuffer *dataBuffer) {
  auto p = dataBuffer->dataBuffer()->isPrimaryActual();
  auto d = dataBuffer->dataBuffer()->isSpecialActual();

  if (p && d)
    return 0;
  else if (p)
    return -1;
  else
    return 1;
}

void setVedaDeviceLibFolder(std::string path){

}
