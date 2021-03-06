open Basic
open Term
open Rule

let allow_non_linear = ref false

type dtree_error =
  | BoundVariableExpected of pattern
  | VariableBoundOutsideTheGuard of term
  | NotEnoughArguments of loc*ident*int*int*int
  | HeadSymbolMismatch of loc*ident*ident
  | ArityMismatch of loc*ident
  | UnboundVariable of loc*ident*pattern
  | AVariableIsNotAPattern of loc*ident
  | DistinctBoundVariablesExpected of loc*ident
  | NonLinearRule of rule2

exception DtreeExn of dtree_error

type rule2 =
    { loc:loc ; pats:pattern2 array ; right:term ;
      constraints:constr list ; esize:int ; }

(* ************************************************************************** *)

let fold_map (f:'b->'a->('c*'b)) (b0:'b) (alst:'a list) : ('c list*'b) =
  let (clst,b2) =
    List.fold_left (fun (accu,b1) a -> let (c,b2) = f b1 a in (c::accu,b2))
      ([],b0) alst in
    ( List.rev clst , b2 )

(* ************************************************************************** *)

module IntSet = Set.Make(struct type t=int let compare=(-) end)
type lin_ty = { cstr:constr list; fvar:int ; seen:IntSet.t }
let br = hstring "{_}"

let extract_db k = function
  | Var (_,_,n,[]) when n<k -> n
  | p -> raise (DtreeExn (BoundVariableExpected p))

let rec all_distinct = function
  | [] -> true
  | hd::tl -> if List.mem hd tl then false else all_distinct tl

(* This function extracts non-linearity and bracket constraints from a list
 * of patterns. *)
let linearize (esize:int) (lst:pattern list) : int * pattern2 list * constr list =
  let rec aux k (s:lin_ty) = function
  | Lambda (l,x,p) ->
      let (p2,s2) = (aux (k+1) s p) in
        ( Lambda2 (x,p2) , s2 )
  | Var (l,x,n,args) when n<k ->
      let (args2,s2) = fold_map (aux k) s args in
        ( BoundVar2 (x,n,Array.of_list args2) , s2 )
  | Var (l,x,n,args) (* n>=k *) ->
    let args2 = List.map (extract_db k) args in
    if all_distinct args2 then
      begin
        if IntSet.mem (n-k) (s.seen) then
          ( Var2(x,s.fvar+k,args2) ,
            { s with fvar=(s.fvar+1);
                     cstr= (Linearity (mk_DB l x s.fvar,mk_DB l x (n-k)))::(s.cstr) ; } )
        else
          ( Var2(x,n,args2) , { s with seen=IntSet.add (n-k) s.seen; } )
      end
    else
      raise (DtreeExn (DistinctBoundVariablesExpected (l,x)))
    | Brackets t ->
      begin
        try
          ( Var2(br,s.fvar+k,[]),
            { s with fvar=(s.fvar+1);
                     cstr=(Bracket (mk_DB dloc br s.fvar,Subst.unshift k t))::(s.cstr) ;} )
        with
        | Subst.UnshiftExn -> raise (DtreeExn (VariableBoundOutsideTheGuard t))
      end
    | Pattern (_,m,v,args) ->
        let (args2,s2) = (fold_map (aux k) s args) in
          ( Pattern2(m,v,Array.of_list args2) , s2 )
  in
  let (lst,r) = fold_map (aux 0) { fvar=esize; cstr=[]; seen=IntSet.empty; } lst in
    ( r.fvar , lst , r.cstr )

(* For each matching variable count the number of arguments *)
let get_nb_args (esize:int) (p:pattern) : int array =
  let arr = Array.make esize (-1) in (* -1 means +inf *)
  let min a b =
    if a = -1 then b
    else if a<b then a else b
  in
  let rec aux k = function
    | Brackets _ -> ()
    | Var (_,_,n,args) when n<k -> List.iter (aux k) args
    | Var (_,id,n,args) -> arr.(n-k) <- min (arr.(n-k)) (List.length args)
    | Lambda (_,_,pp) -> aux (k+1) pp
    | Pattern (_,_,_,args) -> List.iter (aux k) args
  in
    ( aux 0 p ; arr )

