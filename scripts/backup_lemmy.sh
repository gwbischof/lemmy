#!/usr/bin/env bash
CWD="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

cd $CWD/../backups

pg_dump -Fc lemmy -U postgres > lemmy.dump
