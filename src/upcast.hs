{-# LANGUAGE QuasiQuotes, TemplateHaskell, OverloadedStrings, RecordWildCards, NamedFieldPuns #-}

module Main where

import Upcast.Monad
import Options.Applicative

import System.Directory (removeFile)
import System.Posix.Env (getEnvDefault)
import System.Posix.Files (readSymbolicLink)
import System.FilePath.Posix

import Data.List (intercalate)
import qualified Data.Text as T
import Data.Text (Text(..))
import Data.Maybe (catMaybes)
import qualified Data.Map as Map
import qualified Data.ByteString.Char8 as B8

import Upcast.Types
import Upcast.IO
import Upcast.Interpolate (nl, n)
import Upcast.Nix
import Upcast.Infra
import Upcast.DeployCommands
import Upcast.Command
import Upcast.Temp
import Upcast.Environment
import Upcast.Install

evalInfraContext :: NixContext -> IO InfraContext
evalInfraContext nix@NixContext{nix_expressionFile=file} = do
  value <- expectRight $ nixValue <$> fgconsume_ (nixDeploymentInfo nix)
  return InfraContext{ inc_expressionFile = file
                     , inc_stateFile = replaceExtension file "store"
                     , inc_data = value
                     }

icontext :: FilePath -> IO InfraContext
icontext = nixContext >=> evalInfraContext

infra :: FilePath -> IO [Machine]
infra = icontext >=> evalInfra

infraDump :: FilePath -> IO ()
infraDump = icontext >=> pprint . inc_data

infraDebug :: FilePath -> IO ()
infraDebug = icontext >=> debugEvalInfra >=> const (return ())

run :: RunCli -> IO ()
run RunCli{..} = do
  nix <- nixContext rc_expressionFile
  machines' <- evalInfra =<< evalInfraContext nix
  let machines = [m | m@Machine{..} <- machines', m_nix]
      dm = toDelivery rc_pullFrom
  when (null machines) $ oops "no Nix instances, plan complete"

  case rc_closureSubstitutes of
      Nothing ->
        buildThenInstall nix dm machines
      Just s ->
        installMachines dm
        (maybe (error "closure not found") return . flip Map.lookup s) machines

buildThenInstall :: NixContext -> DeliveryMode -> [Machine] -> IO ()
buildThenInstall ctx dm machines = do
  closuresPath <- randomTempFileName "machines."

  expect ExitSuccess "nix build of machine closures failed" $
    fgrun $ nixBuildMachines ctx $ Just closuresPath

  prepAuth $ catMaybes $ fmap m_keyFile machines
  installMachines dm (readSymbolicLink . (closuresPath </>) . T.unpack) machines

build :: FilePath -> IO ()
build = nixContext >=>
  expect ExitSuccess "build failed" .  fgrun . flip nixBuildMachines Nothing

buildRemote :: BuildRemoteCli -> IO ()
buildRemote BuildRemoteCli{..} = do
  let remote = Remote Nothing brc_builder
  drv <-
    case brc_attribute of
        Nothing -> nixContext brc_expressionFile >>= instantiateTmp
        Just attr -> do
          args <- getEnvDefault "UPCAST_NIX_FLAGS" ""
          fgtmp $ nixInstantiate args attr brc_expressionFile

  srsly "nix-copy-closure failed" . fgrun $ nixCopyClosureTo brc_builder drv
  srsly "realise failed" . fgrun . ssh . forward remote $ nixRealise drv
  p <- fgconsume_ . ssh $ Cmd remote [n|cat $(nix-store -qu #{drv})|] "query"
  B8.putStrLn p

instantiate :: FilePath -> IO ()
instantiate = nixContext >=> instantiateTmp >=> putStrLn

instantiateTmp :: NixContext -> IO FilePath
instantiateTmp ctx = fgtmp $ nixInstantiateMachines ctx

sshConfig :: FilePath -> IO ()
sshConfig = infra >=> putStrLn . intercalate "\n" . fmap config
  where
    identity (Just file) = T.concat ["\n    IdentityFile ", file, "\n"]
    identity Nothing = ""

    config Machine{..} = [nl|
Host #{m_hostname}
    # #{m_instanceId}
    HostName #{m_publicIp}
    User root#{identity m_keyFile}
    ControlMaster auto
    ControlPath ~/.ssh/master-%r@%h:%p
    ForwardAgent yes
    ControlPersist 60s
|]

printNixPath :: IO ()
printNixPath = do
  Just p <- nixPath
  putStrLn p

fgtmp :: (FilePath -> Command Local) -> IO FilePath
fgtmp f = do
  tmp <- randomTempFileName "fgtmp."
  let cmd@(Cmd _ _ tag) = f tmp
  expect ExitSuccess (tag <> " failed") $ fgrun cmd
  dest <- readSymbolicLink tmp
  removeFile tmp
  return dest

main :: IO ()
main = do
    hSetBuffering stderr LineBuffering
    join $ customExecParser prefs opts
  where
    prefs = ParserPrefs { prefMultiSuffix = ""
                        , prefDisambiguate = True
                        , prefShowHelpOnError = True
                        , prefBacktrack = True
                        , prefColumns = 80
                        }

    args comm = comm <$> argument str exp
    exp = metavar "<expression>"

    opts = (subparser cmds) `info` header "upcast - infrastructure orchestratrion"

    cmds = command "run"
           (run <$> runCli `info`
            progDesc "evaluate infrastructure, run builds and deploy")

        <> command "infra"
           (args sshConfig `info`
            progDesc "evaluate infrastructure and output ssh_config(5)")

        <> command "infra-tree"
           (args infraDump `info`
            progDesc "dump infrastructure tree in json format")

        <> command "infra-debug"
           (args infraDebug `info`
            progDesc "evaluate infrastructure in debug mode")

        <> command "instantiate"
           (args instantiate `info`
            progDesc "nix-instantiate all NixOS closures")

        <> command "build"
           (args build `info`
            progDesc "nix-build all NixOS closures")

        <> command "build-remote"
           (buildRemote <$> buildRemoteCli `info`
            progDesc "nix-build all NixOS closures remotely")

        <> command "nix-path"
           (pure printNixPath `info`
            progDesc "print effective path to upcast nix expressions")

        <> command "install"
           (install <$> installCli `info`
            progDesc "install nix environment-like closure over ssh")

    installCli = InstallCli
      <$> strOption (long "target"
                     <> short 't'
                     <> metavar "ADDRESS"
                     <> help "SSH-accessible host with Nix")
      <*> optional (strOption
                    (long "profile"
                     <> short 'p'
                     <> metavar "PROFILE"
                     <> help "attach CLOSURE to PROFILE (otherwise system)"))
      <*> pullOption
      <*> argument str (metavar "CLOSURE")

    buildRemoteCli = BuildRemoteCli
      <$> strOption (long "target"
                    <> short 't'
                    <> metavar "ADDRESS"
                    <> help "SSH-accessible host with Nix")
      <*> optional (strOption (short 'A'
                     <> metavar "ATTRIBUTE"
                     <> help "build a specific attribute in the expression file \
                             \(`nix-build'-like behaviour)"))
      <*> argument str exp
