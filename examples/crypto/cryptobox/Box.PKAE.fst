module Box.PKAE

open Platform.Bytes
open FStar.HyperHeap
open FStar.HyperStack
open Box.Flags
open Box.AE
open Box.DH
open Box.PlainPKAE
open Box.PlainAE
open Box.PlainDH
open Box.Indexing
open CoreCrypto

module B = Platform.Bytes
module MR = FStar.Monotonic.RRef
module MM = MonotoneMap
module HH = FStar.HyperHeap
module HS = FStar.HyperStack

type rid = FStar.Monotonic.Seq.rid

assume val box_log_region: (r:MR.rid{ extends r root 
					 /\ is_eternal_region r 
					 /\ is_below r root 
					 /\ disjoint r ae_key_region 
					 /\ disjoint r dh_key_log_region
					 /\ disjoint r id_honesty_table_region
					 /\ disjoint r id_freshness_table_region
					 })

assume val box_key_log_region: (r:MR.rid{ extends r root 
					 /\ is_eternal_region r 
					 /\ is_below r root 
					 /\ disjoint r ae_key_region 
					 /\ disjoint r dh_key_log_region
					 /\ disjoint r id_honesty_table_region
					 /\ disjoint r id_freshness_table_region
					 /\ disjoint r box_log_region
					 })
					 
//let pkae_table_region = new_region root


