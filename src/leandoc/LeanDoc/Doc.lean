/-
Copyright (c) 2023 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: David Thrane Christiansen
-/
import Lean
import Std.Tactic.GuardMsgs

namespace LeanDoc

namespace Doc

open Std (Format)
open Lean (Name)

def docName (moduleName : Name) : Name :=
  id <| .str moduleName "the canonical document object name"
where
  absolutize : Name → Name
    | .anonymous => .anonymous
    | .num ns i => .num (absolutize ns) i
    | n@(.str .anonymous "_root_") => n
    | .str .anonymous other => .str (.str .anonymous "_root_") other
    | .str ns n => .str (absolutize ns) n

structure Genre : Type 1 where
  PartMetadata : Type
  Block : Type
  Inline : Type
  TraverseContext : Type
  TraverseState : Type

def Genre.none : Genre := ⟨Empty, Empty, Empty, Unit, Unit⟩

instance : Repr Genre.none.Block where
  reprPrec e _ := nomatch e

instance : Repr Genre.none.Inline where
  reprPrec e _ := nomatch e

instance : Repr Genre.none.PartMetadata where
  reprPrec e _ := nomatch e


inductive LinkDest where
  | url (address : String)
  | ref (name : String)
deriving Repr

inductive Inline (genre : Genre) : Type where
  | text (string : String)
  | emph (content : Array (Inline genre))
  | bold (content : Array (Inline genre))
  | code (string : String)
  | linebreak (string : String)
  | link (content : Array (Inline genre)) (dest : LinkDest)
  | footnote (name : String)
  | image (alt : String) (dest : LinkDest)
  | concat (content : Array (Inline genre))
  | other (container : genre.Inline) (content : Array (Inline genre))

private def reprArray (r : α → Nat → Format) (arr : Array α) : Format :=
  .bracket "#[" (.joinSep (arr.toList.map (r · max_prec)) ("," ++ .line)) "]"

private def reprList (r : α → Nat → Format) (xs : List α) : Format :=
  .bracket "[" (.joinSep (xs.map (r · max_prec)) ("," ++ .line)) "]"

private def reprPair (x : α → Nat → Format) (y : β → Nat → Format) (v : α × β) : Format :=
  .bracket "(" (x v.fst max_prec ++ ("," ++.line) ++ y v.snd max_prec) ")"

private def reprCtor (c : Name) (args : List Format) : Format :=
  .nest 2 <| .group (.joinSep (.text s!"{c}" :: args) .line)

private def reprHash [BEq α] [Hashable α] (k : α → Nat → Format) (v : β → Nat → Format) (h : Lean.HashMap α β) : Format :=
  reprCtor ``Lean.HashMap.ofList [reprList (fun x _ => reprPair k v x) h.toList]


partial def Inline.reprPrec [Repr g.Inline] (inline : Inline g) (prec : Nat) : Std.Format :=
    open Repr Std.Format in
    let rec go i p :=
      (addAppParen · p) <|
        match i with
        | .text str => reprCtor ``Inline.text [reprArg str]
        | .emph content => reprCtor ``Inline.emph [reprArray go content]
        | .bold content => reprCtor ``Inline.bold [reprArray go content]
        | .code str => reprCtor ``Inline.code [reprArg str]
        | .linebreak str => reprCtor ``Inline.linebreak [reprArg str]
        | .link content dest => reprCtor ``Inline.link [
            reprArray go content,
            reprArg dest
          ]
        | .footnote name => reprCtor ``Inline.footnote [reprArg name]
        | .image content dest => reprCtor ``Inline.image [
            reprArg content,
            reprArg dest
          ]
        | .concat content => reprCtor ``Inline.concat [reprArray go content]
        | .other container content => reprCtor ``Inline.other [reprArg container, reprArray go content]
    go inline prec


instance [Repr g.Inline] : Repr (Inline g) where
  reprPrec := Inline.reprPrec


