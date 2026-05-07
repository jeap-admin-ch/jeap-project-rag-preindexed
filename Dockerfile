FROM repo.bit.admin.ch:8445/bit/jeap-project-rag:0.1.0-trixie-20260504143403 AS indexer

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

ENV PROJECT_RAG_MODEL_PATH=/opt/models/all-MiniLM-L6-v2
RUN mkdir -p "$PROJECT_RAG_MODEL_PATH" \
 && cd "$PROJECT_RAG_MODEL_PATH" \
 && BASE=https://huggingface.co/Qdrant/all-MiniLM-L6-v2-onnx/resolve/main \
 && for f in model.onnx tokenizer.json config.json special_tokens_map.json tokenizer_config.json; do \
        curl -fL -o "$f" "$BASE/$f"; \
    done

ENTRYPOINT []

COPY scripts/jeap-index.sh /usr/local/bin/jeap-index.sh
RUN chmod +x /usr/local/bin/jeap-index.sh

RUN /usr/local/bin/jeap-index.sh \
        https://bitbucket.bit.admin.ch/scm/jeap/jeap-spring-boot-db-migration-starter.git \
        jeap-spring-boot-db-migration-starter

RUN /usr/local/bin/jeap-index.sh \
        https://bitbucket.bit.admin.ch/scm/jeap/jeap-messaging.git \
        jeap-messaging

FROM repo.bit.admin.ch:8445/bit/jeap-project-rag:0.1.0-trixie-20260504143403 AS final

COPY --from=indexer /root/.local/share/project-rag /root/.local/share/project-rag
COPY --from=indexer /root/.cache/project-rag       /root/.cache/project-rag
COPY --from=indexer /opt/models                    /opt/models

ENV PROJECT_RAG_MODEL_PATH=/opt/models/all-MiniLM-L6-v2
