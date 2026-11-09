-- =====================================================================
-- VANSILK · ĐIỀU PHỐI VỆ TINH + QC NHIỀU LẦN + TIỀN GIA CÔNG
-- Chạy SAU file 01. Supabase → SQL Editor → New query → dán → Run.
-- Chạy lại nhiều lần cũng không hỏng.
--
-- Luật Sếp chốt 09/11/2026:
--  · Đơn giá/cái nhập tay cho mỗi lần giao.
--  · Mỗi lần nhận hàng về = một lần QC: Đạt + Cần sửa + Hư = Số nhận về.
--  · Cái cần sửa và cái hư đều Ở LẠI vệ tinh. Hư (do vải hay do may) thì xưởng
--    cấp lại vải, vệ tinh may lại cho đủ đơn, không để rớt cái nào.
--    Vẫn ghi hư do vải hay do may để biết lỗi ở khâu nào + số vải phải cấp lại.
--  · Tiền công = Số cái ĐẠT × Đơn giá. Trả 1 lần, sửa / may lại không trả thêm.
--  · Đơn hàng có "đơn giá gia công / cái" để biết cả đơn tốn bao nhiêu tiền công.
-- =====================================================================

-- 0) Đơn giá gia công / cái trên đơn hàng
alter table public.don_hang add column if not exists don_gia_gia_cong integer check (don_gia_gia_cong is null or don_gia_gia_cong >= 0);

-- 1) Danh sách vệ tinh
create table if not exists public.ve_tinh (
  id        uuid primary key default gen_random_uuid(),
  ten       text not null,
  sdt       text,
  dia_chi   text,            -- nơi ở hiện nay (nơi giao nhận hàng)
  ghi_chu   text,
  dang_lam  boolean not null default true,
  tao_luc   timestamptz not null default now()
);
alter table public.ve_tinh add column if not exists ma text;         -- mã vệ tinh, VD XM7
alter table public.ve_tinh add column if not exists danh_xung text;  -- Ông / Bà
alter table public.ve_tinh add column if not exists que_quan text;   -- địa chỉ thường trú
create unique index if not exists ve_tinh_ma_key on public.ve_tinh (ma);

-- 2) Mỗi lần giao hàng cho vệ tinh = một dòng.
--    Các cột số (đã nhận, đạt, hư…) do lần QC tự cộng lên, không gõ tay.
create table if not exists public.giao_may (
  id               uuid primary key default gen_random_uuid(),
  don_id           uuid not null references public.don_hang(id) on delete cascade,
  ve_tinh_id       uuid not null references public.ve_tinh(id),
  so_luong_giao    integer not null check (so_luong_giao > 0),
  don_gia          integer not null check (don_gia >= 0),   -- đồng / cái
  ngay_giao        date not null default current_date,
  han_tra          date,
  so_luong_tra     integer not null default 0,              -- tổng số đã nhận về qua các lần QC
  so_dat           integer not null default 0,
  da_thanh_toan    boolean not null default false,
  ngay_thanh_toan  date,
  ghi_chu          text,
  tao_boi          uuid default auth.uid(),
  tao_luc          timestamptz not null default now(),
  sua_luc          timestamptz not null default now()
);
alter table public.giao_may add column if not exists so_hu_may    integer not null default 0;  -- hư do vệ tinh
alter table public.giao_may add column if not exists so_hu_xuong  integer not null default 0;  -- hư do vải / cắt
alter table public.giao_may add column if not exists so_kiem_lan1 integer not null default 0;  -- lần 1: nhận − hư
alter table public.giao_may add column if not exists so_dat_lan1  integer not null default 0;
alter table public.giao_may drop constraint if exists giao_may_dat_loi_khong_qua_tra;
alter table public.giao_may drop constraint if exists giao_may_dat_khong_qua_giao;
alter table public.giao_may drop constraint if exists giao_may_xong_khong_qua_giao;
alter table public.giao_may add constraint giao_may_xong_khong_qua_giao
  check (so_dat <= so_luong_giao);
alter table public.giao_may drop column if exists thanh_tien;
alter table public.giao_may add column thanh_tien bigint
  generated always as (so_dat::bigint * don_gia) stored;
create index if not exists giao_may_don_idx on public.giao_may (don_id);
create index if not exists giao_may_ve_tinh_idx on public.giao_may (ve_tinh_id);

-- 3) Mỗi lần nhận hàng về + QC
create table if not exists public.qc_lan (
  id           uuid primary key default gen_random_uuid(),
  giao_may_id  uuid not null references public.giao_may(id) on delete cascade,
  lan          smallint not null,
  ngay         date not null default current_date,
  so_nhan      integer not null check (so_nhan > 0),
  so_dat       integer not null default 0 check (so_dat >= 0),
  so_sua       integer not null default 0 check (so_sua >= 0),
  hu_may       integer not null default 0 check (hu_may >= 0),
  hu_xuong     integer not null default 0 check (hu_xuong >= 0),
  ly_do        text,
  nguoi        uuid default auth.uid(),
  tao_luc      timestamptz not null default now(),
  constraint qc_lan_cong_dung check (so_dat + so_sua + hu_may + hu_xuong = so_nhan),
  constraint qc_lan_khong_trung unique (giao_may_id, lan)
);
create index if not exists qc_lan_giao_idx on public.qc_lan (giao_may_id);

