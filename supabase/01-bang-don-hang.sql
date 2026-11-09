-- =====================================================================
-- VANSILK · BẢNG ĐƠN HÀNG CHUNG (8 chặng C1 → C8)
-- Cách chạy: Supabase → SQL Editor → New query → dán toàn bộ file → Run.
-- Chạy lại nhiều lần cũng không hỏng (không xoá dữ liệu đã có).
-- Cần sẵn bảng nhan_vien (id = id tài khoản đăng nhập, vai_tro, trang_thai).
-- =====================================================================

-- 1) Hàm kiểm tra quyền (đọc bảng nhan_vien)
create or replace function public.la_nv_dang_lam() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.nhan_vien
                 where id = auth.uid() and trang_thai = 'dang_lam');
$$;

create or replace function public.la_quan_ly() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.nhan_vien
                 where id = auth.uid() and trang_thai = 'dang_lam'
                   and vai_tro in ('admin', 'quan_ly'));
$$;

create or replace function public.la_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.nhan_vien
                 where id = auth.uid() and trang_thai = 'dang_lam'
                   and vai_tro = 'admin');
$$;

-- Danh sách nhân viên đang làm (chỉ tên + phòng ban) để chọn "người giữ đơn".
-- Không mở cả bảng nhan_vien cho mọi người xem.
create or replace function public.ds_nhan_vien()
returns table (id uuid, ma_nv text, ho_ten text, phong_ban text)
language sql stable security definer set search_path = public as $$
  select n.id, n.ma_nv::text, n.ho_ten::text, n.phong_ban::text
  from public.nhan_vien n
  where n.trang_thai = 'dang_lam' and public.la_nv_dang_lam()
  order by n.ho_ten;
$$;

-- 2) Bảng đơn: mỗi dòng là một thẻ trên bảng
create table if not exists public.don_hang (
  id             uuid primary key default gen_random_uuid(),
  ma_don         text not null unique,
  ten_khach      text not null,
  san_pham       text,
  so_luong       integer check (so_luong is null or so_luong >= 0),
  chang          smallint not null default 1 check (chang between 1 and 8),
  nguoi_giu      uuid references public.nhan_vien(id) on delete set null,
  dang_cho       text,
  han_giao       date,
  uu_tien        text not null default 'P4' check (uu_tien in ('P0','P1','P2','P3','P4')),
  khoa_ky_thuat  boolean not null default false,  -- 🔑1 bảng kỹ thuật đã ký
  khoa_vai       boolean not null default false,  -- 🔑2 vải đã về kho, đã soi
  khoa_rap       boolean not null default false,  -- 🔑3 rập + số đo đã chốt
  da_thu_du      boolean not null default false,  -- C8: tiền đã về đủ
  ghi_chu        text,
  vao_chang_luc  timestamptz not null default now(),
  tao_luc        timestamptz not null default now(),
  tao_boi        uuid default auth.uid(),
  sua_luc        timestamptz not null default now()
);

-- 3) Nhật ký chuyển chặng (để đếm số liệu, KPI về sau)
create table if not exists public.don_hang_lich_su (
  id         bigint generated always as identity primary key,
  don_id     uuid not null references public.don_hang(id) on delete cascade,
  tu_chang   smallint,
  den_chang  smallint not null,
  nguoi      uuid default auth.uid(),
  luc        timestamptz not null default now(),
  ghi_chu    text
);
create index if not exists don_hang_lich_su_don_idx on public.don_hang_lich_su (don_id);

-- 4) Luật tự động
-- Cổng 1: chưa đủ 3 khoá thì không vào C7 Sản xuất.
-- Đổi chặng thì tự đặt lại "ngày vào chặng" (để đếm số ngày đứng yên).
create or replace function public.don_hang_truoc_luu() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    new.sua_luc := now();
    new.tao_luc := old.tao_luc;
    new.tao_boi := old.tao_boi;
  end if;
  if tg_op = 'INSERT' or new.chang is distinct from old.chang then
    new.vao_chang_luc := now();
    if new.chang >= 7
       and (tg_op = 'INSERT' or old.chang < 7)
       and not (new.khoa_ky_thuat and new.khoa_vai and new.khoa_rap) then
      raise exception 'Chưa đủ 3 khoá (bảng kỹ thuật · vải đã soi · rập + số đo) nên chưa vào Sản xuất được.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists don_hang_truoc_luu on public.don_hang;
create trigger don_hang_truoc_luu before insert or update on public.don_hang
for each row execute function public.don_hang_truoc_luu();

create or replace function public.don_hang_sau_luu() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.don_hang_lich_su (don_id, tu_chang, den_chang, nguoi, ghi_chu)
    values (new.id, null, new.chang, auth.uid(), 'Tạo đơn');
  elsif new.chang is distinct from old.chang then
    insert into public.don_hang_lich_su (don_id, tu_chang, den_chang, nguoi)
    values (new.id, old.chang, new.chang, auth.uid());
  end if;
  return null;
end $$;

drop trigger if exists don_hang_sau_luu on public.don_hang;
create trigger don_hang_sau_luu after insert or update on public.don_hang
for each row execute function public.don_hang_sau_luu();

-- 5) Khoá quyền (Row Level Security)
alter table public.don_hang enable row level security;
alter table public.don_hang_lich_su enable row level security;

drop policy if exists "nv xem don" on public.don_hang;
create policy "nv xem don" on public.don_hang
  for select to authenticated using (public.la_nv_dang_lam());

drop policy if exists "nv tao don" on public.don_hang;
create policy "nv tao don" on public.don_hang
  for insert to authenticated with check (public.la_nv_dang_lam());

-- Ai đang giữ đơn thì sửa/kéo được đơn đó; Quản lý + Quản trị sửa được mọi đơn.
drop policy if exists "giu don thi sua" on public.don_hang;
create policy "giu don thi sua" on public.don_hang
  for update to authenticated
  using (public.la_quan_ly() or nguoi_giu = auth.uid())
  with check (public.la_nv_dang_lam());

drop policy if exists "admin xoa don" on public.don_hang;
create policy "admin xoa don" on public.don_hang
  for delete to authenticated using (public.la_admin());

drop policy if exists "nv xem lich su" on public.don_hang_lich_su;
create policy "nv xem lich su" on public.don_hang_lich_su
  for select to authenticated using (public.la_nv_dang_lam());