(* Checks that the variables are applied to enough arguments *)
let check_nb_args (nb_args:int array) (te:term) : unit =
  let rec aux k = function
    | Kind | Type _ | Const _ -> ()
    | DB (l,id,n) ->
        if n>=k && nb_args.(n-k)>0 then
          raise (DtreeExn (NotEnoughArguments (l,id,n,0,nb_args.(n-k))))
    | App(DB(l,id,n),a1,args) when n>=k ->
      let min_nb_args = nb_args.(n-k) in
      let nb_args = List.length args + 1 in
        if ( min_nb_args > nb_args  ) then
          raise (DtreeExn (NotEnoughArguments (l,id,n,nb_args,min_nb_args)))
        else List.iter (aux k) (a1::args)
    | App (f,a1,args) -> List.iter (aux k) (f::a1::args)
    | Lam (_,_,None,b) -> aux (k+1) b
    | Lam (_,_,Some a,b) | Pi (_,_,a,b) -> (aux k a;  aux (k+1) b)
  in
    aux 0 te

let check_vars esize ctx p =
  let seen = Array.make esize false in
  let rec aux q = function
    | Pattern (_,_,_,args) -> List.iter (aux q) args
    | Var (_,_,n,args) ->
        begin
          ( if n-q >= 0 then seen.(n-q) <- true );
          List.iter (aux q) args
        end
    | Lambda (_,_,t) -> aux (q+1) t
    | Brackets _ -> ()
  in
    aux 0 p;
    Array.iteri (
      fun i b ->
        if (not b) then
          let (l,x,_) = List.nth ctx i in
            raise (DtreeExn (UnboundVariable (l,x,p)))
    ) seen

let rec is_linear = function
  | [] -> true
  | (Bracket _)::tl -> is_linear tl
  | (Linearity _)::tl -> false

let to_rule_infos (r:Rule.rule2) : (rule_infos,dtree_error) error =
  try
    begin
      let (ctx,lhs,rhs) = r in
      let esize = List.length ctx in
      let (l,md,id,args) = match lhs with
        | Pattern (l,md,id,args) ->
            begin
              check_vars esize ctx lhs;
              (l,md,id,args)
            end
        | Var (l,x,_,_) -> raise (DtreeExn (AVariableIsNotAPattern (l,x)))
        | Lambda _ | Brackets _ -> assert false
      in
      let nb_args = get_nb_args esize lhs in
      let _ = check_nb_args nb_args rhs in
      let (esize2,pats2,cstr) = linearize esize args in
      let is_nl = not (is_linear cstr) in
      if is_nl && (not !allow_non_linear) then
        Err (NonLinearRule r)
      else
        let () = if is_nl then debug "Non-linear Rewrite Rule" in
        OK { l ; ctx ; md ; id ; args ; rhs ;
             esize = esize2 ;
             l_args = Array.of_list pats2 ;
             constraints = cstr ; }
    end
  with
      DtreeExn e -> Err e

(* ************************************************************************** *)

type matrix =
    { col_depth: int array;
      first:rule2 ;
      others:rule2 list ; }

(*
 * col_nums:    [ (n_0,p_0)     (n_1,p_1)       ...     (n_k,p_k) ]
 * first:       [ pats.(0)      pats.(1)        ...     pats.(k)  ]
 * others:      [ pats.(0)      pats.(1)        ...     pats.(k)  ]
 *                      ...
 *              [ pats.(0)      pats.(1)        ...     pats.(k)  ]
 *
 *              n_i is a pointeur to the stack
 *              k_i records the depth of the column (number of binders under which it stands)
 *)

let to_rule2 (r:rule_infos) : rule2 =
  { loc = r.l ;
    pats = r.l_args ;
    right = r.rhs ;
    constraints = r.constraints ;
    esize = r.esize ; }

