(** Term reduction and conversion test. *)

open Term

val hnf         : Signature.t -> term -> term
(** [hnf sg te] computes the head normal form of [te] using the signature [sg]. *)

val whnf        : Signature.t -> term -> term
(** Same as {!hnf} for the weak head normal form. *)

val snf         : Signature.t -> term -> term
(** Same as {!hnf} for the strong normal form. *)

val are_convertible             : Signature.t -> term -> term -> bool
(** [are_convertible sg t1 t2] check if [t1] and [t2] are convertible using the signature [sg]. *)

val one_step                    : Signature.t -> term -> term option
(** [one_step sg te] computes one reduction step on [te] using the signature [sg]. *)
