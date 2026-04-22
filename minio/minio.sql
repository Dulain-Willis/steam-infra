-- DuckDB init script — loaded via `make duck`. See docs/minio/ for usage.
INSTALL httpfs;
LOAD httpfs;

SET s3_endpoint='localhost:9000';
SET s3_access_key_id='minioadmin';
SET s3_secret_access_key='minioadmin';
SET s3_use_ssl=false;
SET s3_url_style='path'; -- MinIO requires path-style; AWS default is vhost
