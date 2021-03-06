(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

module F = Format

type base = Var.t * Typ.t

type access =
  | FieldAccess of Ident.fieldname * Typ.t
  | ArrayAccess of Typ.t

type raw = base * access list

type t =
  | Exact of raw
  | Abstracted of raw

let base_compare ((var1, typ1) as base1) ((var2, typ2) as base2) =
  if base1 == base2
  then 0
  else
    Var.compare var1 var2
    |> next Typ.array_sensitive_compare typ1 typ2

let base_equal base1 base2 =
  base_compare base1 base2 = 0

let access_compare access1 access2 =
  if access1 == access2
  then 0
  else
    match access1, access2 with
    | FieldAccess (f1, typ1), FieldAccess (f2, typ2) ->
        Ident.fieldname_compare f1 f2
        |> next Typ.compare typ1 typ2
    | ArrayAccess typ1, ArrayAccess typ2 ->
        Typ.compare typ1 typ2
    | FieldAccess _, _ -> 1
    | _, FieldAccess _ -> -1

let access_equal access1 access2 =
  access_compare access1 access2 = 0

let raw_compare ((base1, accesses1) as ap1) ((base2, accesses2) as ap2) =
  if ap1 == ap2
  then 0
  else
    base_compare base1 base2
    |> next (IList.compare access_compare) accesses1 accesses2

let raw_equal ap1 ap2 =
  raw_compare ap1 ap2 = 0

let compare ap1 ap2 = match ap1, ap2 with
  | Exact ap1, Exact ap2 | Abstracted ap1, Abstracted ap2 -> raw_compare ap1 ap2
  | Exact _, Abstracted _ -> 1
  | Abstracted _, Exact _ -> (-1)

let equal ap1 ap2 =
  compare ap1 ap2 = 0

let base_of_pvar pvar typ =
  Var.of_pvar pvar, typ

let base_of_id id typ =
  Var.of_id id, typ

let of_pvar pvar typ =
  base_of_pvar pvar typ, []

let of_id id typ =
  base_of_id id typ, []

let of_exp exp0 typ0 ~(f_resolve_id : Var.t -> raw option) =
  (* [typ] is the type of the last element of the access path (e.g., typeof(g) for x.f.g) *)
  let rec of_exp_ exp typ accesses acc =
    match exp with
    | Exp.Var id ->
        begin
          match f_resolve_id (Var.of_id id) with
          | Some (base, base_accesses) -> (base, base_accesses @ accesses) :: acc
          | None -> (base_of_id id typ, accesses) :: acc
        end
    | Exp.Lvar pvar when Pvar.is_frontend_tmp pvar ->
        begin
          match f_resolve_id (Var.of_pvar pvar) with
          | Some (base, base_accesses) -> (base, base_accesses @ accesses) :: acc
          | None -> (base_of_pvar pvar typ, accesses) :: acc
        end
    | Exp.Lvar pvar ->
        (base_of_pvar pvar typ, accesses) :: acc
    | Exp.Lfield (root_exp, fld, root_exp_typ) ->
        let field_access = FieldAccess (fld, typ) in
        of_exp_ root_exp root_exp_typ (field_access :: accesses) acc
    | Exp.Lindex (root_exp, _) ->
        let array_access = ArrayAccess typ in
        let array_typ = Typ.Tarray (typ, None) in
        of_exp_ root_exp array_typ (array_access :: accesses) acc
    | Exp.Cast (cast_typ, cast_exp) ->
        of_exp_ cast_exp cast_typ [] acc
    | Exp.UnOp (_, unop_exp, _) ->
        of_exp_ unop_exp typ [] acc
    | Exp.Exn exn_exp ->
        of_exp_ exn_exp typ [] acc
    | Exp.BinOp (_, exp1, exp2) ->
        of_exp_ exp1 typ [] acc
        |> of_exp_ exp2 typ []
    | Exp.Const _ | Closure _ | Sizeof _ ->
        (* trying to make access path from an invalid expression *)
        acc in
  of_exp_ exp0 typ0 [] []

let of_lhs_exp lhs_exp typ ~(f_resolve_id : Var.t -> raw option) =
  match of_exp lhs_exp typ ~f_resolve_id with
  | [lhs_ap] -> Some lhs_ap
  | _ -> None

let append (base, old_accesses) new_accesses =
  base, old_accesses @ new_accesses

let with_base_var var = function
  | Exact ((_, base_typ), accesses) -> Exact ((var, base_typ), accesses)
  | Abstracted ((_, base_typ), accesses) -> Abstracted ((var, base_typ), accesses)

let rec is_prefix_path path1 path2 =
  if path1 == path2
  then true
  else
    match path1, path2 with
    | [], _ -> true
    | _, [] -> false
    | access1 :: p1, access2 :: p2 -> access_equal access1 access2 && is_prefix_path p1 p2

let is_prefix ((base1, path1) as ap1) ((base2, path2) as ap2) =
  if ap1 == ap2
  then true
  else
    base_equal base1 base2 && is_prefix_path path1 path2

let extract = function
  | Exact ap | Abstracted ap -> ap

let is_exact = function
  | Exact _ -> true
  | Abstracted _ -> false

let (<=) ~lhs ~rhs =
  match lhs, rhs with
  | Abstracted _, Exact _ -> false
  | Exact lhs_ap, Exact rhs_ap -> raw_equal lhs_ap rhs_ap
  | (Exact lhs_ap | Abstracted lhs_ap), Abstracted rhs_ap -> is_prefix rhs_ap lhs_ap

let pp_base fmt (pvar, _) =
  Var.pp fmt pvar

let pp_access fmt = function
  | FieldAccess (field_name, _) -> Ident.pp_fieldname fmt field_name
  | ArrayAccess _ -> F.fprintf fmt "[_]"

let pp_access_list fmt accesses =
  let pp_sep _ _ = F.fprintf fmt "." in
  F.pp_print_list ~pp_sep pp_access fmt accesses

let pp_raw fmt = function
  | base, [] ->  pp_base fmt base
  | base, accesses ->  F.fprintf fmt "%a.%a" pp_base base pp_access_list accesses

let pp fmt = function
  | Exact access_path -> pp_raw fmt access_path
  | Abstracted access_path -> F.fprintf fmt "%a*" pp_raw access_path

module BaseMap = PrettyPrintable.MakePPMap(struct
    type t = base
    let compare = base_compare
    let pp_key = pp_base
  end)

module AccessMap = PrettyPrintable.MakePPMap(struct
    type t = access
    let compare = access_compare
    let pp_key = pp_access
  end)
