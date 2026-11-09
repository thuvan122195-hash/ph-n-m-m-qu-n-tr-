-- =====================================================================
-- VANSILK · 12 CHẶNG + QUYỀN THEO GHẾ (Sếp chốt 09/11/2026)
-- Chạy SAU file 00, 01, 02. Chạy lại nhiều lần cũng không hỏng.
--
-- 12 chặng: 1 Nhận đơn · 2 Ra rập · 3 May mẫu · 4 Duyệt mẫu · 5 Lên đơn SX · 6 Đã cắt
--           7 Đang may · 8 QC · 9 Bàn giao kho · 10 Xuất cho Sale · 11 Đã giao khách · 12 Phản hồi khách
--
-- Mỗi ghế sửa được đơn đang nằm ở chặng của mình, kéo lùi/nhảy trong phạm vi mình,
-- và được đẩy đơn sang ĐÚNG MỘT chặng kế bên (bàn giao cho ghế sau).
--   Sale       : 1 → 5  và  10 → 12
--   Rập        : 2 → 4      ·  May mẫu: 3
--   Điều phối  : 1 → 7      ·  QC: 8 → 9      ·  Kho: 9
--   Kế toán    : không kéo đơn, chỉ tick "Tiền đã về đủ" + ghi chú, đánh dấu đã trả vệ tinh
--   Quản lý, Giám đốc, Quản trị: mọi chặng
-- Giao vệ tinh: Điều phối (+ toàn quyền). Ghi lần QC: QC (+ toàn quyền).
-- =====================================================================

-- 1) Ghế của người đang đăng nhập (đọc từ chức vụ)
create or replace function public.ghe_toi() returns text
language sql stable security definer set search_path = public as $$
  select case
    when n.id is null or n.trang_thai <> 'dang_lam' then 'khong'
    when n.vai_tro = 'admin' then 'toan_quyen'
    when lower(coalesce(n.chuc_vu, '')) like '%kế toán%' then 'ke_toan'
    when n.vai_tro = 'quan_ly' then 'toan_quyen'
    when lower(coalesce(n.chuc_vu, '')) like '%sale%' then 'sale'
    when lower(coalesce(n.chuc_vu, '')) like '%may mẫu%' then 'may_mau'
    when lower(coalesce(n.chuc_vu, '')) like '%rập%' then 'rap'
    when lower(coalesce(n.chuc_vu, '')) like '%điều phối%' then 'dieu_phoi'
    when lower(coalesce(n.chuc_vu, '')) like '%qc%' then 'qc'
    when lower(coalesce(n.chuc_vu, '')) like '%kho%' then 'kho'
    else 'xem' end
  from (select 1) x left join public.nhan_vien n on n.id = auth.uid();
$$;

create or replace function public.chang_cua_ghe(g text) returns int[]
language sql immutable as $$
  select case g
    when 'toan_quyen' then array[1,2,3,4,5,6,7,8,9,10,11,12]
    when 'sale'       then array[1,2,3,4,5,10,11,12]
    when 'rap'        then array[2,3,4]
    when 'may_mau'    then array[3]
    when 'dieu_phoi'  then array[1,2,3,4,5,6,7]
    when 'qc'         then array[8,9]
    when 'kho'        then array[9]
    else array[]::int[] end;
$$;

-- 2) Đổi 11 → 12 chặng (chỉ dời số MỘT lần: đơn ở 9,10,11 cũ → 10,11,12)
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'don_hang_chang_check'
                   and pg_get_constraintdef(oid) like '%12%') then
    alter table public.don_hang drop constraint if exists don_hang_chang_check;
    alter table public.don_hang disable trigger user;
    update public.don_hang set chang = chang + 1 where chang >= 9;
    alter table public.don_hang enable trigger user;
    update public.don_hang_lich_su set tu_chang = tu_chang + 1 where tu_chang >= 9;
    update public.don_hang_lich_su set den_chang = den_chang + 1 where den_chang >= 9;
    alter table public.don_hang add constraint don_hang_chang_check check (chang between 1 and 12);
  end if;
end $$;

