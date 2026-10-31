-- =====================================================================
-- FOOTWEAR BOX: database schema, security policies and order function
-- Run this whole file once in: Supabase Dashboard > SQL Editor > New query
-- Safe to re-run for most parts; review before running on a live project.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Admin allow-list. A user is an administrator only if their auth user id
-- appears here. Add rows only through the SQL editor (see README).
-- ---------------------------------------------------------------------
create table if not exists public.admin_users (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.admin_users where user_id = auth.uid());
$$;

-- ---------------------------------------------------------------------
-- Categories (admin can create and edit; men/women/unisex grouping)
-- ---------------------------------------------------------------------
create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9-]+$'),
  name text not null,
  gender text not null default 'unisex' check (gender in ('men', 'women', 'unisex')),
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Products. Price is nullable on purpose: a product without a price cannot
-- be ordered, so the admin must enter one before publishing.
-- ---------------------------------------------------------------------
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9-]+$'),
  name text not null,
  description text not null default '',
  category_id uuid references public.categories (id) on delete set null,
  gender text not null default 'unisex' check (gender in ('men', 'women', 'unisex')),
  price_pkr integer check (price_pkr is null or price_pkr >= 0),
  sale_price_pkr integer check (sale_price_pkr is null or sale_price_pkr >= 0),
  sizes text[] not null default '{}',
  colors text[] not null default '{}',
  stock integer not null default 0 check (stock >= 0),
  images text[] not null default '{}',
  featured boolean not null default false,
  new_arrival boolean not null default false,
  best_seller boolean not null default false,
  active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sale_below_regular check (
    sale_price_pkr is null or price_pkr is null or sale_price_pkr <= price_pkr
  )
);

create index if not exists products_active_idx on public.products (active);
create index if not exists products_category_idx on public.products (category_id);

-- ---------------------------------------------------------------------
-- Store settings: key/value so the admin can edit contact details, footer
-- text, homepage copy and so on without code changes.
-- ---------------------------------------------------------------------
create table if not exists public.store_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Orders. Customers never write these tables directly; they use place_order().
-- ---------------------------------------------------------------------
create sequence if not exists public.order_number_seq;

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  status text not null default 'pending'
    check (status in ('pending', 'confirmed', 'processing', 'dispatched', 'delivered', 'cancelled')),
  customer_name text not null,
  customer_phone text not null,
  city text not null,
  address text not null,
  instructions text,
  subtotal_pkr integer not null check (subtotal_pkr >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  product_id uuid references public.products (id) on delete set null,
  product_name text not null,
  product_slug text not null,
  size text,
  color text,
  quantity integer not null check (quantity > 0),
  unit_price_pkr integer not null check (unit_price_pkr >= 0),
  line_total_pkr integer not null check (line_total_pkr >= 0)
);

create index if not exists order_items_order_idx on public.order_items (order_id);

-- ---------------------------------------------------------------------
-- place_order: the only way a customer can create an order.
-- - Prices are read from the database, never trusted from the browser.
-- - Stock is checked and reduced in the same transaction.
-- - Order and items are written together or not at all.
-- ---------------------------------------------------------------------
create or replace function public.place_order(payload jsonb)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := btrim(coalesce(payload->>'customer_name', ''));
  v_phone text := coalesce(payload->>'customer_phone', '');
  v_city text := btrim(coalesce(payload->>'city', ''));
  v_address text := btrim(coalesce(payload->>'address', ''));
  v_instructions text := nullif(btrim(coalesce(payload->>'instructions', '')), '');
  v_items jsonb := coalesce(payload->'items', '[]'::jsonb);
  v_item jsonb;
  v_product public.products%rowtype;
  v_qty integer;
  v_unit integer;
  v_subtotal integer := 0;
  v_order_id uuid;
  v_order_number text;
  v_size text;
  v_color text;
