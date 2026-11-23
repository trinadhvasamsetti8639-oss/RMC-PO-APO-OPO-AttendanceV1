# Polling Duty Attendance App

Static app (GitHub Pages) + Supabase (free) for shared, real-time data.

## Setup
1. Supabase: create a project, open SQL Editor, run `supabase_setup.sql` (safe to re-run when updating; existing users and attendance are kept).
2. Edit `config.js`: Supabase URL + anon key (and optionally a Google Maps JS API key for the map picker).
3. Push all files to a GitHub repo, then Settings > Pages > deploy from `main` / root.
4. Log in as `admin` / `admin123` and **change that password immediately** (Admin tab > Users).

Leave `config.js` empty for demo mode (`admin/admin123`, `user/user123`, `ro/ro123` for stations 1-5, `sec/sec123`; data stays in your browser).

## Roles
- **user**: Capture attendance (team or reserve), reports, dashboard.
- **ro**: Reports + dashboard for the polling stations assigned by admin only (server-filtered), with Call buttons for absentees. No capture.
- **sec** (Administrative Secretary): assigns attended reserve staff to polling teams, plus reports and dashboard.
- **admin**: everything (including assigning reserve), plus geofence, user management, clearing attendance and replacing/updating the employee database from Excel.

## Colours
Green = present, Yellow = not attended with a reason (Leave, Health Issues, Duties Cancelled, Changed to Reserve), Red = not yet reported / absent.

## Notes
- Dashboard: Team (25 stations per slide) and Reserve (50 staff per slide), 3 minutes per slide, data refreshes every 10 s.
- Reserve assignment: only reserve staff marked Attended can be assigned, only to team slots not yet present. Assigned reserve show a green person with a ✕ badge.
- Employee database uploaded by admin is stored in Supabase and overrides the bundled `data.json` / `reserve.json`.
- Geofence is enforced in the browser and on the server. Phones need HTTPS (Pages is) and location permission.
- `data.json` / `reserve.json` hold employee names and phones and are publicly readable on a public Pages site; use a private repo if that matters.
