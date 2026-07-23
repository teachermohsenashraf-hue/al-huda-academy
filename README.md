# أكاديمية الهدى — منصة تعليم القرآن وبناء الإنسان

A comprehensive Quran education platform built with HTML, CSS, and JavaScript.

## Pages

| Route | Description |
|-------|-------------|
| `/` | Landing page — public-facing marketing page |
| `/dashboard` | Admin / Dashboard panel |
| `/admin` | Alias for dashboard |

## Tech Stack

- Pure HTML + CSS + JavaScript (no framework)
- Supabase for backend/auth
- Hosted on Vercel

## Deployment

This project is deployed on Vercel. Push to `main` branch to trigger automatic deployments.

```
https://your-project.vercel.app/          → Landing Page
https://your-project.vercel.app/dashboard → Admin Dashboard
```

## Database setup (from scratch)

Run these in the Supabase SQL Editor, **in order**, on a fresh project:

1. `migrations/000_core_schema.sql` — creates the ten highest-traffic tables (`profiles`, `students`, `groups`, `payments`, `messages`, `chats`, `join_requests`, `sessions`, `session_ratings`, `notifications`) and enables RLS on them. This is the only file that defines their structure; they used to exist only inside the Supabase dashboard with no record in the repo. (~40 lower-traffic tables — mostly the `quran_*` curriculum tables and an unused parallel commerce schema — still only exist in the live dashboard.)
2. `SETUP.sql` — all RLS policies, triggers, RPC functions, and additive columns/tables built on top of the core schema. Safe to re-run in full any time (fully idempotent).
3. Anything under `migrations/` dated after `000_` — smaller one-off additive migrations, each independent and safe to run once.  9
