-- =====================================================================
-- VANSILK · NHÂN VIÊN + TÀI KHOẢN ĐĂNG NHẬP (chạy ĐẦU TIÊN, trước file 01)
-- Supabase → SQL Editor → New query → dán toàn bộ file → Run.
-- Chạy lại nhiều lần cũng không hỏng.
--
-- Đăng nhập trong app bằng MÃ NHÂN VIÊN + MẬT KHẨU.
-- (Bên trong, mã NV001 được đổi thành email nv001@vansilk.local — người dùng không cần biết.)
--
-- 3 quyền:
--   admin     = Quản trị : mọi việc + tạo/khoá tài khoản + xoá đơn
--   quan_ly   = Quản lý  : sửa/kéo mọi đơn, đánh dấu đã trả tiền vệ tinh, sửa lần QC ghi sai
--   nhan_vien = Nhân viên: xem bảng, tạo đơn, kéo đơn mình đang giữ, ghi giao vệ tinh + QC
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.nhan_vien (
  id          uuid primary key references auth.users(id) on delete cascade,
  ma_nv       text not null unique,
  ho_ten      text not null,
  phong_ban   text,
  chuc_vu     text,
  vai_tro     text not null default 'nhan_vien' check (vai_tro in ('admin','quan_ly','nhan_vien')),
  trang_thai  text not null default 'dang_lam' check (trang_thai in ('dang_lam','tam_khoa','nghi_viec')),
  tao_luc     timestamptz not null default now()
);

-- Hàm kiểm tra quyền (file 01 cũng có, chạy lại không sao)
create or replace function public.la_nv_dang_lam() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.nhan_vien where id = auth.uid() and trang_thai = 'dang_lam');
$$;
create or replace function public.la_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.nhan_vien where id = auth.uid() and trang_thai = 'dang_lam' and vai_tro = 'admin');
$$;

alter table public.nhan_vien enable row level security;
drop policy if exists "nv xem ho so minh" on public.nhan_vien;
create policy "nv xem ho so minh" on public.nhan_vien for select to authenticated using (id = auth.uid() or public.la_admin());
drop policy if exists "admin sua nhan vien" on public.nhan_vien;
create policy "admin sua nhan vien" on public.nhan_vien for update to authenticated
  using (public.la_admin()) with check (public.la_admin());

-- Tạo tài khoản: chỉ Quản trị (trong app) hoặc chạy trực tiếp ở SQL Editor (lần đầu cho Sếp)
create or replace function public.tao_nhan_vien(
  p_ma text, p_ho_ten text, p_mat_khau text,
  p_phong_ban text default null, p_chuc_vu text default null, p_vai_tro text default 'nhan_vien')
returns uuid
language plpgsql security definer set search_path = public, extensions, auth as $$
declare
  uid uuid := gen_random_uuid();
  ma  text := upper(trim(p_ma));
  em  text := lower(trim(p_ma)) || '@vansilk.local';
begin
  if auth.uid() is not null and not public.la_admin() then
    raise exception 'Chỉ Quản trị mới tạo được tài khoản.';
  end if;
  if ma = '' or ma ~ '[^A-Z0-9_.-]' then raise exception 'Mã nhân viên chỉ gồm chữ không dấu và số, VD NV001.'; end if;
  if coalesce(trim(p_ho_ten), '') = '' then raise exception 'Cần có họ tên.'; end if;
  if length(coalesce(p_mat_khau, '')) < 6 then raise exception 'Mật khẩu cần ít nhất 6 ký tự.'; end if;
  if p_vai_tro not in ('admin','quan_ly','nhan_vien') then raise exception 'Quyền không hợp lệ.'; end if;
  if exists (select 1 from auth.users where email = em) or exists (select 1 from public.nhan_vien where ma_nv = ma) then
    raise exception 'Mã % đã có tài khoản.', ma;
  end if;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change, email_change_token_new)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em,
          crypt(p_mat_khau, gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}', jsonb_build_object('ma_nv', ma), now(), now(),
          '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text,
          jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true), 'email', now(), now(), now());
  insert into public.nhan_vien (id, ma_nv, ho_ten, phong_ban, chuc_vu, vai_tro, trang_thai)
  values (uid, ma, trim(p_ho_ten), nullif(trim(p_phong_ban), ''), nullif(trim(p_chuc_vu), ''), p_vai_tro, 'dang_lam');
  return uid;
end $$;

-- Cấp lại mật khẩu: chỉ Quản trị
create or replace function public.dat_lai_mat_khau(p_id uuid, p_mat_khau text) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if auth.uid() is not null and not public.la_admin() then raise exception 'Chỉ Quản trị mới cấp lại mật khẩu được.'; end if;
  if length(coalesce(p_mat_khau, '')) < 6 then raise exception 'Mật khẩu cần ít nhất 6 ký tự.'; end if;
  update auth.users set encrypted_password = crypt(p_mat_khau, gen_salt('bf')), updated_at = now() where id = p_id;
  if not found then raise exception 'Không tìm thấy tài khoản.'; end if;
end $$;

-- Không cho Quản trị tự hạ quyền / tự khoá chính mình (tránh mất hết quyền quản trị)
create or replace function public.nhan_vien_khong_tu_khoa() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() = old.id and (new.vai_tro <> 'admin' or new.trang_thai <> 'dang_lam') then
    raise exception 'Không tự hạ quyền hoặc tự khoá tài khoản của chính mình được.';
  end if;
  new.id := old.id; new.ma_nv := old.ma_nv;
  return new;
end $$;
drop trigger if exists nhan_vien_khong_tu_khoa on public.nhan_vien;
create trigger nhan_vien_khong_tu_khoa before update on public.nhan_vien
for each row execute function public.nhan_vien_khong_tu_khoa();

revoke execute on function public.tao_nhan_vien(text, text, text, text, text, text) from public, anon;
grant  execute on function public.tao_nhan_vien(text, text, text, text, text, text) to authenticated;
revoke execute on function public.dat_lai_mat_khau(uuid, text) from public, anon;
grant  execute on function public.dat_lai_mat_khau(uuid, text) to authenticated;

-- =====================================================================
-- TÀI KHOẢN ĐẦU TIÊN CHO SẾP (chạy MỘT lần, sau khi chạy phần trên):
-- Mở New query khác, dán dòng dưới, ĐỔI chữ MatKhauCuaSep thành mật khẩu Sếp chọn, rồi Run.
--
--   select public.tao_nhan_vien('NV001', 'Lê Thị Thu Vân', 'MatKhauCuaSep', 'Ban Giám đốc', 'Giám đốc', 'admin');
--
-- Sau đó vào app: mã NV001 + mật khẩu vừa đặt. Nhân viên khác Sếp tạo ngay trong app
-- (trang "Quản lý nhân viên"), không cần vào Supabase nữa.
-- =====================================================================