(* mk_matrix lst builds a matrix out of the non-empty list of rules [lst]
*  It is checked that all rules have the same head symbol and arity.
* *)
let mk_matrix : rule_infos list -> matrix = function
  | [] -> assert false
  | r1::rs ->
      let f = to_rule2 r1 in
      let n = Array.length f.pats in
      let o = List.map (
        fun r2 ->
          if not (ident_eq r1.id r2.id) then
            raise (DtreeExn (HeadSymbolMismatch (r2.l,r1.id,r2.id)))
          else
            let r2' = to_rule2 r2 in
              if n != Array.length r2'.pats then
                raise (DtreeExn (ArityMismatch (r2.l,r1.id)))
              else r2'
      ) rs in
        { first=f; others=o; col_depth=Array.make (Array.length f.pats) 0 ;}

let pop mx =
  match mx.others with
    | [] -> None
    | f::o -> Some { mx with first=f; others=o; }

let width mx = Array.length mx.first.pats

let get_first_term mx = mx.first.right
let get_first_constraints mx = mx.first.constraints

(* ***************************** *)

let filter (f:rule2 -> bool) (mx:matrix) : matrix option =
  match List.filter f (mx.first::mx.others) with
    | [] -> None
    | f::o -> Some { mx with first=f; others=o; }

(* Keeps only the rules with a lambda on column [c] *)
let filter_l c r =
  match r.pats.(c) with
    | Lambda2 _ | Joker2 | Var2 _ -> true
    | _ -> false

(* Keeps only the rules with a bound variable of index [n] on column [c] *)
let filter_bv c n r =
  match r.pats.(c) with
    | BoundVar2 (_,m,_) when n==m -> true
    | Var2 _ | Joker2 -> true
    | _ -> false

(* Keeps only the rules with a pattern head by [m].[v] on column [c] *)
let filter_p c m v r =
  match r.pats.(c) with
    | Pattern2 (m',v',_) when ident_eq v v' && ident_eq m m' -> true
    | Var2 _ | Joker2 -> true
    | _ -> false

(* Keeps only the rules with a joker or a variable on column [c] *)
let default (mx:matrix) (c:int) : matrix option =
  filter (
    fun r -> match r.pats.(c) with
      | Var2 _ | Joker2 -> true
      | Lambda2 _ | Pattern2 _ | BoundVar2 _ -> false
  ) mx

(* ***************************** *)

(* Specialize the rule [r] on column [c]
 * i.e. remove colum [c] and append [nargs] new column at the end.
 * These new columns contain
 * - the arguments if column [c] is a the pattern
 * - or the body if column [c] is a lambda
 * - or Jokers otherwise
* *)
let specialize_rule (c:int) (nargs:int) (r:rule2) : rule2 =
  let size = Array.length r.pats in
  let aux i =
    if i < size then
      if i==c then
        match r.pats.(c) with
          | Var2 _ as v -> v
          | _ -> Joker2
      else r.pats.(i)
    else (* size <= i < size+nargs *)
      match r.pats.(c) with
        | Joker2 | Var2 _ -> Joker2
        | Pattern2 (_,_,pats2) | BoundVar2 (_,_,pats2) ->
            ( assert ( Array.length pats2 == nargs );
              pats2.( i - size ) )
        | Lambda2 (_,p) -> ( assert ( nargs == 1); p )
  in
    { r with pats = Array.init (size+nargs) aux }

(* Specialize the col_infos field of a matrix.
 * Invalid for specialization by lambda. *)
let spec_col_depth (c:int) (nargs:int) (col_depth: int array) : int array =
  let size = Array.length col_depth in
  let aux i =
    if i < size then col_depth.(i)
    else (* < size+nargs *) col_depth.(c)
  in
    Array.init (size+nargs) aux

(* Specialize the col_infos field of a matrix: the lambda case. *)
let spec_col_depth_l (c:int) (col_depth: int array) : int array =
  let size = Array.length col_depth in
  let aux i =
    if i < size then col_depth.(i)
    else (*i == size *) col_depth.(c) + 1
  in
    Array.init (size+1) aux

