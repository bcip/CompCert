(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Xavier Leroy, INRIA Paris-Rocquencourt                     *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(** Correctness of instruction selection for operators *)

Require Import Coqlib.
Require Import AST.
Require Import Integers.
Require Import Floats.
Require Import Values.
Require Import Memory.
Require Import Globalenvs.
Require Import Cminor.
Require Import Op.
Require Import CminorSel.
Require Import SelectOp.

Local Open Scope cminorsel_scope.

(** * Useful lemmas and tactics *)

(** The following are trivial lemmas and custom tactics that help
  perform backward (inversion) and forward reasoning over the evaluation
  of operator applications. *)

Ltac EvalOp := eapply eval_Eop; eauto with evalexpr.

Ltac InvEval1 :=
  match goal with
  | [ H: (eval_expr _ _ _ _ _ (Eop _ Enil) _) |- _ ] =>
      inv H; InvEval1
  | [ H: (eval_expr _ _ _ _ _ (Eop _ (_ ::: Enil)) _) |- _ ] =>
      inv H; InvEval1
  | [ H: (eval_expr _ _ _ _ _ (Eop _ (_ ::: _ ::: Enil)) _) |- _ ] =>
      inv H; InvEval1
  | [ H: (eval_exprlist _ _ _ _ _ Enil _) |- _ ] =>
      inv H; InvEval1
  | [ H: (eval_exprlist _ _ _ _ _ (_ ::: _) _) |- _ ] =>
      inv H; InvEval1
  | _ =>
      idtac
  end.

Ltac InvEval2 :=
  match goal with
  | [ H: (eval_operation _ _ _ nil _ = Some _) |- _ ] =>
      simpl in H; FuncInv
  | [ H: (eval_operation _ _ _ (_ :: nil) _ = Some _) |- _ ] =>
      simpl in H; FuncInv
  | [ H: (eval_operation _ _ _ (_ :: _ :: nil) _ = Some _) |- _ ] =>
      simpl in H; FuncInv
  | [ H: (eval_operation _ _ _ (_ :: _ :: _ :: nil) _ = Some _) |- _ ] =>
      simpl in H; FuncInv
  | _ =>
      idtac
  end.

Ltac InvEval := InvEval1; InvEval2; InvEval2; subst.

Ltac TrivialExists :=
  match goal with
  | [ |- exists v, _ /\ Val.lessdef ?a v ] => exists a; split; [EvalOp | auto]
  end.

(** * Correctness of the smart constructors *)

Section CMCONSTR.

Variable ge: genv.
Variable sp: val.
Variable e: env.
Variable m: mem.

(** We now show that the code generated by "smart constructor" functions
  such as [SelectOp.notint] behaves as expected.  Continuing the
  [notint] example, we show that if the expression [e]
  evaluates to some integer value [Vint n], then [SelectOp.notint e]
  evaluates to a value [Vint (Int.not n)] which is indeed the integer
  negation of the value of [e].

  All proofs follow a common pattern:
- Reasoning by case over the result of the classification functions
  (such as [add_match] for integer addition), gathering additional
  information on the shape of the argument expressions in the non-default
  cases.
- Inversion of the evaluations of the arguments, exploiting the additional
  information thus gathered.
- Equational reasoning over the arithmetic operations performed,
  using the lemmas from the [Int] and [Float] modules.
- Construction of an evaluation derivation for the expression returned
  by the smart constructor.
*)

Definition unary_constructor_sound (cstr: expr -> expr) (sem: val -> val) : Prop :=
  forall le a x,
  eval_expr ge sp e m le a x ->
  exists v, eval_expr ge sp e m le (cstr a) v /\ Val.lessdef (sem x) v.

Definition binary_constructor_sound (cstr: expr -> expr -> expr) (sem: val -> val -> val) : Prop :=
  forall le a x b y,
  eval_expr ge sp e m le a x ->
  eval_expr ge sp e m le b y ->
  exists v, eval_expr ge sp e m le (cstr a b) v /\ Val.lessdef (sem x y) v.

Lemma eval_Olea_ptr:
  forall a el m,
  eval_operation ge sp (Olea_ptr a) el m = eval_addressing ge sp a el.
Proof.
  unfold Olea_ptr, eval_addressing; intros. destruct Archi.ptr64; auto.
Qed.

Theorem eval_addrsymbol:
  forall le id ofs,
  exists v, eval_expr ge sp e m le (addrsymbol id ofs) v /\ Val.lessdef (Genv.symbol_address ge id ofs) v.
Proof.
  intros. unfold addrsymbol. exists (Genv.symbol_address ge id ofs); split; auto.
  destruct (symbol_is_external id).
  predSpec Ptrofs.eq Ptrofs.eq_spec ofs Ptrofs.zero.
  subst. EvalOp.
  EvalOp. econstructor. EvalOp. simpl; eauto. econstructor.
  unfold Olea_ptr; destruct Archi.ptr64 eqn:SF; simpl;
  [ rewrite <- Genv.shift_symbol_address_64 by auto | rewrite <- Genv.shift_symbol_address_32 by auto ];
  f_equal; f_equal;
  rewrite Ptrofs.add_zero_l;
  [ apply Ptrofs.of_int64_to_int64 | apply Ptrofs.of_int_to_int ];
  auto.
  EvalOp. (*rewrite eval_Olea_ptr. apply eval_addressing_Aglobal. *)
Qed.

Theorem eval_addrstack:
  forall le ofs,
  exists v, eval_expr ge sp e m le (addrstack ofs) v /\ Val.lessdef (Val.offset_ptr sp ofs) v.
Proof.
  intros. unfold addrstack. TrivialExists. (*rewrite eval_Olea_ptr. apply eval_addressing_Ainstack.*)
Qed.

Theorem eval_notint: unary_constructor_sound notint Val.notint.
Proof.
  unfold notint; red; intros until x. case (notint_match a); intros; InvEval.
- TrivialExists.
- rewrite Val.not_xor. rewrite Val.xor_assoc. TrivialExists.
- TrivialExists.
Qed.

Theorem eval_addimm:
  forall n, unary_constructor_sound (addimm n) (fun x => Val.add x (Vint n)).
Proof.
  red; unfold addimm; intros until x.
  predSpec Int.eq Int.eq_spec n Int.zero.
- subst n. intros. exists x; split; auto.
  destruct x; simpl; rewrite ?Int.add_zero, ?Ptrofs.add_zero; auto.
- case (addimm_match a); intros; InvEval.
+ TrivialExists; simpl. rewrite Int.add_commut. auto.
+ inv H0. simpl in H6. TrivialExists. simpl.
  erewrite eval_offset_addressing_total_32 by eauto. rewrite Int.repr_signed; auto.
+ TrivialExists. simpl. rewrite Int.repr_signed; auto.
Qed.

Theorem eval_add: binary_constructor_sound add Val.add.
Proof.
  assert (A: forall x y, Int.repr (x + y) = Int.add (Int.repr x) (Int.repr y)).
  { intros; apply Int.eqm_samerepr; auto with ints. }
  assert (B: forall id ofs n, Archi.ptr64 = false ->
             Genv.symbol_address ge id (Ptrofs.add ofs (Ptrofs.repr n)) =
             Val.add (Genv.symbol_address ge id ofs) (Vint (Int.repr n))).
  { intros. replace (Ptrofs.repr n) with (Ptrofs.of_int (Int.repr n)) by auto with ptrofs.
    apply Genv.shift_symbol_address_32; auto. }
  red; intros until y.
  unfold add; case (add_match a b); intros; InvEval.
- rewrite Val.add_commut. apply eval_addimm; auto.
- apply eval_addimm; auto.
- TrivialExists. simpl. rewrite A, Val.add_permut_4. auto.
- TrivialExists. simpl. rewrite A, Val.add_assoc. decEq; decEq. rewrite Val.add_permut. auto.
- TrivialExists. simpl. rewrite A, Val.add_permut_4. rewrite <- Val.add_permut. rewrite <- Val.add_assoc. auto.
- TrivialExists. simpl. rewrite Heqb0. rewrite B by auto. rewrite ! Val.add_assoc.
  rewrite (Val.add_commut v1). rewrite Val.add_permut. rewrite Val.add_assoc. auto.
- TrivialExists. simpl. rewrite Heqb0. rewrite B by auto. rewrite Val.add_assoc. do 2 f_equal. apply Val.add_commut.
- TrivialExists. simpl. rewrite Heqb0. rewrite B by auto. rewrite !Val.add_assoc.
  rewrite (Val.add_commut (Vint (Int.repr n1))). rewrite Val.add_permut. do 2 f_equal. apply Val.add_commut.
- TrivialExists. simpl. rewrite Heqb0. rewrite B by auto. rewrite !Val.add_assoc.
  rewrite (Val.add_commut (Vint (Int.repr n2))). rewrite Val.add_permut. auto.
- TrivialExists. simpl. rewrite Val.add_permut. rewrite Val.add_assoc.
    decEq; decEq. apply Val.add_commut.
- TrivialExists.
- TrivialExists. simpl. repeat rewrite Val.add_assoc. decEq; decEq. apply Val.add_commut.
- TrivialExists. simpl. rewrite Val.add_assoc; auto.
- TrivialExists. simpl.
  unfold Val.add; destruct Archi.ptr64, x, y; auto.
  + rewrite Int.add_zero; auto.
  + rewrite Int.add_zero; auto.
  + rewrite Ptrofs.add_assoc, Ptrofs.add_zero. auto.
  + rewrite Ptrofs.add_assoc, Ptrofs.add_zero. auto.
Qed.

Theorem eval_sub: binary_constructor_sound sub Val.sub.
Proof.
  red; intros until y.
  unfold sub; case (sub_match a b); intros; InvEval.
- rewrite Val.sub_add_opp. apply eval_addimm; auto.
- rewrite Val.sub_add_l. rewrite Val.sub_add_r.
    rewrite Val.add_assoc. simpl. rewrite Int.add_commut. rewrite <- Int.sub_add_opp.
    replace (Int.repr (n1 - n2)) with (Int.sub (Int.repr n1) (Int.repr n2)).
    apply eval_addimm; EvalOp.
    apply Int.eqm_samerepr; auto with ints.
- rewrite Val.sub_add_l. apply eval_addimm; EvalOp.
- rewrite Val.sub_add_r. replace (Int.repr (-n2)) with (Int.neg (Int.repr n2)). apply eval_addimm; EvalOp.
    apply Int.eqm_samerepr; auto with ints.
- TrivialExists.
Qed.

Theorem eval_negint: unary_constructor_sound negint Val.neg.
Proof.
  red; intros until x. unfold negint. case (negint_match a); intros; InvEval.
- TrivialExists.
- TrivialExists.
Qed.

Theorem eval_shlimm:
  forall n, unary_constructor_sound (fun a => shlimm a n)
                                    (fun x => Val.shl x (Vint n)).
Proof.
  red; intros until x.  unfold shlimm.
  predSpec Int.eq Int.eq_spec n Int.zero.
  intros; subst. exists x; split; auto. destruct x; simpl; auto. rewrite Int.shl_zero; auto.
  destruct (Int.ltu n Int.iwordsize) eqn:LT; simpl.
  destruct (shlimm_match a); intros; InvEval.
- exists (Vint (Int.shl n1 n)); split. EvalOp.
  simpl. rewrite LT. auto.
- destruct (Int.ltu (Int.add n n1) Int.iwordsize) eqn:?.
+ exists (Val.shl v1 (Vint (Int.add n n1))); split. EvalOp.
  destruct v1; simpl; auto.
  rewrite Heqb.
  destruct (Int.ltu n1 Int.iwordsize) eqn:?; simpl; auto.
  destruct (Int.ltu n Int.iwordsize) eqn:?; simpl; auto.
  rewrite Int.add_commut. rewrite Int.shl_shl; auto. rewrite Int.add_commut; auto.
+ TrivialExists. econstructor. EvalOp. simpl; eauto. constructor.
  simpl. auto.
- destruct (shift_is_scale n).
+ econstructor; split. EvalOp. simpl. eauto.
  rewrite ! Int.repr_unsigned.
  destruct v1; simpl; auto. rewrite LT.
  rewrite Int.shl_mul. rewrite Int.mul_add_distr_l. rewrite (Int.shl_mul (Int.repr n1)). auto.
+ TrivialExists. econstructor. EvalOp. simpl; eauto. constructor. auto.
- destruct (shift_is_scale n).
+ econstructor; split. EvalOp. simpl. eauto.
  destruct x; simpl; auto. rewrite LT.
  rewrite Int.repr_unsigned. rewrite Int.add_zero. rewrite Int.shl_mul. auto.
+ TrivialExists.
- intros; TrivialExists. constructor. eauto. constructor. EvalOp. simpl; eauto. constructor.
  auto.
Qed.

Theorem eval_shruimm:
  forall n, unary_constructor_sound (fun a => shruimm a n)
                                    (fun x => Val.shru x (Vint n)).
Proof.
  red; intros until x.  unfold shruimm.
  predSpec Int.eq Int.eq_spec n Int.zero.
  intros; subst. exists x; split; auto. destruct x; simpl; auto. rewrite Int.shru_zero; auto.
  destruct (Int.ltu n Int.iwordsize) eqn:LT; simpl.
  destruct (shruimm_match a); intros; InvEval.
- exists (Vint (Int.shru n1 n)); split. EvalOp.
  simpl. rewrite LT; auto.
- destruct (Int.ltu (Int.add n n1) Int.iwordsize) eqn:?.
+ exists (Val.shru v1 (Vint (Int.add n n1))); split. EvalOp.
  subst. destruct v1; simpl; auto.
  rewrite Heqb.
  destruct (Int.ltu n1 Int.iwordsize) eqn:?; simpl; auto.
  rewrite LT. rewrite Int.add_commut. rewrite Int.shru_shru; auto. rewrite Int.add_commut; auto.
+ TrivialExists. econstructor. EvalOp. simpl; eauto. constructor.
  simpl. auto.
- TrivialExists.
- intros; TrivialExists. constructor. eauto. constructor. EvalOp. simpl; eauto. constructor.
  auto.
Qed.

Theorem eval_shrimm:
  forall n, unary_constructor_sound (fun a => shrimm a n)
                                    (fun x => Val.shr x (Vint n)).
Proof.
  red; intros until x.  unfold shrimm.
  predSpec Int.eq Int.eq_spec n Int.zero.
  intros; subst. exists x; split; auto. destruct x; simpl; auto. rewrite Int.shr_zero; auto.
  destruct (Int.ltu n Int.iwordsize) eqn:LT; simpl.
  destruct (shrimm_match a); intros; InvEval.
- exists (Vint (Int.shr n1 n)); split. EvalOp.
  simpl. rewrite LT; auto.
- destruct (Int.ltu (Int.add n n1) Int.iwordsize) eqn:?.
+ exists (Val.shr v1 (Vint (Int.add n n1))); split. EvalOp.
  subst. destruct v1; simpl; auto.
  rewrite Heqb.
  destruct (Int.ltu n1 Int.iwordsize) eqn:?; simpl; auto.
  rewrite LT.
  rewrite Int.add_commut. rewrite Int.shr_shr; auto. rewrite Int.add_commut; auto.
+ TrivialExists. econstructor. EvalOp. simpl; eauto. constructor.
  simpl. auto.
- TrivialExists.
- intros; TrivialExists. constructor. eauto. constructor. EvalOp. simpl; eauto. constructor.
  auto.
Qed.

Lemma eval_mulimm_base:
  forall n, unary_constructor_sound (mulimm_base n) (fun x => Val.mul x (Vint n)).
Proof.
  intros; red; intros; unfold mulimm_base.
  generalize (Int.one_bits_decomp n) (Int.one_bits_range n); intros D R.
  destruct (Int.one_bits n) as [ | i l].
  TrivialExists.
  destruct l as [ | j l ].
  replace (Val.mul x (Vint n)) with (Val.shl x (Vint i)). apply eval_shlimm; auto.
  destruct x; auto; simpl. rewrite D; simpl; rewrite Int.add_zero.
  rewrite R by auto with coqlib. rewrite Int.shl_mul. auto.
  destruct l as [ | k l ].
  exploit (eval_shlimm i (x :: le) (Eletvar 0) x). constructor; auto. intros [v1 [A1 B1]].
  exploit (eval_shlimm j (x :: le) (Eletvar 0) x). constructor; auto. intros [v2 [A2 B2]].
  exploit eval_add. eexact A1. eexact A2. intros [v3 [A3 B3]].
  exists v3; split. econstructor; eauto.
  rewrite D; simpl; rewrite Int.add_zero.
  replace (Vint (Int.add (Int.shl Int.one i) (Int.shl Int.one j)))
     with (Val.add (Val.shl Vone (Vint i)) (Val.shl Vone (Vint j))).
  rewrite Val.mul_add_distr_r.
  repeat rewrite Val.shl_mul.
  apply Val.lessdef_trans with (Val.add v1 v2); auto. apply Val.add_lessdef; auto.
  simpl. rewrite ! R by auto with coqlib. auto.
  TrivialExists.
Qed.

Theorem eval_mulimm:
  forall n, unary_constructor_sound (mulimm n) (fun x => Val.mul x (Vint n)).
Proof.
  intros; red; intros until x; unfold mulimm.
  predSpec Int.eq Int.eq_spec n Int.zero.
  intros. exists (Vint Int.zero); split. EvalOp.
  destruct x; simpl; auto. subst n. rewrite Int.mul_zero. auto.
  predSpec Int.eq Int.eq_spec n Int.one.
  intros. exists x; split; auto.
  destruct x; simpl; auto. subst n. rewrite Int.mul_one. auto.
- case (mulimm_match a); intros; InvEval.
+ TrivialExists. simpl. rewrite Int.mul_commut; auto.
+ rewrite Val.mul_add_distr_l.
  exploit eval_mulimm_base; eauto. instantiate (1 := n). intros [v' [A1 B1]].
  exploit (eval_addimm (Int.mul n (Int.repr n2)) le (mulimm_base n t2) v'). auto. intros [v'' [A2 B2]].
  exists v''; split; auto. eapply Val.lessdef_trans. eapply Val.add_lessdef; eauto.
  rewrite Val.mul_commut; auto.
+ apply eval_mulimm_base; auto.
Qed.

Theorem eval_mul: binary_constructor_sound mul Val.mul.
Proof.
  red; intros until y.
  unfold mul; case (mul_match a b); intros; InvEval.
- rewrite Val.mul_commut. apply eval_mulimm. auto.
- apply eval_mulimm. auto.
- TrivialExists.
Qed.

Theorem eval_mulhs: binary_constructor_sound mulhs Val.mulhs.
Proof.
  unfold mulhs; red; intros; TrivialExists.
Qed.
  
Theorem eval_mulhu: binary_constructor_sound mulhu Val.mulhu.
Proof.
  unfold mulhu; red; intros; TrivialExists.
Qed.
  
Theorem eval_andimm:
  forall n, unary_constructor_sound (andimm n) (fun x => Val.and x (Vint n)).
Proof.
  intros; red; intros until x. unfold andimm.
  predSpec Int.eq Int.eq_spec n Int.zero.
  intros. exists (Vint Int.zero); split. EvalOp.
  destruct x; simpl; auto. subst n. rewrite Int.and_zero. auto.
  predSpec Int.eq Int.eq_spec n Int.mone.
  intros. exists x; split; auto.
  destruct x; simpl; auto. subst n. rewrite Int.and_mone. auto.
  case (andimm_match a); intros; InvEval.
- TrivialExists. simpl. rewrite Int.and_commut; auto.
- TrivialExists. simpl. rewrite Val.and_assoc. rewrite Int.and_commut. auto.
- rewrite Val.zero_ext_and. TrivialExists. rewrite Val.and_assoc.
  rewrite Int.and_commut. auto. compute; auto.
- rewrite Val.zero_ext_and. TrivialExists. rewrite Val.and_assoc.
  rewrite Int.and_commut. auto. compute; auto.
- TrivialExists.
Qed.

Theorem eval_and: binary_constructor_sound and Val.and.
Proof.
  red; intros until y; unfold and; case (and_match a b); intros; InvEval.
- rewrite Val.and_commut. apply eval_andimm; auto.
- apply eval_andimm; auto.
- TrivialExists.
Qed.

Theorem eval_orimm:
  forall n, unary_constructor_sound (orimm n) (fun x => Val.or x (Vint n)).
Proof.
  intros; red; intros until x. unfold orimm.
  predSpec Int.eq Int.eq_spec n Int.zero.
  intros. exists x; split. auto.
  destruct x; simpl; auto. subst n. rewrite Int.or_zero. auto.
  predSpec Int.eq Int.eq_spec n Int.mone.
  intros. exists (Vint Int.mone); split. EvalOp.
  destruct x; simpl; auto. subst n. rewrite Int.or_mone. auto.
  destruct (orimm_match a); intros; InvEval.
- TrivialExists. simpl. rewrite Int.or_commut; auto.
- subst. rewrite Val.or_assoc. simpl. rewrite Int.or_commut. TrivialExists.
- TrivialExists.
Qed.

Remark eval_same_expr:
  forall a1 a2 le v1 v2,
  same_expr_pure a1 a2 = true ->
  eval_expr ge sp e m le a1 v1 ->
  eval_expr ge sp e m le a2 v2 ->
  a1 = a2 /\ v1 = v2.
Proof.
  intros until v2.
  destruct a1; simpl; try (intros; discriminate).
  destruct a2; simpl; try (intros; discriminate).
  case (ident_eq i i0); intros.
  subst i0. inversion H0. inversion H1. split. auto. congruence.
  discriminate.
Qed.

Remark int_add_sub_eq:
  forall x y z, Int.add x y = z -> Int.sub z x = y.
Proof.
  intros. subst z. rewrite Int.sub_add_l. rewrite Int.sub_idem. apply Int.add_zero_l.
Qed.

Lemma eval_or: binary_constructor_sound or Val.or.
Proof.
  red; intros until y; unfold or; case (or_match a b); intros.
  (* intconst *)
- InvEval. rewrite Val.or_commut. apply eval_orimm; auto.
- InvEval. apply eval_orimm; auto.
- (* shlimm - shruimm *)
  predSpec Int.eq Int.eq_spec (Int.add n1 n2) Int.iwordsize.
  destruct (same_expr_pure t1 t2) eqn:?.
  InvEval. exploit eval_same_expr; eauto. intros [EQ1 EQ2]; subst.
  exists (Val.ror v0 (Vint n2)); split. EvalOp.
  destruct v0; simpl; auto.
  destruct (Int.ltu n1 Int.iwordsize) eqn:?; auto.
  destruct (Int.ltu n2 Int.iwordsize) eqn:?; auto.
  simpl. rewrite <- Int.or_ror; auto.
  InvEval. econstructor; split; eauto. EvalOp.
  simpl. erewrite int_add_sub_eq; eauto.
  TrivialExists.
- (* shruimm - shlimm *)
  predSpec Int.eq Int.eq_spec (Int.add n1 n2) Int.iwordsize.
  destruct (same_expr_pure t1 t2) eqn:?.
  InvEval. exploit eval_same_expr; eauto. intros [EQ1 EQ2]; subst.
  exists (Val.ror v1 (Vint n2)); split. EvalOp.
  destruct v1; simpl; auto.
  destruct (Int.ltu n2 Int.iwordsize) eqn:?; auto.
  destruct (Int.ltu n1 Int.iwordsize) eqn:?; auto.
  simpl. rewrite Int.or_commut. rewrite <- Int.or_ror; auto.
  InvEval. econstructor; split; eauto. EvalOp.
  simpl. erewrite int_add_sub_eq; eauto.
  rewrite Val.or_commut; auto.
  TrivialExists.
- (* default *)
  TrivialExists.
Qed.

Theorem eval_xorimm:
  forall n, unary_constructor_sound (xorimm n) (fun x => Val.xor x (Vint n)).
Proof.
  intros; red; intros until x. unfold xorimm.
  predSpec Int.eq Int.eq_spec n Int.zero.
  intros. exists x; split. auto.
  destruct x; simpl; auto. subst n. rewrite Int.xor_zero. auto.
  destruct (xorimm_match a); intros; InvEval.
- TrivialExists. simpl. rewrite Int.xor_commut; auto.
- rewrite Val.xor_assoc. simpl. rewrite Int.xor_commut. TrivialExists.
- rewrite Val.not_xor. rewrite Val.xor_assoc.
  rewrite (Val.xor_commut (Vint Int.mone)). TrivialExists.
- TrivialExists.
Qed.

Theorem eval_xor: binary_constructor_sound xor Val.xor.
Proof.
  red; intros until y; unfold xor; case (xor_match a b); intros; InvEval.
- rewrite Val.xor_commut. apply eval_xorimm; auto.
- apply eval_xorimm; auto.
- TrivialExists.
Qed.

Theorem eval_divs_base:
  forall le a b x y z,
  eval_expr ge sp e m le a x ->
  eval_expr ge sp e m le b y ->
  Val.divs x y = Some z ->
  exists v, eval_expr ge sp e m le (divs_base a b) v /\ Val.lessdef z v.
Proof.
  intros. unfold divs_base. exists z; split. EvalOp. auto.
Qed.

Theorem eval_divu_base:
  forall le a b x y z,
  eval_expr ge sp e m le a x ->
  eval_expr ge sp e m le b y ->
  Val.divu x y = Some z ->
  exists v, eval_expr ge sp e m le (divu_base a b) v /\ Val.lessdef z v.
Proof.
  intros. unfold divu_base. exists z; split. EvalOp. auto.
Qed.

Theorem eval_mods_base:
  forall le a b x y z,
  eval_expr ge sp e m le a x ->
  eval_expr ge sp e m le b y ->
  Val.mods x y = Some z ->
  exists v, eval_expr ge sp e m le (mods_base a b) v /\ Val.lessdef z v.
Proof.
  intros. unfold mods_base. exists z; split. EvalOp. auto.
Qed.

Theorem eval_modu_base:
  forall le a b x y z,
  eval_expr ge sp e m le a x ->
  eval_expr ge sp e m le b y ->
  Val.modu x y = Some z ->
  exists v, eval_expr ge sp e m le (modu_base a b) v /\ Val.lessdef z v.
Proof.
  intros. unfold modu_base. exists z; split. EvalOp. auto.
Qed.

Theorem eval_shrximm:
  forall le a n x z,
  eval_expr ge sp e m le a x ->
  Val.shrx x (Vint n) = Some z ->
  exists v, eval_expr ge sp e m le (shrximm a n) v /\ Val.lessdef z v.
Proof.
  intros. unfold shrximm.
  predSpec Int.eq Int.eq_spec n Int.zero.
  subst n. exists x; split; auto.
  destruct x; simpl in H0; try discriminate.
  destruct (Int.ltu Int.zero (Int.repr 31)); inv H0.
  replace (Int.shrx i Int.zero) with i. auto.
  unfold Int.shrx, Int.divs. rewrite Int.shl_zero.
  change (Int.signed Int.one) with 1. rewrite Z.quot_1_r. rewrite Int.repr_signed; auto.
  econstructor; split. EvalOp. auto.
Qed.

Theorem eval_shl: binary_constructor_sound shl Val.shl.
Proof.
  red; intros until y; unfold shl; case (shl_match b); intros.
- InvEval. apply eval_shlimm; auto.
- TrivialExists.
Qed.

Theorem eval_shr: binary_constructor_sound shr Val.shr.
Proof.
  red; intros until y; unfold shr; case (shr_match b); intros.
- InvEval. apply eval_shrimm; auto.
- TrivialExists.
Qed.

Theorem eval_shru: binary_constructor_sound shru Val.shru.
Proof.
  red; intros until y; unfold shru; case (shru_match b); intros.
- InvEval. apply eval_shruimm; auto.
- TrivialExists.
Qed.

Theorem eval_negf: unary_constructor_sound negf Val.negf.
Proof.
  red; intros. TrivialExists.
Qed.

Theorem eval_absf: unary_constructor_sound absf Val.absf.
Proof.
  red; intros. TrivialExists.
Qed.

Theorem eval_addf: binary_constructor_sound addf Val.addf.
Proof.
  red; intros; TrivialExists.
Qed.

Theorem eval_subf: binary_constructor_sound subf Val.subf.
Proof.
  red; intros; TrivialExists.
Qed.

Theorem eval_mulf: binary_constructor_sound mulf Val.mulf.
Proof.
  red; intros; TrivialExists.
Qed.

Theorem eval_negfs: unary_constructor_sound negfs Val.negfs.
Proof.
  red; intros. TrivialExists.
Qed.

Theorem eval_absfs: unary_constructor_sound absfs Val.absfs.
Proof.
  red; intros. TrivialExists.
Qed.

Theorem eval_addfs: binary_constructor_sound addfs Val.addfs.
Proof.
  red; intros; TrivialExists.
Qed.

Theorem eval_subfs: binary_constructor_sound subfs Val.subfs.
Proof.
  red; intros; TrivialExists.
Qed.

Theorem eval_mulfs: binary_constructor_sound mulfs Val.mulfs.
Proof.
  red; intros; TrivialExists.
Qed.

Section COMP_IMM.

Variable default: comparison -> int -> condition.
Variable intsem: comparison -> int -> int -> bool.
Variable sem: comparison -> val -> val -> val.

Hypothesis sem_int: forall c x y, sem c (Vint x) (Vint y) = Val.of_bool (intsem c x y).
Hypothesis sem_undef: forall c v, sem c Vundef v = Vundef.
Hypothesis sem_eq: forall x y, sem Ceq (Vint x) (Vint y) = Val.of_bool (Int.eq x y).
Hypothesis sem_ne: forall x y, sem Cne (Vint x) (Vint y) = Val.of_bool (negb (Int.eq x y)).
Hypothesis sem_default: forall c v n, sem c v (Vint n) = Val.of_optbool (eval_condition (default c n) (v :: nil) m).

Lemma eval_compimm:
  forall le c a n2 x,
  eval_expr ge sp e m le a x ->
  exists v, eval_expr ge sp e m le (compimm default intsem c a n2) v
         /\ Val.lessdef (sem c x (Vint n2)) v.
Proof.
  intros until x.
  unfold compimm; case (compimm_match c a); intros.
- (* constant *)
  InvEval. rewrite sem_int. TrivialExists. simpl. destruct (intsem c0 n1 n2); auto.
- (* eq cmp *)
  InvEval. inv H. simpl in H5. inv H5.
  destruct (Int.eq_dec n2 Int.zero). subst n2. TrivialExists.
  simpl. rewrite eval_negate_condition.
  destruct (eval_condition c0 vl m); simpl.
  unfold Vtrue, Vfalse. destruct b; simpl; rewrite sem_eq; auto.
  rewrite sem_undef; auto.
  destruct (Int.eq_dec n2 Int.one). subst n2. TrivialExists.
  simpl. destruct (eval_condition c0 vl m); simpl.
  unfold Vtrue, Vfalse. destruct b; simpl; rewrite sem_eq; auto.
  rewrite sem_undef; auto.
  exists (Vint Int.zero); split. EvalOp.
  destruct (eval_condition c0 vl m); simpl.
  unfold Vtrue, Vfalse. destruct b; rewrite sem_eq; rewrite Int.eq_false; auto.
  rewrite sem_undef; auto.
- (* ne cmp *)
  InvEval. inv H. simpl in H5. inv H5.
  destruct (Int.eq_dec n2 Int.zero). subst n2. TrivialExists.
  simpl. destruct (eval_condition c0 vl m); simpl.
  unfold Vtrue, Vfalse. destruct b; simpl; rewrite sem_ne; auto.
  rewrite sem_undef; auto.
  destruct (Int.eq_dec n2 Int.one). subst n2. TrivialExists.
  simpl. rewrite eval_negate_condition. destruct (eval_condition c0 vl m); simpl.
  unfold Vtrue, Vfalse. destruct b; simpl; rewrite sem_ne; auto.
  rewrite sem_undef; auto.
  exists (Vint Int.one); split. EvalOp.
  destruct (eval_condition c0 vl m); simpl.
  unfold Vtrue, Vfalse. destruct b; rewrite sem_ne; rewrite Int.eq_false; auto.
  rewrite sem_undef; auto.
- (* eq andimm *)
  destruct (Int.eq_dec n2 Int.zero). InvEval; subst.
  econstructor; split. EvalOp. simpl; eauto.
  destruct v1; simpl; try (rewrite sem_undef; auto). rewrite sem_eq.
  destruct (Int.eq (Int.and i n1) Int.zero); auto.
  TrivialExists. simpl. rewrite sem_default. auto.
- (* ne andimm *)
  destruct (Int.eq_dec n2 Int.zero). InvEval; subst.
  econstructor; split. EvalOp. simpl; eauto.
  destruct v1; simpl; try (rewrite sem_undef; auto). rewrite sem_ne.
  destruct (Int.eq (Int.and i n1) Int.zero); auto.
  TrivialExists. simpl. rewrite sem_default. auto.
- (* default *)
  TrivialExists. simpl. rewrite sem_default. auto.
Qed.

Hypothesis sem_swap:
  forall c x y, sem (swap_comparison c) x y = sem c y x.

Lemma eval_compimm_swap:
  forall le c a n2 x,
  eval_expr ge sp e m le a x ->
  exists v, eval_expr ge sp e m le (compimm default intsem (swap_comparison c) a n2) v
         /\ Val.lessdef (sem c (Vint n2) x) v.
Proof.
  intros. rewrite <- sem_swap. eapply eval_compimm; eauto.
Qed.

End COMP_IMM.

Theorem eval_comp:
  forall c, binary_constructor_sound (comp c) (Val.cmp c).
Proof.
  intros; red; intros until y. unfold comp; case (comp_match a b); intros; InvEval.
  eapply eval_compimm_swap; eauto.
  intros. unfold Val.cmp. rewrite Val.swap_cmp_bool; auto.
  eapply eval_compimm; eauto.
  TrivialExists.
Qed.

Theorem eval_compu:
  forall c, binary_constructor_sound (compu c) (Val.cmpu (Mem.valid_pointer m) c).
Proof.
  intros; red; intros until y. unfold compu; case (compu_match a b); intros; InvEval.
  eapply eval_compimm_swap; eauto.
  intros. unfold Val.cmpu. rewrite Val.swap_cmpu_bool; auto.
  eapply eval_compimm; eauto.
  TrivialExists.
Qed.

Theorem eval_compf:
  forall c, binary_constructor_sound (compf c) (Val.cmpf c).
Proof.
  intros; red; intros. unfold compf. TrivialExists.
Qed.

Theorem eval_compfs:
  forall c, binary_constructor_sound (compfs c) (Val.cmpfs c).
Proof.
  intros; red; intros. unfold compfs. TrivialExists.
Qed.

Theorem eval_cast8signed: unary_constructor_sound cast8signed (Val.sign_ext 8).
Proof.
  red; intros until x. unfold cast8signed. case (cast8signed_match a); intros; InvEval.
  TrivialExists.
  TrivialExists.
Qed.

Theorem eval_cast8unsigned: unary_constructor_sound cast8unsigned (Val.zero_ext 8).
Proof.
  red; intros until x. unfold cast8unsigned. destruct (cast8unsigned_match a); intros; InvEval.
  TrivialExists.
  subst. rewrite Val.zero_ext_and. rewrite Val.and_assoc.
  rewrite Int.and_commut. apply eval_andimm; auto. compute; auto.
  TrivialExists.
Qed.

Theorem eval_cast16signed: unary_constructor_sound cast16signed (Val.sign_ext 16).
Proof.
  red; intros until x. unfold cast16signed. case (cast16signed_match a); intros; InvEval.
  TrivialExists.
  TrivialExists.
Qed.

Theorem eval_cast16unsigned: unary_constructor_sound cast16unsigned (Val.zero_ext 16).
Proof.
  red; intros until x. unfold cast16unsigned. destruct (cast16unsigned_match a); intros; InvEval.
  TrivialExists.
  subst. rewrite Val.zero_ext_and. rewrite Val.and_assoc.
  rewrite Int.and_commut. apply eval_andimm; auto. compute; auto.
  TrivialExists.
Qed.

Theorem eval_select: 
  forall le ty cond al vl a1 v1 a2 v2 a b,
  select ty cond al a1 a2 = Some a ->
  eval_exprlist ge sp e m le al vl ->
  eval_expr ge sp e m le a1 v1 ->
  eval_expr ge sp e m le a2 v2 ->
  eval_condition cond vl m = Some b ->
  exists v, 
     eval_expr ge sp e m le a v
  /\ Val.lessdef (Val.select (Some b) v1 v2 ty) v.
Proof.
  unfold select; intros. 
  destruct (select_supported ty); try discriminate.
  destruct (select_swap cond); inv H.
- exists (Val.select (Some (negb b)) v2 v1 ty); split.
  apply eval_Eop with (v2 :: v1 :: vl).
  constructor; auto. constructor; auto.
  simpl. rewrite eval_negate_condition, H3; auto.
  destruct b; auto.
- exists (Val.select (Some b) v1 v2 ty); split.
  apply eval_Eop with (v1 :: v2 :: vl).
  constructor; auto. constructor; auto.
  simpl. rewrite H3; auto.
  auto.
Qed.

Theorem eval_singleoffloat: unary_constructor_sound singleoffloat Val.singleoffloat.
Proof.
  red; intros. unfold singleoffloat. TrivialExists.
Qed.

Theorem eval_floatofsingle: unary_constructor_sound floatofsingle Val.floatofsingle.
Proof.
  red; intros. unfold floatofsingle. TrivialExists.
Qed.

Theorem eval_intoffloat:
  forall le a x y,
  eval_expr ge sp e m le a x ->
  Val.intoffloat x = Some y ->
  exists v, eval_expr ge sp e m le (intoffloat a) v /\ Val.lessdef y v.
Proof.
  intros; unfold intoffloat. exists y; split; auto.
  EvalOp. simpl; rewrite H0; auto.
Qed.

Theorem eval_floatofint:
  forall le a x y,
  eval_expr ge sp e m le a x ->
  Val.floatofint x = Some y ->
  exists v, eval_expr ge sp e m le (floatofint a) v /\ Val.lessdef y v.
Proof.
  intros until y; unfold floatofint. case (floatofint_match a); intros; InvEval.
  TrivialExists.
  TrivialExists.
Qed.

Theorem eval_intuoffloat:
  forall le a x y,
  eval_expr ge sp e m le a x ->
  Val.intuoffloat x = Some y ->
  exists v, eval_expr ge sp e m le (intuoffloat a) v /\ Val.lessdef y v.
Proof.
  intros. destruct x; simpl in H0; try discriminate.
  destruct (Float.to_intu f) as [n|] eqn:?; simpl in H0; inv H0.
  exists (Vint n); split; auto. unfold intuoffloat.
  set (im := Int.repr Int.half_modulus).
  set (fm := Float.of_intu im).
  assert (eval_expr ge sp e m (Vfloat fm :: Vfloat f :: le) (Eletvar (S O)) (Vfloat f)).
    constructor. auto.
  assert (eval_expr ge sp e m (Vfloat fm :: Vfloat f :: le) (Eletvar O) (Vfloat fm)).
    constructor. auto.
  econstructor. eauto.
  econstructor. instantiate (1 := Vfloat fm). EvalOp.
  eapply eval_Econdition with (va := Float.cmp Clt f fm).
  eauto with evalexpr.
  destruct (Float.cmp Clt f fm) eqn:?.
  exploit Float.to_intu_to_int_1; eauto. intro EQ.
  EvalOp. simpl. rewrite EQ; auto.
  exploit Float.to_intu_to_int_2; eauto.
  change Float.ox8000_0000 with im. fold fm. intro EQ.
  set (t2 := subf (Eletvar (S O)) (Eletvar O)).
  set (t3 := intoffloat t2).
  exploit (eval_subf (Vfloat fm :: Vfloat f :: le) (Eletvar (S O)) (Vfloat f) (Eletvar O)); eauto.
  fold t2. intros [v2 [A2 B2]]. simpl in B2. inv B2.
  exploit (eval_addimm Float.ox8000_0000 (Vfloat fm :: Vfloat f :: le) t3).
    unfold t3. unfold intoffloat. EvalOp. simpl. rewrite EQ. simpl. eauto.
  intros [v4 [A4 B4]]. simpl in B4. inv B4.
  rewrite Int.sub_add_opp in A4. rewrite Int.add_assoc in A4.
  rewrite (Int.add_commut (Int.neg im)) in A4.
  rewrite Int.add_neg_zero in A4.
  rewrite Int.add_zero in A4.
  auto.
Qed.

Theorem eval_floatofintu:
  forall le a x y,
  eval_expr ge sp e m le a x ->
  Val.floatofintu x = Some y ->
  exists v, eval_expr ge sp e m le (floatofintu a) v /\ Val.lessdef y v.
Proof.
  intros until y; unfold floatofintu. case (floatofintu_match a); intros.
- InvEval. TrivialExists.
- destruct x; simpl in H0; try discriminate. inv H0.
  exists (Vfloat (Float.of_intu i)); split; auto.
  destruct (favor_branchless tt).
+ econstructor. eauto.
  assert (eval_expr ge sp e m (Vint i :: le) (Eletvar O) (Vint i)) by (constructor; auto).
  exploit (eval_andimm Float.ox7FFF_FFFF (Vint i :: le) (Eletvar 0)); eauto.
  simpl. intros [v1 [A1 B1]]. inv B1.
  exploit (eval_andimm Float.ox8000_0000 (Vint i :: le) (Eletvar 0)); eauto.
  simpl. intros [v2 [A2 B2]]. inv B2.
  unfold subf. econstructor.
  constructor. econstructor. constructor. eexact A1. constructor. simpl; eauto.
  constructor. econstructor. constructor. eexact A2. constructor. simpl; eauto.
  constructor.
  simpl. rewrite Float.of_intu_of_int_3. auto.
+ econstructor. eauto.
  set (fm := Float.of_intu Float.ox8000_0000).
  assert (eval_expr ge sp e m (Vint i :: le) (Eletvar O) (Vint i)).
    constructor. auto.
  eapply eval_Econdition with (va := Int.ltu i Float.ox8000_0000).
  eauto with evalexpr.
  destruct (Int.ltu i Float.ox8000_0000) eqn:?.
  rewrite Float.of_intu_of_int_1; auto.
  unfold floatofint. EvalOp.
  exploit (eval_addimm (Int.neg Float.ox8000_0000) (Vint i :: le) (Eletvar 0)); eauto.
  simpl. intros [v [A B]]. inv B.
  unfold addf. EvalOp.
  constructor. unfold floatofint. EvalOp. simpl; eauto.
  constructor. EvalOp. simpl; eauto. constructor. simpl; eauto.
  fold fm. rewrite Float.of_intu_of_int_2; auto.
  rewrite Int.sub_add_opp. auto.
Qed.

Theorem eval_intofsingle:
  forall le a x y,
  eval_expr ge sp e m le a x ->
  Val.intofsingle x = Some y ->
  exists v, eval_expr ge sp e m le (intofsingle a) v /\ Val.lessdef y v.
Proof.
  intros; unfold intoffloat. exists y; split; auto.
  EvalOp. simpl; rewrite H0; auto.
Qed.

Theorem eval_singleofint:
  forall le a x y,
  eval_expr ge sp e m le a x ->
  Val.singleofint x = Some y ->
  exists v, eval_expr ge sp e m le (singleofint a) v /\ Val.lessdef y v.
Proof.
  intros until y; unfold singleofint. case (singleofint_match a); intros; InvEval.
  TrivialExists.
  TrivialExists.
Qed.

Theorem eval_intuofsingle:
  forall le a x y,
  eval_expr ge sp e m le a x ->
  Val.intuofsingle x = Some y ->
  exists v, eval_expr ge sp e m le (intuofsingle a) v /\ Val.lessdef y v.
Proof.
  intros. destruct x; simpl in H0; try discriminate.
  destruct (Float32.to_intu f) as [n|] eqn:?; simpl in H0; inv H0.
  unfold intuofsingle. apply eval_intuoffloat with (Vfloat (Float.of_single f)).
  unfold floatofsingle. EvalOp.
  simpl. change (Float.of_single f) with (Float32.to_double f).
  erewrite Float32.to_intu_double; eauto. auto.
Qed.

Theorem eval_singleofintu:
  forall le a x y,
  eval_expr ge sp e m le a x ->
  Val.singleofintu x = Some y ->
  exists v, eval_expr ge sp e m le (singleofintu a) v /\ Val.lessdef y v.
Proof.
  intros until y; unfold singleofintu. case (singleofintu_match a); intros.
  InvEval. TrivialExists.
  destruct x; simpl in H0; try discriminate. inv H0.
  exploit eval_floatofintu. eauto. simpl. reflexivity.
  intros (v & A & B).
  exists (Val.singleoffloat v); split.
  unfold singleoffloat; EvalOp.
  inv B; simpl. rewrite Float32.of_intu_double. auto.
Qed.

Theorem eval_addressing:
  forall le chunk a v b ofs,
  eval_expr ge sp e m le a v ->
  v = Vptr b ofs ->
  match addressing chunk a with (mode, args) =>
    exists vl,
    eval_exprlist ge sp e m le args vl /\
    eval_addressing ge sp mode vl = Some v
  end.
Proof.
  intros until ofs.
  assert (A: v = Vptr b ofs -> eval_addressing ge sp (Aindexed 0) (v :: nil) = Some v).
  { intros. subst v. unfold eval_addressing.
    destruct Archi.ptr64 eqn:SF; simpl; rewrite SF; rewrite Ptrofs.add_zero; auto. }
  assert (D: forall a,
             eval_expr ge sp e m le a v ->
             v = Vptr b ofs ->
             exists vl, eval_exprlist ge sp e m le (a ::: Enil) vl
                     /\ eval_addressing ge sp (Aindexed 0) vl = Some v).
  { intros. exists (v :: nil); split. constructor; auto. constructor. auto. }
  unfold addressing; case (addressing_match a); intros.
- destruct (negb Archi.ptr64 && addressing_valid addr) eqn:E.
+ inv H. InvBooleans. apply negb_true_iff in H. unfold eval_addressing; rewrite H.
  exists vl; auto.
+ apply D; auto.
- destruct (Archi.ptr64 && addressing_valid addr) eqn:E.
+ inv H. InvBooleans. unfold eval_addressing; rewrite H.
  exists vl; auto.
+ apply D; auto.
- apply D; auto.
Qed.

Theorem eval_builtin_arg_addr:
  forall addr al vl v,
  eval_exprlist ge sp e m nil al vl ->
  Op.eval_addressing ge sp addr vl = Some v ->
  CminorSel.eval_builtin_arg ge sp e m (builtin_arg_addr addr al) v.
Proof.
  intros until v. unfold builtin_arg_addr; case (builtin_arg_addr_match addr al); intros; InvEval.
- set (v2 := if Archi.ptr64 then Vlong (Int64.repr n) else Vint (Int.repr n)).
  assert (EQ: v = if Archi.ptr64 then Val.addl v1 v2 else Val.add v1 v2).
  { unfold Op.eval_addressing in H0; unfold v2; destruct Archi.ptr64; simpl in H0; inv H0; auto. }
  rewrite EQ. constructor. constructor; auto. unfold v2; destruct Archi.ptr64; constructor.
- rewrite eval_addressing_Aglobal in H0. inv H0. constructor.
- rewrite eval_addressing_Ainstack in H0. inv H0. constructor.
- constructor. econstructor. eauto. rewrite eval_Olea_ptr. auto. 
Qed. 

Theorem eval_builtin_arg:
  forall a v,
  eval_expr ge sp e m nil a v ->
  CminorSel.eval_builtin_arg ge sp e m (builtin_arg a) v.
Proof.
  intros until v. unfold builtin_arg; case (builtin_arg_match a); intros; InvEval.
- constructor.
- constructor.
- destruct Archi.ptr64 eqn:SF. 
+ constructor; auto.
+ inv H. eapply eval_builtin_arg_addr. eauto. unfold Op.eval_addressing; rewrite SF; assumption.
- destruct Archi.ptr64 eqn:SF. 
+ inv H. eapply eval_builtin_arg_addr. eauto. unfold Op.eval_addressing; rewrite SF; assumption.
+ constructor; auto.
- simpl in H5. inv H5. constructor.
- constructor; auto.
- inv H. InvEval. rewrite eval_addressing_Aglobal in H6. inv H6. constructor; auto.
- inv H. InvEval. rewrite eval_addressing_Ainstack in H6. inv H6. constructor; auto.
- constructor; auto.
Qed.

End CMCONSTR.
