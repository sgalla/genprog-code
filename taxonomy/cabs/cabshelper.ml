
open Cabs

let nextident = ref 0
let getident () =
    nextident := !nextident + 1;
    !nextident

let currentLoc () = 
  let l, f, c = Errormsg.getPosition () in
  { lineno   = l; 
    filename = f; 
    byteno   = c;
    ident    = getident ();}

let cabslu = {lineno = -10; 
	      filename = "cabs loc unknown"; 
	      byteno = -10;
              ident = 0}

(* clexer puts comments here *)
let commentsGA = Growarray.make 100 (Growarray.Elem(cabslu,"",false))


(*********** HELPER FUNCTIONS **********)

let missingFieldDecl = ("___missing_field_name", JUSTBASE, [], cabslu)

let rec isStatic = function
    [] -> false
  | (SpecStorage STATIC) :: _ -> true
  | _ :: rest -> isStatic rest

let rec isExtern = function
    [] -> false
  | (SpecStorage EXTERN) :: _ -> true
  | _ :: rest -> isExtern rest

let rec isInline = function
    [] -> false
  | SpecInline :: _ -> true
  | _ :: rest -> isInline rest

let rec isTypedef = function
    [] -> false
  | node :: _ when node == SpecTypedef -> true
  | _ :: rest -> isTypedef rest


let get_definitionloc (d : definition) : cabsloc =
  match d with
  | DIRECTIVE(n) -> 
	  (match (dn n) with
		 PREINCLUDE(_,l) -> l)
  | FUNDEF(_, _, l, _) -> l
  | DECDEF(_, l) -> l
  | TYPEDEF(_, l) -> l
  | ONLYTYPEDEF(_, l) -> l
  | GLOBASM(_, l) -> l
  | PRAGMA(_, l) -> l
  | LINKAGE (_, l, _) -> l

let get_statementloc (s : statement) : cabsloc =
begin
  match s with
  | NOP(loc) -> loc
  | COMPUTATION(_,loc) -> loc
  | BLOCK(_,loc) -> loc
  | SEQUENCE(_,_,loc) -> loc
  | IF(_,_,_,loc) -> loc
  | WHILE(_,_,loc) -> loc
  | DOWHILE(_,_,loc) -> loc
  | FOR(_,_,_,_,loc) -> loc
  | BREAK(loc) -> loc
  | CONTINUE(loc) -> loc
  | RETURN(_,loc) -> loc
  | SWITCH(_,_,loc) -> loc
  | CASE(_,_,loc) -> loc
  | CASERANGE(_,_,_,loc) -> loc
  | DEFAULT(_,loc) -> loc
  | LABEL(_,_,loc) -> loc
  | GOTO(_,loc) -> loc
  | COMPGOTO (_, loc) -> loc
  | DEFINITION d -> get_definitionloc (dn d)
  | ASM(_,_,_,loc) -> loc
  | TRY_EXCEPT(_, _, _, loc) -> loc
  | TRY_FINALLY(_, _, loc) -> loc
end


let explodeStringToInts (s: string) : int64 list =  
  let rec allChars i acc = 
    if i < 0 then acc
    else allChars (i - 1) (Int64.of_int (Char.code (String.get s i)) :: acc)
  in
  allChars (-1 + String.length s) []

let valueOfDigit chr =
  let int_value = 
    match chr with
      '0'..'9' -> (Char.code chr) - (Char.code '0')
    | 'a'..'z' -> (Char.code chr) - (Char.code 'a') + 10
    | 'A'..'Z' -> (Char.code chr) - (Char.code 'A') + 10
    | _ -> Errormsg.s (Errormsg.bug "not a digit") in
  Int64.of_int int_value
  
    
open Pretty
let d_cabsloc () cl = 
  text cl.filename ++ text ":" ++ num cl.lineno