-- 3) Luật quyền khi tạo / sửa / kéo đơn (chạy trước luật 3 khoá)
create or replace function public.don_hang_a_quyen() returns trigger
language plpgsql security definer set search_path = public as $$
declare g text; r int[]; lo int; hi int;
begin
  if auth.uid() is null then return new; end if;          -- chạy trong SQL Editor
  g := public.ghe_toi();
  if g = 'toan_quyen' then return new; end if;
  r := public.chang_cua_ghe(g);

  if tg_op = 'INSERT' then
    if not (1 = any(r)) or not (new.chang = any(r)) then
      raise exception 'Ghế của chị không tạo đơn mới được (chỉ Sale, Điều phối, Quản lý).';
    end if;
    return new;
  end if;

  if g = 'ke_toan' then
    if new.chang is distinct from old.chang
       or (to_jsonb(new) - 'da_thu_du' - 'ghi_chu' - 'sua_luc')
          is distinct from (to_jsonb(old) - 'da_thu_du' - 'ghi_chu' - 'sua_luc') then
      raise exception 'Kế toán chỉ tick "Tiền đã về đủ" và ghi chú, không sửa/kéo đơn.';
    end if;
    return new;
  end if;

  if not (old.chang = any(r)) then
    raise exception 'Đơn đang ở chặng %, không thuộc phần việc của chị nên chỉ xem được.', old.chang;
  end if;
  -- đoạn liền nhau chứa chặng hiện tại (Sale: 1–5 và 10–12 là 2 đoạn riêng)
  lo := old.chang; hi := old.chang;
  while (lo - 1) = any(r) loop lo := lo - 1; end loop;
  while (hi + 1) = any(r) loop hi := hi + 1; end loop;
  if new.chang is distinct from old.chang
     and not (new.chang between lo and hi or new.chang = old.chang + 1) then
    raise exception 'Chị chỉ kéo được đơn trong phần việc của mình, hoặc đẩy sang đúng chặng kế tiếp.';
  end if;
  if new.ma_don is distinct from old.ma_don then
    raise exception 'Chỉ Quản lý mới đổi mã đơn.';
  end if;
  return new;
end $$;
drop trigger if exists don_hang_a_quyen on public.don_hang;
create trigger don_hang_a_quyen before insert or update on public.don_hang
for each row execute function public.don_hang_a_quyen();

-- Ai đang làm cũng được gửi lệnh sửa; luật trên quyết định được hay không.
drop policy if exists "giu don thi sua" on public.don_hang;
create policy "giu don thi sua" on public.don_hang
  for update to authenticated
  using (public.la_nv_dang_lam())
  with check (public.la_nv_dang_lam());

-- 4) Giao vệ tinh: Điều phối + toàn quyền. Kế toán chỉ đánh dấu trả tiền.
create or replace function public.giao_may_a_quyen() returns trigger
language plpgsql security definer set search_path = public as $$
declare g text;
begin
  if auth.uid() is null then return new; end if;
  if pg_trigger_depth() > 1 then return new; end if;     -- lần QC tự cộng số lên dòng giao
  g := public.ghe_toi();
  if g in ('toan_quyen', 'dieu_phoi') then return new; end if;
  if g = 'ke_toan' and tg_op = 'UPDATE'
     and (to_jsonb(new) - 'da_thanh_toan' - 'ngay_thanh_toan' - 'sua_luc' - 'thanh_tien')
         is not distinct from (to_jsonb(old) - 'da_thanh_toan' - 'ngay_thanh_toan' - 'sua_luc' - 'thanh_tien') then
    return new;
  end if;
  raise exception 'Chỉ Điều phối mới giao / sửa dòng giao vệ tinh.';
end $$;
drop trigger if exists giao_may_a_quyen on public.giao_may;
create trigger giao_may_a_quyen before insert or update on public.giao_may
for each row execute function public.giao_may_a_quyen();

-- 5) Ghi lần QC: QC + toàn quyền
drop policy if exists "nv ghi qc" on public.qc_lan;
create policy "nv ghi qc" on public.qc_lan for insert to authenticated
  with check (public.ghe_toi() in ('toan_quyen', 'qc'));

grant execute on function public.ghe_toi() to authenticated;
