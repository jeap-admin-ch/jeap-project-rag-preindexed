ARG JEAP_PROJECT_RAG_TAG=0.1.0-al2023-20260508043103

FROM repo.bit.admin.ch:8444/bit/jeap-project-rag:${JEAP_PROJECT_RAG_TAG} AS indexer

USER root

RUN dnf install -y --allowerasing --setopt=install_weak_deps=False \
        git \
        ca-certificates \
        curl \
    && dnf clean all \
    && rm -rf /var/cache/dnf

ENV PROJECT_RAG_MODEL_PATH=/opt/models/all-MiniLM-L6-v2
RUN mkdir -p "$PROJECT_RAG_MODEL_PATH" \
 && cd "$PROJECT_RAG_MODEL_PATH" \
 && BASE=https://huggingface.co/Qdrant/all-MiniLM-L6-v2-onnx/resolve/main \
 && for f in model.onnx tokenizer.json config.json special_tokens_map.json tokenizer_config.json; do \
        curl -fL -o "$f" "$BASE/$f"; \
    done

COPY scripts/jeap-index.sh /usr/local/bin/jeap-index.sh
COPY scripts/jeap-index-all.sh /usr/local/bin/jeap-index-all.sh
RUN chmod +x /usr/local/bin/jeap-index.sh /usr/local/bin/jeap-index-all.sh

RUN /usr/local/bin/jeap-index-all.sh

FROM repo.bit.admin.ch:8444/bit/jeap-project-rag:${JEAP_PROJECT_RAG_TAG} AS final

COPY --from=indexer /root/.local/share/project-rag /root/.local/share/project-rag
COPY --from=indexer /root/.cache/project-rag       /root/.cache/project-rag
COPY --from=indexer /opt/models                    /opt/models

ENV PROJECT_RAG_MODEL_PATH=/opt/models/all-MiniLM-L6-v2