(* Specialize the matrix [mx] on column [c] *)
let specialize mx c case : matrix =
  let (mx_opt,nargs) = match case with
    | CLam -> ( filter (filter_l c) mx , 1 )
    | CDB (nargs,n) -> ( filter (filter_bv c n) mx , nargs )
    | CConst (nargs,m,v) -> ( filter (filter_p c m v) mx , nargs )
  in
  let new_cn = match case with
    | CLam -> spec_col_depth_l c mx.col_depth
    | _ ->    spec_col_depth c nargs mx.col_depth
  in
    match mx_opt with
      | None -> assert false
      | Some mx2 ->
          { first = specialize_rule c nargs mx2.first;
            others = List.map (specialize_rule c nargs) mx2.others;
            col_depth = new_cn;
          }

(* ***************************** *)

(* Give the index of the first non variable column *)
let choose_column mx =
  let rec aux i =
    if i < Array.length mx.first.pats then
      ( match mx.first.pats.(i) with
        | Pattern2 _ | Lambda2 _ | BoundVar2 _ -> Some i
        | Var2 _ | Joker2 -> aux (i+1) )
    else None
  in aux 0

let eq a b =
  match a, b with
    | CLam, CLam -> true
    | CDB (_,n), CDB (_,n') when n==n' -> true
    | CConst (_,m,v), CConst (_,m',v') when (ident_eq v v' && ident_eq m m') -> true
    | _, _ -> false

let partition mx c =
  let aux lst li =
    let add h = if List.exists (eq h) lst then lst else h::lst in
      match li.pats.(c) with
        | Pattern2 (m,v,pats)  -> add (CConst (Array.length pats,m,v))
        | BoundVar2 (_,n,pats) -> add (CDB (Array.length pats,n))
        | Lambda2 _ -> add CLam
        | Var2 _ | Joker2 -> lst
  in
    List.fold_left aux [] (mx.first::mx.others)

(* ***************************** *)

let array_to_llist arr =
  LList.make_unsafe (Array.length arr) (Array.to_list arr)

(* Extracts the pre_context from the first line. *)
let get_first_pre_context mx =
  let esize = mx.first.esize in
  let dummy = { position=(-1); depth=0; } in
  let dummy2 = { position2=(-1); depth2=0; dbs=LList.nil; } in
  let arr1 = Array.make esize dummy in
  let arr2 = Array.make esize dummy2 in
  let mp = ref false in
    Array.iteri
      (fun i p -> match p with
         | Joker2 -> ()
         | Var2 (_,n,lst) ->
             begin
               let k = mx.col_depth.(i) in
                 assert( 0 <= n-k ) ;
                 assert(n-k < esize ) ;
                 arr1.(n-k) <- { position=i; depth=mx.col_depth.(i); };
                 if lst=[] then
                   arr2.(n-k) <- { position2=i; dbs=LList.nil; depth2=mx.col_depth.(i); }
                 else (
                   mp := true ;
                   arr2.(n-k) <- { position2=i; dbs=LList.of_list lst; depth2=mx.col_depth.(i); } )
             end
         | _ -> assert false
      ) mx.first.pats ;
    ( Array.iter ( fun r -> assert (r.position >= 0 ) ) arr1 );
    if !mp then MillerPattern (array_to_llist arr2)
    else Syntactic (array_to_llist arr1)

(******************************************************************************)

(* Construct a decision tree out of a matrix *)
let rec to_dtree (mx:matrix) : dtree =
  match choose_column mx with
    (* There are only variables on the first line of the matrix *)
    | None   -> Test ( get_first_pre_context mx,
                       get_first_constraints mx,
                       get_first_term mx,
                       map_opt to_dtree (pop mx) )
    (* Pattern on the first line at column c *)
    | Some c ->
        let cases = partition mx c in
        let aux ca = ( ca , to_dtree (specialize mx c ca) ) in
          Switch (c, List.map aux cases, map_opt to_dtree (default mx c) )

(******************************************************************************)


let of_rules (rs:rule_infos list) : (int*dtree,dtree_error) error =
  try
    let mx = mk_matrix rs in OK ( Array.length mx.first.pats , to_dtree mx )
  with DtreeExn e -> Err e
