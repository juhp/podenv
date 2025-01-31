{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | This module contains the podenv CLI entrypoint
-- The workflow is: Main -> Config -> Build -> Application -> Context
--
-- * Main: select the app and override with command line arguments
-- * Config: load the configuration and select the application
-- * Build: optional application build
-- * App: convert application and capability into a Context
-- * Runtime: execute with podman or kubernetes
module Podenv.Main
  ( main,

    -- * exports for tests
    usage,
    cliConfigLoad,
    cliInfo,
    cliPrepare,
    CLI (..),
  )
where

import Data.Version (showVersion)
import Options.Applicative hiding (command)
import Paths_podenv (version)
import qualified Podenv.Application
import Podenv.Build (BuildEnv (beInfos, beName, beUpdate))
import qualified Podenv.Build
import qualified Podenv.Config
import Podenv.Dhall
import Podenv.Prelude
import Podenv.Runtime (Context, Name (..), RuntimeEnv (..))
import qualified Podenv.Runtime
import qualified Podenv.Version (version)

-- | podenv entrypoint
main :: IO ()
main = do
  cli@CLI {..} <- usage =<< getArgs
  when showDhallEnv (putTextLn Podenv.Config.podenvImportTxt >> exitSuccess)
  when listCaps (printCaps >> exitSuccess)
  when listApps (printApps configExpr >> exitSuccess)

  (cliApp, mode, ctxName, be, re) <- cliConfigLoad cli
  (ready, app) <- Podenv.Build.prepare be cliApp
  ctx <- Podenv.Application.prepare app mode ctxName

  if showApplication
    then putTextLn $ showApp app ctx be re
    else do
      unless ready $ Podenv.Build.execute be
      when update $ beUpdate (fromMaybe (error "Need build env") be)
      Podenv.Runtime.execute re ctx

usage :: [String] -> IO CLI
usage args = do
  cli <- handleParseResult $ execParserPure defaultPrefs cliInfo cliArgs
  pure $ cli {extraArgs = map toText appArgs}
  where
    cliArgs = takeCliArgs [] args
    appArgs = case drop (length cliArgs) args of
      -- Drop any `--` prefix
      ("--" : rest) -> rest
      xs -> xs

    -- Collect args until the selector, the rest should not be passed to optparse-applicative
    isPodenvArg arg
      | arg `elem` strOptions || "--bash-completion-" `isPrefixOf` arg = True
      | otherwise = False
    takeCliArgs acc args' = case args' of
      [] -> reverse acc
      -- Handle toggle such as `"--name" : "app-name" : _`
      (toggle : x : xs) | isPodenvArg toggle -> takeCliArgs (x : toggle : acc) xs
      (x : xs)
        -- `--` is a hard separator, stop now.
        | "--" == x -> takeCliArgs acc []
        -- this is switch, keep on taking
        | "--" `isPrefixOf` x -> takeCliArgs (x : acc) xs
        -- otherwise the selector is found, stop now
        | otherwise -> takeCliArgs (x : acc) []

data CLI = CLI
  { -- action modes:
    listApps :: Bool,
    listCaps :: Bool,
    showDhallEnv :: Bool,
    showApplication :: Bool,
    configExpr :: Maybe Text,
    -- runtime env:
    update :: Bool,
    verbose :: Bool,
    -- app modifiers:
    capsOverride :: [Capabilities -> Capabilities],
    shell :: Bool,
    namespace :: Maybe Text,
    -- TODO: add namespaced :: Bool (when set, namespace is the app name head)
    name :: Maybe Text,
    cliEnv :: [Text],
    volumes :: [Text],
    selector :: Maybe Text,
    extraArgs :: [Text]
  }

-- WARNING: when adding strOption, update the 'strOptions' list
cliParser :: Parser CLI
cliParser =
  CLI
    -- action modes:
    <$> switch (long "list" <> help "List available applications")
    <*> switch (long "list-caps" <> help "List available capabilities")
    <*> switch (long "dhall-env" <> hidden)
    <*> switch (long "show" <> help "Show the environment without running it")
    <*> optional (strOption (long "config" <> help "A config expression"))
    -- runtime env:
    <*> switch (long "update" <> help "Update the runtime")
    <*> switch (long "verbose" <> help "Increase verbosity")
    -- app modifiers:
    <*> capsParser
    <*> switch (long "shell" <> help "Start a shell instead of the application command")
    <*> optional (strOption (long "namespace" <> help "Share a network ns"))
    <*> optional (strOption (long "name" <> metavar "NAME" <> help "Container name"))
    <*> many (strOption (long "env" <> metavar "ENV" <> help "Extra env 'KEY=VALUE'"))
    <*> many (strOption (long "volume" <> short 'v' <> metavar "VOLUME" <> help "Extra volumes 'volume|hostPath[:containerPath]'"))
    <*> optional (strArgument (metavar "APP" <> help "Application config name or image:name or nix:expr"))
    <*> many (strArgument (metavar "ARGS" <> help "Application args"))

-- | List of strOption that accept an argument (that is not the selector)
strOptions :: [String]
strOptions = ["--namespace", "--name", "--env", "--volume", "-v"]

-- | Parse all capabilities toggles
capsParser :: Parser [Capabilities -> Capabilities]
capsParser = catMaybes <$> traverse mkCapParser Podenv.Application.capsAll
  where
    mkCapParser :: Podenv.Application.Cap -> Parser (Maybe (Capabilities -> Capabilities))
    mkCapParser cap =
      toggleCapParser cap True <|> toggleCapParser cap False

-- | A helper function to parse CLI capability toggle
toggleCapParser :: Podenv.Application.Cap -> Bool -> Parser (Maybe (Capabilities -> Capabilities))
toggleCapParser Podenv.Application.Cap {..} isOn = setMaybeCap <$> flagParser
  where
    -- We parse a dummy flag from the command line
    flagParser :: Parser (Maybe ())
    flagParser = optional (flag' () (long flagName <> hidden))
    flagName = toString $ (if isOn then "" else "no-") <> capName

    -- That will be replaced by the setCap when Just ()
    setMaybeCap :: Maybe () -> Maybe (Capabilities -> Capabilities)
    setMaybeCap = fmap (const setCap)
    setCap :: Capabilities -> Capabilities
    setCap = capLens .~ isOn

cliInfo :: ParserInfo CLI
cliInfo =
  info
    (versionOption <*> cliParser <**> helper)
    (fullDesc <> header "podenv - a podman wrapper")
  where
    versionOption =
      infoOption
        (concat [showVersion version, " ", Podenv.Version.version])
        (long "version" <> help "Show version")

-- | Load the config
cliConfigLoad :: CLI -> IO (Application, Podenv.Application.Mode, Name, Maybe BuildEnv, RuntimeEnv)
cliConfigLoad cli@CLI {..} = do
  system <- Podenv.Config.loadSystem
  config <- Podenv.Config.load selector configExpr
  (args, (builderM, baseApp)) <- mayFail $ Podenv.Config.select config (maybeToList selector <> extraArgs)
  let app = cliPrepare cli args baseApp
      be = Podenv.Build.initBuildEnv app <$> builderM
      name' = Name $ fromMaybe (app ^. appName) name
      re = RuntimeEnv {verbose, system}
      mode = if shell then Podenv.Application.Shell else Podenv.Application.Regular
  pure (app, mode, name', be, re)

-- | Apply the CLI argument to the application
cliPrepare :: CLI -> [Text] -> Application -> Application
cliPrepare CLI {..} args = modifiers
  where
    modifiers = setShell . setEnvs . setVolumes . setCaps . setNS . addArgs

    addArgs = appCommand %~ (<> args)

    setNS = maybe id (appNamespace ?~) namespace

    setShell = bool id setShellCap shell
    setShellCap = appCapabilities %~ (capTerminal .~ True) . (capInteractive .~ True)

    setEnvs app' = foldr (\v -> appEnviron %~ (v :)) app' cliEnv

    setVolumes app' = foldr (\v -> appVolumes %~ (v :)) app' volumes

    setCaps app' = foldr (appCapabilities %~) app' capsOverride

showApp :: Application -> Context -> Maybe BuildEnv -> RuntimeEnv -> Text
showApp Application {..} ctx beM re = unlines infos
  where
    infos =
      maybe [] (\be -> ["[+] runtime: " <> beName be, beInfos be, ""]) beM
        <> ["[+] Capabilities", unwords appCaps, ""]
        <> ["[+] Command", cmd]
    cmd = Podenv.Runtime.showPodmanCmd re ctx
    appCaps = concatMap showCap Podenv.Application.capsAll
    showCap Podenv.Application.Cap {..} =
      [capName | capabilities ^. capLens]

printCaps :: IO ()
printCaps = do
  putText $ unlines $ sort $ map showCap Podenv.Application.capsAll
  where
    showCap Podenv.Application.Cap {..} =
      capName <> "\t" <> capDescription

printApps :: Maybe Text -> IO ()
printApps configTxt = do
  config <- Podenv.Config.load Nothing configTxt
  let atoms = sortOn fst $ case config of
        Podenv.Config.ConfigDefault app -> [("default", Podenv.Config.Lit app)]
        Podenv.Config.ConfigApplication atom -> [("default", atom)]
        Podenv.Config.ConfigApplications xs -> xs
      showApp' (Podenv.Config.ApplicationRecord app) =
        "Application" <> maybe "" (\desc -> " (" <> desc <> ")") (app ^. appDescription)
      showConfig = \case
        Podenv.Config.Lit app -> showApp' app
        Podenv.Config.LamArg name f -> "λ " <> show name <> " → " <> showApp' (f ("<" <> show name <> ">"))
        Podenv.Config.LamApp _ -> "λ app → app"
      showAtom (name, app) = name <> ": " <> showConfig app
  traverse_ (putTextLn . showAtom) atoms
