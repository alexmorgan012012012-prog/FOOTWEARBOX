# FOOTWEAR BOX: website (Phase 1)

Storefront for FOOTWEAR BOX, Karmani Road, Chung, Lahore. Built with React, TypeScript, Vite, React Router, GSAP and Supabase.

## What is included in Phase 1

- Session-gated cinematic intro with a Skip button and a reduced-motion version
- Typographic FOOTWEAR BOX wordmark (no logo image)
- Homepage: hero, men's and women's entry points, featured, new arrivals, best sellers, category rows, "Why choose", brand introduction, reviews placeholder
- Shop page with search, collection, category, size, availability and maximum-price filters
- Product detail page with gallery, validated size, color and quantity, Add to Cart, Buy Now and WhatsApp ordering
- Cart with localStorage persistence; every price is read from the live catalog
- Checkout with validation, server-side order placement and an order number
- WhatsApp message builder for products, cart and checkout (number 923206894412)
- Privacy, Terms and Returns pages with placeholder text until you supply the final wording
- Database schema with row-level security, stock checks and server-side pricing

## What is NOT included yet

- **Phase 2: admin dashboard** (`/admin/login`, `/admin/dashboard`), image uploads, order status management, homepage and store-settings editing. Until then, products are added directly in Supabase.
- **Phase 3: the men's and women's GSAP scroll sequences.** The reference video and product photos have not been supplied yet, so the homepage shows entry cards instead of the cinematic sections.
- Men's and women's scroll sequences, product photos and prices: none are invented. Products appear only after you add them.

## Requirements

- Node.js 18.18 or newer (20 LTS recommended)
- A Supabase project (free tier is enough to start)

## 1. Install and run locally

```bash
npm install
cp .env.example .env.local
# edit .env.local and fill in your Supabase URL and anon key
npm run dev
```

Open http://localhost:5173. Without Supabase values the site still runs. It shows an honest "catalog not connected" state, and WhatsApp ordering still works.

## 2. Create the database

1. In Supabase, open **SQL Editor → New query**.
2. Paste the contents of `supabase/schema.sql` and run it.
3. Check **Table Editor**: you should see `categories`, `products`, `orders`, `order_items`, `store_settings` and `admin_users`.

## 3. Get your keys

In Supabase, go to **Project Settings → API**.

- **Project URL** → `VITE_SUPABASE_URL`
- **anon public key** → `VITE_SUPABASE_ANON_KEY`

Never put the **service_role** key in this project. It must not appear in any file that is sent to the browser.

## 4. Create the first administrator

Admin login arrives in Phase 2. For now, the admin account is created securely like this:

1. In Supabase, open **Authentication → Users → Add user → Create new user**. Enter your email and a strong password. Turn off "Auto Confirm" only if you want to verify the email yourself.
2. Open **SQL Editor** and run, replacing the email:

```sql
insert into public.admin_users (user_id)
select id from auth.users where email = 'your-email@example.com';
```

Do not share the password in chat, email or screenshots. Do not use a default or guessable password.

## 5. Add products (until the dashboard exists)

Add products in **Table Editor → products** or with SQL. Each product needs a unique `slug` (lowercase letters, numbers and hyphens), a `category_id` from the categories table, a `gender`, and `active = true` to be visible. Products need a `price_pkr` before they can be ordered. Product photos go in the `product-images` storage bucket, and their public URLs are stored in `images`.

## 6. Deploy

The project includes `vercel.json`, so deep links and refreshes (for example `/product/some-slug`) do not return 404.

**Vercel (recommended for this setup)**

1. Push the folder to a GitHub repository.
2. In Vercel, click **Add New → Project** and import the repository.
3. Framework preset: **Vite**. Build command: `npm run build`. Output directory: `dist`.
4. Under **Environment Variables**, add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` (Production and Preview).
5. Deploy, then open the site and test a product, the cart, checkout and a WhatsApp link.

**Netlify**: the same build settings apply. Add a `public/_redirects` file containing `/* /index.html 200`.

Any other static host needs a rule that serves `index.html` for unknown paths.

## Important notes

- **Order saving:** checkout saves an order only when the database confirms it. If the database is unavailable, the site says the order was not saved and offers WhatsApp instead.
- **WhatsApp is not an order record.** Opening WhatsApp does not save an order on the website. The site makes this clear to customers.
- **Stock:** placing an order reduces the product's total stock. If you cancel an order, restore stock manually until the Phase 2 dashboard does it for you.
- **Payment:** the site does not take online payments. Do not claim otherwise until a payment provider is integrated.
- **Policies:** Privacy, Terms and Returns show placeholder text until you provide the final wording.
- **Testing:** this code has not yet been run in a browser or against a live Supabase project from the build environment. Please run `npm run build` and test checkout end to end before launch.

## Project structure

```
src/
  App.tsx, main.tsx          app shell and routes
  config/store.ts            brand, contacts, social links (defaults)
  context/CartContext.tsx    cart state and persistence
  components/                Header, Footer, Intro, Wordmark, ProductCard
  lib/                       Supabase client, catalog data, PKR format, WhatsApp
  pages/                     Home, Shop, ProductDetail, Cart, Checkout, Policy
  styles/global.css          design system and responsive rules
supabase/schema.sql          tables, RLS, place_order function, storage
```
