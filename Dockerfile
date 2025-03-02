FROM julia:1.11 as base
RUN mkdir /planar \
    && apt-get update \
    && apt-get -y install sudo direnv git \
    && useradd -u 1000 -G sudo -U -m -s /bin/bash vdtuser \
    && chown vdtuser:vdtuser /planar \
    # Allow sudoers
    && echo "vdtuser ALL=(ALL) NOPASSWD: /bin/chown" >> /etc/sudoers
WORKDIR /planar
USER vdtuser
ARG CPU_TARGET=generic
ENV JULIA_BIN=/usr/local/julia/bin/julia
ARG JULIA_CMD="$JULIA_BIN -C $CPU_TARGET"
ENV JULIA_CMD=$JULIA_CMD
ENV JULIA_CPU_TARGET ${CPU_TARGET}

# PLANAR ENV VARS GO HERE
ENV PLANAR_LIQUIDATION_BUFFER=0.02
ENV JULIA_NOPRECOMP=""
ENV JULIA_PRECOMP=Remote,PaperMode,LiveMode,Fetch,Optimization,Plotting
CMD $JULIA_BIN -C $JULIA_CPU_TARGET

FROM base as python1
ENV JULIA_LOAD_PATH=:/planar
ENV JULIA_CONDAPKG_ENV=/planar/user/.conda
# avoids progressbar spam
ENV CI=true
COPY --chown=vdtuser:vdtuser ./Lang/ /planar/Lang/
COPY --chown=vdtuser:vdtuser ./Python/*.toml /planar/Python/
# Instantiate python env since CondaPkg is pulled from master
ARG CACHE=1
RUN $JULIA_CMD --project=/planar/Python -e "import Pkg; Pkg.instantiate()"
COPY --chown=vdtuser:vdtuser ./Python /planar/Python
RUN $JULIA_CMD --project=/planar/Python -e "using Python"

FROM python1 as precompile1
COPY --chown=vdtuser:vdtuser ./Planar/*.toml /planar/Planar/
ENV JULIA_PROJECT=/planar/Planar
ARG CACHE=1
RUN $JULIA_CMD --project=/planar/Planar -e "import Pkg; Pkg.instantiate()"

FROM precompile1 as precompile2
RUN JULIA_PROJECT= $JULIA_CMD -e "import Pkg; Pkg.add([\"DataFrames\", \"CSV\", \"ZipFile\"])"

FROM precompile2 as precompile3
COPY --chown=vdtuser:vdtuser ./ /planar/
RUN git submodule update --init

FROM precompile3 as precomp-base
USER vdtuser
WORKDIR /planar
ENV JULIA_NUM_THREADS=auto
CMD $JULIA_BIN -C $JULIA_CPU_TARGET

FROM precomp-base as planar-precomp
ENV JULIA_PROJECT=/planar/Planar
RUN $JULIA_CMD -e "import Pkg; Pkg.instantiate()"
RUN $JULIA_CMD -e "using Planar; using Metrics"
RUN $JULIA_CMD -e "using Metrics"

FROM planar-precomp as planar-precomp-interactive
ENV JULIA_PROJECT=/planar/PlanarInteractive
RUN JULIA_PROJECT= $JULIA_CMD -e "import Pkg; Pkg.add([\"Makie\", \"WGLMakie\"])"
RUN $JULIA_CMD -e "import Pkg; Pkg.instantiate()"
RUN $JULIA_CMD -e "using PlanarInteractive"


FROM planar-precomp as planar-sysimage
USER root
RUN apt-get install -y gcc g++
ENV JULIA_PROJECT=/planar/user/Load
ARG COMPILE_SCRIPT
RUN scripts/docker_compile.sh; \
    su vdtuser -c "cd /planar; \
    . .envrc; \
    cat /tmp/compile.jl; \
    $JULIA_CMD -e \
    'include(\"/tmp/compile.jl\"); compile(\"user/Load\"; cpu_target=\"$JULIA_CPU_TARGET\")'"; \
    rm -rf /tmp/compile.jl
USER vdtuser
ENV JULIA_PROJECT=/planar/Planar
# Resets condapkg env
RUN $JULIA_CMD --sysimage "/planar/Planar.so" -e "using Planar"
CMD $JULIA_CMD --sysimage "/planar/Planar.so"

FROM planar-precomp-interactive as planar-sysimage-interactive
USER root
ENV JULIA_PROJECT=/planar/PlanarInteractive
RUN apt-get install -y gcc g++
ARG COMPILE_SCRIPT
RUN scripts/docker_compile.sh; \
    su vdtuser -c "cd /planar; \
    . .envrc; \
    cat /tmp/compile.jl; \
    $JULIA_CMD -e \
    'include(\"/tmp/compile.jl\"); compile(\"PlanarInteractive\"; cpu_target=\"$JULIA_CPU_TARGET\")'"; \
    rm -rf /tmp/compile.jl
USER vdtuser
# Resets condapkg env
RUN $JULIA_CMD --sysimage "/planar/Planar.so" -e "using PlanarInteractive"
CMD $JULIA_CMD --sysimage Planar.so
