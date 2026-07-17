{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}

module Brainbox.Scheduler where

import Data.Foldable
import System.IO
import System.Environment

import Text.JSON

import qualified JSONParser as JP

validateLine :: String -> IO ()
validateLine encoded = case decodeStrict encoded of
  Ok val -> case JP.fromJSON $ JP.simplify val of
    Left  err     -> pVal stderr ("A:" ++ encoded) err
    Right decoded -> pVal stdout encoded decoded
  Error err -> pVal stderr ("B:" ++ encoded) err

pVal :: Show a => Handle -> String -> a -> IO ()
pVal h raw decoded = do
  hPutStr h raw
  hPutStr h "|"
  hPutStrLn h $ show decoded

validateDS :: Handle -> IO ()
validateDS h = do
  encoded <- hGetContents h
  for_ (lines encoded) validateLine

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["validate"] -> validateDS stdin
    _            -> error $ "Invalid cmd: " ++ show args
