{-# LANGUAGE TupleSections #-}
module Kit.Project (
  totalSpecDependencies,
  unpackKit,
  generateXcodeProject
  )
    where

import Kit.Spec
import Kit.Contents
import Kit.Repository
import Kit.Util
import Kit.Util.FSAction
import Kit.Xcode.Builder
import Kit.Xcode.XCConfig

import Control.Monad.Error
import Data.Maybe
import Data.List
import Data.Tree
import System.Cmd
import System.Posix.Files

-- Paths

kitDir, projectDir, prefixFile, projectFile, xcodeConfigFile, depsConfigFile, kitUpdateMakeFilePath :: FilePath

kitDir = "." </> "Kits"
projectDir = "KitDeps.xcodeproj"
prefixFile = "Prefix.pch"
projectFile = projectDir </> "project.pbxproj"
xcodeConfigFile = "Kit.xcconfig"
depsConfigFile = "DepsOnly.xcconfig"
kitUpdateMakeFilePath = "Makefile"

kitUpdateMakeFile :: String
kitUpdateMakeFile = "kit: Kit.xcconfig\n" ++
                    "Kit.xcconfig: ../KitSpec\n" ++
                    "\tcd .. && kit update && exit 1\n"

prefixDefault :: String
prefixDefault = "#ifdef __OBJC__\n" ++ 
                "    #import <Foundation/Foundation.h>\n" ++ 
                "    #import <UIKit/UIKit.h>\n" ++ 
                "#endif\n"

generateXcodeProject :: [KitSpec] -> Maybe String -> KitIO ()
generateXcodeProject specs depsOnlyConfig = do
  liftIO $ inDirectory kitDir $ do
    kitsContents <- mapM readKitContents specs
    runAction $ createProjectFile kitsContents
    runAction $ createHeader kitsContents
    runAction $ createConfig kitsContents
    runAction $ FileCreate kitUpdateMakeFilePath kitUpdateMakeFile
    runAction $ FileCreate depsConfigFile $ "#include \"" ++ xcodeConfigFile ++ "\"\n" ++ fromMaybe "" depsOnlyConfig 
    symlinkAll specs
  where createProjectFile cs = do
          let headers = concatMap contentHeaders cs
          let sources = concatMap contentSources cs
          let libs = concatMap contentLibs cs
          FileCreate projectFile $ renderXcodeProject headers sources libs "libKitDeps.a"
        createHeader cs = do
          let headers = mapMaybe namedPrefix cs
          let combinedHeader = stringJoin "\n" headers
          FileCreate prefixFile $ prefixDefault ++ combinedHeader ++ "\n"
        createConfig cs = do
          let sourceDirs = map (\spec -> packageFileName spec </> specSourceDirectory spec) specs >>= (\s -> [s, kitDir </> s])
          let configs = mapMaybe contentConfig cs
          let combinedConfig = multiConfig "KitConfig" configs
          let kitHeaders = "HEADER_SEARCH_PATHS = $(HEADER_SEARCH_PATHS) " ++ stringJoin " " sourceDirs
          let prefixHeaders = "GCC_PRECOMPILE_PREFIX_HEADER = YES\nGCC_PREFIX_HEADER = $(SRCROOT)/Prefix.pch\n"
          FileCreate xcodeConfigFile $ kitHeaders ++ "\n" ++  prefixHeaders ++ "\n" ++ configToString combinedConfig ++ "\n"

symlinkAll :: [KitSpec] -> IO ()
symlinkAll specs = do
  mkdirP "Resources"
  mapM_ symlinkResources specs

symlinkResources :: KitSpec -> IO ()
symlinkResources spec = do 
  let resourcesDir = packageFileName spec </> specResourcesDirectory spec
  let linkName = "Resources" </> packageName spec
  when' (fileExist linkName) $ removeLink linkName
  when' (doesDirectoryExist resourcesDir) $ do
    puts $ "-> Linking resources in " ++ resourcesDir
    -- symbolic link target paths are relative to the the link
    createSymbolicLink (".." </> resourcesDir) linkName

-- | Return all the (unique) children of this tree (except the top node), in reverse depth order.
refineDeps :: Eq a => Tree a -> [a]
refineDeps = nub . concat . reverse . drop 1 . levels

-- todo: check for conflicts
-- todo: check for version ranges :)
totalSpecDependencies :: KitRepository -> KitSpec -> KitIO [KitSpec]
totalSpecDependencies kr spec = refineDeps <$> unfoldTreeM (unfoldDeps kr) spec

unfoldDeps :: KitRepository -> KitSpec -> KitIO (KitSpec, [KitSpec])
unfoldDeps kr ks = (ks,) <$> mapM (readKitSpec kr) (specDependencies ks) -- s/mapM/traverse ?

unpackKit :: KitRepository -> Kit -> IO ()
unpackKit kr kit = do
    tmpDir <- getTemporaryDirectory
    let fp = tmpDir </> (packageFileName kit ++ ".tar.gz")
    putStrLn $ " -> Installing " ++ packageFileName kit
    copyKitPackage kr kit fp
    mkdirP kitDir 
    inDirectory kitDir $ system ("tar zxf " ++ fp)
    return ()

