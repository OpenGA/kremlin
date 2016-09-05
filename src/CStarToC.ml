(** Converting from C* to C abstract syntax. *)

open C
open CStar
open Idents
open KPrint

let any = 
  Cast (Constant (K.UInt8, "0"), Pointer Void)

(* Turns the ML declaration inside-out to match the C reading of a type. *)
let rec mk_spec_and_decl name (t: typ) (k: C.declarator -> C.declarator): C.type_spec * C.declarator =
  match t with
  | Pointer t ->
      mk_spec_and_decl name t (fun d -> Pointer (k d))
  | Array (t, size) ->
      mk_spec_and_decl name t (fun d -> Array (k d, mk_expr size))
  | Function (t, ts) ->
      mk_spec_and_decl name t (fun d -> Function (k d, List.map (fun t -> mk_spec_and_decl "" t (fun d -> d)) ts))
  | Int w ->
      Int w, k (Ident name)
  | Void ->
      Void, k (Ident name)
  | Qualified l ->
      Named (string_of_lident l), k (Ident name)
  | Z ->
      Named "mpz_t", k (Ident name)
  | Bool ->
      Named "bool", k (Ident name)
  | Struct (struct_name, fields) ->
      Struct (struct_name, List.map (fun (name, typ) ->
        let spec, decl = mk_spec_and_declarator name typ in
        spec, None, [ decl, None ]
      ) fields), k (Ident name)

and mk_spec_and_declarator name t =
  mk_spec_and_decl name t (fun d -> d)

and mk_spec_and_declarator_f name ret_t params =
  mk_spec_and_decl name ret_t (fun d -> Function (d, List.map (fun (n, t) -> mk_spec_and_decl n t (fun d -> d)) params))

(* Enforce the invariant that declarations are wrapped in compound statements
 * and cannot appear "alone". *)
and mk_compound_if (stmts: C.stmt list): C.stmt =
  match stmts with
  | [ Decl _ ] ->
      Compound stmts
  | [ stmt ] ->
      stmt
  | _ ->
      Compound stmts

and ensure_compound (stmts: C.stmt list): C.stmt =
  match stmts with
  | [ Compound _ as stmt ] ->
      stmt
  | _ ->
      Compound stmts

and mk_stmt (stmt: stmt): C.stmt list =
  match stmt with
  | Return e ->
      [ Return (Some (mk_expr e)) ]

  | Ignore e ->
      [ Expr (mk_expr e) ]

  | Decl (binder, BufCreate (init, size)) ->
      (* In the case where this is a buffer creation in the C* meaning, then we
       * declare a fixed-length array; this is an "upcast" from pointer type to
       * array type, in the C sense. *)
      let t = match binder.typ with
        | Pointer t -> Array (t, size)
        | _ -> failwith "impossible"
      in
      let module T = struct type init = Nope | Memset | Forloop end in
      let (maybe_init, init_type): C.init option * T.init = match init, size with
        | Constant ((_, "0") as k), Constant _
        | Cast (Constant ((_, "0") as k), _), Constant _ ->
            (* The only case the we can initialize statically is a known, static
             * size _and_ a zero initializer. *)
            Some (Initializer [ InitExpr (C.Constant k) ]), T.Nope
        | Constant ((_, "0")), _ ->
            None, T.Memset
        | _ ->
            None, T.Forloop
      in
      let spec, decl = mk_spec_and_declarator binder.name t in
      let extra_stmt: C.stmt list =
        match init_type with
        | T.Memset ->
            [ Expr (Call (Name "memset", [
                Name binder.name;
                Constant (K.UInt8, "0");
                Op2 (K.Mult,
                  mk_expr size,
                  Sizeof (Index (Name binder.name, Constant (K.UInt8, "0"))))]))]
        | T.Nope ->
            [ ]
        | T.Forloop ->
            (* Note: only works if the length and initial value are pure
             * computations... which F* guarantees! *)
            [ For (
                (Int K.Int, None, [ Ident "i", Some (InitExpr (Constant (K.Int, "0")))]),
                Op2 (K.Lt, Name "i", mk_expr size),
                Op1 (K.PreIncr, Name "i"),
                Expr (Op2 (K.Assign, Index (Name binder.name, Name "i"), mk_expr init)))]
      in
      Decl (spec, None, [ decl, maybe_init ]) :: extra_stmt

  | Decl (binder, BufCreateL inits) ->
      let t = match binder.typ with
        | Pointer t -> Array (t, Constant (Constant.of_int (List.length inits)))
        | _ -> failwith "impossible"
      in
      let spec, decl = mk_spec_and_declarator binder.name t in
      [ Decl (spec, None, [ decl, Some (Initializer (List.map (fun e ->
        InitExpr (mk_expr e)
      ) inits))])]

  | Decl (binder, Struct (_typ, fields)) ->
      let spec, decl = mk_spec_and_declarator binder.name binder.typ in
      let init = initializer_of_fields fields in
      [ Decl (spec, None, [ decl, Some (Initializer init) ]) ]

  | Decl (binder, e) ->
      let spec, decl = mk_spec_and_declarator binder.name binder.typ in
      let init: init option = match e with Any -> None | _ -> Some (InitExpr (mk_expr e)) in
      [ Decl (spec, None, [ decl, init ]) ]

  | IfThenElse (e, b1, b2) ->
      if List.length b2 > 0 then
        [ IfElse (mk_expr e, mk_compound_if (mk_stmts b1), mk_compound_if (mk_stmts b2)) ]
      else
        [ If (mk_expr e, mk_compound_if (mk_stmts b1)) ]

  | Assign (e1, e2) ->
      [ Expr (Assign (mk_expr e1, mk_expr e2)) ]

  | BufWrite (e1, e2, e3) ->
      [ Expr (Assign (Index (mk_expr e1, mk_expr e2), mk_expr e3)) ]

  | BufBlit (e1, e2, e3, e4, e5) ->
      [ Expr (Call (Name "memcpy", [
        Op2 (K.Add, mk_expr e3, mk_expr e4);
        Op2 (K.Add, mk_expr e1, mk_expr e2);
        Op2 (K.Mult, mk_expr e5, Sizeof (Index (mk_expr e1, Constant (K.UInt8, "0"))))])) ]

  | Abort ->
      [ Expr (Call (Name "exit", [ Constant (K.UInt8, "255") ])) ]

  | While (e1, e2) ->
      [ While (mk_expr e1, mk_compound_if (mk_stmts e2)) ]

  | PushFrame | PopFrame ->
      failwith "[mk_stmt]: nested frames not supported"

