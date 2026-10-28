module Main (main) where

import BudgetEngine
import Data.Aeson (encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import System.Exit (exitFailure)
import System.IO (stdin, stdout, stderr, hSetBinaryMode, hPutStrLn)

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  raw <- BS.hGet stdin (16 * 1024 * 1024 + 1)
  if BS.length raw > 16 * 1024 * 1024
    then invalid "input exceeds 16 MiB"
    else case parseRequest (BL.fromStrict raw) of
      Left message -> invalid message
      Right request -> BL.putStr (encode (summaryJSON (calculate request)) <> BL.singleton 10)
  where invalid message = hPutStrLn stderr ("budget-engine: " ++ message) >> exitFailure
