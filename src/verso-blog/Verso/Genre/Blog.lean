import SubVerso.Highlighting
import SubVerso.Examples

import Verso.Genre.Blog.Basic
import Verso.Genre.Blog.Generate
import Verso.Genre.Blog.Site
import Verso.Genre.Blog.Site.Syntax
import Verso.Genre.Blog.Template
import Verso.Genre.Blog.Theme
import Verso.Doc.ArgParse
import Verso.Doc.Lsp
import Verso.Doc.Suggestion
import Verso.Hover
open Verso.Output Html
open Lean (RBMap)

namespace Verso.Genre.Blog

open Lean Elab
open Verso ArgParse Doc Elab

open SubVerso.Examples (loadExamples Example)


def classArgs : ArgParse DocElabM String := .named `«class» .string false

@[role_expander htmlSpan]
def htmlSpan : RoleExpander
  | args, stxs => do
    let classes ← classArgs.run args
    let contents ← stxs.mapM elabInline
    let val ← ``(Inline.other (Blog.InlineExt.htmlSpan $(quote classes)) #[$contents,*])
    pure #[val]

@[directive_expander htmlDiv]
def htmlDiv : DirectiveExpander
  | args, stxs => do
    let classes ← classArgs.run args
    let contents ← stxs.mapM elabBlock
    let val ← ``(Block.other (Blog.BlockExt.htmlDiv $(quote classes)) #[ $contents,* ])
    pure #[val]

@[directive_expander blob]
def blob : DirectiveExpander
  | #[.anon (.name blobName)], stxs => do
    if h : stxs.size > 0 then logErrorAt stxs[0] "Expected no contents"
    let actualName ← resolveGlobalConstNoOverloadWithInfo blobName
    let val ← ``(Block.other (Blog.BlockExt.blob ($(mkIdentFrom blobName actualName) : Html)) #[])
    pure #[val]
  | _, _ => throwUnsupportedSyntax

@[role_expander blob]
def inlineBlob : RoleExpander
  | #[.anon (.name blobName)], stxs => do
    if h : stxs.size > 0 then logErrorAt stxs[0] "Expected no contents"
    let actualName ← resolveGlobalConstNoOverloadWithInfo blobName
    let val ← ``(Inline.other (Blog.InlineExt.blob ($(mkIdentFrom blobName actualName) : Html)) #[])
    pure #[val]
  | _, _ => throwUnsupportedSyntax

@[role_expander label]
def label : RoleExpander
  | #[.anon (.name l)], stxs => do
    let args ← stxs.mapM elabInline
    let val ← ``(Inline.other (Blog.InlineExt.label $(quote l.getId)) #[ $[ $args ],* ])
    pure #[val]
  | _, _ => throwUnsupportedSyntax

@[role_expander ref]
def ref : RoleExpander
  | #[.anon (.name l)], stxs => do
    let args ← stxs.mapM elabInline
    let val ← ``(Inline.other (Blog.InlineExt.ref $(quote l.getId)) #[ $[ $args ],* ])
    pure #[val]
  | _, _ => throwUnsupportedSyntax


@[role_expander page_link]
def page_link : RoleExpander
  | #[.anon (.name page)], stxs => do
    let args ← stxs.mapM elabInline
    let pageName := mkIdentFrom page <| docName page.getId
    let val ← ``(Inline.other (Blog.InlineExt.pageref $(quote pageName.getId)) #[ $[ $args ],* ])
    pure #[val]
  | _, _ => throwUnsupportedSyntax

inductive LeanExampleData where
  | inline (commandState : Command.State) (parserState : Parser.ModuleParserState)
  | subproject (loaded : NameMap Example)
deriving Inhabited

structure ExampleContext where
  contexts : NameMap LeanExampleData := {}
deriving Inhabited

initialize exampleContextExt : EnvExtension ExampleContext ← registerEnvExtension (pure {})

structure ExampleMessages where
  messages : NameMap (MessageLog ⊕ List (MessageSeverity × String)) := {}
deriving Inhabited

initialize messageContextExt : EnvExtension ExampleMessages ← registerEnvExtension (pure {})

-- FIXME this is a horrid kludge - find a way to systematically rewrite srclocs?
def parserInputString [Monad m] [MonadFileMap m] (str : TSyntax `str) : m String := do
  let preString := (← getFileMap).source.extract 0 (str.raw.getPos?.getD 0)
  let mut code := ""
  let mut iter := preString.iter
  while !iter.atEnd do
    if iter.curr == '\n' then code := code.push '\n'
    else
      for _ in [0:iter.curr.utf8Size.toNat] do
        code := code.push ' '
    iter := iter.next
  code := code ++ str.getString
  return code

