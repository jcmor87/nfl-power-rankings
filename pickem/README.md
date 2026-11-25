# Family Pick’em private development preview

Serve the reviewed feature branch privately and open `/pickem/`. The app can use fictional sample picks or sign in to a configured Supabase project. See the [iPad preview and hosted test guide](../docs/PICKEM_PHASE3.md).

The connection form accepts the hosted project URL and an `sb_publishable_` key. With a configured session, the app shows active/completed weeks, Pacific kickoff times, own picks and completed standings. It submits changes through the database RPC and keeps the access token in page memory. Reloading requires a fresh sign-in. The committed deployment defaults are empty.

Keep the hosted preview private and use only the approved temporary accounts. Passwordless sign-in is a future enhancement.