inductive ArgVal where
  | name (x : String)
  | str (text : String)
  | num (n : Nat)
deriving Repr

inductive Arg where
  | anon (value : ArgVal)
  | named (name : String) (value : ArgVal)
deriving Repr

structure ListItem (α : Type u) where
  indent : Nat
  contents : Array α
deriving Repr

def ListItem.reprPrec [Repr α] : ListItem α → Nat → Std.Format := Repr.reprPrec

structure DescItem (α : Type u) (β : Type v) where
  term : Array α
  desc : Array β
deriving Repr

def DescItem.reprPrec [Repr α] [Repr β] : DescItem α β → Nat → Std.Format := Repr.reprPrec

inductive Block (genre : Genre) : Type where
  | para (contents : Array (Inline genre))
  | code (name : Option String) (args : Array Arg) (indent : Nat) (content : String)
  | ul (items : Array (ListItem (Block genre)))
  | ol (start : Int) (items : Array (ListItem (Block genre)))
  | dl (items : Array (DescItem (Inline genre) (Block genre)))
  | blockquote (items : Array (Block genre))
  | concat (content : Array (Block genre))
  | other (container : genre.Block) (content : Array (Block genre))

partial def Block.reprPrec [Repr g.Inline] [Repr g.Block] (inline : Block g) (prec : Nat) : Std.Format :=
    open Repr Std.Format in
    let rec go i p :=
      (addAppParen · p) <|
        match i with
        | para contents => reprCtor ``Block.para [reprArg contents]
        | code name args indent content => reprCtor ``Block.code [reprArg name, reprArg args, reprArg indent, reprArg content]
        | ul items => reprCtor ``Block.ul [reprArray (@ListItem.reprPrec _ ⟨go⟩) items]
        | ol start items => reprCtor ``Block.ol [reprArg start, reprArray (@ListItem.reprPrec _ ⟨go⟩) items]
        | dl items => reprCtor ``Block.dl [reprArray (@DescItem.reprPrec _ _ _ ⟨go⟩) items]
        | blockquote items => reprCtor ``Block.blockquote [reprArray go items]
        | concat content => reprCtor ``Block.concat [reprArray go content]
        | other container content => reprCtor ``Block.other [reprArg container, reprArray go content]
    go inline prec

instance [Repr g.Inline] [Repr g.Block] : Repr (Block g) where
  reprPrec b p := Block.reprPrec b p


inductive Part (genre : Genre) : Type where
  | mk (title : Array (Inline genre)) (titleString : String) (metadata : Option genre.PartMetadata) (content : Array (Block genre)) (subParts : Array (Part genre))
deriving Inhabited

def Part.title : Part genre → Array (Inline genre)
  | .mk title .. => title
def Part.titleString : Part genre → String
  | .mk _ titleString .. => titleString
def Part.metadata : Part genre → Option genre.PartMetadata
  | .mk _ _ metadata .. => metadata
def Part.content  : Part genre → Array (Block genre)
  | .mk _ _ _ content .. => content
def Part.subParts : Part genre → Array (Part genre)
  | .mk _ _ _ _ subParts => subParts

def Part.withoutMetadata : Part genre → Part genre
  | .mk title titleString _ content subParts => .mk title titleString none content subParts

partial def Part.reprPrec [Repr g.Inline] [Repr g.Block] [Repr g.PartMetadata] (part : Part g) (prec : Nat) : Std.Format :=
  open Std.Format in
  reprCtor ``Part.mk [
      reprArg part.title,
      reprArg part.titleString,
      reprArg part.metadata,
      reprArg part.content,
      reprArray Part.reprPrec part.subParts
    ]

instance [Repr g.Inline] [Repr g.Block] [Repr g.PartMetadata] : Repr (Part g) := ⟨Part.reprPrec⟩

structure Doc (genre : Genre) where
  content : Part genre
  linkRefs : Lean.HashMap String String
  footnotes : Lean.HashMap String (Array (Inline genre))
