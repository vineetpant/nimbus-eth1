# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

FROM debian:bullseye-slim AS build

RUN apt-get update \
 && apt-get install -y --fix-missing build-essential make git \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ARG BRANCH_NAME=master
ENV NPROC=2

ENV NIMFLAGS_COMMON="-d:disableMarchNative --gcc.options.debug:'-g1' --clang.options.debug:'-gline-tables-only'"

RUN git clone https://github.com/status-im/nimbus-eth1.git \
 && cd nimbus-eth1 \
 && git checkout ${BRANCH_NAME} \
 && git pull \
 && make -j${NPROC} NIMFLAGS="${NIMFLAGS_COMMON} --parallelBuild:${NPROC}" V=1 update

RUN cd nimbus-eth1 && \
    make -j${NPROC} NIMFLAGS="${NIMFLAGS_COMMON} --parallelBuild:${NPROC}" nimbus_portal_client && \
    mv build/nimbus_portal_client /usr/bin/

# --------------------------------- #
# Starting new image to reduce size #
# --------------------------------- #
FROM debian:bullseye-slim AS deploy

COPY --from=build /usr/bin/nimbus_portal_client /usr/bin/nimbus_portal_client

# Legacy name for backwards compatibility
RUN ln -s /usr/bin/nimbus_portal_client /usr/bin/fluffy

ENTRYPOINT ["/usr/bin/nimbus_portal_client"]
