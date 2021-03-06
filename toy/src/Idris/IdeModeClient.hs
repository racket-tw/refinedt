{-# LANGUAGE QuasiQuotes, RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE GADTs, KindSignatures #-}

module Idris.IdeModeClient
( sendCommand
, readReply
, withFile
, write
, dumpFile

, typeCheck
, loadFile
, File

, IdrisHandle
, withIdris
, startIdris
, stopIdris
, runIdrisClient
, IdrisClientT
) where

import qualified Data.ByteString.Char8 as BS
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception(bracket)
import Control.Monad
import Control.Monad.Catch(MonadMask, finally)
import Control.Monad.Extra
import Control.Monad.IO.Class
import Control.Monad.Operational
import Data.Default
import Data.Kind
import Data.String
import Data.String.Interpolate.IsString
import Data.Void
import GHC.Conc
import Numeric
import System.Directory.Extra
import System.FilePath
import System.IO(Handle, hPutStrLn, hFlush, hGetContents, hSeek, SeekMode(..))
import System.IO.Temp
import System.Process
import Text.Megaparsec
import Text.SExpression

newtype Command = Command { commandStr :: String } deriving (IsString)

data File = File
  { handle :: Handle
  , path :: FilePath
  }

data IdrisAction :: (Type -> Type) -> Type -> Type where
  SendCommand :: Command -> IdrisAction m ()
  ReadReply :: IdrisAction m SExpr
  Write :: File -> String -> IdrisAction m ()
  WithFile :: (File -> IdrisClientT m r) -> IdrisAction m r
  DumpFile :: File -> IdrisAction m ()

type IdrisClientT m = ProgramT (IdrisAction m) m

sendCommand :: Command -> IdrisClientT m ()
sendCommand = singleton . SendCommand

readReply :: IdrisClientT m SExpr
readReply = singleton ReadReply

write :: File -> String -> IdrisClientT m ()
write f s = singleton $ Write f s

dumpFile :: File -> IdrisClientT m ()
dumpFile f = singleton $ DumpFile f

withFile :: (File -> IdrisClientT m r) -> IdrisClientT m r
withFile = singleton . WithFile

typeCheck :: String -> Command
typeCheck ty = [i|((:type-of "#{ty}") 1)|]

loadFile :: File -> Command
loadFile file = [i|((:load-file "#{path file}") 1)|]

parseIdrisResponse :: String -> Either (ParseErrorBundle String Void) SExpr
parseIdrisResponse = runParser (parseSExpr def <* eof) ""

withIdris :: IdrisClientT IO r -> IO r
withIdris prog = bracket
  startIdris
  stopIdris
  (`runIdrisClient` prog)

checkVersion :: Monad m => IdrisClientT m ()
checkVersion = do
  reply <- readReply
  case reply of
       List [Atom ":protocol-version", Number 1, Number 0] -> pure ()
       List [Atom ":protocol-version", Number 2, Number 0] -> pure ()
       _ -> error [i|Unknown protocol: #{reply}|]

newtype IdrisInstance = IdrisInstance (Handle, Handle, Handle, ProcessHandle)
newtype IdrisHandle = IdrisHandle { instancesTVar :: TVar [IdrisInstance] }

startIdris :: IO IdrisHandle
startIdris = IdrisHandle <$> do
  instances <- replicateConcurrently numCapabilities startIdrisInstance
  newTVarIO instances

-- assumes all handles have been returned to the pool
stopIdris :: IdrisHandle -> IO ()
stopIdris IdrisHandle { .. } = do
  instances <- readTVarIO instancesTVar
  mapM_ stopIdrisInstance instances

startIdrisInstance :: IO IdrisInstance
startIdrisInstance = do
  ih <- IdrisInstance <$> runInteractiveCommand "idris2 --ide-mode"
  runIdrisClientInst ih checkVersion
  pure ih

stopIdrisInstance :: IdrisInstance -> IO ()
stopIdrisInstance (IdrisInstance (stdin, stdout, stderr, ph)) = cleanupProcess (Just stdin, Just stdout, Just stderr, ph)

runIdrisClient :: (MonadMask m, MonadIO m) => IdrisHandle -> IdrisClientT m r -> m r
runIdrisClient IdrisHandle { .. } act = do
  inst <- liftIO $ atomically $ do
    available <- readTVar instancesTVar
    when (null available) retry
    writeTVar instancesTVar $ tail available
    pure $ head available
  res <- runIdrisClientInst inst act
  liftIO $ atomically $ modifyTVar' instancesTVar (inst:)
  pure res

runIdrisClientInst :: (MonadMask m, MonadIO m) => IdrisInstance -> IdrisClientT m r -> m r
runIdrisClientInst ih@(IdrisInstance (idrStdin, idrStdout, _, _)) = viewT >=> go
  where
    go (Return val) = pure val
    go (act :>>= cont) = intAct act >>= viewT . cont >>= go

    intAct :: (MonadMask m, MonadIO m) => IdrisAction m r -> m r
    intAct (SendCommand cmd) = do
      liftIO $ hPutStrLn idrStdin $ fmtLength cmd <> commandStr cmd
      liftIO $ hFlush idrStdin
    intAct ReadReply = liftIO $ do
      countStr <- BS.unpack <$> BS.hGet idrStdout 6
      line <- BS.hGet idrStdout $ read $ "0x" <> countStr
      case parseIdrisResponse $ BS.unpack line of
           Right val -> pure val
           Left err -> error $ unlines [BS.unpack line, show err]
    intAct (Write f s) = liftIO $ hPutStrLn (handle f) s >> hFlush (handle f)
    intAct (WithFile act) = withTempFile "" "toyidris.idr" $ \path handle ->
      runIdrisClientInst ih (act File { .. })
        `finally` cleanupIdrisFiles path
    intAct (DumpFile f) = liftIO $ hSeek (handle f) AbsoluteSeek 0 >> hGetContents (handle f) >>= putStrLn

cleanupIdrisFiles :: MonadIO m => FilePath -> m ()
cleanupIdrisFiles path = liftIO $ do
  removeFile' $ "build/ttc/" <> path -<.> "ttc"
  removeFile' $ "build/ttc/" <> path -<.> "ttm"
  where
    removeFile' p = whenM (doesFileExist p) $ removeFile p

fmtLength :: Command -> String
fmtLength cmd = replicate (6 - length hex) '0' <> hex
  where
    hex = showHex (length (commandStr cmd) + 1) ""
