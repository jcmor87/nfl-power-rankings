# Pick’em development preview

Serve the repository as static files and open `/pickem/`. Try sample picks to use the board without credentials. Fictional games render in the browser’s time zone, and selections live in page memory.

For password sign-in in a private development checkout, edit `config.mjs` to use a disposable hosted Supabase project URL and its publishable key. Apply the migrations and provision a confirmed synthetic Auth user linked to an active participant. The client uses Supabase’s password endpoint and checks access through the participant directory policy. It renders the same fictional board after authentication and never writes picks to Supabase. Sign-out clears local state and requests local-session logout. The committed configuration leaves hosted sign-in disabled.

Keep real accounts and privileged credentials out of the frontend. Passwordless sign-in, persistent picks, live schedules, and results are future work. The link back to Power Rankings is relative to the repository root.