open System in
@[block_role_expander leanExampleProject]
def leanExampleProject : BlockRoleExpander
  | #[.anon (.name name), .anon (.str projectDir)], #[] => do
    if exampleContextExt.getState (← getEnv) |>.contexts |>.contains name.getId then
      throwError "Example context '{name}' already defined in this module"
    let path : FilePath := ⟨projectDir.getString⟩
    if path.isAbsolute then
      throwError "Expected a relative path, got {path}"
    let loadedExamples ← loadExamples path
    let mut savedExamples := {}
    for (mod, modExamples) in loadedExamples.toList do
      for (exName, ex) in modExamples.toList do
        savedExamples := savedExamples.insert (mod ++ exName) ex
    modifyEnv fun env => exampleContextExt.modifyState env fun s => {s with
      contexts := s.contexts.insert name.getId (.subproject savedExamples)
    }
    for (name, ex) in savedExamples.toList do
      modifyEnv fun env => messageContextExt.modifyState env fun s => {s with messages := s.messages.insert name (.inr ex.messages) }
    Verso.Hover.addCustomHover (← getRef) <| "Contains:\n" ++ String.join (savedExamples.toList.map (s!" * `{toString ·.fst}`\n"))
    pure #[]
  | _, more =>
    if h : more.size > 0 then
      throwErrorAt more[0] "Unexpected contents"
    else
      throwError "Unexpected arguments"
where
  getModExamples (mod : Name) (json : Json) : DocElabM (NameMap Example) := do
    let .ok exs := json.getObj?
      | throwError "Not an object: '{json}'"
    let mut found := {}
    for ⟨name, exJson⟩ in exs.toArray do
      match FromJson.fromJson? exJson with
      | .error err =>
        throwError "Error deserializing example '{name}' in '{mod}': {err}\nfrom:\n{json}"
      | .ok ex => found := found.insert (mod ++ name.toName) ex
    pure found

private def getSubproject (project : Ident) : TermElabM (NameMap Example) := do
  let some ctxt := exampleContextExt.getState (← getEnv) |>.contexts |>.find? project.getId
    | throwErrorAt project "Subproject '{project}' not loaded"
  let .subproject projectExamples := ctxt
    | throwErrorAt project "'{project}' is not loaded as a subproject"
  Verso.Hover.addCustomHover project <| "Contains:\n" ++ String.join (projectExamples.toList.map (s!" * `{toString ·.fst}`\n"))
  pure projectExamples

@[block_role_expander leanCommand]
def leanCommand : BlockRoleExpander
  | #[.anon (.name project), .anon (.name exampleName)], #[] => do
    let projectExamples ← getSubproject project
    let some {highlighted := hls, original := str, ..} := projectExamples.find? exampleName.getId
      | throwErrorAt exampleName "Example '{exampleName}' not found - options are {projectExamples.toList.map (·.fst)}"
    Verso.Hover.addCustomHover exampleName s!"```lean\n{str}\n```"
    pure #[← ``(Block.other (Blog.BlockExt.highlightedCode $(quote project.getId) (SubVerso.Highlighting.Highlighted.seq $(quote hls))) #[Block.code none #[] 0 $(quote str)])]
  | _, more =>
    if h : more.size > 0 then
      throwErrorAt more[0] "Unexpected contents"
    else
      throwError "Unexpected arguments"

