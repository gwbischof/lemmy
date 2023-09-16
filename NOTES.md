# Update db schema
- Create a migration manually.
- source .env, to set the DATABASE_URL that is used by diesel.
- `diesel migration run`
- sometimes the script test.sh will update the schema also, maybe db needs to be cleared first.
