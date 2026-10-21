# Builds the software Pancake guest and runs the EEST corpus with Spike.
# Both evm-asm (fixture conversion) and riscv-isa-sim (Spike) must be initialized:
#   git submodule update --init evm-asm riscv-isa-sim
#   docker build -t stateless-pancaketh-eest-spike .

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG EEST_TAG=tests-zkevm@v21.0.1
ARG GIT_COMMIT=unknown
ARG GIT_REF=unknown
ARG BUILD_DATE=unknown
ARG SPIKE_BUILD_JOBS=2

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 build-essential \
    binutils-riscv64-unknown-elf libboost-all-dev \
    device-tree-compiler libssl-dev zlib1g-dev libzstd-dev xxd \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
    | sh -s -- -y --default-toolchain none
ENV PATH="/root/.elan/bin:$PATH"

WORKDIR /stateless-pancaketh
COPY . .

# Compile the driver without registering ZisK precompile CSRs.
RUN test -f riscv-isa-sim/configure && test -f evm-asm/scripts/eest-stateless-to-input.py \
    && mkdir -p riscv-isa-sim/build \
    && cd riscv-isa-sim/build \
    && ../configure \
    && make -j"${SPIKE_BUILD_JOBS}"
RUN SPIKE_ACCEL=0 tools/spike/build.sh
ENV SPIKE_RUN=/stateless-pancaketh/tools/spike/spike_run

# The default guest/build.sh variant implements precompiles in Pancake and
# links a runtime without accelerator CSR stubs.
RUN elan toolchain install "$(cat lean-toolchain)"
RUN mkdir -p guest/build \
    && env -u ACCEL guest/build.sh guest/src/main.pnk guest/build/guest.elf

RUN mkdir -p /usr/local/share/licenses/lean-packages \
    && for pkg_dir in .lake/packages/*/; do \
         pkg_name=$(basename "$pkg_dir"); \
         for f in LICENSE LICENSE.md LICENSE.txt NOTICE NOTICE.md COPYING; do \
           if [ -f "${pkg_dir}${f}" ]; then \
             cp "${pkg_dir}${f}" \
               "/usr/local/share/licenses/lean-packages/${pkg_name}-${f}"; \
             break; \
           fi; \
         done; \
       done \
    && cp riscv-isa-sim/LICENSE /usr/local/share/licenses/riscv-isa-sim-LICENSE

RUN dpkg-query -W --showformat='${Package} ${Version}\n' \
    > /usr/local/share/licenses/ubuntu-packages.txt

RUN curl -sSf \
      https://raw.githubusercontent.com/leanprover/elan/master/LICENSE \
      -o /usr/local/share/licenses/elan-LICENSE.txt \
    || printf 'elan: Apache-2.0\nhttps://github.com/leanprover/elan/blob/master/LICENSE\n' \
      > /usr/local/share/licenses/elan-LICENSE.txt
RUN curl -sSf \
      https://raw.githubusercontent.com/ethereum/execution-spec-tests/main/LICENSE \
      -o /usr/local/share/licenses/eest-LICENSE.txt \
    || printf 'execution-spec-tests: MIT\nhttps://github.com/ethereum/execution-spec-tests/blob/main/LICENSE\n' \
      > /usr/local/share/licenses/eest-LICENSE.txt

RUN canonical_tag="$(tr -d '[:space:]' < eest-fixture-tag.txt)" \
    && if [ "${EEST_TAG}" != "${canonical_tag}" ]; then \
         echo "EEST_TAG=${EEST_TAG} disagrees with eest-fixture-tag.txt=${canonical_tag}" >&2; \
         exit 1; \
       fi \
    && tools/make-inputs.sh --all work/inputs

LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.source="https://github.com/flamingoponderado/stateless-pancaketh"
LABEL org.opencontainers.image.revision="${GIT_COMMIT}"
LABEL org.opencontainers.image.ref.name="${GIT_REF}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL eest.fixture.tag="${EEST_TAG}"

ENTRYPOINT ["python3", "tools/eest-run.py"]
CMD ["guest/build/guest.elf", "work/inputs/manifest.tsv", "--quiet-passes"]
