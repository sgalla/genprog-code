(*
 * Structural Diff on C Programs
 *
 * --generate: given two C files, produce a data file and a text patch file
 *   that can be used to turn one into the other
 *
 * --use: given the data file and some subset of the text file, apply that
 *   subset of the changes to turn the first file into (something like) the
 *   second file 
 *
 * Used by Weimer's prototype GP project to post-mortem minimize a 
 * candidate patch. Typically used in conjunction with delta-debugging 
 * to produce a 1-minimal subset of the original patch that still has the
 * desired behavior. 
 *)
open Pretty
open Printf
open Cil
open Global

type node_id = int 

(*
 * We convert to a very generic tree data structure (below) for the
 * purposes of doing the DiffX structural difference algorithm. Then we
 * convert back later after applying the diff script. 
 *)
type tree_node = {
  mutable nid : node_id ; (* unique per node *)
  mutable children : int array ;
  mutable typelabel : int ; 
  (* two nodes that represent the same C statement will have the same
     typelabel. "children" are not considered for calculating typelabels,
     so 'if (x<y) { foo(); }' and 'if (x<y) { bar(); }' have the
     same typelabels, but their children (foo and bar) will not.  *) 

} 

let typelabel_ht = Hashtbl.create 255 
let inv_typelabel_ht = Hashtbl.create 255 
let typelabel_counter = ref 0 


let node_id_to_cil_stmt : (int, Cil.stmt) Hashtbl.t = Hashtbl.create 255
  (* Intermediary steps for verbose_node_info *)

let node_of_nid node_map x = IntMap.find x node_map

let print_tree node_map (n : tree_node) = 
  let rec print n depth = 
    printf "%*s%02d (tl = %02d) (%d children)\n" 
      depth "" 
      n.nid n.typelabel
      (Array.length n.children) ;
    Array.iter (fun child ->
      let child = node_of_nid node_map child in
		print child (depth + 2)
    ) n.children
  in
	print n 0 

let deleted_node = {
  nid = -1;
  children = [| |] ;
  typelabel = -1 ;
} 

let init_map () = IntMap.add (-1) deleted_node (IntMap.empty)

let rec cleanup_tree node_map t =
  let node_map =
	Array.fold_left
	  (fun node_map ->
		fun child ->
		  let child = node_of_nid node_map child in
			cleanup_tree node_map child
	  ) node_map (t.children)
  in
  let lst = Array.to_list t.children in
  let lst = List.filter (fun child ->
	let child = node_of_nid node_map child in
    child.typelabel <> -1
  ) lst in
  t.children <- Array.of_list lst;
	IntMap.add (t.nid) t node_map

let delete node_map node =
  let nid = node.nid in 
  node.nid <- -1 ; 
  node.children <- [| |] ; 
  node.typelabel <- -1 ;
  IntMap.add nid node node_map

let node_counter = ref 0 

let new_node typelabel = 
  let nid = !node_counter in
  incr node_counter ;
  { nid = nid ;
    children = [| |] ; 
    typelabel = typelabel ;
  }  

let nodes_eq t1 t2 =
  (* if both their types and their labels are equal *) 
  t1.typelabel = t2.typelabel 

module OrderedNode =
  struct
    type t = tree_node
    let compare x y = compare x.nid y.nid
  end
module OrderedNodeNode =
  struct
    type t = tree_node * tree_node
    let compare (a,b) (c,d) = 
      let r1 = compare a.nid c.nid in
      if r1 = 0 then
        compare b.nid d.nid
      else
        r1 
  end

module NodeSet = Set.Make(OrderedNode)
module NodeMap = Set.Make(OrderedNodeNode)

exception Found_It 
exception Found_Node of tree_node 

(* returns true if (t,_) is in m *) 
let in_map_domain m t =
  try 
    NodeMap.iter (fun (a,_) -> 
      if a.nid = t.nid then raise Found_It
    ) m ;
    false
  with Found_It -> true 

