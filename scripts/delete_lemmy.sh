#!/usr/bin/env bash

psql -U lemmy -c "DROP DATABASE lemmy; DROP USER lemmy;"