-- Trước khi ghi một lần QC: tự đánh số lần, không cho nhận về nhiều hơn số còn ở vệ tinh
create or replace function public.qc_lan_truoc_luu() returns trigger
language plpgsql security definer set search_path = public as $$
declare g public.giao_may; con integer;
begin
  select * into g from public.giao_may where id = new.giao_may_id for update;
  if tg_op = 'INSERT' then
    select coalesce(max(lan), 0) + 1 into new.lan from public.qc_lan where giao_may_id = new.giao_may_id;
  end if;
  -- Còn ở vệ tinh = số giao − số đã đạt (cái sửa và cái hư vẫn ở vệ tinh để may lại)
  select g.so_luong_giao - coalesce(sum(so_dat), 0) into con
  from public.qc_lan where giao_may_id = new.giao_may_id and id <> new.id;
  if new.so_nhan > con then
    raise exception 'Vệ tinh chỉ còn giữ % cái, không nhận về % cái được.', con, new.so_nhan;
  end if;
  return new;
end $$;
drop trigger if exists qc_lan_truoc_luu on public.qc_lan;
create trigger qc_lan_truoc_luu before insert or update on public.qc_lan
for each row execute function public.qc_lan_truoc_luu();

-- Sau khi ghi / sửa / xoá một lần QC: cộng lại số lên dòng giao
create or replace function public.qc_lan_cong_lai() returns trigger
language plpgsql security definer set search_path = public as $$
declare gid uuid := coalesce(new.giao_may_id, old.giao_may_id);
begin
  update public.giao_may g set
    so_luong_tra = s.nhan, so_dat = s.dat, so_hu_may = s.hm, so_hu_xuong = s.hx,
    so_kiem_lan1 = coalesce(l1.so_nhan - l1.hu_may - l1.hu_xuong, 0),
    so_dat_lan1  = coalesce(l1.so_dat, 0)
  from (select coalesce(sum(so_nhan),0) nhan, coalesce(sum(so_dat),0) dat,
               coalesce(sum(hu_may),0) hm, coalesce(sum(hu_xuong),0) hx
        from public.qc_lan where giao_may_id = gid) s
  left join (select * from public.qc_lan where giao_may_id = gid order by lan limit 1) l1 on true
  where g.id = gid;
  return null;
end $$;
drop trigger if exists qc_lan_cong_lai on public.qc_lan;
create trigger qc_lan_cong_lai after insert or update or delete on public.qc_lan
for each row execute function public.qc_lan_cong_lai();

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

-- Chỉ Quản lý đánh dấu đã trả tiền, và dòng đã trả thì không ai khác đổi số / giá được
create or replace function public.giao_may_khoa_thanh_toan() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.la_quan_ly() then
    if tg_op = 'INSERT' and new.da_thanh_toan then
      raise exception 'Chỉ Quản lý mới đánh dấu đã thanh toán.';
    end if;
    if tg_op = 'UPDATE' and (new.da_thanh_toan is distinct from old.da_thanh_toan
        or (old.da_thanh_toan and (new.so_dat, new.don_gia, new.so_luong_giao)
                                  is distinct from (old.so_dat, old.don_gia, old.so_luong_giao))) then
      raise exception 'Dòng này đã trả tiền. Chỉ Quản lý mới sửa được.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists giao_may_khoa_thanh_toan on public.giao_may;
create trigger giao_may_khoa_thanh_toan before insert or update on public.giao_may
for each row execute function public.giao_may_khoa_thanh_toan();

-- 4) Khoá quyền
alter table public.ve_tinh  enable row level security;
alter table public.giao_may enable row level security;
alter table public.qc_lan   enable row level security;

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
drop policy if exists "nv sua giao may" on public.giao_may;
create policy "nv sua giao may" on public.giao_may for update to authenticated
  using (public.la_nv_dang_lam()) with check (public.la_nv_dang_lam());
drop policy if exists "ql xoa giao may" on public.giao_may;
create policy "ql xoa giao may" on public.giao_may for delete to authenticated using (public.la_quan_ly());

-- Ai đang làm cũng ghi được lần QC (điều phối, QC). Sửa / xoá lần QC ghi sai: Quản lý.
drop policy if exists "nv xem qc" on public.qc_lan;
create policy "nv xem qc" on public.qc_lan for select to authenticated using (public.la_nv_dang_lam());
drop policy if exists "nv ghi qc" on public.qc_lan;
create policy "nv ghi qc" on public.qc_lan for insert to authenticated with check (public.la_nv_dang_lam());
drop policy if exists "ql sua qc" on public.qc_lan;
create policy "ql sua qc" on public.qc_lan for update to authenticated using (public.la_quan_ly()) with check (public.la_quan_ly());
drop policy if exists "ql xoa qc" on public.qc_lan;
create policy "ql xoa qc" on public.qc_lan for delete to authenticated using (public.la_quan_ly());
