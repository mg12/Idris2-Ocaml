module Ocaml.Ocaml

import Idris.Driver
import Idris.Syntax

import Compiler.Common
import Compiler.CompileExpr

import Core.Context
import Core.Context.Log as Log
import Core.Directory

import Libraries.Utils.Path

import Data.List
import Data.String
import Libraries.Data.StringMap
import Data.SortedSet
import Libraries.Data.NameMap
import Data.Maybe
import Data.Vect

import System
import System.Directory
import System.File
import System.Info


import Ocaml.Expr
import Ocaml.Foreign
import Ocaml.Utils
import Ocaml.Modules
import Ocaml.CompileCommands


||| Generate OCaml code for a "definition" (function, constructor, foreign func, etc)
mlDef : Name ->
        NamedDef ->
        Core String
mlDef name (MkNmFun [] expr) = do
    let header = mlName name ++ " : Obj.t lazy_t = lazy ("
    code <- mlExpr expr
    pure $ header ++ code ++ ")\n\n"
    
mlDef name (MkNmFun args expr) = do

    let argDecls = showSep " " $ map (\n => "(" ++ mlName n ++ " : Obj.t)") args
        header = mlName name ++ " " ++ argDecls ++ " : Obj.t = "

    code <- mlExpr expr
    pure $ header ++ code ++ "\n\n"

mlDef name (MkNmCon _ _ _) = pure ""
mlDef name (MkNmForeign ccs [] retTy) = do
    let header = mlName name ++ " () : Obj.t = "
    let callArgs = ["(Obj.magic ())"]
    let fun = foreignFun name ccs [] retTy
    let call = fun ++ " " ++ showSep " " callArgs
    
    pure $ header ++ "(Obj.magic (" ++ call ++ "))\n\n"
    
mlDef name (MkNmForeign ccs argTys retTy) = do

    let args = flap ([1..(length argTys)] `zip` argTys) \(i, t) =>
            let isWorld = case t of
                            CFWorld => True
                            _ => False
            in ("arg_" ++ show i, isWorld)
    
    let nonWorldArgs' = filter (\(_, isWorld) => not isWorld) args
    let nonWorldArgs = if isNil nonWorldArgs' then [("()", False)] else nonWorldArgs'
    
    let argDecls = showSep " " $ map (\(n,_) => "(" ++ n ++ " : Obj.t)") args
    let header = mlName name ++ " " ++ argDecls ++ " : Obj.t = "
    
    let callArgs = flap nonWorldArgs \(n,_) => "(Obj.magic " ++ n ++ ")"
    let fun = foreignFun name ccs argTys retTy
    let call = fun ++ " " ++ showSep " " callArgs
    
    pure $ header ++ "(Obj.magic (" ++ call ++ "))\n\n"

mlDef name (MkNmError msg) = do
    let header = mlName name ++ " () : Obj.t = "
    body <- mlExpr msg
    pure $ header ++ body ++ "\n\n"

writeModule : (path : String) -> (mod : Ocaml.Modules.Module) -> Core ()
writeModule path mod = do
    
    Right mlFile <- coreLift $ openFile path WriteTruncate
        | Left err => throw (FileErr path err)
        
    let append = \strData => Core.Core.do
            Right () <- coreLift $ fPutStr mlFile strData
                | Left err => throw (FileErr path err)
            coreLift $ fflush mlFile

    let imports = concatMap (++";;\n") $ map ("open "++) (SortedSet.toList mod.deps)
    
    append $ "open OcamlRts;;\n\n" ++
            imports ++ "\nlet rec "
    
    first <- coreLift $ newIORef True
    defsWritten <- coreLift $ newIORef (the Int 0)
    Ocaml.Utils.for_ mod.defs \(n, d) => do
        def <- mlDef n d
        if def == ""
            then pure ()
            else do
                isFirst <- coreLift $ readIORef first
                if isFirst
                    then coreLift $ writeIORef first False
                    else append "and "
                append def
                coreLift $ modifyIORef defsWritten (+1)
    
    append ";;"

    coreLift $ closeFile mlFile
    
    if !(coreLift $ readIORef defsWritten) == 0
        then do
            _ <- coreLift $ writeFile path ""
            pure ()
        else pure ()

    pure ()


||| OCaml implementation of the `compileExpr` interface.
compileExpr : CompilerCommands c => (comp : c) ->
              Ref Ctxt Defs ->
              Ref Syn SyntaxInfo ->
              (tmpDir : String) ->
              (outputDir : String) ->
              ClosedTerm ->
              (outfile : String) ->
              Core (Maybe String)
