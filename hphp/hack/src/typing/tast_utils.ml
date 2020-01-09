(*
 * Copyright (c) 2018, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Hh_prelude
open Ast_defs
open Aast_defs
open Typing_defs
module Env = Tast_env
module MakeType = Typing_make_type
module Decl_provider = Decl_provider_ctx
module Cls = Decl_provider.Class

(** Return true if ty definitely does not contain null.  I.e., the
    return value false can mean two things: ty does contain null, e.g.,
    it is an option type; or we cannot tell, e.g., it is an opaque
    newtype. *)
let rec type_non_nullable env ty =
  let (_, ty) = Env.expand_type env ty in
  match ty with
  | ( _,
      ( Tprim
          ( Tint | Tbool | Tfloat | Tstring | Tresource | Tnum | Tarraykey
          | Tnoreturn )
      | Tnonnull | Tfun _ | Ttuple _ | Tshape _ | Tanon _ | Tobject | Tclass _
      | Tarraykind _ ) ) ->
    true
  | (_, Tnewtype (_, _, ty))
  | (_, Tdependent (_, ty))
    when type_non_nullable env ty ->
    true
  | (_, Tunion tyl) when not (List.is_empty tyl) ->
    List.for_all tyl (type_non_nullable env)
  | _ -> false

(* Truthiness utilities ******************************************************)
(* For types other than bool used in condition expressions, boolean binary
   expressions, and casts to bool. An always-truthy type used in a condition is
   always a logic error. A nullable possibly-falsy type used in a condition is a
   sketchy null check--it isn't clear whether the user meant to check for null
   or for one of the other falsy values. *)

type truthiness =
  | Unknown
  | Always_truthy
  | Always_falsy
  | Possibly_falsy

let fold_truthiness acc truthiness =
  match (acc, truthiness) with
  | (Unknown, _)
  | (_, Unknown) ->
    Unknown
  | (Always_truthy, Always_truthy) -> Always_truthy
  | (Always_falsy, Always_falsy) -> Always_falsy
  | (Possibly_falsy, Possibly_falsy) -> Possibly_falsy
  | _ -> Possibly_falsy

let intersect_truthiness tr1 tr2 =
  match (tr1, tr2) with
  | (Unknown, Possibly_falsy)
  | (Possibly_falsy, Unknown) ->
    Unknown
  | (Unknown, tr)
  | (tr, Unknown) ->
    tr
  | (Always_truthy, _)
  | (_, Always_truthy) ->
    Always_truthy
  | (Always_falsy, _)
  | (_, Always_falsy) ->
    Always_falsy
  | (Possibly_falsy, Possibly_falsy) -> Possibly_falsy

let (tclass_is_falsy_when_empty, is_traversable) =
  let r = Typing_reason.Rnone in
  let mixed = MakeType.mixed r in
  let simple_xml_el = MakeType.class_type r "\\SimpleXMLElement" [] in
  let container_type = MakeType.container r mixed in
  let pair_type = MakeType.pair r mixed mixed in
  let tclass_is_falsy_when_empty env ty =
    Env.can_subtype env ty simple_xml_el
    || Env.can_subtype env ty container_type
       && not (Env.can_subtype env ty pair_type)
  in
  let trv = MakeType.traversable r mixed in
  let is_traversable env ty = Env.can_subtype env ty trv in
  (tclass_is_falsy_when_empty, is_traversable)

(** Return the {!truthiness} of {ty}. Only possibly-falsy types are suitable
    scrutinees in a truthiness test--it is reasonable to test the truthiness of
    nullable types and container types which are falsy when empty. Other types
    (e.g. user-defined objects) are always truthy, so testing their truthiness
    indicates a logic error. *)
let rec truthiness env ty =
  let (env, ty) = Env.expand_type env ty in
  match snd ty with
  | Tany _
  | Terr
  | Tdynamic
  | Tvar _ ->
    Unknown
  | Tnonnull
  | Tarraykind _
  | Toption _ ->
    Possibly_falsy
  | Tnewtype (id, _, _) when Env.is_enum env id -> Possibly_falsy
  | Tclass ((_, cid), _, _) ->
    if String.equal cid SN.Classes.cStringish then
      Possibly_falsy
    else if String.equal cid SN.Classes.cXHPChild then
      Possibly_falsy
    else if tclass_is_falsy_when_empty env ty then
      Possibly_falsy
    else if not (is_traversable env ty) then
      Always_truthy
    else (
      (* Classes which implement Traversable but not Container will always be
       truthy when empty. If this Tclass is instead an interface type like
       KeyedTraversable, the value may or may not be truthy when empty. *)
      match Decl_provider.get_class (Env.get_ctx env) cid with
      | None -> Unknown
      | Some cls ->
        (match Cls.kind cls with
        | Cnormal
        | Cabstract ->
          Always_truthy
        | Cinterface
        | Cenum ->
          Possibly_falsy
        | Ctrait -> Unknown)
    )
  | Tprim Tresource -> Always_truthy
  | Tprim Tnull -> Always_falsy
  | Tprim Tvoid -> Always_falsy
  | Tprim Tnoreturn -> Unknown
  | Tprim (Tint | Tbool | Tfloat | Tstring | Tnum | Tarraykey) -> Possibly_falsy
  (* Tatom are string at runtine, but neither "0" nor "" are valid atom names *)
  | Tprim (Tatom _) -> Always_truthy
  | Tunion tyl ->
    begin
      match List.map tyl (truthiness env) with
      | [] -> Unknown
      | hd :: tl -> List.fold tl ~init:hd ~f:fold_truthiness
    end
  | Tintersection tyl ->
    List.map tyl (truthiness env)
    |> List.fold ~init:Possibly_falsy ~f:intersect_truthiness
  | Tgeneric _
  | Tnewtype _
  | Tdependent _ ->
    let (env, tyl) = Env.get_concrete_supertypes env ty in
    begin
      match List.map tyl (truthiness env) with
      | [] -> Unknown
      | hd :: tl -> List.fold tl ~init:hd ~f:fold_truthiness
    end
  | Tshape (Closed_shape, fields) when Int.equal 0 (ShapeMap.cardinal fields) ->
    Always_falsy
  | Tshape (_, fields) ->
    let has_non_optional_fields =
      ShapeMap.fold
        (fun _ { sft_optional = opt; _ } -> ( || ) (not opt))
        fields
        false
    in
    if has_non_optional_fields then
      Always_truthy
    else
      Possibly_falsy
  | Ttuple [] -> Always_falsy
  | Tobject
  | Tfun _
  | Ttuple _
  | Tanon _ ->
    Always_truthy
  | Tpu _
  | Tpu_type_access _ ->
    (* TODO(T36532263) check if that's ok *) Unknown

(** When a type represented by one of these variants is used in a truthiness
    test, it indicates a potential logic error, since the truthiness of some
    values in the type may be surprising. *)
type sketchy_type_kind =
  | String
  | Arraykey
  | Stringish
  | XHPChild
      (** Truthiness tests on strings may not behave as expected. The user may not
      know that the string "0" is falsy, and may have intended only to check for
      emptiness. *)
  | Traversable_interface of string
      (** Interface types which implement Traversable but not Container may be
      always truthy, even when empty. *)

let rec find_sketchy_types env acc ty =
  let (env, ty) = Env.expand_type env ty in
  match snd ty with
  | Toption ty -> find_sketchy_types env acc ty
  | Tprim Tstring -> String :: acc
  | Tprim Tarraykey -> Arraykey :: acc
  | Tclass ((_, cid), _, _) ->
    if String.equal cid SN.Classes.cStringish then
      Stringish :: acc
    else if String.equal cid SN.Classes.cXHPChild then
      XHPChild :: acc
    else if tclass_is_falsy_when_empty env ty || not (is_traversable env ty)
    then
      acc
    else (
      match Decl_provider.get_class (Env.get_ctx env) cid with
      | None -> acc
      | Some cls ->
        (match Cls.kind cls with
        | Cinterface -> Traversable_interface (Env.print_ty env ty) :: acc
        | Cnormal
        | Cabstract
        | Ctrait
        | Cenum ->
          acc)
    )
  | Tunion tyl -> List.fold tyl ~init:acc ~f:(find_sketchy_types env)
  | Tintersection tyl ->
    (* If one of the types in tyl does not have any sketchy type, then it's ok. *)
    let sketchy_tys = List.map tyl ~f:(find_sketchy_types env []) in
    let sketchy_tys =
      if List.exists sketchy_tys ~f:List.is_empty then
        []
      else
        List.fold sketchy_tys ~init:[] ~f:( @ )
    in
    sketchy_tys @ acc
  | Tgeneric _
  | Tnewtype _
  | Tdependent _ ->
    let (env, tyl) = Env.get_concrete_supertypes env ty in
    List.fold tyl ~init:acc ~f:(find_sketchy_types env)
  | Tany _
  | Tnonnull
  | Tdynamic
  | Terr
  | Tobject
  | Tprim _
  | Tfun _
  | Ttuple _
  | Tshape _
  | Tvar _
  | Tanon _
  | Tarraykind _ ->
    acc
  | Tpu _ -> acc
  | Tpu_type_access _ -> acc

let find_sketchy_types env ty = find_sketchy_types env [] ty

let valid_newable_class cls =
  match Cls.kind cls with
  | Ast_defs.Cnormal
  | Ast_defs.Cabstract ->
    Cls.final cls
    || not (equal_consistent_kind (snd (Cls.construct cls)) Inconsistent)
  (* There is currently a bug with interfaces that allows constructors to change
   * their signature, so they are not considered here. TODO: T41093452 *)
  | _ -> false
