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

import Data.Either.Extra

import DateSet
import qualified JSONParser as JP

validateLine :: String -> IO ()
validateLine encoded = case JP.fromString encoded of
  Right decoded -> pVal stderr ("A:" ++ encoded) decoded
  Left  err     -> pVal stderr ("B:" ++ encoded) err

pVal :: Show a => Handle -> String -> a -> IO ()
pVal h raw decoded = do
  hPutStr h raw
  hPutStr h "|"
  hPutStrLn h $ show decoded

validateDS :: Handle -> IO ()
validateDS h = do
  encoded <- hGetContents h
  for_ (lines encoded) validateLine

fromFile :: String -> IO [DateSet]
fromFile path = do
  cts <- readFile path
  return $ fromRight' <$> JP.fromString <$> lines cts

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["validate"] -> validateDS stdin
    _            -> error $ "Invalid cmd: " ++ show args
