(** Substitutions using DeBruijn indices. *)
open Term

exception UnshiftExn

val shift               : int -> term -> term
(** [shift i t] shifts every deBruijn indices in [t] by [i]. *)

val unshift             : int -> term -> term
(** [unshift i t] shifts every deBruijn indices in [t] by [-i]. Raise [UnshiftExn] when
    it is applied to an indices [k] such that k < i. *)

val psubst_l            : (term Lazy.t) Basic.LList.t -> int -> term -> term
(** Parallel substitution of lazy terms. *)

val subst               : term -> term -> term
(** [subst te u] substitutes the deBruijn indice [0] with [u] in [te]. *)

val subst_n : int -> Basic.ident -> term -> term
(** [subst_n n y t] replaces x[n] by y[0] and shift by one. *)

module S :
sig
  type t
  val identity : t
  val add : t -> Basic.ident -> int -> term -> t option
  val apply : t -> term -> int -> term
  (* val merge : t -> t -> t *)
  val is_identity : t -> bool
  val mk_idempotent : t -> t
  val pp : out_channel -> t -> unit
  val fold : (int -> (Basic.ident*term) -> 'b -> 'b) -> t -> 'b -> 'b
  val iter : (int -> (Basic.ident*term) -> unit) -> t -> unit
end
