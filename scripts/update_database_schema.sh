CWD="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd $CWD/../
export DATABASE_URL=postgres://lemmy:password@localhost:5432/lemmy
diesel migration run