deriving Inhabited

instance [Repr k] [Repr v] [BEq k] [Hashable k] : Repr (Lean.HashMap k v) where
  reprPrec h _n := reprCtor ``Lean.HashMap.ofList [reprArg h.toList]

def Doc.reprPrec [Repr (Inline g)] [Repr (Part g)] (doc : Doc g) (prec : Nat) : Std.Format :=
  reprCtor ``Doc.mk [reprArg doc.content, reprArg doc.linkRefs, reprArg doc.footnotes]

instance [Repr g.Inline] [Repr g.Block] [Repr g.PartMetadata] [Repr (Part g)] : Repr (Doc g)  := ⟨Doc.reprPrec⟩

class Traverse (g : Genre) (m : outParam (Type → Type)) where
  part [MonadReader g.TraverseContext m] [MonadState g.TraverseState m] : Part g → m Unit
  block [MonadReader g.TraverseContext m] [MonadState g.TraverseState m] : Block g → m Unit
  inline [MonadReader g.TraverseContext m] [MonadState g.TraverseState m] : Inline g → m Unit
  genrePart [MonadReader g.TraverseContext m] [MonadState g.TraverseState m] : g.PartMetadata → Part g → m (Option (Part g))
  genreBlock [MonadReader g.TraverseContext m] [MonadState g.TraverseState m] : g.Block → Array (Block g) → m (Option (Block g))
  genreInline [MonadReader g.TraverseContext m] [MonadState g.TraverseState m] : g.Inline → Array (Inline g) → m (Option (Inline g))



partial def Genre.traverse (g : Genre)
    [Traverse g m] [Monad m] [MonadReader g.TraverseContext m] [MonadState g.TraverseState m]
    (top : Doc g) : m (Doc g) :=
  doc top

where
  inline (i : Doc.Inline g) : m (Doc.Inline g) := do
    Traverse.inline i
    match i with
    | .emph content => .emph <$> content.mapM inline
    | .bold content => .bold <$> content.mapM inline
    | .link content ref => (.link · ref) <$> content.mapM inline
    | .footnote name => pure <| .footnote name
    | .image alt ref => pure <| .image alt ref
    | .concat content => .concat <$> content.mapM inline
    | .other container content => do
      match ← Traverse.genreInline container content with
      | .none => .other container <$> content.mapM inline
      | .some i' => inline i'
    | .text .. | .linebreak .. | .code .. => pure i

  block (b : Doc.Block g) : m (Doc.Block g) := do
    Traverse.block b
    match b with
    | .para contents => .para <$> contents.mapM inline
    | .ul items => .ul <$> items.mapM fun
      | ListItem.mk n contents => ListItem.mk n <$> contents.mapM block
    | .ol start items => .ol start <$> items.mapM fun
      | ListItem.mk n contents => ListItem.mk n <$> contents.mapM block
    | .dl items => .dl <$> items.mapM fun
      | DescItem.mk t d => DescItem.mk <$> t.mapM inline <*> d.mapM block
    | .blockquote items => .blockquote <$> items.mapM block
    | .concat items => .concat <$> items.mapM block
    | .other container content =>
      match ← Traverse.genreBlock container content with
      | .none => .other container <$> content.mapM block
      | .some b' => block b'
    | .code .. => pure b

  part (p : Doc.Part g) : m (Doc.Part g) := do
    let mut p := p
    if let some md := p.metadata then
      if let some p' ← Traverse.genrePart md p then
        p := p'
    let .mk title titleString meta content subParts := p
    pure <| .mk (← title.mapM inline) titleString meta (← content.mapM block) (← subParts.mapM part)

  doc (d : Doc g) : m (Doc g) := do
    pure <| .mk (← part d.content) d.linkRefs (← d.footnotes.foldM (fun fs k v => do pure <| fs.insert k (← v.mapM inline)) .empty)