compileExpr comp c s tmpDir outputDir tm outfile = do
    let appDirRel = outfile ++ "_app" -- relative to build dir
    let appDirGen = outputDir </> appDirRel -- relative to here
    Right () <- coreLift $ mkdirAll appDirGen
        | Left err => throw (InternalError ("Can't mkdir" ++ appDirGen))
    Just cwd <- coreLift currentDir
        | Nothing => throw (InternalError "Can't get current directory")

    let ext = if isWindows then ".exe" else ""
    let outFile = cwd </> outputDir </> outfile <.> ext
    
    let modRelFileName = \ns,ext => appDirRel </> ns <.> ext
    let modAbsFileName = \ns,ext => cwd </> outputDir </> modRelFileName ns ext
    
    cData <- getCompileData False Cases tm
    let ndefs = flap (namedDefs cData) \(name, _, def) => (name, def)
    let mainExpr = forget (mainExpr cData)

    ctxtDefs <- get Ctxt
    let context = gamma ctxtDefs

    let mods = modules ndefs

    modules <- Ocaml.Utils.for (moduleDefs mods) $ \mod => do
        let modName = mod.name
        let path = modAbsFileName modName "ml"
        writeModule path mod
        pure modName

    -- deal with Main function
    do
        -- main takes ALL modules as dependencies
        let mainImports = flap (StringMap.keys mods.defsByNamespace) $ \n =>
                fromMaybe n $ StringMap.lookup n mods.namespaceMapping
                
        let mainFnName = UN (Basic "main")
        let mainDefs = [(mainFnName, MkNmFun [] mainExpr)]
        let mainMLPath = modAbsFileName "Main" "ml"
        let mainModule = MkModule "Main" mainDefs (SortedSet.fromList mainImports)
        
        writeModule mainMLPath mainModule
        
        -- still needs the actual call to the main function Main.main
        let mainCallSrc = "\n\nLazy.force (" ++ mlName mainFnName ++ ");;\n\n"
        
        Right mainMLFile <- coreLift $ openFile mainMLPath Append
            | Left err => throw (FileErr mainMLPath err)
            
        Right () <- coreLift $ fPutStr mainMLFile mainCallSrc
            | Left err => throw (FileErr mainMLPath err)
            
        coreLift $ closeFile mainMLFile

    -- TMP HACK
    -- .a and .h files
    _ <- coreLift $ system $ unwords
        ["cp", "~/.idris2/idris2-0.6.0/lib/*", appDirGen]

    _ <- coreLift $ system $ "cp ~/.idris2/idris2-0.6.0/support/ocaml/ocaml_rts.o " ++ appDirGen
    _ <- coreLift $ system $ "cp ~/.idris2/idris2-0.6.0/support/ocaml/OcamlRts.ml " ++ appDirGen

    let cmdBuildRts = compileRTSCmd comp "OcamlRts"
        cmdBuildMods = concat $ [compileModuleCmd comp ns | ns <- modules]
                                ++ [compileModuleCmd comp "Main"]
        cmdLink = linkCmd comp
                    (modules ++ ["Main"])
                    ["ocaml_rts.o", "libidris2_support.a"]
                    "OcamlRts"
                    outFile
        
        cmdFull = cmdBuildRts ++ cmdBuildMods ++ cmdLink

    Ocaml.Utils.for_ cmdFull $ \cmd => do
        let cmd' = "cd " ++ appDirGen ++ " && " ++ cmd
        ok <- the (Core Int) . coreLift $ system cmd'
        --Log.log "codegen.ocaml.build" 2 $ ("Running command `" ++ cmd ++ "`")
        if ok /= 0
            then throw . InternalError $ "Command `" ++ cmd ++ "` failed."
            else pure ()

    pure (Just outFile)

||| OCaml implementation of the `executeExpr` interface.
executeExpr : CompilerCommands c => (comp : c) ->
              Ref Ctxt Defs ->
              Ref Syn SyntaxInfo ->
              (tmpDir : String) ->
              ClosedTerm ->
              Core ()
executeExpr comp c s tmpDir tm = do
    Just bin <- compileExpr comp c s tmpDir tmpDir tm "tmpocaml"
        | Nothing => throw (InternalError "compileExpr returned Nothing")
    _ <- coreLift $ system bin
    pure ()

export
codegenOcaml : CompilerCommands c => (comp : c) -> Codegen
codegenOcaml comp = MkCG (compileExpr comp) (executeExpr comp) Nothing Nothing

main : IO ()
main =
    mainWithCodegens [
            ("ocaml-native", codegenOcaml $ nativeCompiler Nothing False),
            ("ocaml-native-debug", codegenOcaml $ nativeCompiler Nothing True),
            ("ocaml-bytecode", codegenOcaml $ bytecodeCompiler Nothing False),
            ("ocaml-bytecode-debug", codegenOcaml $ bytecodeCompiler Nothing True)
        ]
