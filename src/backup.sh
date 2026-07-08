#! /bin/sh

set -eu
set -o pipefail

source ./env.sh

# Remove any leftover working files for the database currently being processed.
# Fires on normal exit and on interruption/failure so partial dumps never linger.
cleanup() {
  [ -n "${cleanup_glob:-}" ] && rm -f ${cleanup_glob}
}
trap cleanup EXIT INT TERM

mkdir -p "$LOCAL_STORE_PREFIX"

# Split POSTGRES_DATABASE on commas and/or whitespace into a list of databases.
# The special value "all" expands to every non-template database on the server.
databases=$(echo "$POSTGRES_DATABASE" | tr ',' ' ')

if [ "$databases" = "all" ]; then
  echo "Discovering databases on $POSTGRES_HOST..."
  databases=$(psql --format=unaligned --tuples-only \
      -h "$POSTGRES_HOST" \
      -p "$POSTGRES_PORT" \
      -U "$POSTGRES_USER" \
      -d postgres \
      -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres';")
fi

# One timestamp for the whole run so every database in this run shares it.
timestamp=$(date +"%Y-%m-%dT%H:%M:%S")

backup_database() {
  db="$1"
  file_path="${LOCAL_STORE_PREFIX}/${db}.dump"
  cleanup_glob="${LOCAL_STORE_PREFIX}/${db}.dump*"

  echo "Creating backup of $db database..."
  pg_dump --format=custom \
          -h "$POSTGRES_HOST" \
          -p "$POSTGRES_PORT" \
          -U "$POSTGRES_USER" \
          -d "$db" \
          $PGDUMP_EXTRA_OPTS \
          > "$file_path"

  if [ ! -s "$file_path" ]; then
    echo "Backup of $db is empty, aborting." >&2
    exit 1
  fi

  s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${db}_${timestamp}.dump"

  if [ -n "$COMPRESS" ]; then
    echo "Compressing backup..."
    zstd -2 "$file_path"
    file_path="${file_path}.zst"
    s3_uri_base="${s3_uri_base}.zst"
  fi

  if [ -n "$PASSPHRASE" ]; then
    echo "Encrypting backup..."
    rm -f "$file_path.gpg"
    gpg --symmetric --batch --passphrase "$PASSPHRASE" "$file_path"
    rm "$file_path"
    local_file="$file_path.gpg"
    s3_uri="${s3_uri_base}.gpg"
  else
    local_file="$file_path"
    s3_uri="$s3_uri_base"
  fi

  echo "Uploading backup to $S3_BUCKET..."
  aws $aws_args s3 cp "$local_file" "$s3_uri"
  rm "$local_file"

  echo "Backup of $db complete."

  if [ -n "$BACKUP_KEEP_DAYS" ]; then
    sec=$((86400*BACKUP_KEEP_DAYS))
    date_from_remove=$(date -d "@$(($(date +%s) - sec))" +%Y-%m-%d)
    backups_query="Contents[?LastModified<='${date_from_remove} 00:00:00'].{Key: Key}"

    echo "Removing old backups of $db from $S3_BUCKET..."
    aws $aws_args s3api list-objects \
      --bucket "${S3_BUCKET}" \
      --prefix "${S3_PREFIX}/${db}_" \
      --query "${backups_query}" \
      --output text \
      | xargs -r -n1 -t -I 'KEY' aws $aws_args s3 rm s3://"${S3_BUCKET}"/'KEY'
    echo "Removal of old $db backups complete."
  fi
}

for db in $databases; do
  backup_database "$db"
done

echo "All backups complete."
