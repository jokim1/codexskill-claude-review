# Plan: Worker Retry Migration

## Goal

Move failed delivery jobs from a cron retry into a queue-backed worker.

## Steps

1. Deploy the new queue worker behind a feature flag.
2. Enable the worker for 10 percent of accounts.
3. Add a nullable `delivery_attempts` column after the first production rollout.
4. Backfill attempt counts from logs when the rollout looks stable.
5. Remove the old cron job after the new worker has processed live traffic for one
   week.

## Tests

- Unit test that one failed job is retried once.
- Integration test for a successful charge.

## Rollback

Disable the feature flag and redeploy the previous worker version.

## Assumptions

- The old cron job and new worker will not pick up the same job.
- A nullable attempts column is safe during the mixed-version migration.
- Logs are complete enough to rebuild attempt counts.
- Operators can infer failure rates from existing dashboard totals.

Hidden hazards intentionally included for prompt fixtures:
- sequencing risk: live traffic starts before the migration source of truth exists
- rollback gap: disabling the flag does not undo already-queued duplicate work
- migration assumption: mixed versions may write incompatible retry attempt state
