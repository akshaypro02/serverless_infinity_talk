# syntax=docker/dockerfile:1.7
# (BuildKit syntax line is required for --mount=type=cache and COPY --chmod)

# ---------------------------------------------------------------------------
# Global build args
# ---------------------------------------------------------------------------
ARG BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04
# Pin this (e.g. 0.9.0) for reproducible builds
ARG UV_VERSION=latest

# uv binary comes from the official image: no "curl | sh" at build time
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# ---------------------------------------------------------------------------
# Main image
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS base

ARG COMFYUI_VERSION=latest
ARG CUDA_VERSION_FOR_COMFY
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL
# Python packages needed by custom nodes that live on the network volume.
# Add more here as you find them (space-separated).
ARG EXTRA_PIP_PACKAGES="opencv-python-headless accelerate piexif scikit-image ultralytics gguf"

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PIP_NO_INPUT=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8 \
    UV_HTTP_TIMEOUT=300 \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:${PATH}"

COPY --from=uv /uv /uvx /usr/local/bin/

# --- System packages (one layer, apt cache kept OUT of the image) ----------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        python3.12 \
        python3.12-venv \
        git \
        wget \
        ca-certificates \
        libgl1 \
        libglib2.0-0 \
        libsm6 \
        libxext6 \
        libxrender1 \
        ffmpeg \
    && ln -sf /usr/bin/python3.12 /usr/bin/python

# --- Venv + all light Python deps together (rarely change -> cached) -------
# requirements.txt: runpod~=1.7.12, websocket-client, requests (handler deps)
COPY requirements.txt /tmp/requirements.txt
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv /opt/venv --python /usr/bin/python3.12 \
    && uv pip install comfy-cli pip setuptools wheel -r /tmp/requirements.txt

# --- ComfyUI + PyTorch upgrade in ONE layer --------------------------------
# (separate layers would keep the old torch in the image forever)
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=cache,target=/root/.cache/pip \
    if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi \
    && uv pip install -r /comfyui/requirements.txt \
    && if [ "${ENABLE_PYTORCH_UPGRADE}" = "true" ]; then \
         uv pip install --force-reinstall torch torchvision torchaudio --index-url "${PYTORCH_INDEX_URL}"; \
       fi

# --- Dependencies for custom nodes mounted from the volume -----------------
# Runs AFTER the torch upgrade and pins the installed torch so these packages
# can never replace the cu128 build.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip freeze | grep -iE "^(torch|torchvision|torchaudio)==" > /tmp/torch-constraints.txt \
    && uv pip install -c /tmp/torch-constraints.txt ${EXTRA_PIP_PACKAGES} \
    && rm /tmp/torch-constraints.txt

# Custom nodes are NOT installed here: they are mounted from the network volume.

# ---------------------------------------------------------------------------
# Small, frequently-edited files go LAST so edits never invalidate the
# heavy layers above
# ---------------------------------------------------------------------------
WORKDIR /comfyui
COPY --chmod=755 scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
COPY src/extra_model_paths.yaml /comfyui/

WORKDIR /
COPY --chmod=755 src/start.sh /start.sh
COPY handler.py test_input.json /

CMD ["/start.sh"]
