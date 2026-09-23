# Welding website: setup guide

## Who can do what

| Role | Signs in at | What they get |
| --- | --- | --- |
| **Owner** (you, 2 logins) | `owner.html` | Everything: staff access, welders, sign-up approvals, every request |
| **Staff** | `admin.html` | Handle requests, quote, assign welders, add welders |
| **Welder** | `welder.html` | Their own jobs only: take or pass, message the customer |

A person only lands on their own page. Try signing in as one role and you are
sent to the right place automatically.

## What is in this folder

| File | What it does |
| --- | --- |
| `index.html` | The website customers see, with the step-by-step build request |
| `owner.html` | The owner dashboard: staff codes, welder sign-ups, everything |
| `admin.html` | Staff login and the daily work area (requests + welders) |
| `welder.html` | Welder sign in, sign up, and their job board. Also opens offer links |
| `config.js` | Business name, phone numbers, photos, and your database keys |
| `api.js`, `style.css` | Shared code and design. You don't need to edit these |
| `supabase-setup.sql` | Creates the database tables and security rules |

## Try it first (demo mode)

Open `index.html` in your browser. With the default `config.js` the site runs in
demo mode: requests are saved only in your own browser.

## Go live: 8 steps

### 1. Create the free database

1. Go to supabase.com and create a free account.
2. Click **New project**. Choose any name and a strong database password. Save that password.
3. Wait about two minutes for the project to be ready.

### 2. Create the tables

1. In your project, open **SQL Editor** and click **New query**.
2. Open `supabase-setup.sql`. Check the last few lines: the owner email is set
   to `ogiehenifemi@gmail.com`. Change it if that is not the login you will use.
3. Copy everything, paste it in, and click **Run**.

You should see `Success. No rows returned`. If you ever need a second owner
account later, add another line to that last `values (...)` block and run the
file again - it is safe to re-run.

### 3. Allow sign-ups, but only for people you invite

1. Open **Authentication**, then **Sign In / Providers** (or **Email**).
2. Turn **ON** "Allow new users to sign up".
3. Leave **Confirm email** switched **ON**. This is what stops someone from
   claiming an owner account by typing in your email address.

Do not add any other user by hand. Staff get in with an invite code, welders
get in through their WhatsApp number.

### 4. Connect the website to the database

1. Open **Project Settings**, then **API**.
2. Copy the **Project URL** and the **anon public** key.
3. Open `config.js` and paste them into `SUPABASE_URL` and `SUPABASE_ANON_KEY`.

### 5. Add your uncle's real details

In `config.js`, change `BUSINESS_NAME`, `FALLBACK_WHATSAPP`, `PHONE_DISPLAY`,
`ADDRESS`, and `HOURS`. Use the WhatsApp number in international form without a
plus sign, for example `2348031234567`.

To show photos of finished work, put the image files in this folder and list
them in `GALLERY`.

### 6. Put it online

Upload the whole folder to a free host such as Netlify (drag and drop the
folder at app.netlify.com/drop) or Cloudflare Pages.

### 7. Sign in as the owner

Open `owner.html`, sign in with the owner email that is listed at the bottom of
`supabase-setup.sql`. If it says the login is not an owner account, check that
the email matches exactly (same letters, same domain) and run the SQL again.

### 8. Set up the people

**Add welders** (Welders tab): name, WhatsApp number, what they do. Tell each
welder to open `welder.html`, choose **Sign up as a welder**, and type the same
WhatsApp number you just saved. If the number matches, they are in straight
away. If it does not match, their request lands in the **Sign-ups** tab for you
to approve.

**Add staff** (Staff tab): press **Create invite code** and send the code to
the person. They go to `admin.html`, sign in with their own email, then press
*Enter your invite code* and type it once.

## Daily use

- **Owner** (`owner.html`): check the red numbers on the dashboard, approve
  sign-ups, keep the staff list right.
- **Staff** (`admin.html`): check the **New** count. Open a request, press
  *Message customer* to start the WhatsApp chat, set the status to **Quoted**
  and type the price. Move it to **In progress**, then **Done**.
- **Welder** (`welder.html`): signs in, sees their jobs, presses *I'll take
  this job*, then messages the customer.

Offer links still work: on a request, press **Copy accept link** and send it on
WhatsApp. The welder can open it without signing in.

## Good to know

- Free Supabase projects pause after a long time with no use. If the site stops
  saving, open the Supabase dashboard and press **Restore project**.
- The customer's WhatsApp message is written for them, but they still press
  send. Customers can attach photos in that chat.
- To change the questions or options (materials, finishes, item types), edit
  the `ITEMS`, `MATERIALS`, `FINISH` and `BUDGET` lists near the top of the
  script in `index.html`.
