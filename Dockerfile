# Bakes in the flapjack-compiled guest (software + accelerated) and the
# full EEST tests-zkevm fixture corpus, ready to run under ziskemu with no
# further network access. See evm-asm/Dockerfile for the sibling image this
# mirrors (same ziskemu-from-source pattern, same license-collection style).
#
# The `evm-asm` submodule must be initialized in the build context before
# `docker build` (its scripts/{eest-fetch-fixtures.sh,
# eest-stateless-to-input.py} are needed; the fixture tag itself is pinned by
# this repo's eest-fixture-tag.txt; `cakeml`, `flapjack`, and
# `riscv-isa-sim` are not — flapjack is fetched by `lake` itself, and
# `riscv-isa-sim`/`cakeml` are only needed for Spike/cake, not ziskemu):
#
#   git submodule update --init evm-asm
#   docker build -t stateless-pancaketh-eest-ziskemu .

# ── Stage 1: build ziskemu from source ───────────────────────────────────────
FROM ubuntu:24.04 AS ziskemu-builder

ARG ZISK_TAG=v1.3.0-alpha
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential cmake \
    libomp-dev libgmp-dev protobuf-compiler uuid-dev \
    nasm libclang-dev clang \
    libopenmpi-dev openmpi-bin \
    nlohmann-json3-dev \
    libgrpc++-dev libprotobuf-dev \
    libsecp256k1-dev libsodium-dev \
    libpqxx-dev \
    gcc-riscv64-unknown-elf \
    python3 \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:$PATH"

RUN git clone --depth 1 --branch "${ZISK_TAG}" \
    https://github.com/0xPolygonHermez/zisk /zisk
WORKDIR /zisk
# proofman-starks-src's Makefile greps /proc/cpuinfo at build time and adds
# -mavx512f when the *build* machine has AVX-512. GitHub's runner pool mixes
# CPUs with and without it, so the published ziskemu died with SIGILL
# ("Illegal instruction") on any host lacking AVX-512 whenever the image
# happened to be built on an AVX-512 runner. Blank that detection so the C++
# side is built for the same portable baseline on every runner (AVX2 is still
# detected; zisk's own .cargo/config.toml already pins bmi2+adx, a
# Broadwell/Zen1 floor).
RUN cargo fetch \
    && mk="$(ls -d /root/.cargo/registry/src/*/proofman-starks-src-*)/Makefile" \
    && sed -i 's/^\([[:space:]]*AVX512_SUPPORTED := \).*/\1/' "$mk" \
    && grep -n 'AVX512_SUPPORTED :=' "$mk"
RUN cargo build --release -p ziskemu

# Collect zisk project licenses (dual MIT/Apache-2.0) and a per-crate license inventory
RUN mkdir -p /license-report \
    && for f in LICENSE LICENSE.md LICENSE.txt LICENSE-MIT LICENSE-APACHE \
                LICENCE LICENCE.md LICENCE-MIT LICENCE-APACHE COPYING; do \
         if [ -f "/zisk/$f" ]; then cp "/zisk/$f" "/license-report/zisk-${f}"; fi; \
       done \
    && cargo metadata --format-version 1 \
       | python3 -c 'import json,sys; [print(p["name"], p["version"], p.get("license") or "UNKNOWN") for p in sorted(json.load(sys.stdin)["packages"], key=lambda p: p["name"].lower())]' \
       > /license-report/zisk-rust-crates.txt


# ── Stage 2: flapjack build + guest ELFs + fixture bake ──────────────────────
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG EEST_TAG=tests-zkevm@v21.0.1
ARG GIT_COMMIT=unknown
ARG GIT_REF=unknown
ARG BUILD_DATE=unknown

# libomp-dev/libgmp-dev/libopenmpi-dev/libsodium-dev (not just their -bin/
# runtime-only counterparts, to guarantee the exact same package version as
# the ziskemu-builder stage, since both are FROM the same base image) supply
# ziskemu's own dynamic-link dependencies (confirmed via `ldd`: libomp.so.5,
# libgmp.so.10, libmpi.so.40/libopen-rte.so.40/libopen-pal.so.40, and their
# own transitive libhwloc/libevent/libudev/libcap, plus libsodium.so.23).
# Without these, ziskemu fails to launch at all (a dynamic-linker error),
# which surfaces as every single EEST case erroring.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 build-essential \
    binutils-riscv64-unknown-elf \
    libomp-dev libgmp-dev libopenmpi-dev libsodium-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ziskemu-builder /zisk/target/release/ziskemu /usr/local/bin/ziskemu

# Copy zisk/Rust license artifacts from builder stage
COPY --from=ziskemu-builder /license-report/ /usr/local/share/licenses/

RUN curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
    | sh -s -- -y --default-toolchain none
ENV PATH="/root/.elan/bin:$PATH"

WORKDIR /stateless-pancaketh
COPY . .

# Install the pinned Lean toolchain; `lake exe flapjack-compile` (invoked by
# guest/build.sh below) resolves and fetches the flapjack/riscv-zkvm lake
# dependencies pinned in lakefile.toml/lake-manifest.json on first use.
RUN elan toolchain install "$(cat lean-toolchain)"

# Build the software and ZisK-accelerated guest ELFs with flapjack
# (guest/build.sh's default COMPILER). This is what populates
# .lake/packages/ (flapjack, riscv-zkvm), collected below.
RUN tools/build_both.sh

# Collect license files from each Lean package lake fetched into .lake/packages/
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
       done

# Generate Ubuntu package inventory; copyright texts live in /usr/share/doc/<pkg>/copyright
RUN dpkg-query -W --showformat='${Package} ${Version}\n' \
    > /usr/local/share/licenses/ubuntu-packages.txt

# Fetch elan and EEST fixture top-level licenses; fall back to a URL pointer on failure
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

# Fetch and bake in EEST fixtures (tools/make-inputs.sh --all auto-fetches
# via evm-asm/scripts/eest-fetch-fixtures.sh if missing) and convert the
# whole corpus into guest inputs + a manifest under work/inputs. Keep the
# ARG so the resolved value remains visible in the image label, but reject
# drift from the repository's canonical fixture-tag source.
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

ENV ZISKEMU=/usr/local/bin/ziskemu

# Defaults to the accelerated guest against the full corpus; override CMD
# (e.g. `docker run IMAGE guest/build/guest.elf work/inputs/manifest.tsv
# --ziskemu --quiet-passes --jobs 4`) to run the software guest instead, or
# to pass eest-run.py options like --json/--filter/--jobs.
ENTRYPOINT ["python3", "tools/eest-run.py"]
CMD ["guest/build/guest-accel.elf", "work/inputs/manifest.tsv", "--ziskemu", "--quiet-passes"]
