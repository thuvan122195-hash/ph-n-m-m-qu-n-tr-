-- =====================================================================
-- VANSILK · BẢNG ĐƠN HÀNG CHUNG (11 chặng, Sếp chốt 09/11/2026)
--  1 Nhận đơn · 2 Ra rập · 3 May mẫu · 4 Duyệt mẫu · 5 Lên đơn SX · 6 Đã cắt
--  7 Đang may · 8 QC · 9 Bàn giao Sale · 10 Đã giao khách · 11 Phản hồi khách
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
  chang          smallint not null default 1,
  nguoi_giu      uuid references public.nhan_vien(id) on delete set null,
  dang_cho       text,
  han_giao       date,
  uu_tien        text not null default 'P4' check (uu_tien in ('P0','P1','P2','P3','P4')),
  khoa_ky_thuat  boolean not null default false,  -- 🔑1 bảng kỹ thuật đã ký
  khoa_vai       boolean not null default false,  -- 🔑2 vải đã về kho, đã soi
  khoa_rap       boolean not null default false,  -- 🔑3 rập + số đo đã chốt
  da_thu_du      boolean not null default false,  -- tiền đã về đủ
  ghi_chu        text,
  vao_chang_luc  timestamptz not null default now(),
  tao_luc        timestamptz not null default now(),
  tao_boi        uuid default auth.uid(),
  sua_luc        timestamptz not null default now()
);

-- Cột thêm cho bản 11 chặng (chạy được cả khi bảng đã tạo từ bản 8 chặng)
alter table public.don_hang add column if not exists hoan_tat boolean not null default false;  -- đóng đơn, cất khỏi bảng
alter table public.don_hang add column if not exists phan_hoi text;                             -- lời khách phản hồi
alter table public.don_hang add column if not exists muc_hai_long text;                         -- hai_long / binh_thuong / khieu_nai
alter table public.don_hang drop constraint if exists don_hang_chang_check;
alter table public.don_hang add constraint don_hang_chang_check check (chang between 1 and 11);
alter table public.don_hang drop constraint if exists don_hang_muc_hai_long_check;
alter table public.don_hang add constraint don_hang_muc_hai_long_check
  check (muc_hai_long is null or muc_hai_long in ('hai_long','binh_thuong','khieu_nai'));

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
-- Cổng 1: chưa đủ 3 khoá thì không sang chặng 6 "Đã cắt" (khoá kiểm ở chặng 5 "Lên đơn SX").
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
    if new.chang >= 6
       and (tg_op = 'INSERT' or old.chang < 6)
       and not (new.khoa_ky_thuat and new.khoa_vai and new.khoa_rap) then
      raise exception 'Chưa đủ 3 khoá (bảng kỹ thuật · vải đã soi · rập + số đo) nên chưa cắt được.';
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
