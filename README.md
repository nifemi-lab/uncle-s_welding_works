# Welding website: setup guide

## What is in this folder

| File | What it does |
| --- | --- |
| `index.html` | The website customers see, with the step-by-step build request |
| `admin.html` | The private page where your uncle sees requests and updates their status |
| `config.js` | Business name, phone numbers, photos, and your database keys |
| `api.js`, `style.css` | Shared code and design. You don't need to edit these |
| `supabase-setup.sql` | Creates the database tables and security rules |

## Try it first (demo mode)

Open `index.html` in your browser. With the default `config.js` the site runs in demo mode:
requests are saved only in your own browser. Send a test request, then open `admin.html`
(type anything to sign in) to see it appear. Nothing is shared with anyone else yet.

## Go live: 6 steps

### 1. Create the free database

1. Go to supabase.com and create a free account.
2. Click **New project**. Choose any name and a strong database password. Save that password.
3. Wait about two minutes for the project to be ready.

### 2. Create the tables

1. In your project, open **SQL Editor** and click **New query**.
2. Open `supabase-setup.sql`, copy everything, paste it in, and click **Run**.

### 3. Create your uncle's login and lock the door

1. Open **Authentication**, then **Users**, and click **Add user**. Enter your uncle's email and a strong password. Tick **Auto confirm user**.
2. Open **Authentication**, then **Sign In / Providers** (the wording may differ slightly), and **turn off "Allow new users to sign up"**.

This second part matters. Any signed-in user can read customer requests, so only your uncle
(and anyone you add yourself) should have an account.

### 4. Connect the website to the database

1. Open **Project Settings**, then **API**.
2. Copy the **Project URL** and the **anon public** key.
3. Open `config.js` and paste them into `SUPABASE_URL` and `SUPABASE_ANON_KEY`.

The anon key is safe to be public. The security rules from step 2 are what protect the data.

### 5. Add your uncle's real details

In `config.js`, change `BUSINESS_NAME`, `FALLBACK_WHATSAPP`, `PHONE_DISPLAY`, `ADDRESS`, and `HOURS`.
Use the WhatsApp number in international form without a plus sign, for example `2348031234567`.

To show photos of finished work, put the image files in this folder and list them in `GALLERY`.

### 6. Put it online

Upload the whole folder to a free host such as Netlify (drag and drop the folder at app.netlify.com/drop)
or Cloudflare Pages. Then:

1. Open `your-site-address/admin.html` and sign in with your uncle's email and password.
2. Open the **Welders** tab and add each welder with their WhatsApp number. Mark them as available or busy.

Customers can now use the site. Each request appears in the Requests tab as **New**.

## Daily use

- Open `admin.html`, sign in, and check the **New** count.
- Open a request, press **Message customer** to start the WhatsApp chat, then set the status to **Quoted** and type the price.
- Move it to **In progress** when work starts and **Done** when finished.
- Use the **Welders** tab to mark someone as busy so customers don't choose them.

## Good to know

- Free Supabase projects can pause after a long time with no use. If the site stops saving, open the Supabase dashboard and press **Restore project**.
- The customer's WhatsApp message is written for them, but they still press send. Customers can attach photos in that chat.
- To change the questions or options (materials, finishes, item types), edit the `ITEMS`, `MATERIALS`, `FINISH`, and `BUDGET` lists near the top of the script in `index.html`.
