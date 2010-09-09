module Kit.Project (
  getMyDeps,
  installKit,
  generateXCodeProject,
  myKitSpec)
    where

  import Control.Monad.Trans
  import Control.Monad
  import Control.Applicative
  import qualified Data.Foldable as F
  import Data.Maybe
  import Data.List
  import Data.Tree
  import Data.Monoid
  import System.Cmd
  import Kit.Model
  import Kit.Repository
  import Kit.Util
  import Kit.XCode.Builder
  import Kit.XCode.XCConfig
  import Text.JSON
  import qualified Data.Traversable as T

  -- Paths
  kitDir = "." </> "Kits"
  projectDir = "KitDeps.xcodeproj"
  prefixFile = "KitDeps_Prefix.pch"
  projectFile = projectDir </> "project.pbxproj"
  xcodeConfigFile = "Kit.xcconfig"

  prefixDefault = "#ifdef __OBJC__\n" ++ "    #import <Foundation/Foundation.h>\n    #import <UIKit/UIKit.h>\n" ++ "#endif\n"

  -- Represents an extracted project
  -- Headers, Sources, Config, Prefix content
  data KitContents = KitContents { contentHeaders :: [String], contentSources :: [String], contentConfig :: Maybe XCConfig, contentPrefix :: Maybe String }

  readKitContents :: Kit -> IO KitContents
  readKitContents kit  =
    let kitDir = kitFileName kit
        find tpe = glob ((kitDir </> "src/**/*") ++ tpe)
        headers = find ".h"
        sources = fmap join $ T.sequence [find ".m", find ".mm", find ".c"]
        config = readConfig kit
        prefix = readHeader kit
    in  KitContents <$> headers <*> sources <*> config <*> prefix

  generateXCodeProject :: [Kit] -> IO ()
  generateXCodeProject deps = do
    mkdir_p kitDir
    inDirectory kitDir $ do
      kitsContents <- T.for deps readKitContents
      createProjectFile kitsContents
      createHeader kitsContents
      createConfig kitsContents
    where kitFileNames = deps |> kitFileName
          createProjectFile cs = do
            let headers = cs >>= contentHeaders
            let sources = cs >>= contentSources
            mkdir_p projectDir
            writeFile projectFile $ buildXCodeProject headers sources
          createHeader cs = do
            let headers = catMaybes $ cs |> contentPrefix
            let combinedHeader = stringJoin "\n" headers
            writeFile prefixFile $ prefixDefault ++ combinedHeader ++ "\n"
          createConfig cs = do
            let configs = catMaybes $ cs |> contentConfig
            let combinedConfig = multiConfig "KitConfig" configs
            let kitHeaders = "HEADER_SEARCH_PATHS = $(HEADER_SEARCH_PATHS) " ++ (stringJoin " "  $ kitFileNames >>= (\x -> [kitDir </> x </> "src", x </> "src"])) ++ "\n" ++ "GCC_PRECOMPILE_PREFIX_HEADER = YES\nGCC_PREFIX_HEADER = $(SRCROOT)/KitDeps_Prefix.pch\n"
            writeFile xcodeConfigFile $ kitHeaders ++ "\n" ++ configToString combinedConfig

  kitPrefixFile = "Prefix.pch"

  readHeader :: Kit -> IO (Maybe String)
  readHeader kit = do
    let fp = kitFileName kit </> kitPrefixFile
    exists <- doesFileExist fp
    contents <- T.sequence (fmap readFile $ justTrue exists fp)
    return contents

  readConfig :: Kit -> IO (Maybe XCConfig)
  readConfig kit = do
    let fp = kitConfigFile kit
    exists <- doesFileExist fp
    contents <- T.sequence (fmap readFile $ justTrue exists fp)
    return $ fmap (fileContentsToXCC $ kitName kit) contents

  refineDeps :: Tree Kit -> [Kit]
  refineDeps = nub . concat . reverse . drop 1 . levels

  depsForSpec' :: KitRepository -> KitSpec -> KitIO [Kit]
  depsForSpec' kr spec = do
      tree <- unfoldTreeM (unfoldDeps kr) spec
      -- todo: check for conflicts
      return $ refineDeps tree

  unfoldDeps :: KitRepository -> KitSpec -> KitIO (Kit, [KitSpec])
  unfoldDeps kr ks = do
      let kit = specKit ks
      let depKits = specDependencies ks
      specs <- mapM (getKitSpec kr) depKits
      return (kit, specs)

  getMyDeps :: KitRepository -> KitIO [Kit]
  getMyDeps kr = myKitSpec >>= depsForSpec' kr

  installKit :: KitRepository -> Kit -> IO ()
  installKit kr kit = do
      tmpDir <- getTemporaryDirectory
      let fp = tmpDir </> (kitFileName kit ++ ".tar.gz")
      putStrLn $ " -> Installing " ++ kitFileName kit
      fmap fromJust $ getKit kr kit fp
      let dest = kitDir
      mkdir_p dest
      inDirectory dest $ sh ("tar zxf " ++ fp)
      return ()
    where sh = system

  readSpec :: FilePath -> KitIO KitSpec
  readSpec kitSpecPath = readSpecContents kitSpecPath >>= KitIO . return . parses

  myKitSpec :: KitIO KitSpec
  myKitSpec = readSpec "KitSpec"

  -- private!
  checkExists :: FilePath -> KitIO FilePath
  checkExists kitSpecPath = do
    doesExist <- liftIO $ doesFileExist kitSpecPath
    maybeToKitIO ("Couldn't find the spec at " ++ kitSpecPath) (justTrue doesExist kitSpecPath)

  readSpecContents :: FilePath -> KitIO String
  readSpecContents kitSpecPath = checkExists kitSpecPath >>= liftIO . readFile

  parses :: String -> Either [KitError] KitSpec
  parses contents = case (decode contents) of
                      Ok a -> Right a
                      Error a -> Left [a]

