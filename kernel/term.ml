open Basic

(** {2 Terms/Patterns} *)

type term =
  | Kind                                (* Kind *)
  | Type  of loc                        (* Type *)
  | DB    of loc*ident*int              (* deBruijn *)
  | Const of loc*ident*ident            (* Global variable *)
  | App   of term * term * term list    (* f a1 [ a2 ; ... an ] , f not an App *)
  | Lam   of loc*ident*term option*term        (* Lambda abstraction *)
  | Pi    of loc*ident*term*term (* Pi abstraction *)

type context = ( loc * ident * term ) list

let rec get_loc = function
  | Type l | DB (l,_,_) | Const (l,_,_) | Lam (l,_,_,_) | Pi (l,_,_,_)  -> l
  | Kind -> dloc
  | App (f,_,_) -> get_loc f

let mk_Kind             = Kind
let mk_Type l           = Type l
let mk_DB l x n         = DB (l,x,n)
let mk_Const l m v      = Const (l,m,v)
let mk_Lam l x a b      = Lam (l,x,a,b)
let mk_Pi l x a b       = Pi (l,x,a,b)
let mk_Arrow l a b      = Pi (l,qmark,a,b)

(* *************************************************** *)
(* Changed fragile ("awful") version for the interval type from cubical *)
let rec compare_ou = Pervasives.compare

and mk_ou f a1 a2 =
  let apd = App(f,a1,(a2::[])) in
  let ap f' x y = App(f',x,(y::[])) in
  let str id = string_of_ident id in
  match (a1,a2) with
  | (x, Const (l,md,id)) -> (match str id with | "0" ->  x | "1" ->  Const (l,md,id) | _ -> apd)
  | (Const (l,md,id), x) -> (match str id with | "0" ->  x | "1" ->  Const (l,md,id) | _ -> apd)
  | (App(f',x,(y::[])), z) ->
    (match f' with
     | Const (_,_,id) ->
       (match str id with
        | "Ou" -> mk_ou f x (mk_ou f' y z)
        | "Et" -> mk_et f' (mk_ou f x z) (mk_ou f y z)
        | _ -> apd
       )
     | _ -> apd
    )
  | (x, App(f',y,(z::[]))) ->
     (match f' with
      | Const (_,_,id) ->
        (match str id with
         | "Ou" ->
	         if compare_ou x y > 0 then mk_ou f y (mk_ou f' x z) else ap f x (ap f' y z)
         | "Et" -> mk_et f' (mk_ou f x z) (mk_ou f y z)
         | _ -> apd
        )
      | _ -> apd
     )
  | (x, y) when compare_ou x y > 0 -> mk_ou f y x
  | (x, y) -> apd

let mk_App f a1 args =
  let str id = string_of_ident id in
  match f with
  | Const (lc,md,nm) ->
    (match args,str nm with
     | (a2::nil),"Et" -> mk_et f a1 a2
     | (a2::nil),"Ou" -> mk_ou f a1 a2
     | _,_ -> App(f,a1,args)
    )
  | App (f',a1',args') -> App (f',a1',args'@(a1::args))
  | _ -> App(f,a1,args)

let rec term_eq t1 t2 =
  (* t1 == t2 || *)
  match t1, t2 with
    | Kind, Kind | Type _, Type _ -> true
    | DB (_,_,n), DB (_,_,n') -> n==n'
    | Const (_,m,v), Const (_,m',v') -> ident_eq v v' && ident_eq m m'
    | App (f,a,l), App (f',a',l') ->
        ( try List.for_all2 term_eq (f::a::l) (f'::a'::l')
          with _ -> false )
    | Lam (_,_,a,b), Lam (_,_,a',b') -> term_eq b b'
    | Pi (_,_,a,b), Pi (_,_,a',b') -> term_eq a a' && term_eq b b'
    | _, _  -> false

let rec pp_term out = function
  | Kind               -> output_string out "Kind"
  | Type _             -> output_string out "Type"
  | DB  (_,x,n)        -> Printf.fprintf out "%a[%i]" pp_ident x n
  | Const (_,m,v)      -> Printf.fprintf out "%a.%a" pp_ident m pp_ident v
  | App (f,a,args)     -> pp_list " " pp_term_wp out (f::a::args)
  | Lam (_,x,None,f)   -> Printf.fprintf out "%a => %a" pp_ident x pp_term f
  | Lam (_,x,Some a,f) -> Printf.fprintf out "%a:%a => %a" pp_ident x pp_term_wp a pp_term f
  | Pi  (_,x,a,b)      -> Printf.fprintf out "%a:%a -> %a" pp_ident x pp_term_wp a pp_term b

and pp_term_wp out = function
  | Kind | Type _ | DB _ | Const _ as t -> pp_term out t
  | t                                  -> Printf.fprintf out "(%a)" pp_term t

let pp_context out ctx =
  pp_list ".\n" (fun out (_,x,ty) ->
                   Printf.fprintf out "%a: %a" pp_ident x pp_term ty )
    out (List.rev ctx)
