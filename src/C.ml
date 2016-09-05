(** A (simplified) grammar of C. *)

module K = Constant

(* This pretty-printer based on: http:/ /en.cppreference.com/w/c/language/declarations 
 * Many cases are omitted from this bare-bones C grammar; hopefully, to be extended. *)
type type_spec =
  | Int of Constant.width
  | Void
  | Named of ident
  | Struct of ident option * declaration list
    (** not encoding all the invariants here *)

and storage_spec =
  | Typedef
  | Extern

and declarator_and_init =
  declarator * init option

and declarator_and_inits =
  declarator_and_init list

and declarator =
  | Ident of ident
  | Pointer of declarator
  | Array of declarator * expr
  | Function of declarator * params

and expr =
  | Op1 of K.op * expr
  | Op2 of K.op * expr * expr
  | Index of expr * expr
  | Deref of expr
  | Address of expr
  | Member of expr * expr
  | MemberP of expr * expr
  | Assign of expr * expr
    (** not covering *=, +=, etc. *)
  | Call of expr * expr list
  | Name of ident
  | Cast of type_name * expr
  | Constant of K.t
  | Bool of bool
  | Sizeof of expr
  | CompoundLiteral of type_name * init list
  | MemberAccess of expr * ident

(** this is a WILD approximation of the notion of "type name" in C _and_ a hack
 * because there's the invariant that the ident found at the bottom of the
 * [declarator] is irrelevant... *)
and type_name =
  type_spec * declarator

and params =
  (* No support for old syntax, e.g. K&R, or [void f(void)]. *)
  param list

and param =
  (** Also approximate. *)
  type_spec * declarator

and declaration =
  type_spec * storage_spec option * declarator_and_inits

and ident =
  string

and init =
  | InitExpr of expr
  | Designated of designator * expr
  | Initializer of init list

and designator =
  | Dot of ident
  | Bracket of int

(** Note: according to http:/ /en.cppreference.com/w/c/language/statements,
 * declarations can only be part of a compound statement... we do not enforce
 * this invariant via the type [stmt], but rather check it at runtime (see
 * [mk_compound_if]), as the risk of messing things up, naturally. *)
type stmt =
  | Compound of stmt list
  | Decl of declaration
  | Expr of expr
  | If of expr * stmt
  | IfElse of expr * stmt * stmt
  | While of expr * stmt
  | For of declaration * expr * expr * stmt
    (** "init_clause may be an expression or a declaration" -> only doing the
     * latter *)
  | Return of expr option

and program =
  declaration_or_function list

and declaration_or_function =
  | Decl of declaration
  | Function of declaration * stmt
    (** [stmt] _must_ be a compound statement *)