(* returns true if (_,t) is in m *) 
let in_map_range m t =
  try 
    NodeMap.iter (fun (_,a) -> 
      if a.nid = t.nid then raise Found_It
    ) m ;
    false
  with Found_It -> true 

let find_node_that_maps_to m y =
  try 
    NodeMap.iter (fun (a,b) -> 
      if b.nid = y.nid then raise (Found_Node(a))
    ) m ;
    None
  with Found_Node(a) -> Some(a)  

(* return a set containing all nodes in t equal to n *) 
let rec nodes_in_tree_equal_to node_map t n = 
  let sofar = ref 
    (if nodes_eq t n then NodeSet.singleton t else NodeSet.empty)
  in 
  Array.iter (fun child ->
	let child = node_of_nid node_map child in
    sofar := NodeSet.union !sofar (nodes_in_tree_equal_to node_map child n) 
  ) t.children ; 
  !sofar 

let map_size m = NodeMap.cardinal m 

let level_order_traversal node_map t callback =
  let q = Queue.create () in 
  Queue.add t q ; 
  while not (Queue.is_empty q) do
    let x = Queue.take q in 
    Array.iter (fun child ->
	  let child = node_of_nid node_map child in
      Queue.add child q
    ) x.children ; 
    callback x ; 
  done 

let parent_of node_map tree some_node =
  try 
    level_order_traversal node_map tree (fun p ->
      Array.iter (fun child ->
		let child = node_of_nid node_map child in 
          if child.nid = some_node.nid then
			raise (Found_Node(p) )
      ) p.children 
    ) ;
    None
  with Found_Node(n) -> Some(n) 

let parent_of_nid node_map tree some_nid =
  try 
    level_order_traversal node_map tree (fun p ->
      Array.iter (fun child ->
		let child = node_of_nid node_map child in
        if child.nid = some_nid then
          raise (Found_Node(p) )
      ) p.children 
    ) ;
    None
  with Found_Node(n) -> Some(n) 

let position_of node_map (parent : tree_node option) child =
  match parent with
  | None -> None
  | Some(parent) -> 
    let result = ref None in 
    Array.iteri (fun i child' ->
	  let child' = node_of_nid node_map child' in 
      if child.nid = child'.nid then
        result := Some(i) 
    ) parent.children ;
    !result 

let position_of_nid node_map (parent : tree_node option) child_nid =
  match parent with
  | None -> None
  | Some(parent) -> 
    let result = ref None in 
    Array.iteri (fun i child' ->
	  let child' = node_of_nid node_map child' in
      if child_nid = child'.nid then
        result := Some(i) 
    ) parent.children ;
    !result 

(* This is the DiffX algorithm, taken verbatim from their paper *) 
let rec mapping node_map t1 t2 =
  let t1 = node_of_nid node_map t1 in 
  let t2 = node_of_nid node_map t2 in
  let m = ref NodeMap.empty in 
  level_order_traversal node_map t1 (fun x -> 
    if in_map_domain !m x then
      () (* skip current node *)
    else begin
      let y = nodes_in_tree_equal_to node_map t2 x in 
      let m'' = ref NodeMap.empty in 
      NodeSet.iter (fun yi ->
        if not (in_map_range !m yi) then begin
          let m' = ref NodeMap.empty in 
          match_fragment node_map x yi !m m' ;
          if map_size !m' > map_size !m'' then begin
            m'' := !m'
          end 
        end 
      ) y ;
      m := NodeMap.union !m !m'' 
    end 
  ) ;
  !m 