@[role_expander leanTerm]
def leanTerm : RoleExpander
  | #[.anon (.name project)], #[arg] => do
    let `(inline|code{ $name:str }) := arg
      | throwErrorAt arg "Expected code literal with the example name"
    let exampleName := name.getString.toName
    let projectExamples ← getSubproject project
    let some {highlighted := hls, original := str, ..} := projectExamples.find? exampleName
      | throwErrorAt name "Example '{exampleName}' not found - options are {projectExamples.toList.map (·.fst)}"
    Verso.Hover.addCustomHover arg s!"```lean\n{str}\n```"
    pure #[← ``(Inline.other (Blog.InlineExt.highlightedCode $(quote project.getId) (SubVerso.Highlighting.Highlighted.seq $(quote hls))) #[Inline.code $(quote str)])]
  | _, more =>
    if h : more.size > 0 then
      throwErrorAt more[0] "Unexpected contents"
    else
      throwError "Unexpected arguments"


structure LeanBlockConfig where
  exampleContext : Ident
  «show» : Option Bool := none
  keep : Option Bool := none
  name : Option Name := none
  error : Option Bool := none

def LeanBlockConfig.parse [Monad m] [MonadInfoTree m] [MonadResolveName m] [MonadEnv m] [MonadError m] : ArgParse m LeanBlockConfig :=
  LeanBlockConfig.mk <$> .positional `exampleContext .ident <*> .named `show .bool true <*> .named `keep .bool true <*> .named `name .name true <*> .named `error .bool true

@[code_block_expander leanInit]
def leanInit : CodeBlockExpander
  | args , str => do
    let config ← LeanBlockConfig.parse.run args
    let context := Parser.mkInputContext (← parserInputString str) (← getFileName)
    let (header, state, msgs) ← Parser.parseHeader context
    for imp in header[1].getArgs do
      logErrorAt imp "Imports not yet supported here"
    let opts := Options.empty -- .setBool `trace.Elab.info true
    if header[0].isNone then -- if the "prelude" option was not set, use the current env
      let commandState := configureCommandState (←getEnv) {}
      modifyEnv <| fun env => exampleContextExt.modifyState env fun s => {s with contexts := s.contexts.insert config.exampleContext.getId (.inline commandState  state)}
    else
      if header[1].getArgs.isEmpty then
        let (env, msgs) ← processHeader header opts msgs context 0
        if msgs.hasErrors then
          for msg in msgs.toList do
            logMessage msg
          liftM (m := IO) (throw <| IO.userError "Errors during import; aborting")
        let commandState := configureCommandState env {}
        modifyEnv <| fun env => exampleContextExt.modifyState env fun s => {s with contexts := s.contexts.insert config.exampleContext.getId (.inline commandState state)}
    if config.show.getD false then
      pure #[← ``(Block.code none #[] 0 $(quote str.getString))] -- TODO highlighting hack
    else pure #[]
where
  configureCommandState (env : Environment) (msg : MessageLog) : Command.State :=
    { Command.mkState env msg with infoState := { enabled := true } }

open SubVerso.Highlighting Highlighted in
@[code_block_expander lean]
def lean : CodeBlockExpander
  | args, str => do
    let config ← LeanBlockConfig.parse.run args
    let x := config.exampleContext
    let some (.inline commandState state) := exampleContextExt.getState (← getEnv) |>.contexts.find? x.getId
      | throwErrorAt x "Can't find example context"
    let context := Parser.mkInputContext (← parserInputString str) (← getFileName)
    -- Process with empty messages to avoid duplicate output
    let s ← IO.processCommands context state { commandState with messages.msgs := {} }
    for t in s.commandState.infoState.trees do
      pushInfoTree t

    match config.error with
    | none =>
      for msg in s.commandState.messages.msgs do
        logMessage msg
    | some true =>
      if s.commandState.messages.hasErrors then
        for msg in s.commandState.messages.errorsToWarnings.msgs do
          logMessage msg
      else
        throwErrorAt str "Error expected in code block, but none occurred"
    | some false =>
      for msg in s.commandState.messages.msgs do
        logMessage msg
      if s.commandState.messages.hasErrors then
        throwErrorAt str "No error expected in code block, one occurred"

    if config.keep.getD true && !(config.error.getD false) then
      modifyEnv fun env => exampleContextExt.modifyState env fun st => {st with
        contexts := st.contexts.insert x.getId (.inline {s.commandState with messages := {} } s.parserState)
      }
    if let some infoName := config.name then
      modifyEnv fun env => messageContextExt.modifyState env fun st => {st with
        messages := st.messages.insert infoName (.inl s.commandState.messages)
      }
    let mut hls := Highlighted.empty
    let infoSt ← getInfoState
    let env ← getEnv
    try
      setInfoState s.commandState.infoState
      setEnv s.commandState.env
      for cmd in s.commands do
        hls := hls ++ (← highlight cmd s.commandState.messages.msgs.toArray s.commandState.infoState.trees)
    finally
      setInfoState infoSt
      setEnv env
    if config.show.getD true then
      pure #[← ``(Block.other (Blog.BlockExt.highlightedCode $(quote x.getId) $(quote hls)) #[Block.code none #[] 0 $(quote str.getString)])]
    else
      pure #[]


structure LeanOutputConfig where
  name : Ident
  severity : Option MessageSeverity
  summarize : Bool

def LeanOutputConfig.parser [Monad m] [MonadInfoTree m] [MonadResolveName m] [MonadEnv m] [MonadError m] : ArgParse m LeanOutputConfig :=
  LeanOutputConfig.mk <$> .positional `name output <*> .named `severity sev true <*> ((·.getD false) <$> .named `summarize .bool true)
