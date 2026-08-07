{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}

module Scheduler (
  validateDS,
  preview
) where

import Control.Monad
import Data.Foldable
import System.IO
import System.Environment
import Debug.Trace(trace)

import Data.Either.Extra
import Text.Parse
import Data.Time.Calendar
import Data.Time.Calendar.Month
import Data.Time.Clock
import Data.Tuple.Utils
import Data.Time.Format

import DateSet
import qualified Interval as Interval
import Interval(DateTime, Interval(..), TimePeriod(..), (|+))
import qualified JSONParser as JP
import Parser

validateDS :: String -> IO ()
validateDS encoded = case JP.fromString encoded of
  Right decoded -> putStrLn $ show decoded
  Left  err     -> pErr $ "B:" ++ encoded ++ "|" ++ err

pErr :: String -> IO ()
pErr err = hPutStrLn stderr err

fromFile :: String -> IO [DateSet]
fromFile path = do
  contents <- readFile path
  return $ fromRight' <$> JP.fromString <$> lines contents

reverseVideo :: String -> String
reverseVideo s = "\x1b[7m" ++ s ++ "\x1b[m"

showMonth :: MonthOfYear -> String
showMonth  1 = "January"
showMonth  2 = "February"
showMonth  3 = "March"
showMonth  4 = "April"
showMonth  5 = "May"
showMonth  6 = "June"
showMonth  7 = "July"
showMonth  8 = "August"
showMonth  9 = "September"
showMonth 10 = "October"
showMonth 11 = "November"
showMonth 12 = "December"

formatDay :: Day -> String
formatDay d =
  let day = thd3 $ toGregorian d
  in if day < 10
     then " " ++ show day
     else show day

printDay :: DateSet -> Day -> IO ()
printDay ds day = do
  if DateSet.within ds (Interval.fromDay day)
    then putStr $ reverseVideo $ formatDay day
    else putStr $ formatDay day
  case dayOfWeek day of
    Saturday -> putStrLn ""
    _      -> putStr " "

previewMonth :: DateSet -> TimePeriod -> IO ()
previewMonth ds w = for_ (Interval.sequenceMonths w) $ \month -> do
  let (YearMonth y m) = month
  let (first : days) = periodAllDays month
  putStrLn $ showMonth m ++ " " ++ show y
  putStrLn "Su Mo Tu We Th Fr Sa"
  putStr $ (replicate (3 * (fromEnum (dayOfWeek first))) ' ')
  printDay ds first
  for_ days (printDay ds)
  putStr "\n\n"

previewWeek :: DateSet -> TimePeriod -> IO ()
previewWeek ds w = do
  for_ (Interval.sequenceWeeks w) $ \week -> do
    putStrLn $ formatTime defaultTimeLocale "%Y-%m-%d" (head week)
    putStrLn "      | Su | Mo | Tu | We | Th | Fr | Sa"
    for_ (Interval.sequenceTime
          (Interval.hour *  8)
          (Interval.hour * 23)
          (Interval.minute * 30)) $ \time -> do
      putStr $ formatTime defaultTimeLocale "%0H:%0M" time ++ " "
      for_ week $ \day -> do
        if DateSet.within ds $ (Interval.fromDay day) |+ time
          then putStr $ "|" ++ reverseVideo "    "
          else putStr   "|    "
      putStrLn ""
    putStrLn ""

preview :: String -> String -> String -> IO ()
preview mode window expr =
  let expr' = case JP.fromString expr of
        Left err -> error err
        Right e -> e
      w = case runParser parseTimePeriod window of
        (Right w, _) -> w
        _ -> error "invalid interval"
  in case mode of
    "list"  -> for_ (intervals expr' w) $ putStrLn . show
    "month" -> previewMonth expr' w
    "week"  -> previewWeek  expr' w

completionGraph :: DateSet -> [DateTime] -> TimePeriod -> IO ()
completionGraph self history window = do
  for_ (completions self history window) $ \(i, complete) ->
    if complete
      then putStr "|"
      else putStr "."
  putStrLn ""
