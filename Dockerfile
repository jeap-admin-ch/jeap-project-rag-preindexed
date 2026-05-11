ARG JEAP_PROJECT_RAG_TAG=0.1.0-al2023-20260519140153

FROM repo.bit.admin.ch:8444/bit/jeap-project-rag:${JEAP_PROJECT_RAG_TAG} AS indexer

USER root

RUN dnf install -y --allowerasing --setopt=install_weak_deps=False \
        git \
        ca-certificates \
        curl \
        findutils \
    && dnf clean all \
    && rm -rf /var/cache/dnf \
    && mkdir -p /home/raguser/bin \
    && chown raguser:raguser /home/raguser/bin \
    && mkdir -p /jeap \
    && chown raguser:raguser /jeap

COPY scripts/jeap-index.sh /home/raguser/bin/jeap-index.sh
COPY scripts/jeap-index-all.sh /home/raguser/bin/jeap-index-all.sh
RUN chmod +x /home/raguser/bin/jeap-index.sh /home/raguser/bin/jeap-index-all.sh

USER raguser

ENV PROJECT_RAG_MODEL_PATH=/home/raguser/models/all-MiniLM-L6-v2
RUN mkdir -p "$PROJECT_RAG_MODEL_PATH" \
 && cd "$PROJECT_RAG_MODEL_PATH" \
 && BASE=https://huggingface.co/Qdrant/all-MiniLM-L6-v2-onnx/resolve/main \
 && for f in model.onnx tokenizer.json config.json special_tokens_map.json tokenizer_config.json; do \
        curl -fL -o "$f" "$BASE/$f"; \
    done


RUN /home/raguser/bin/jeap-index-all.sh

FROM repo.bit.admin.ch:8444/bit/jeap-project-rag:${JEAP_PROJECT_RAG_TAG} AS final

COPY --from=indexer /home/raguser/.local/share/project-rag /home/raguser/.local/share/project-rag
COPY --from=indexer /home/raguser/.cache/project-rag       /home/raguser/.cache/project-rag
COPY --from=indexer /home/raguser/models                    /home/raguser/models
COPY --from=indexer /jeap/src                              /jeap/src

ENV PROJECT_RAG_MODEL_PATH=/home/raguser/models/all-MiniLM-L6-v2
