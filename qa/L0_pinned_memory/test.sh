#!/bin/bash
# Copyright (c) 2019, NVIDIA CORPORATION. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#  * Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#  * Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#  * Neither the name of NVIDIA CORPORATION nor the names of its
#    contributors may be used to endorse or promote products derived
#    from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
# OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

REPO_VERSION=${NVIDIA_TENSORRT_SERVER_VERSION}
if [ "$#" -ge 1 ]; then
    REPO_VERSION=$1
fi
if [ -z "$REPO_VERSION" ]; then
    echo -e "Repository version must be specified"
    echo -e "\n***\n*** Test Failed\n***"
    exit 1
fi

CLIENT=../clients/simple_perf_client
# Only use libtorch as it accepts GPU I/O and it can handle variable shape
BACKENDS=${BACKENDS:="libtorch"}
WARMUP_ITERS=20
MEASURE_ITERS=100
BATCH_SIZE=1

DATADIR=/data/inferenceserver/${REPO_VERSION}

SERVER=/opt/tensorrtserver/bin/trtserver
source ../common/util.sh

# Select the single GPU that will be available to the inference server
export CUDA_VISIBLE_DEVICES=0

rm -f *.log *.serverlog *.csv *.metrics
RET=0

rm -fr ./custom_models && mkdir ./custom_models && \
    cp -r ../custom_models/custom_zero_1_float32 ./custom_models/. && \
    mkdir -p ./custom_models/custom_zero_1_float32/1 && \
    cp ./libidentity.so ./custom_models/custom_zero_1_float32/1/libcustom.so

#
# Use "identity" model for all model types.
#
rm -fr models && mkdir -p models && \
    cp -r ./custom_models/custom_zero_1_float32 models/. && \
        (cd models/custom_zero_1_float32 && \
                sed -i "s/dims:.*\[.*\]/dims: \[ -1 \]/g" config.pbtxt && \
                echo "instance_group [ { kind: KIND_CPU }]" >> config.pbtxt)

for BACKEND in $BACKENDS; do
    MODEL_NAME=${BACKEND}_zero_1_float32
    REPO_DIR=$DATADIR/qa_identity_model_repository

    cp -r $REPO_DIR/$MODEL_NAME models/. && \
        (cd models/$MODEL_NAME && \
            sed -i "s/dims:.*\[.*\]/dims: \[ -1 \]/g" config.pbtxt && \
            echo "instance_group [ { kind: KIND_GPU }]" >> config.pbtxt)
    
    ENSEMBLE_NAME=${BACKEND}_ensemble
    mkdir -p models/$ENSEMBLE_NAME/1 && \
        cp $ENSEMBLE_NAME.pbtxt models/$ENSEMBLE_NAME/config.pbtxt

    # With pinned memory
    SERVER_ARGS="--model-repository=`pwd`/models --log-verbose=1"
    SERVER_LOG="${ENSEMBLE_NAME}.pinned.serverlog"
    run_server
    if (( $SERVER_PID == 0 )); then
        echo -e "\n***\n*** Failed to start $SERVER\n***"
        cat $SERVER_LOG
        exit 1
    fi

    # Sanity check that the server allocates pinned memory for large size
    set +e
    $CLIENT -m${ENSEMBLE_NAME} -b1 -s16777216 -n1
    if (( $? != 0 )); then
        RET=1
    fi

    grep "] non-pinned" ${ENSEMBLE_NAME}.pinned.serverlog
    if [ $? -eq 0 ]; then
        echo -e "\n***\n*** Failed. Expected only pinned memory is allocated\n***"
        RET=1
    fi
    set -e

    kill $SERVER_PID
    wait $SERVER_PID

    # Restart the server without verbose logging
    SERVER_ARGS="--model-repository=`pwd`/models"
    SERVER_LOG="${ENSEMBLE_NAME}.pinned.serverlog"
    run_server
    if (( $SERVER_PID == 0 )); then
        echo -e "\n***\n*** Failed to start $SERVER\n***"
        cat $SERVER_LOG
        exit 1
    fi

    # 16k 1m 2m 4m 8m 16m elements
    set +e
    for TENSOR_SIZE in 16384 1048576 2097152 4194304 8388608 16777216; do
        $CLIENT -i grpc -u localhost:8001 -m${ENSEMBLE_NAME} \
                -b${BATCH_SIZE} -s${TENSOR_SIZE} -n${MEASURE_ITERS} \
                >> ${BACKEND}.${TENSOR_SIZE}.pinned.log 2>&1
        if (( $? != 0 )); then
            RET=1
        fi
    done
    set -e

    kill $SERVER_PID
    wait $SERVER_PID

    # Without pinned memory
    SERVER_ARGS="--model-repository=`pwd`/models --pinned-memory-pool-byte-size=0 --log-verbose=1"
    SERVER_LOG="${ENSEMBLE_NAME}.nonpinned.serverlog"
    run_server
    if (( $SERVER_PID == 0 )); then
        echo -e "\n***\n*** Failed to start $SERVER\n***"
        cat $SERVER_LOG
        exit 1
    fi

    # Sanity check that the server allocates non-pinned memory
    set +e
    $CLIENT -m${ENSEMBLE_NAME} -b1 -s1 -n1
    if (( $? != 0 )); then
        RET=1
    fi

    grep "] pinned" ${ENSEMBLE_NAME}.nonpinned.serverlog
    if [ $? -eq 0 ]; then
        echo -e "\n***\n*** Failed. Expected only non-pinned memory is allocated\n***"
        RET=1
    fi
    set -e

    kill $SERVER_PID
    wait $SERVER_PID

    # Restart the server without verbose logging
    SERVER_ARGS="--model-repository=`pwd`/models --pinned-memory-pool-byte-size=0"
    SERVER_LOG="${ENSEMBLE_NAME}.nonpinned.serverlog"
    run_server
    if (( $SERVER_PID == 0 )); then
        echo -e "\n***\n*** Failed to start $SERVER\n***"
        cat $SERVER_LOG
        exit 1
    fi

    # 16k 1m 2m 4m 8m 16m elements
    set +e
    for TENSOR_SIZE in 16384 1048576 2097152 4194304 8388608 16777216; do
        $CLIENT -i grpc -u localhost:8001 -m${ENSEMBLE_NAME} \
                -b${BATCH_SIZE} -s${TENSOR_SIZE} -n${MEASURE_ITERS} \
                >> ${BACKEND}.${TENSOR_SIZE}.nonpinned.log 2>&1
        if (( $? != 0 )); then
            RET=1
        fi
    done
    set -e

    kill $SERVER_PID
    wait $SERVER_PID
done

for BACKEND in $BACKENDS; do
    for TENSOR_SIZE in 16384 1048576 2097152 4194304 8388608 16777216; do
        echo -e "${BACKEND} ensemble ${TENSOR_SIZE} elements\n"
        echo -e "non-pinned\n"
        cat ${BACKEND}.${TENSOR_SIZE}.nonpinned.log
        echo -e "pinned\n"
        cat ${BACKEND}.${TENSOR_SIZE}.pinned.log
    done
done

if (( $RET == 0 )); then
    echo -e "\n***\n*** Test Passed\n***"
else
    echo -e "\n***\n*** Test FAILED\n***"
fi

exit $RET
