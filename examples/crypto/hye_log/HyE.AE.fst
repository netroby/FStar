module HyE.AE

open FStar.Seq
open FStar.SeqProperties
open FStar.Monotonic.Seq
open FStar.HyperHeap
open FStar.HyperStack
open FStar.Monotonic.RRef
open MonotoneMap
open HyE.Flags
open HyE.Indexing

open Platform.Bytes
open CoreCrypto

module B = Platform.Bytes

open HyE.PlainAE

let ivsize = aeadRealIVSize AES_128_GCM
type keysize = aeadKeySize AES_128_GCM
type aes_key = lbytes keysize (* = b:bytes{B.length b = keysize} *)
type msg = protected_ae_plain
type cipher = b:bytes{B.length b >= ivsize}
(* MK: minimal cipher length twice blocksize? *)

let plain_to_cipher (i:id) = fun (p:protected_ae_plain i) -> cipher

//type log_t (i:id) (r:rid) = m_rref r (seq ((msg i) * cipher)) grows
type log_t (i:id) (r:rid) = MonotoneMap.t r (protected_ae_plain i) (plain_to_cipher i) (grows (empty_map (protected_ae_plain i) (plain_to_cipher i)))


(**
   The key type is abstract and can only be accessed via the leak and coerce_key functions.
*)
noeq abstract type key (i:id) =
  | Key: #region:rid -> raw:aes_key -> log:log_t i region -> honest:bool-> (key i)

(** 
    safe_key_gen makes sure that memory safety is preserved while generating a key.
    Also, it makes sure that the log created along with the key is empty.
*)
let safe_key_gen #i parent m0 (k:key i) m1 =
    modifies Set.empty m0 m1
  /\ extends k.region parent
  /\ fresh_region k.region m0.h m1.h
  /\ m_contains k.log m1
  /\ m_sel m1 k.log == createEmpty

(**
   This function generates a key in a fresh region of memory below the parent region.
   The postcondition ensures that the log is empty after creation.
*)
val keygen: #i:id -> parent:rid -> ST (key i)
  (requires (fun _ -> True))
  (ensures  (fun h0 k h1 -> 
    safe_key_gen parent h0 k h1
  ))
let keygen #i parent =
  let raw = random keysize in
  let region = new_region parent in
  let log = alloc_mref_seq region createEmpty in
  Key #i #region raw log true

(**
   The leak_key function transforms an abstract key into a raw aes_key.
   The refinement type on the key makes sure that no honest keys can be leaked.
*)
val leak_key: #i:id -> k:key i{not (honest i)} -> Tot aes_key 
let leak_key #i k =
  k.raw

(**
   The coerce function transforms a raw aes_key into an abstract key. The function is stateful,
   as we need to allocate space in memory for the key. The refinement type on the key makes sure that
   abstract keys created this way can not be honest.
*)
val coerce_key: i:id{not (honest i) } -> parent:rid -> aes_key -> ST (key i)
  (requires (fun _ -> True))
  (ensures  (safe_key_gen parent))
let coerce_key i parent raw = 
  let region = new_region parent in
  let log = alloc_mref_seq region createEmpty in
  Key #i #region raw log false

(**
   safe_log_append makes sure that new entries added to the log are appended in a memory-safe way.
*)
type safe_log_append k entry h0 h1 =
    modifies_one k.region h0 h1 
    /\ m_contains k.log h1
    /\ m_sel h1 k.log == snoc (m_sel h0 k.log) entry
    /\ witnessed (at_least (Seq.length (m_sel h0 k.log)) entry k.log)
(**
   Encrypt a a message under a key. Idealize if the key is honest and ae_ind_cca true.
*)
val encrypt: #(i:id) -> (k:key i) -> (m:msg i) -> ST cipher
  (requires (fun h0 -> True
    (*m_contains k.log h0*)))
  (ensures  (fun h0 c h1 -> 
    safe_log_append k (m,c) h0 h1 ))
let encrypt #i k m : cipher =
  m_recall k.log;
  let iv = random ivsize in
  let p = if (ae_ind_cca && honest i) then createBytes (length m) 0z else (repr m) in
  let c = CoreCrypto.aead_encrypt AES_128_GCM k.raw iv empty_bytes p in
  let c = iv@|c in
  write_at_end k.log (m,c);
  c

(**
   Decrypt a ciphertext c using a key k. If the key is honest and ae_int_ctxt is idealized,
   try to obtain the ciphertext from the log. Else decrypt via concrete implementation.
   TODO: Make this a total function.
*)
val decrypt: #(i:id) -> (k:key i) -> c:cipher -> ST (option (msg i))
  (requires (fun h -> True (* Could require Map.contains h0 k.region *)))
  (ensures  (fun h0 res h1 -> //True))
    modifies_none h0 h1
    ///\ ( (b2t ae_ind_cca /\ honest i /\ Some? res) ==> SeqProperties.mem (Some?.v res,c) (m_sel h0 k.log) )
    ))
let decrypt #i k c =
  if ae_ind_cca && honest i then
    let log = m_read k.log in
    match seq_find (fun mc -> snd mc = c) log with
    | Some mc -> Some (fst mc)
    | None -> None
  else
    let iv,c' = split c ivsize in
    assume( B.length c' >= aeadTagSize AES_128_GCM);
    let poption = (CoreCrypto.aead_decrypt AES_128_GCM k.raw iv empty_bytes c') in
    if Some? poption then
      Some (PlainAE.coerce (Some?.v poption))
    else
      None