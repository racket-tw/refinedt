{-# LANGUAGE QuasiQuotes #-}

module TestUtils where

import Control.Monad
import Control.Monad.IO.Class
import Data.Bifunctor
import Data.Either
import Data.String.Interpolate
import Data.String.Interpolate.Util
import Data.Void
import Test.Hspec
import Text.Megaparsec
import Text.SExpression

import Idris.IdeModeClient
import Toy.Language.Parser
import Toy.Language.Syntax.Decls

parse' :: Parsec Void String a -> String -> Either ErrorMsg a
parse' p = first (ErrorMsg . errorBundlePretty) . runParser (p <* eof) ""

newtype ErrorMsg = ErrorMsg { getErrorMsg :: String } deriving (Eq)

instance Show ErrorMsg where
  show = getErrorMsg

infixr 0 ~~>
(~~>) :: (Show err, Eq err, Show r, Eq r) => Either err r -> r -> Expectation
parseRes ~~> expected = parseRes `shouldBe` Right expected

testWithIdris :: SpecWith IdrisHandle -> SpecWith ()
testWithIdris = parallel . beforeAll startIdris . afterAll stopIdris

testParseFunWithCtx :: String -> IO ([FunSig], (FunSig, FunDef))
testParseFunWithCtx str =
  case parseRes of
       Right r -> pure r
       _ -> do
          parseRes `shouldSatisfy` isRight
          error "expected Right"
  where
    parseRes = parse' funWithCtx $ unindent str

isReturn :: SExpr -> Bool
isReturn (List (Atom ":return" : _)) = True
isReturn _ = False

isOkReply :: SExpr -> Bool
isOkReply (List [Atom ":return", List (Atom ":ok" : _), _]) = True
isOkReply _ = False

testIdrisFile :: MonadIO m => File -> IdrisClientT m ()
testIdrisFile file = do
  sendCommand $ loadFile file
  replies <- unfoldWhileIncludingM (not . isReturn) readReply
  unless (isOkReply $ last replies) $ do
    liftIO $ mapM_ print replies
    dumpFile file
  liftIO $ last replies `shouldSatisfy` isOkReply

-- TODO move that to monad-loops
unfoldWhileIncludingM :: Monad m => (a -> Bool) -> m a -> m [a]
unfoldWhileIncludingM p m = loop id
    where
        loop f = do
            x <- m
            if p x
                then loop (f . (x:))
                else return (f [x])

writePrelude :: File -> IdrisClientT m ()
writePrelude file = write file [i|
import Data.List

intLength : List a -> Int
intLength = cast . length

smt : a
smt = believe_me ()
|]
