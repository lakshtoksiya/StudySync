# StudySync

A notes-sharing web app for college classes. Students join a private community (for example "CSE-A 2nd Year"), upload the day's class notes as photos or PDFs, and everyone in the community can browse, zoom, save and download them. Notes are organised by semester, subject and unit, so they stay searchable for all four years.

## Features

- Email and Google login (Supabase Auth)
- Communities with roles: Admin, CR, Member. Join with a code or a link; private communities need approval
- Subjects load from a CSE template (Sem 1 to 7) and can be edited by the Admin or CR
- Classroom feed for daily class notes, plus per-subject tabs: Class Notes (Daily), Units, Assignments, PYQs, Important
- Upload several subjects at once; photos are compressed in the browser; one notification per upload
- Note viewer with zoom, PDF view, download, save, "helpful" votes and correction suggestions
- Light and dark theme, responsive layout with a mobile drawer

## Architecture

```
Browser (index.html + config.js)   hosted on Netlify
        |
        v
Supabase (backend)
  |- Auth        login, signup, Google
  |- Postgres    14 tables, functions, triggers, Row Level Security
  |- Storage     private "notes" bucket (photos and PDFs, 20 MB limit)
  |- Realtime    notifications table
```

There is no separate server. The frontend talks to Supabase directly, and access is enforced inside the database with Row Level Security: a note is only visible to active members of its community.

## Database (supabase/migrations)

| File | What it does |
|---|---|
| `01_templates_cse.sql` | Creates the `templates` table and loads the CSE subject lists for Sem 1 to 7 |
| `02_full_schema.sql` | All other tables, permission helpers, RPC functions, triggers, RLS policies and the storage bucket |
| `03_english_messages_patch.sql` | Replaces database messages with English text (run after 02) |

Tables: `profiles`, `communities`, `members`, `terms`, `subjects`, `subject_requests`, `notes`, `note_files`, `note_edits`, `note_suggestions`, `likes`, `saves`, `notifications`, `templates`.

Main functions (called from the frontend with `supabase.rpc`):

- `create_community`, `join_community`, `reset_join_code`, `start_new_term`
- `set_member_role`, `set_member_status`
- `publish_upload`, `delete_note`
- `accept_suggestion`, `reject_suggestion`

Permission helpers used by the policies: `is_member`, `is_staff`, `is_admin`.

## Setup

1. Create a project at [supabase.com](https://supabase.com).
2. In the SQL Editor, run the three files in `supabase/migrations` in order (01, 02, 03). If a "Potential issue" popup appears, choose "Run and enable RLS".
3. Copy `config.example.js` to `config.js` and paste your Project URL and anon (publishable) key from Supabase, Project Settings, API.
4. Optional for local testing: in Authentication, Sign In / Providers, switch off "Confirm email".
5. Open `index.html` in a browser, or upload the folder to Netlify Drop.
6. For join links and Google login on a hosted site, add your site address under Authentication, URL Configuration (Site URL and Redirect URLs).

## Security notes

- Only the anon (publishable) key belongs in the frontend. Never commit a `service_role` key or your database password.
- `config.js` is listed in `.gitignore`. The anon key is designed to be public, but keeping it out of the repo is cleaner.
- Privacy depends on the RLS policies in `02_full_schema.sql`. Do not disable RLS on any table.

## Status and roadmap

Working: login, communities, subjects, uploads, Classroom feed, viewer, saves, alerts, member management.

Not built in the frontend yet: accept or reject screen for correction suggestions (the database functions exist), note editing, a "start new semester" button, push notifications, more branches and Medical templates.