type box_log_key = (nonce*(i:id{AE_id? i /\ honest i}))
type box_log_value = (protected_pkae_plain)
type box_log_range = fun box_log_key -> box_log_value
type box_log_inv (f:MM.map' box_log_key box_log_range) = True
assume val box_log: MM.t box_log_region box_log_key box_log_range box_log_inv
//let box_log = MM.alloc #pkae_table_region #pkae_table_key #pkae_table_range #pkae_table_inv

type box_key_log_key = i:id{AE_id? i /\ honest i}
type box_key_log_value = (AE.key)
type box_key_log_range = fun (i:box_key_log_key) -> (k:box_key_log_value{AE.get_index k = i})
type box_key_log_inv (f:MM.map' box_key_log_key box_key_log_range) = True
assume val box_key_log:  MM.t box_key_log_region box_key_log_key box_key_log_range box_key_log_inv
//let box_key_log = MM.alloc #pkae_table_region #pkae_table_key #pkae_table_range #pkae_table_inv


noeq abstract type pkae_pkey (pk_id:id{DH_id? pk_id}) =
  | PKey: dh_pk:dh_pkey{DH.pk_get_index dh_pk=pk_id} -> pkae_pkey pk_id

noeq abstract type pkae_skey (sk_id:id{DH_id? sk_id}) =
  | SKey: dh_sk:dh_skey{DH.sk_get_index dh_sk=sk_id} -> pkae_pk:pkae_pkey sk_id -> pkae_skey sk_id

val keygen: #(i:id{DH_id? i}) -> ST (pkae_pkey i * pkae_skey i)
  (requires (fun h0 -> 
  fresh i h0
  /\ registered i
  ))
  (ensures (fun h0 res h1 -> 
    unfresh i
    /\ modifies (Set.singleton id_freshness_table_region) h0 h1
  ))
let keygen #i =
  let (dh_pk, dh_sk) = DH.keygen #i in
  let pkae_pk = PKey #i dh_pk in
  pkae_pk, SKey #i dh_sk pkae_pk


type c = AE.cipher

// TODO: We should be able to replace "dishonest i"  with "~(honest i)" everywhere!
let log_invariant (h:mem) = 
  (forall (i:id{AE_id? i /\ honest i}) .(*{:pattern (MM.defined box_key_log i h) \/ (honest i /\ AE_id? i) \/ (MM.defined dh_key_log i h)}*) MM.defined box_key_log i h <==> MM.defined dh_key_log i h) // dh_key_log and box_key_log are in sync
  ///\ 
  //(forall (i:id{AE_id? i /\ honest i}) . MM.fresh box_key_log i h <==> fresh i h)
  ///\
  //(forall (i:id{AE_id? i /\ honest i}) (n:nonce) . (MM.defined box_key_log i h ==> (let k = MM.value box_key_log i h in 
  //									   let k_log = get_logGT k in
  //									   MM.defined box_log (n,i) h <==> MM.defined k_log n h)))
  ///\
  //(forall (i:id{AE_id? i /\ honest i}) (n:nonce) . (MM.fresh box_key_log i h ==> MM.fresh box_log (n,i) h))



#set-options "--z3rlimit 25"
val encrypt_beforenm: #(pk_id:id{DH_id? pk_id /\ registered pk_id}) -> 
	              #(sk_id:id{DH_id? sk_id /\ registered sk_id}) -> 
	              pk:pkae_pkey pk_id -> 
	              sk:pkae_skey sk_id ->
		      ST (k:AE.key)
  (requires (fun h0 -> 
    let i = generate_ae_id pk_id sk_id in
    registered i
    /\ (honest i /\ MM.fresh box_key_log i h0 ==> fresh i h0)
    /\ log_invariant h0
  ))
  (ensures (fun h0 k h1 -> 
    let i = generate_ae_id pk_id sk_id in
    let regions_modified_dishonest = [id_freshness_table_region] in
    let regions_modified_honest_set = Set.as_set (regions_modified_dishonest @ [dh_key_log_region;box_key_log_region]) in
    let regions_modified_dishonest_set:Set.set (r:HH.rid) = Set.as_set regions_modified_dishonest in
    let k_log = get_logGT k in
    (PlainDH.ae_key_get_index k = i)
    /\ (
        ( (honest i)
    	    ==> (modifies regions_modified_honest_set h0 h1
    	       /\ (MR.witnessed (MM.contains dh_key_log i k) 
		 \/ MR.witnessed (MM.contains box_key_log i k)
    		 )
	      )
        )
        \/ 
    	( (dishonest i \/ ~Flags.prf_odh)
    	    ==> (modifies regions_modified_dishonest_set h0 h1
    	       /\ leak_key k = DH.prf_odhT sk.dh_sk pk.dh_pk
    	      )
        )
      )
    /\ MR.m_contains k_log h1
    /\ modifies regions_modified_honest_set h0 h1
    /\ (forall (i:id{AE_id? i /\ honest i}) . MM.defined box_key_log i h1 <==> MM.defined dh_key_log i h1)
    ///\ (forall (i:id{AE_id? i /\ honest i}) (n:nonce) . MM.defined box_key_log i h ==> (let k = MM.value box_key_log i h in 
	//								   let k_log = get_logGT k in
		//							   MM.defined box_log (n,i) h <==> MM.defined k_log n h))
    /\ log_invariant h1
  ))
let encrypt_beforenm #pk_id #sk_id pk sk =
  MR.m_recall box_log;
  MR.m_recall box_key_log;
  MR.m_recall dh_key_log;
  let i = generate_ae_id pk_id sk_id in
  if is_honest i then
    match MM.lookup box_key_log i with
    | Some k -> 
        recall_log k;
        k
    | None ->
        let k = prf_odh sk.dh_sk pk.dh_pk in
	MR.testify (MM.contains dh_key_log i k);
        MM.extend box_key_log i k;
	fresh_unfresh_contradiction i;
        recall_log k;
        k
  else (
    lemma_dishonest_not_honest i;
    let k = prf_odh sk.dh_sk pk.dh_pk in
    recall_log k;
    k)
  


val encrypt_afternm: k:AE.key ->
		     n:nonce ->
		     p:protected_pkae_plain{PlainPKAE.get_index p = AE.get_index k} ->
		     ST c
  (requires (fun h0 -> 
    let k_log = get_logGT k in
    MM.fresh box_log (n,AE.get_index k) h0
    /\ MR.m_contains k_log h0
    /\ MR.m_contains box_log h0
    /\ log_invariant h0
  ))
  (ensures (fun h0 c h1 -> 
    let i = AE.get_index k in
    let k_log = get_logGT k in
    let k_raw = get_keyGT k in
    ///\ (
    //	( (dishonest i \/ ~(b2t pkae))
    //	    ==> c = CoreCrypto.aead_encryptT AES_128_CCM k_raw n empty_bytes (PlainPKAE.repr p))
    //  \/ 
    //    ( (honest i /\ b2t ae_ind_cca)
    //	    ==> c = CoreCrypto.aead_encryptT AES_128_CCM k_raw n empty_bytes (createBytes (PlainPKAE.length p) 0z) )
    //  )
    (dishonest i \/ honest i)
    /\ MR.witnessed (MM.contains k_log n (c,ae_message_wrap p))
    /\ MR.witnessed (MM.contains box_log (n,i) p)
    /\ log_invariant h0
  ))
let encrypt_afternm k n p =
//  let h0 = ST.get() in
//  assert(
//    let k_log = get_logGT k in
//    MM.fresh k_log n h0);
//  admit();
  let ae_i = AE.get_index k in
  let ae_m = ae_message_wrap #ae_i p in
  MM.extend box_log (n,ae_i) p;
  AE.encrypt #ae_i n k ae_m
  

#set-options "--z3rlimit 25"
val encrypt: #(pk_id:id{DH_id? pk_id}) -> 
	     #(sk_id:id{DH_id? sk_id}) -> 
	     pk:pkae_pkey pk_id{registered pk_id} -> 
	     sk:pkae_skey sk_id{registered sk_id} -> 
	     n:nonce -> 
	     p:protected_pkae_plain{PlainPKAE.get_index p = generate_ae_id pk_id sk_id} 
	     -> ST unit
  (requires (fun h0 ->
    let i = generate_ae_id pk_id sk_id in
    registered i
    /\ MR.m_contains box_log h0
    /\ (honest i ==> (~(MR.witnessed(MM.defined dh_key_log i) ==> ~(fresh i h0))))
    /\ MM.fresh box_log (n,i) h0
    // Make sure that log_invariant holds
    /\ MM.fresh box_log (n,i) h0
    /\ log_invariant h0
  ))
  (ensures (fun h0 c h1 -> 
    log_invariant h1
  ))
let encrypt #pk_id #sk_id pkae_pk pkae_sk n p =
  let k = encrypt_beforenm #pk_id #sk_id pkae_pk pkae_sk in
  let c = encrypt_afternm k n p in
  let h0 = ST.get() in
  assert(log_invariant h0);
  ()


// Implement decrypt_beforenm and decrypt_afternm
// - add similar specification as in AE and in PKAE.encrypt..
val decrypt: #(sk_id:id) -> 
	     #(pk_id:id) -> 
	     n:nonce ->  
	     pkae_skey sk_id -> 
	     pkae_pkey sk_id -> 
	     c -> 
	     St(option (p:protected_pkae_plain))
	     
let decrypt #sk_id #pk_id n sk pk c =
  MR.m_recall box_log;
  let (dh_sh,ae_c) = c in 
  let k = prf_odh sk.dh_sk pk.dh_pk  in
  let ae_i = AE.get_index k in
  match AE.decrypt #ae_i n k ae_c with
  | Some p -> 
    let p' = (PlainAE.ae_message_unwrap #ae_i p) in 
    Some p'
  | None -> None