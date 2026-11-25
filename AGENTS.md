# Repository instructions

- Keep Pick’em work on the feature branch and obtain explicit owner approval before merging or publishing.
- Preserve the existing Power Rankings layout, conference and division filtering, and Tuesday publishing automation.
- Keep participant addresses, credentials and backups out of the repository and logs. Use synthetic identities and games for tests.
- Validate NFL schedules and results against an authorized source. Keep ambiguous statuses locked and withhold picks until official final verification.
- Keep database changes in ordered Supabase migrations. Enforce participant authorization, kickoff and pick privacy in PostgreSQL.
- Use free services and obtain approval for the next eligible full week if the intended start week’s first kickoff has passed.