and mk_stmts stmts: C.stmt list =
  let mk = KList.map_flatten mk_stmt in
  match stmts with
  | PushFrame :: stmts ->
      begin match List.rev stmts with
      | PopFrame :: stmts ->
          [ Compound (mk (List.rev stmts)) ]
      | _ ->
          failwith "[mk_stmts]: unmatched push_frame"
      end
  | _ ->
      mk stmts

and mk_expr (e: expr): C.expr =
  match e with
  | Call (Op o, [ e ]) ->
      Op1 (o, mk_expr e)

  | Call (Op o, [ e1; e2 ]) ->
      Op2 (o, mk_expr e1, mk_expr e2)

  | Call (e, es) ->
      Call (mk_expr e, List.map mk_expr es)

  | Var ident ->
      Name ident

  | Qualified lident ->
      Name (string_of_lident lident)

  | Constant k ->
      Constant k

  | BufCreate _ | BufCreateL _ ->
      failwith "[mk_expr]: Buffer.create; Buffer.createl may only appear as let ... = Buffer.create"

  | BufRead (e1, e2) ->
      Index (mk_expr e1, mk_expr e2)

  | BufSub (e1, e2) ->
      Op2 (K.Add, mk_expr e1, mk_expr e2)

  | Cast (e, t) ->
      Cast (mk_type t, mk_expr e)

  | Any ->
      mk_expr any

  | Op _ ->
      failwith "[mk_expr]: op should've been caught"

  | Bool b ->
      Bool b

  | Struct (name, fields) ->
      let inits = initializer_of_fields fields in
      (* TODO really properly specify C's type_name! *)
      CompoundLiteral ((Named name, Ident ""), inits)

  | Field (e, field) ->
      MemberAccess (mk_expr e, field)


and initializer_of_fields fields =
  List.map (function
    | Some field, e -> Designated (Dot field, mk_expr e)
    | None, e -> InitExpr (mk_expr e)
  ) fields


and mk_type t =
  (* hack alert *)
  mk_spec_and_declarator "" t

(** .c files include their own header *)
let mk_decl_or_function (d: decl): C.declaration_or_function option =
  match d with
  | Type _ ->
      None

  | Function (return_type, name, parameters, body) ->
      begin try
        let parameters = List.map (fun { name; typ } -> name, typ) parameters in
        let spec, decl = mk_spec_and_declarator_f name return_type parameters in
        let body = ensure_compound (mk_stmts body) in
        Some (Function ((spec, None, [ decl, None ]), body))
      with e ->
        beprintf "Fatal exception raised in %s\n" name;
        raise e
      end

  | Global (name, t, expr) ->
      let t = match t with Function _ -> Pointer t | _ -> t in
      let spec, decl = mk_spec_and_declarator name t in
      let expr = mk_expr expr in
      Some (Decl (spec, None, [ decl, Some (InitExpr expr) ]))


let mk_program decls =
  KList.filter_map mk_decl_or_function decls

let mk_files files =
  List.map (fun (name, program) -> name, mk_program program) files


let mk_stub_or_function (d: decl): C.declaration_or_function =
  match d with
  | Type (name, t) ->
      let spec, decl = mk_spec_and_declarator name t in
      Decl (spec, Some Typedef, [ decl, None ])

  | Function (return_type, name, parameters, _) ->
      begin try
        let parameters = List.map (fun { name; typ } -> name, typ) parameters in
        let spec, decl = mk_spec_and_declarator_f name return_type parameters in
        Decl (spec, None, [ decl, None ])
      with e ->
        beprintf "Fatal exception raised in %s\n" name;
        raise e
      end

  | Global (name, t, _) ->
      let t = match t with Function _ -> Pointer t | _ -> t in
      let spec, decl = mk_spec_and_declarator name t in
      Decl (spec, Some Extern, [ decl, None ])


let mk_header decls =
  List.map mk_stub_or_function decls

let mk_headers files =
  List.map (fun (name, program) -> name, mk_header program) files
