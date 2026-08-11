# glibc-based Glances so the NVIDIA runtime's libnvidia-ml.so (glibc) loads for GPU metrics.
# The official nicolargo/glances:*-full images are musl/Alpine and fail with
# "dlvsym: symbol not found" when the nvidia runtime injects the glibc NVML library.
FROM python:3.12-slim

RUN pip install --no-cache-dir "glances[web,gpu,containers]" nvidia-ml-py \
    && rm -rf /root/.cache

EXPOSE 61208
# -w runs the built-in web server + REST API (Homepage reads the REST API)
CMD ["glances", "-w"]