where
  output : ValDesc m Ident := {
    description := "output name",
    get := fun
      | .name x => pure x
      | other => throwError "Expected output name, got {repr other}"
  }
  opt {α} (p : ArgParse m α) : ArgParse m (Option α) := (some <$> p) <|> pure none
  optDef {α} (fallback : α) (p : ArgParse m α) : ArgParse m α := p <|> pure fallback
  sev : ValDesc m MessageSeverity := {
    description := open MessageSeverity in m!"The expected severity: '{``error}', '{``warning}', or '{``information}'",
    get := open MessageSeverity in fun
      | .name b => do
        let b' ← resolveGlobalConstNoOverloadWithInfo b
        if b' == ``MessageSeverity.error then pure MessageSeverity.error
        else if b' == ``MessageSeverity.warning then pure MessageSeverity.warning
        else if b' == ``MessageSeverity.information then pure MessageSeverity.information
        else throwErrorAt b "Expected '{``error}', '{``warning}', or '{``information}'"
      | other => throwError "Expected severity, got {repr other}"
  }

@[code_block_expander leanOutput]
def leanOutput : Doc.Elab.CodeBlockExpander
  | args, str => do
    --let config ← LeanOutputConfig.fromArgs args -- TODO actual parser for my args
    let config ← LeanOutputConfig.parser.run args

    let some savedInfo := messageContextExt.getState (← getEnv) |>.messages |>.find? config.name.getId
      | throwErrorAt str "No saved info for name '{config.name.getId}'"
    let messages ← match savedInfo with
      | .inl log =>
        let messages ← liftM <| log.msgs.toArray.mapM contents
        for m in log.msgs do
          if mostlyEqual str.getString (← contents m) then
            if let some s := config.severity then
              if s != m.severity then
                throwErrorAt str s!"Expected severity {sevStr s}, but got {sevStr m.severity}"
            let content ← if config.summarize then
                let lines := str.getString.splitOn "\n"
                let pre := lines.take 3
                let post := String.join (lines.drop 3 |>.intersperse "\n")
                let preHtml : Html := pre.map (fun (l : String) => {{<code>{{l}}</code>}})
                ``(Block.other (Blog.BlockExt.htmlDetails $(quote (sevStr m.severity)) $(quote preHtml)) #[Block.code none #[] 0 $(quote post)])
              else
                ``(Block.other (Blog.BlockExt.htmlDiv $(quote (sevStr m.severity))) #[Block.code none #[] 0 $(quote str.getString)])
            return #[content]
        pure messages
      | .inr msgs =>
        let messages := msgs.toArray.map Prod.snd
        for (sev, txt) in msgs do
          if mostlyEqual str.getString txt then
            if let some s := config.severity then
              if s != sev then
                throwErrorAt str s!"Expected severity {sevStr s}, but got {sevStr sev}"
            let content ← if config.summarize then
                let lines := str.getString.splitOn "\n"
                let pre := lines.take 3
                let post := String.join (lines.drop 3 |>.intersperse "\n")
                let preHtml : Html := pre.map (fun (l : String) => {{<code>{{l}}</code>}})
                ``(Block.other (Blog.BlockExt.htmlDetails $(quote (sevStr sev)) $(quote preHtml)) #[Block.code none #[] 0 $(quote post)])
              else
                ``(Block.other (Blog.BlockExt.htmlDiv $(quote (sevStr sev))) #[Block.code none #[] 0 $(quote str.getString)])
            return #[content]
        pure messages

    for m in messages do
      Verso.Doc.Suggestion.saveSuggestion str (m.take 30 ++ "…") m
    throwErrorAt str "Didn't match - expected one of: {indentD (toMessageData messages)}\nbut got:{indentD (toMessageData str.getString)}"
where
  withNewline (str : String) := if str == "" || str.back != '\n' then str ++ "\n" else str

  sevStr : MessageSeverity → String
    | .error => "error"
    | .information => "information"
    | .warning => "warning"

  contents (message : Message) : IO String := do
    let head := if message.caption != "" then message.caption ++ ":\n" else ""
    pure <| withNewline <| head ++ (← message.data.toString)

  mostlyEqual (s1 s2 : String) : Bool :=
    s1.trim == s2.trim

open Lean Elab Command in
elab "#defineLexerBlock" blockName:ident " ← " lexerName:ident : command => do
  let lexer ← resolveGlobalConstNoOverloadWithInfo lexerName
  elabCommand <| ← `(@[code_block_expander $blockName]
    def $blockName : Doc.Elab.CodeBlockExpander
      | #[], str => do
        let out ← Verso.Genre.Blog.LexedText.highlight $(mkIdentFrom lexerName lexer) str.getString
        return #[← ``(Block.other (Blog.BlockExt.lexedText $$(quote out)) #[])]
      | _, str => throwErrorAt str "Expected no arguments")


private def filterString (p : Char → Bool) (str : String) : String := Id.run <| do
  let mut out := ""
  for c in str.toList do
    if p c then out := out.push c
  pure out

def blogMain (theme : Theme) (site : Site) (relativizeUrls := true) (options : List String) : IO UInt32 := do
  let hasError ← IO.mkRef false
  let logError msg := do hasError.set true; IO.eprintln msg
  let cfg ← opts {logError := logError} options
  let (site, xref) ← site.traverse cfg
  let rw := if relativizeUrls then
      some <| relativize
    else none
  site.generate theme {site := site, ctxt := ⟨[], cfg⟩, xref := xref, dir := cfg.destination, config := cfg, rewriteHtml := rw}
  if (← hasError.get) then
    IO.eprintln "Errors were encountered!"
    return 1
  else
    return 0
where
  opts (cfg : Config)
    | ("--output"::dir::more) => opts {cfg with destination := dir} more
    | ("--drafts"::more) => opts {cfg with showDrafts := true} more
    | (other :: _) => throw (↑ s!"Unknown option {other}")
    | [] => pure cfg
  urlAttr (name : String) : Bool := name ∈ ["href", "src", "data", "poster"]
  rwAttr (attr : String × String) : ReaderT TraverseContext Id (String × String) := do
    if urlAttr attr.fst && "/".isPrefixOf attr.snd then
      let path := (← read).path
      pure { attr with
        snd := String.join (List.replicate path.length "../") ++ attr.snd.drop 1
      }
    else
      pure attr
  rwTag (tag : String) (attrs : Array (String × String)) (content : Html) : ReaderT TraverseContext Id (Option Html) := do
    pure <| some <| .tag tag (← attrs.mapM rwAttr) content
  relativize _err ctxt html :=
    pure <| html.visitM (m := ReaderT TraverseContext Id) (tag := rwTag) |>.run ctxt