begin
  if length(v_name) < 2 or length(v_city) < 2 or length(v_address) < 10 then
    raise exception 'Please complete all required delivery details.';
  end if;
  if v_phone !~ '^92[0-9]{10}$' then
    raise exception 'Please provide a valid Pakistani mobile number.';
  end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception 'Your cart is empty.';
  end if;
  if jsonb_array_length(v_items) > 30 then
    raise exception 'Too many items in one order. Please contact us on WhatsApp.';
  end if;

  v_order_number := 'FB' || to_char(now() at time zone 'Asia/Karachi', 'YYMMDD')
                    || '-' || lpad(nextval('public.order_number_seq')::text, 4, '0');

  insert into public.orders (order_number, customer_name, customer_phone, city, address, instructions, subtotal_pkr)
  values (v_order_number, v_name, v_phone, v_city, v_address, v_instructions, 0)
  returning id into v_order_id;

  for v_item in select * from jsonb_array_elements(v_items) loop
    v_qty := coalesce((v_item->>'quantity')::integer, 0);
    if v_qty < 1 or v_qty > 50 then
      raise exception 'Invalid quantity for one of the items.';
    end if;

    select * into v_product
    from public.products
    where id = (v_item->>'product_id')::uuid
    for update;

    if not found or not v_product.active then
      raise exception 'One of the products is no longer available.';
    end if;
    if v_product.price_pkr is null then
      raise exception '% is not available to order right now.', v_product.name;
    end if;
    if v_product.stock < v_qty then
      raise exception 'Only % left in stock for %.', v_product.stock, v_product.name;
    end if;

    v_size := nullif(v_item->>'size', '');
    v_color := nullif(v_item->>'color', '');
    if v_size is not null and not (v_size = any (v_product.sizes)) then
      raise exception 'Size % is not offered for %.', v_size, v_product.name;
    end if;
    if v_color is not null and not (v_color = any (v_product.colors)) then
      raise exception 'Color % is not offered for %.', v_color, v_product.name;
    end if;

    v_unit := coalesce(
      case when v_product.sale_price_pkr is not null and v_product.sale_price_pkr < v_product.price_pkr
           then v_product.sale_price_pkr end,
      v_product.price_pkr
    );

    update public.products set stock = stock - v_qty, updated_at = now() where id = v_product.id;

    insert into public.order_items
      (order_id, product_id, product_name, product_slug, size, color, quantity, unit_price_pkr, line_total_pkr)
    values
      (v_order_id, v_product.id, v_product.name, v_product.slug, v_size, v_color, v_qty, v_unit, v_unit * v_qty);

    v_subtotal := v_subtotal + v_unit * v_qty;
  end loop;

  update public.orders set subtotal_pkr = v_subtotal where id = v_order_id;
  return v_order_number;
end;
$$;

revoke all on function public.place_order(jsonb) from public;
grant execute on function public.place_order(jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------
alter table public.admin_users enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.store_settings enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

-- Admin list: an admin can see only their own row.
drop policy if exists "admins read own row" on public.admin_users;
create policy "admins read own row" on public.admin_users
  for select using (user_id = auth.uid());

-- Categories: public reads active ones; admins manage all.
drop policy if exists "public read active categories" on public.categories;
create policy "public read active categories" on public.categories
  for select using (active or public.is_admin());
drop policy if exists "admins manage categories" on public.categories;
create policy "admins manage categories" on public.categories
  for all using (public.is_admin()) with check (public.is_admin());

-- Products: public reads only active products; admins manage all.
drop policy if exists "public read active products" on public.products;
create policy "public read active products" on public.products
  for select using (active or public.is_admin());
drop policy if exists "admins manage products" on public.products;
create policy "admins manage products" on public.products
  for all using (public.is_admin()) with check (public.is_admin());

-- Store settings: public read (contact details are public); admins write.
drop policy if exists "public read settings" on public.store_settings;
create policy "public read settings" on public.store_settings
  for select using (true);
drop policy if exists "admins manage settings" on public.store_settings;
create policy "admins manage settings" on public.store_settings
  for all using (public.is_admin()) with check (public.is_admin());

-- Orders: no public access at all. Customers use place_order(); admins read and update.
drop policy if exists "admins read orders" on public.orders;
create policy "admins read orders" on public.orders
  for select using (public.is_admin());
drop policy if exists "admins update orders" on public.orders;
create policy "admins update orders" on public.orders
  for update using (public.is_admin()) with check (public.is_admin());

drop policy if exists "admins read order items" on public.order_items;
create policy "admins read order items" on public.order_items
  for select using (public.is_admin());

-- ---------------------------------------------------------------------
-- Storage bucket for product photos. Public read so images load on the site;
-- only admins can upload, replace or delete.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do nothing;

drop policy if exists "public read product images" on storage.objects;
create policy "public read product images" on storage.objects
  for select using (bucket_id = 'product-images');

drop policy if exists "admins upload product images" on storage.objects;
create policy "admins upload product images" on storage.objects
  for insert with check (bucket_id = 'product-images' and public.is_admin());

drop policy if exists "admins update product images" on storage.objects;
create policy "admins update product images" on storage.objects
  for update using (bucket_id = 'product-images' and public.is_admin());

drop policy if exists "admins delete product images" on storage.objects;
create policy "admins delete product images" on storage.objects
  for delete using (bucket_id = 'product-images' and public.is_admin());

-- ---------------------------------------------------------------------
-- Starter data: categories only. No products and no prices are invented.
-- ---------------------------------------------------------------------
insert into public.categories (slug, name, gender, sort_order) values
  ('formal', 'Formal Shoes', 'men', 1),
  ('loafers', 'Loafers', 'men', 2),
  ('casual', 'Casual Shoes', 'men', 3),
  ('leather-sandals', 'Leather Sandals & Chapal', 'men', 4),
  ('boots', 'Boots', 'men', 5),
  ('sports', 'Sports Shoes', 'men', 6),
  ('cricket', 'Cricket Shoes', 'men', 7),
  ('heels', 'Heels', 'women', 1),
  ('flats', 'Flats', 'women', 2),
  ('women-sandals', 'Sandals', 'women', 3),
  ('everyday-comfort', 'Everyday Comfort', 'unisex', 1)
on conflict (slug) do nothing;
