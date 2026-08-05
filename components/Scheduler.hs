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
import Debug.Trace(trace)

import Data.Either.Extra
import Text.Parse

import DateSet
import qualified Interval as Interval
import Interval(Interval(..), TimePeriod(..))
import qualified JSONParser as JP
import Parser

validate :: String -> IO ()
validate encoded = case JP.fromString encoded of
  Right decoded -> putStrLn $ show decoded
  Left  err     -> pErr $ "B:" ++ encoded ++ "|" ++ err

pErr :: String -> IO ()
pErr err = hPutStrLn stderr err

forLines :: Handle -> (String -> IO ()) -> IO ()
forLines h f = do
  encoded <- hGetContents h
  for_ (lines encoded) f

fromFile :: String -> IO [DateSet]
fromFile path = do
  cts <- readFile path
  return $ fromRight' <$> JP.fromString <$> lines cts

preview :: String -> String -> IO ()
preview window expr =
  let expr' = case JP.fromString expr of
        Left err -> error err
        Right e -> e
      w = case runParser parseTimePeriod window of
        (Right w, _) -> w
        _ -> error "invalid interval"
  in for_ (intervals expr' w) $ putStrLn . show

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["validate"]   -> forLines stdin validate
    ["preview", w] -> forLines stdin $ preview w
    _              -> error $ "Invalid cmd: " ++ show args
