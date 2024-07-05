#!/usr/bin/env bash
CWD="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

cd $CWD/../backups

psql -U lemmy -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
cat lemmy.sql | psql -U lemmy
psql -U lemmy -c "alter user lemmy with password 'password'"
