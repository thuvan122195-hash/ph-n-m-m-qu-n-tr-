-- =====================================================================
-- VANSILK · ĐIỀU PHỐI VỆ TINH + TIỀN GIA CÔNG (Sếp chốt 09/11/2026)
-- Chạy SAU file 01. Supabase → SQL Editor → New query → dán → Run.
-- Luật: đơn giá/cái nhập tay · chỉ trả tiền cái QC ĐẠT · tiền = số đạt × đơn giá.
-- =====================================================================

-- 1) Danh sách vệ tinh (người/tổ may ngoài nhận khoán)
create table if not exists public.ve_tinh (
  id        uuid primary key default gen_random_uuid(),
  ten       text not null,
  sdt       text,
  dia_chi   text,
  ghi_chu   text,
  dang_lam  boolean not null default true,
  tao_luc   timestamptz not null default now()
);

-- 2) Mỗi lần giao hàng cho vệ tinh = một dòng
create table if not exists public.giao_may (
  id               uuid primary key default gen_random_uuid(),
  don_id           uuid not null references public.don_hang(id) on delete cascade,
  ve_tinh_id       uuid not null references public.ve_tinh(id),
  so_luong_giao    integer not null check (so_luong_giao > 0),
  don_gia          integer not null check (don_gia >= 0),          -- đồng / cái
  ngay_giao        date not null default current_date,
  han_tra          date,
  so_luong_tra     integer not null default 0 check (so_luong_tra >= 0),
  so_dat           integer not null default 0 check (so_dat >= 0),  -- QC đếm
  so_loi           integer not null default 0 check (so_loi >= 0),
  thanh_tien       bigint generated always as (so_dat::bigint * don_gia) stored,
  da_thanh_toan    boolean not null default false,
  ngay_thanh_toan  date,
  ghi_chu          text,
  tao_boi          uuid default auth.uid(),
  tao_luc          timestamptz not null default now(),
  sua_luc          timestamptz not null default now(),
  constraint giao_may_dat_khong_qua_giao check (so_dat <= so_luong_giao),
  constraint giao_may_dat_loi_khong_qua_tra check (so_dat + so_loi <= so_luong_tra)
);
create index if not exists giao_may_don_idx on public.giao_may (don_id);
create index if not exists giao_may_ve_tinh_idx on public.giao_may (ve_tinh_id);

create or replace function public.giao_may_truoc_luu() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.sua_luc := now();
  if new.da_thanh_toan and new.ngay_thanh_toan is null then new.ngay_thanh_toan := current_date; end if;
  if not new.da_thanh_toan then new.ngay_thanh_toan := null; end if;
  return new;
end $$;
drop trigger if exists giao_may_truoc_luu on public.giao_may;
create trigger giao_may_truoc_luu before insert or update on public.giao_may
for each row execute function public.giao_may_truoc_luu();

-- 3) Khoá quyền
alter table public.ve_tinh enable row level security;
alter table public.giao_may enable row level security;

drop policy if exists "nv xem ve tinh" on public.ve_tinh;
create policy "nv xem ve tinh" on public.ve_tinh for select to authenticated using (public.la_nv_dang_lam());
drop policy if exists "nv them ve tinh" on public.ve_tinh;
create policy "nv them ve tinh" on public.ve_tinh for insert to authenticated with check (public.la_nv_dang_lam());
drop policy if exists "nv sua ve tinh" on public.ve_tinh;
create policy "nv sua ve tinh" on public.ve_tinh for update to authenticated using (public.la_nv_dang_lam()) with check (public.la_nv_dang_lam());

drop policy if exists "nv xem giao may" on public.giao_may;
create policy "nv xem giao may" on public.giao_may for select to authenticated using (public.la_nv_dang_lam());
drop policy if exists "nv giao may" on public.giao_may;
create policy "nv giao may" on public.giao_may for insert to authenticated with check (public.la_nv_dang_lam());
-- Ghi số trả / số đạt: ai đang làm cũng ghi được (điều phối, QC).
-- Đánh dấu ĐÃ THANH TOÁN: chỉ Quản lý / Quản trị (chặn ở hàm bên dưới).
drop policy if exists "nv sua giao may" on public.giao_may;
create policy "nv sua giao may" on public.giao_may for update to authenticated
  using (public.la_nv_dang_lam()) with check (public.la_nv_dang_lam());
drop policy if exists "ql xoa giao may" on public.giao_may;
create policy "ql xoa giao may" on public.giao_may for delete to authenticated using (public.la_quan_ly());

create or replace function public.giao_may_khoa_thanh_toan() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.la_quan_ly() then
    if tg_op = 'INSERT' and new.da_thanh_toan then
      raise exception 'Chỉ Quản lý mới đánh dấu đã thanh toán.';
    end if;
    if tg_op = 'UPDATE' and (new.da_thanh_toan is distinct from old.da_thanh_toan
                              or (old.da_thanh_toan and (new.so_dat, new.don_gia) is distinct from (old.so_dat, old.don_gia))) then
      raise exception 'Chỉ Quản lý mới đổi phần thanh toán hoặc sửa dòng đã trả tiền.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists giao_may_khoa_thanh_toan on public.giao_may;
create trigger giao_may_khoa_thanh_toan before insert or update on public.giao_may
for each row execute function public.giao_may_khoa_thanh_toan();
