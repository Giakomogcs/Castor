-- file: 006_castor_rag.sql
-- tier: A
-- purpose: RAG no padrão Sameka — UMA tabela (castor_documents) com file_id
--          armazenado em metadata->>'file_id'. Mais simples, sem problemas de
--          ownership ("must be owner of table") que o modelo de chunks gerava.
-- depends: 001
-- reversible: parcial — não dropa nada já populado.
-- IDEMPOTENTE.

BEGIN;

-- METADADOS DE ARQUIVOS (Drive ou local) -----------------------
CREATE TABLE IF NOT EXISTS castor_document_metadata (
  id              TEXT PRIMARY KEY,
  title           TEXT,
  url             TEXT,
  created_at      TIMESTAMP DEFAULT NOW(),
  schema          TEXT,
  session_id      TEXT,
  modified_time   TEXT,
  content_hash    TEXT,
  last_indexed_at TIMESTAMP
);
ALTER TABLE castor_document_metadata ADD COLUMN IF NOT EXISTS modified_time   TEXT;
ALTER TABLE castor_document_metadata ADD COLUMN IF NOT EXISTS content_hash    TEXT;
ALTER TABLE castor_document_metadata ADD COLUMN IF NOT EXISTS last_indexed_at TIMESTAMP;
CREATE INDEX IF NOT EXISTS castor_idx_doc_metadata_session  ON castor_document_metadata(session_id);
CREATE INDEX IF NOT EXISTS castor_idx_doc_metadata_modified ON castor_document_metadata(modified_time);

-- LINHAS DE PLANILHA (Excel/CSV) -------------------------------
CREATE TABLE IF NOT EXISTS castor_document_rows (
  id         SERIAL PRIMARY KEY,
  dataset_id TEXT REFERENCES castor_document_metadata(id) ON DELETE CASCADE,
  row_data   JSONB
);
CREATE INDEX IF NOT EXISTS castor_idx_doc_rows_dataset ON castor_document_rows(dataset_id);

-- VETORES (UMA tabela só; file_id mora em metadata->>'file_id') -
CREATE TABLE IF NOT EXISTS castor_documents (
  id        bigserial PRIMARY KEY,
  content   text,
  metadata  jsonb,
  embedding vector(1536)
);
CREATE INDEX IF NOT EXISTS castor_idx_documents_metadata_gin ON castor_documents USING GIN (metadata);
CREATE INDEX IF NOT EXISTS castor_idx_documents_file_id      ON castor_documents ((metadata->>'file_id'));

-- BUSCA SEMÂNTICA ----------------------------------------------
CREATE OR REPLACE FUNCTION match_castor_documents (
  query_embedding vector(1536),
  match_count     int   DEFAULT NULL,
  filter          jsonb DEFAULT '{}'
) RETURNS TABLE (
  id         bigint,
  content    text,
  metadata   jsonb,
  similarity float
)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
BEGIN
  RETURN QUERY
  SELECT id, content, metadata,
         1 - (castor_documents.embedding <=> query_embedding) AS similarity
  FROM castor_documents
  WHERE metadata @> filter
  ORDER BY castor_documents.embedding <=> query_embedding
  LIMIT match_count;
END;
$$;

INSERT INTO castor_schema_migrations(version) VALUES ('006_rag') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';