(* still taken verbatim from their paper *) 
and match_fragment node_map x y (m : NodeMap.t) (m' : NodeMap.t ref) = 
  if (not (in_map_domain m x)) &&
     (not (in_map_range m y)) &&
     (nodes_eq x y) then begin
    m' := NodeMap.add (x,y) !m' ;
    let xc = Array.length x.children in 
    let yc = Array.length y.children in 
    for i = 0 to pred (min xc yc) do
      match_fragment node_map (node_of_nid node_map x.children.(i)) (node_of_nid node_map y.children.(i)) m m'
    done 
  end 

type edit_action = 
  | Insert of int * (int option) * (int option)
  | Move   of int * (int option) * (int option)
  | Delete of int 

let noio no = match no with
  | Some(n) -> Some(n.nid)
  | None -> None 

let io_to_str io = match io with
  | Some(n) -> sprintf "%d" n
  | None -> "-1" 

let edit_action_to_str ea = match ea with
  | Insert(n,no,io) -> sprintf "Insert (%d,%s,%s)" n (io_to_str no)
    (io_to_str io)
  | Move(n,no,io) -> sprintf "Move (%d,%s,%s)" n (io_to_str no) 
    (io_to_str io)
  | Delete(n) -> sprintf "Delete (%d,0,0)" n
  
(* This algorithm is not taken directly from their paper, because the
 * version in their paper has bugs! *) 
let generate_script node_map t1 t2 m = 
  let s = ref [] in 
  level_order_traversal node_map t2 (fun y -> 
    if not (in_map_range m y) then begin
      let yparent = parent_of node_map t2 y in 
      let ypos = position_of node_map yparent y in
      match yparent with
      | None -> 
        s := (Insert(y.nid,noio yparent,ypos)) :: !s 
      | Some(yparent) -> begin
        let xx = find_node_that_maps_to m yparent in
        match xx with
        | Some(xx) -> s := (Insert(y.nid,Some(xx.nid),ypos)) :: !s 
        | None     -> s := (Insert(y.nid,Some(yparent.nid),ypos)) :: !s 
          (* in the None case, our yParent was moved over, so this works
             inductively *) 
      end 


    end else begin
      match find_node_that_maps_to m y with
      | None -> printf "generate_script: error: no node that maps to!\n"
      | Some(x) -> begin
        let xparent = parent_of node_map t1 x in
        let yparent = parent_of node_map t2 y in 
        let yposition = position_of node_map yparent y in 
        let xposition = position_of node_map xparent x in 
        match xparent, yparent with
        | Some(xparent), Some(yparent) -> 
          if not (NodeMap.mem (xparent,yparent) m) then begin 
            let xx = find_node_that_maps_to m yparent in
            match xx with
            | Some(xx) -> s := (Move(x.nid,Some(xx.nid),yposition)) :: !s 
            | None     -> s := (Move(x.nid,Some yparent.nid,yposition)) :: !s
          end 
	  else if xposition <> yposition then 
            s := (Move(x.nid,Some xparent.nid,yposition)) :: !s

        | _, _ -> (* well, no parents implies no parents in the mapping *) 
           ()
           (* s := (Move(x,yparent,None)) :: !s *)
      end 
    end 
  ) ;
  level_order_traversal node_map t1 (fun x ->
    if not (in_map_domain m x) then begin
      s := (Delete(x.nid)) :: !s
    end
  ) ;
  List.rev !s

(*************************************************************************)
let dummyBlock = { battrs = [] ; bstmts = [] ; }  
let dummyLoc = { line = 0 ; file = "" ; byte = 0; } 

(* determine the 'typelabel' of a CIL Stmt -- basically, turn 
 *  if (x<y) { foo(); }
 * into:
 *  if (x<y) { }
 * and then hash it. 
 *) 
let stmt_to_typelabel (s : Cil.stmt) = 
  let convert_label l = match l with
    | Label(s,loc,b) -> Label(s,dummyLoc,b) 
    | Case(e,loc) -> Case(e,dummyLoc)
    | Default(loc) -> Default(dummyLoc)
  in 
  let labels = List.map convert_label s.labels in
  let convert_il il = 
    List.map (fun i -> match i with
      | Set(lv,e,loc) -> Set(lv,e,dummyLoc)
      | Call(lvo,e,el,loc) -> Call(lvo,e,el,dummyLoc) 
      | Asm(a,b,c,d,e,loc) -> Asm(a,b,c,d,e,dummyLoc)
    ) il 
  in
  let skind = match s.skind with
    | Instr(il)  -> Instr(convert_il il) 
    | Return(eo,l) -> Return(eo,dummyLoc) 
    | Goto(sr,l) -> Goto(sr,dummyLoc) 
    | Break(l) -> Break(dummyLoc) 
    | Continue(l) -> Continue(dummyLoc) 
    | If(e,b1,b2,l) -> If(e,dummyBlock,dummyBlock,l)
    | Switch(e,b,sl,l) -> Switch(e,dummyBlock,[],l) 
    | Loop(b,l,so1,so2) -> Loop(dummyBlock,l,None,None) 
    | Block(block) -> Block(dummyBlock) 
    | TryFinally(b1,b2,l) -> TryFinally(dummyBlock,dummyBlock,dummyLoc) 
    | TryExcept(b1,(il,e),b2,l) ->
      TryExcept(dummyBlock,(convert_il il,e),dummyBlock,dummyLoc) 
  in
  let it = (labels, skind) in 
  let s' = { s with skind = skind ; labels = labels } in 
  let doc = dn_stmt () s' in 
  let str = Pretty.sprint ~width:80 doc in 
  if Hashtbl.mem typelabel_ht str then begin 
    Hashtbl.find typelabel_ht str , it
  end else begin
    let res = !typelabel_counter in
    incr typelabel_counter ; 
    Hashtbl.add typelabel_ht str res ; 
    Hashtbl.add inv_typelabel_ht res it ; 
    res , it
  end 

let wrap_block b = mkStmt (Block(b))


(* the bitch of this is that all these convert-to-ast functions now need to
   return both the id and the new node map (where before, state was our
   friend *)

let fundec_to_ast node_map (f:Cil.fundec) =
  let node_map = ref node_map in
  let rec stmt_to_node s =
	let tl, (labels,skind) = stmt_to_typelabel s in
	let n = new_node tl in 
	(* now just fill in the children *) 
	let children = 
	  match s.skind with
      | Instr _  | Return _ | Goto _ 
      | Break _  | Continue _  -> [| |]
      | If(e,b1,b2,l)  ->
		[| stmt_to_node (wrap_block b1) ;stmt_to_node (wrap_block b2) |]
      | Switch(e,b,sl,l) -> 
		[| stmt_to_node (wrap_block b) |]
      | Loop(b,l,so1,so2) -> 
		[| stmt_to_node (wrap_block b) |] 
      | TryFinally(b1,b2,l) -> 
		[| stmt_to_node (wrap_block b1) ; stmt_to_node (wrap_block b2) |] 
      | TryExcept(b1,(il,e),b2,l) ->
		[| stmt_to_node (wrap_block b1) ; stmt_to_node (wrap_block b2) |] 
      | Block(block) -> 
		(* Printf.printf "HELLO!\n"; *)
		let children = List.map stmt_to_node block.bstmts in
		  Array.of_list children 
	in
	  n.children <- children ;
	  node_map := IntMap.add n.nid n !node_map ;
	  n.nid
  in
  let b = wrap_block f.sbody in 
	stmt_to_node b , !node_map

(* convert a very abstract tree node into a CIL Stmt *) 
let rec node_to_stmt node_map n = 
  let children = Array.map (fun child ->
	let child = node_of_nid node_map child in
    node_to_stmt node_map child 
  ) n.children in 
  let labels, skind = Hashtbl.find inv_typelabel_ht n.typelabel in 
  let require x = 
    if Array.length children = x then ()
    else begin
      printf "// node_to_stmt: warn: wanted %d children, have %d\n" 
        x (Array.length children) ;
    end
  in 
  let block x = 

    if x >= Array.length children then dummyBlock 
    else match children.(x).skind with
    | Block(b) -> b
    | _ -> begin 
      printf "// node_to_stmt: warn: wanted child %d to be a block\n" x ;
      dummyBlock 
    end 
  in
  let stmt = mkStmt begin
    match skind with
    | Instr _  | Return _ | Goto _ 
    | Break _  | Continue _  -> skind
    | If(e,b1,b2,l)  -> require 2 ; If(e,block 0,block 1,l)  
    | Switch(e,b,sl,l) -> require 1 ; Switch(e,block 0,sl,l) 
    | Loop(b,l,so1,so2) -> require 1 ; Loop(block 0,l,so1,so2) 
    | TryFinally(b1,b2,l) -> require 2 ; TryFinally(block 0,block 1,l) 
    | TryExcept(b1,(il,e),b2,l) -> require 2; TryExcept(block 0,(il,e),block 1,l) 
    | Block _ -> Block(mkBlock (Array.to_list children)) 
  end 
  in
  stmt.labels <- labels ;
  stmt 

let ast_to_fundec node_map (f:Cil.fundec) n =
  let stmt = node_to_stmt node_map n in 
	match stmt.skind with 
  | Block(b) -> { f with sbody = b ; } 
  | _ -> 
    printf "fundec_to_ast: error: wanted child to be a block\n" ;
    failwith "fundec_to_ast" 

let corresponding m y =
  match find_node_that_maps_to m y with
  | Some(x) -> x
  | None -> y


exception Necessary_line
(* Apply a single edit operation to a file. This version if very fault
 * tolerant because we're expecting our caller (= a delta-debugging script)
 * to be throwing out parts of the diff script in an effort to minimize it.
 * So this is 'best effort'. *) 
(* returns a potentially-modified node map *)
let apply_diff (node_map : tree_node IntMap.t) (m) (astt1) (astt2) (s) : tree_node IntMap.t = 
  let ast1 = node_of_nid node_map astt1 in
  let ast2 = node_of_nid node_map astt2 in
	try
      match s with
    (* delete sub-tree rooted at node x *)
      | Delete(nid) -> 
		let node = node_of_nid node_map nid in 
		  delete node_map node 

    (* insert node x as pth child of node y *) 
      | Insert(xid,yopt,ypopt) ->
		let xnode = node_of_nid node_map xid in 
		  
		  (match yopt with
		  | None -> printf "apply: error: insert to root?"  ; node_map
		  | Some(yid) -> 
			let ynode = node_of_nid node_map yid in 
          (* let ynode = corresponding m ynode in  *)
			let ypos = match ypopt with
			  | Some(x) -> x | None -> 0 
			in 

          (* Step 1: remove children of X *) 
			let node_map = 
			  xnode.children <- [| |] ;
			  IntMap.add xnode.nid xnode node_map
			in

		  (* Step 2: remove X from its parent *)
			let node_map =
			  let xparent1 = parent_of node_map ast1 xnode in
			  let xparent2 = parent_of node_map ast2 xnode in 
				(match xparent1, xparent2 with
				| Some(parent), _ 
				| _, Some(parent) -> 
				  let plst = Array.to_list parent.children in
				  let plst = List.map (fun child ->
					let child = node_of_nid node_map child in 
					  if child.nid = xid then
						deleted_node.nid
					  else
						child.nid
				  ) plst in
					parent.children <- Array.of_list plst  ;
					IntMap.add parent.nid parent node_map
				| _, _ -> node_map
			  (* this case is fine, and typically comes up when we are
				 Inserting the children of a node that itself was Inserted over *)
				) 
			in

          (* Step 3: put X as p-th child of Y *) 
			let len = Array.length ynode.children in 
			let before = Array.sub ynode.children 0 ypos in
			let after  = Array.sub ynode.children ypos (len - ypos) in 
			let result = Array.concat [ before ; [| xnode.nid |] ; after ] in 
			  ynode.children <- result ;
			  IntMap.add ynode.nid ynode node_map
		  ) 

    (* move subtree rooted at node x to as p-th child of node y *) 
      | Move(xid,yopt,ypopt) -> 
		let xnode = node_of_nid node_map xid in 
		  (match yopt with
		  | None -> 
			printf "apply: error: %s: move to root?\n"  (edit_action_to_str s) ; node_map
		  | Some(yid) -> 
			let ynode = node_of_nid node_map yid in 
        (* let ynode = corresponding m ynode in *)
			let ypos = match ypopt with
			  | Some(x) -> x | None -> 0 
			in 
        (* Step 1: remove X from its parent *)
			  
			let xparent1 = parent_of node_map ast1 xnode in 	
			let xparent2 = parent_of node_map ast2 xnode in 
			let node_map = 
			  match xparent1, xparent2 with
			  | Some(parent), _ 
			  | _, Some(parent) -> 
				let plst = Array.to_list parent.children in
				let plst = List.map (fun child ->
				  let child = node_of_nid node_map child in
					if child.nid = xid then
					  deleted_node.nid
					else
					  child.nid
				) plst in
				  parent.children <- Array.of_list plst ; 
				  IntMap.add parent.nid parent node_map
			  | None, None -> 
				printf "apply: error: %s: no x parent\n" 
				  (edit_action_to_str s) ; node_map
			in
        (* Step 2: put X as p-th child of Y *) 
			let len = Array.length ynode.children in 
			let before = Array.sub ynode.children 0 ypos in
			let after  = Array.sub ynode.children ypos (len - ypos) in 
			let result = Array.concat [ before ; [| xnode.nid |] ; after ] in 
			  ynode.children <- result ;
			  IntMap.add ynode.nid ynode node_map
		  ) 
	with e -> raise Necessary_line

(* apply_diff assumes that inv_typelabel_ht is all set up *)
let apply_diff_to_file f1 node_map patch_ht data_ht myprint =
  foldGlobals f1 
	(fun node_map ->
	  fun g1 ->
		match g1 with
		| GFun(fd1,l) when Hashtbl.mem patch_ht fd1.svar.vname -> 
		  begin
			let name = fd1.svar.vname in
			let patches = Hashtbl.find patch_ht name in
			let m, t1, t2 = Hashtbl.find data_ht name in 
			let node_map = 
			  try
				List.fold_left 
				  (fun node_map ->
					fun ea ->
					  apply_diff node_map m t1 t2 ea;
				  ) node_map patches
			  with Necessary_line -> node_map
			in
			let node_map = 
			  cleanup_tree node_map (node_of_nid node_map t1) 
			in
			let output_fundec = ast_to_fundec node_map fd1 (node_of_nid node_map t1) in 
			  myprint (GFun(output_fundec,l)) ; node_map
		  end
		| _ -> (myprint g1 ; node_map)
	) node_map 

(* Apply a (partial) diff script. Used by repair only.*) 
let repair_usediff f1 node_map script data_ht =  
  let globals_list = ref [] in
  let patch_ht = Hashtbl.create 255 in 
  let add_patch fname ea = (* preserves order, fwiw *) 
    let sofar = try Hashtbl.find patch_ht fname with _ -> [] in
    Hashtbl.replace patch_ht fname (sofar @ [ea]) 
  in 
  let num_to_io x = if x < 0 then None else Some(x) in 
  let _ =
	List.iter
	  (fun line ->
		Scanf.sscanf line "%s %s %s (%d,%d,%d)" (fun the_file fname ea a b c -> 
			let it = match String.lowercase ea with 
			  | "insert" -> Insert(a, num_to_io b, num_to_io c) 
			  | "move" ->   Move(a, num_to_io b, num_to_io c)
			  | "delete" -> Delete(a) 
			  | _ -> failwith ("invalid patch: " ^ line)
			in add_patch fname it 
		  ) 
	  ) script
  in
  let myprint glob =
    globals_list := glob :: !globals_list
  in 
	ignore(apply_diff_to_file f1 node_map patch_ht data_ht myprint);
	{f1 with globals = (List.rev !globals_list) }  